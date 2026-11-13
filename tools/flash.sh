#!/usr/bin/env bash
# Build this firmware and flash it to a XIAO Smart IR Mate over WiFi (OTA).
#
#   tools/flash.sh <device-ip>             # build + flash
#   tools/flash.sh <device-ip> --logs      # build + flash, then follow the device log
#   tools/flash.sh --compile-only          # just build
#
# Needs Docker (or Podman with a docker alias) and a secrets file at
# esphome/secrets.yaml (copy esphome/secrets.example.yaml and fill it in).
# The first build downloads the ESP-IDF toolchain into esphome/.esphome/
# (about 1 GB, 10-20 minutes); later builds take a minute or two.
#
# First flash from Seeed's stock firmware: keep bedroom_ac_ir_ota_password set
# to the stock password from secrets.example.yaml. ESPHome authenticates
# the upload with the password in YOUR config, and the stock firmware expects
# Seeed's. To change it later, follow ESPHome's "changing the OTA password"
# procedure; a plain edit of the secret makes the next upload fail to authenticate.
set -euo pipefail

ESPHOME_VERSION="${ESPHOME_VERSION:-2026.10.2}"
CONFIG="bedroom-ac-ir.yaml"
here="$(cd "$(dirname "$0")/.." && pwd)"
cfg_dir="$here/esphome"

usage() { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

[ $# -ge 1 ] || usage
if [ ! -f "$cfg_dir/secrets.yaml" ]; then
  echo "Missing $cfg_dir/secrets.yaml - copy secrets.example.yaml and fill it in." >&2
  exit 1
fi

run() {
  local tty=()
  [ -t 0 ] && [ -t 1 ] && tty=(-t)
  docker run --rm -i "${tty[@]}" --network host -v "$cfg_dir":/config \
    "ghcr.io/esphome/esphome:${ESPHOME_VERSION}" "$@"
}

if [ "$1" = "--compile-only" ]; then
  run compile "$CONFIG"
  exit 0
fi

ip="$1"
if ! [[ "$ip" =~ ^[0-9a-zA-Z.:-]+$ ]]; then
  echo "Not an IP address or hostname: $ip" >&2
  exit 1
fi

if [ "${2:-}" = "--logs" ]; then
  run run "$CONFIG" --device "$ip"
else
  run run "$CONFIG" --device "$ip" --no-logs
fi

echo
echo "Flashed. The device restarts in a few seconds. Local web page: http://$ip/"
