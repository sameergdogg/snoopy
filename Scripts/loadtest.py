#!/usr/bin/env python3
"""Blast a running Snoopy with synthetic capture traffic.

Reproduces the load profile that made the app beachball: a chatty app producing many
exchanges a second with large JSON bodies. Use it to check the UI stays interactive and
that resident memory stays inside the store's budget.

    ./Scripts/loadtest.py --count 20000 --body-kb 64 --rate 800
"""
import argparse, base64, json, os, random, socket, struct, sys, time, uuid

HOSTS = ["api.duolingo.com", "goals-api.duolingo.com", "excess.duolingo.com",
         "stories.duolingo.com", "simg-ssl.duolingo.com"]
PATHS = ["/2017-06-30/users/12345", "/2017-06-30/sessions", "/api/1/version_info",
         "/batch", "/2017-06-30/friends/users/1/scores", "/vendor/sprite.png"]


def frame(sock, obj):
    payload = json.dumps(obj).encode()
    sock.sendall(struct.pack(">I", len(payload)) + payload)


def big_json_body(kb):
    """A payload shaped like a real API response, not incompressible noise."""
    items = []
    # ~120 bytes per item, so scale the count to hit the requested size.
    for i in range(max(1, (kb * 1024) // 120)):
        items.append({"id": i, "name": f"skill_{i}", "xp": random.randint(0, 9999),
                      "learned": random.choice([True, False]),
                      "url": f"https://d2.duolingo.com/images/{uuid.uuid4().hex}.svg"})
    return json.dumps({"fromLanguage": "en", "learningLanguage": "es", "items": items}).encode()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--socket", help="defaults to the newest /tmp/snoopy-*.sock")
    ap.add_argument("--count", type=int, default=5000, help="exchanges to send")
    ap.add_argument("--body-kb", type=int, default=32, help="approx response body size")
    ap.add_argument("--rate", type=float, default=500.0, help="exchanges per second (0 = as fast as possible)")
    args = ap.parse_args()

    path = args.socket
    if not path:
        socks = [f"/tmp/{f}" for f in os.listdir("/tmp") if f.startswith("snoopy-") and f.endswith(".sock")]
        if not socks:
            sys.exit("no /tmp/snoopy-*.sock found — is Snoopy running?")
        path = max(socks, key=lambda p: os.stat(p).st_mtime)

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(path)
    print(f"connected to {path}")

    frame(s, {"type": "hello", "pid": os.getpid(), "process": "Duolingo", "bundleId": "com.duolingo.DuolingoMobile"})

    # Prebuild a few bodies so the generator's own JSON cost doesn't throttle the test.
    bodies = [base64.b64encode(big_json_body(args.body_kb)).decode() for _ in range(8)]
    raw_sizes = [len(base64.b64decode(b)) for b in bodies]

    started = time.time()
    interval = 1.0 / args.rate if args.rate > 0 else 0

    for i in range(args.count):
        xid = str(uuid.uuid4())
        now = time.time()
        host, path_ = random.choice(HOSTS), random.choice(PATHS)
        bi = i % len(bodies)

        frame(s, {"type": "request", "id": xid, "taskId": i, "t": now, "method":
                  random.choice(["GET", "GET", "GET", "POST", "PATCH"]),
                  "url": f"https://{host}{path_}",
                  "headers": {"Accept": "application/json", "User-Agent": "Duolingo/7.5.0",
                              "Authorization": "Bearer " + "x" * 180}})
        frame(s, {"type": "response", "id": xid, "t": now + 0.01, "status":
                  random.choices([200, 200, 200, 204, 304, 404, 500], [60, 15, 10, 5, 5, 3, 2])[0],
                  "mimeType": "application/json",
                  "headers": {"Content-Type": "application/json", "Server": "nginx"}})
        frame(s, {"type": "complete", "id": xid, "t": now + 0.05, "status": 200,
                  "mimeType": "application/json",
                  "headers": {"Content-Type": "application/json"},
                  "body": bodies[bi], "bodySize": raw_sizes[bi], "bodyTruncated": False,
                  "metrics": {"fetchStart": now, "dnsStart": now, "dnsEnd": now + 0.002,
                              "connectStart": now + 0.002, "connectEnd": now + 0.01,
                              "requestStart": now + 0.01, "requestEnd": now + 0.012,
                              "responseStart": now + 0.03, "responseEnd": now + 0.05,
                              "protocol": "h2", "remoteAddress": "104.18.0.1", "reused": True}})

        if interval:
            target = started + (i + 1) * interval
            slack = target - time.time()
            if slack > 0:
                time.sleep(slack)
        if i and i % 1000 == 0:
            print(f"  {i} sent ({i / (time.time() - started):.0f}/s)", flush=True)

    elapsed = time.time() - started
    mb = sum(raw_sizes) / len(raw_sizes) * args.count / 1e6
    print(f"sent {args.count} exchanges in {elapsed:.1f}s "
          f"({args.count / elapsed:.0f}/s, ~{mb:.0f} MB of bodies)")
    time.sleep(2)   # let the app drain before we close
    s.close()


if __name__ == "__main__":
    main()
