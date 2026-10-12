# Free Spoofer

Free macOS app for spoofing your iPhone's GPS location: teleport, joystick, unlimited routes, any speed.

Built on [pymobiledevice3](https://github.com/doronz88/pymobiledevice3) and Apple's developer location-simulation service (the same one Xcode uses).

## Features
- Click the map to teleport, or search a place / `lat, lon`
- Joystick (drag pad or WASD / arrow keys)
- Routes that follow roads (walk / bike / car) or straight lines, GPX import, loop, jitter
- Any speed, adjustable live; smooth updates up to 10/sec at high speed
- Unlimited saved routes

## Requirements
- macOS 13+, Xcode command line tools (`swiftc`)
- iPhone on iOS 17+ with Developer Mode on, plugged in and trusted
- Python packages: `pip3 install --user pymobiledevice3 fastapi uvicorn`

## Build
```bash
./mac/build.sh
```
This creates `Free Spoofer.app`; move it to `/Applications`. On launch it asks for your Mac password once to start the device tunnel.

Without the app wrapper: `./start.sh` and open http://127.0.0.1:8765.

## Files
- `spoofer.py` – location engine + local web API
- `index.html` – map UI
- `mac/main.swift` – native app window, launches everything
- `mac/build.sh` – builds the .app; `mac/make_icon.swift` draws `mac/icon.png`

Made by [bracky-dev](https://github.com/bracky-dev).
