# SnoopyTest — example iOS app

A tiny SwiftUI app that exercises the network paths Snoopy captures: a GET, a POST with a
JSON body and auth header, an image download, a 404, and a delegate-based streaming request.
It fires them all on launch and via buttons.

```sh
# boot a simulator first (Xcode > Open Developer Tool > Simulator), then:
./build-and-install.sh                 # installs onto the booted simulator
```

Open Snoopy, pick the simulator, select **Snoopy Test**, and press **Run with Snoopy**.
You should see five requests appear live, including the POST body and the 404.
