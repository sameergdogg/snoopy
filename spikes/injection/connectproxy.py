import socket, threading, sys
def pipe(a,b):
    try:
        while True:
            d=a.recv(65536)
            if not d: break
            b.sendall(d)
    except Exception: pass
    finally:
        try: a.close(); b.close()
        except Exception: pass
def handle(c):
    req=b""
    while b"\r\n\r\n" not in req: req+=c.recv(4096)
    line=req.split(b"\r\n")[0].decode(); print("PROXY:",line,flush=True)
    if line.startswith("CONNECT"):
        host,port=line.split()[1].split(":"); u=socket.create_connection((host,int(port)))
        c.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        threading.Thread(target=pipe,args=(c,u),daemon=True).start(); pipe(u,c)
    else: c.close()
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(("127.0.0.1",8888)); s.listen(16)
while True:
    c,_=s.accept(); threading.Thread(target=handle,args=(c,),daemon=True).start()
