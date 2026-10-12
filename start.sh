#!/bin/bash
# Starts tunneld (needs your Mac password once), mounts the Developer Disk Image, then the map UI.
cd "$(dirname "$0")"
export PYTHONWARNINGS=ignore
SITE="$(python3 -m site --user-site)"

if ! curl -s -m 2 http://127.0.0.1:49151/ >/dev/null; then
  echo "Starting tunneld (enter your Mac password)..."
  sudo env PYTHONPATH="$SITE" PYTHONWARNINGS=ignore python3 -m pymobiledevice3 remote tunneld -d || exit 1
  for i in $(seq 1 20); do curl -s -m 1 http://127.0.0.1:49151/ >/dev/null && break; sleep 1; done
fi

echo "Waiting for iPhone tunnel..."
for i in $(seq 1 30); do
  [ "$(curl -s -m 2 http://127.0.0.1:49151/)" != "{}" ] && break
  sleep 1
done

echo "Mounting Developer Disk Image (skips if already mounted)..."
python3 -m pymobiledevice3 mounter auto-mount --tunnel "" 2>&1 | tail -1

(sleep 2; open http://127.0.0.1:8765) &
python3 spoofer.py
