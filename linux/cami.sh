#!/usr/bin/env bash
# Feeds the Cami iPhone stream into the v4l2loopback camera "iPhone Cam".
#   cami.sh                 USB (needs usbmuxd)
#   cami.sh 192.168.1.20    Wi-Fi, using the phone's IP
set -u
port=5000

dev=${CAMI_DEVICE:-}
if [[ -z $dev ]]; then
  for d in /sys/class/video4linux/video*; do
    [[ $(<"$d/name") == "iPhone Cam" ]] && dev=/dev/${d##*/}
  done
fi
[[ -n $dev ]] || { echo "No encuentro la cámara virtual 'iPhone Cam' (¿está cargado v4l2loopback?)" >&2; exit 1; }

host=${1:-127.0.0.1}
if [[ -z ${1:-} ]]; then
  # Explicit -s: despite its help text, iproxy listens on 0.0.0.0, exposing the camera to the LAN
  iproxy -s 127.0.0.1 "$port:$port" >/dev/null 2>&1 &
  proxy=$!
  trap 'kill $proxy 2>/dev/null' EXIT
fi

echo "iPhone -> $dev  (Ctrl+C para salir)"
while true; do
  # Wait quietly until the phone app sends a byte; otherwise ffmpeg would log errors every second
  until (( $(timeout 2 bash -c "head -c1 </dev/tcp/$host/$port" 2>/dev/null | wc -c) )); do sleep 2; done
  # GPU decode: low_delay turns off frame threading, and one CPU core can't decode 4K60 HEVC
  ffmpeg -hide_banner -loglevel error -hwaccel auto -flags low_delay -probesize 32 -analyzeduration 0 \
    -f hevc -i "tcp://$host:$port" -pix_fmt yuv420p -f v4l2 "$dev"
  sleep 1 # app closed or not open yet: retry
done
