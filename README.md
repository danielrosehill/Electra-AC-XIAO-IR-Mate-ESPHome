# Electra central AC on a XIAO Smart IR Mate (ESPHome)

Custom ESPHome firmware for the **Seeed Studio XIAO Smart IR Mate**
(ESP32-C3, three IR LEDs plus an IR receiver, USB-C powered, about US$11), and
the Home Assistant package that drives it. It controls an **Electra / Tadiran
central (ducted) air conditioner**, the kind that comes with a generic
wall/handheld IR remote.

The firmware doesn't store learned codes. It **builds** each Electra frame on
the device from mode, temperature and fan, and it **decodes** every Electra
frame it hears. So when someone uses the handheld remote, Home Assistant's idea
of the AC state follows along, which a send-only blaster (such as a Broadlink
RM4) can't do.

The protocol itself (Manchester, 34-bit core, no checksum) was reverse-engineered
in the companion repo
[electra-central-ac-ir-codes](https://github.com/danielrosehill/electra-central-ac-ir-codes),
which has the codes, `electra_ir.py`, the raw captures and a write-up.

## Status

In daily use since 2026-11-13, replacing a Broadlink RM4C mini.

| Check | Result |
|---|---|
| Firmware frame builder vs the 120 published state codes + power toggle (`tools/verify_frames.py`) | identical at half-bit level |
| Transmit: `cool 19 high` sent from the IR Mate | AC accepted it (beep) |
| Receive: handheld remote set to `cool 19 med` | decoded as `0001010000001000000000000000000010` → cool / 19 / med |
| Sync gate: helper change while `bedroom_ac_ir_syncing` is on | no frame sent |
| Remote press → event → helpers updated, end to end | handheld set to cool/22/med → helper 19 → 22, nothing re-sent |

## Files

| Path | What |
|---|---|
| `esphome/bedroom-ac-ir.yaml` | Firmware config (ESPHome 2026.10.2, Arduino framework, web server on :80) |
| `esphome/secrets.example.yaml` | Secrets it expects |
| `home-assistant/bedroom_ac.yaml` | HA package: helpers, apply/toggle scripts, remote-sync automation |
| `tools/flash.sh` | Build + flash over WiFi with the ESPHome Docker image (`tools/flash.sh <device-ip>`) |
| `tools/verify_frames.py` | Proves the C++ frame builder matches the published codes |

## Protocol in one paragraph

Half-bit H ≈ 1041 µs (31.7 Broadlink ticks), 38 kHz carrier. One burst is 3
repeats of [mark 3H, space 3H, 34 Manchester bits (0 = mark-space, 1 =
space-mark)], then a 4H mark and a ~109 ms gap. Core bits: 0 = power-toggle
flag; 2-3 mode (cool `01`, heat `10`); 4-5 fan (low `00`, med `01`, high
`10`, auto `11`); 11-14 = °C − 15 (16-30 °C); bit 32 is always 1; all other
bits are 0. Power is a **toggle**, and state frames don't switch the unit on.

## Home Assistant interface

- **Send:** action `esphome.bedroom_ac_ir_send_frame` with
  `{toggle: bool, mode: cool|heat, temp: 16-30, fan: low|med|high|auto}`.
  The package's `script.bedroom_ac_power_toggle` sends `toggle: true` with
  cool / 19 / high, which is bit-for-bit the original remote capture.
- **Receive:** event `esphome.electra_ir_received` with
  `{toggle, mode, temp, fan, core}` (all strings). Automation
  `bedroom_ac_sync_from_remote` copies the event into the helpers and flips
  `input_boolean.bedroom_ac_on` on a toggle frame. While it does that,
  `input_boolean.bedroom_ac_ir_syncing` blocks `bedroom_ac_apply_on_change`,
  so nothing is re-sent.
- **Entities:** last received / last sent frame (text), WiFi signal, IP,
  restart button, status LED, firmware update.
- **Echo suppression:** the receiver ignores anything within 600 ms of the
  device's own transmission.

## Local web API (works with Home Assistant down)

The firmware runs ESPHome's web server (v3) on port 80, so the IR Mate can be
controlled directly with no Home Assistant and no extra server. URLs use the
entity **name**, URL-encoded. POSTs need a body, even an empty one (`-d ""`),
or the server answers `411`.

| Do | Request |
|---|---|
| Web page | `GET http://<device>/` |
| Set temperature (sends a full state frame) | `POST /number/AC%20temperature/set?value=22` |
| Set mode | `POST /select/AC%20mode/set?option=cool` (`cool`, `heat`) |
| Set fan | `POST /select/AC%20fan/set?option=high` (`low`, `med`, `high`, `auto`) |
| Power toggle (carries current mode/temp/fan, like the remote) | `POST /button/AC%20power%20toggle/press` |
| Read a setting | `GET /number/AC%20temperature`, `GET /select/AC%20fan` → `{"id":…,"value":…,"state":…}` |
| Last frame sent / heard | `GET /text_sensor/Last%20sent%20frame`, `GET /text_sensor/Last%20received%20frame` |

Every local command is also reported to HA as `esphome.electra_ir_received`
(`source: local`), so HA's helpers follow when HA is up. Commands from HA only
update these local controls and don't fire the event. These local entities are
`disabled_by_default` in HA, so they don't duplicate the package's helpers.

The device has no idea whether the AC is on: the power button is a toggle.
HA's "assumed on" helper is the only power state.

Verified 2026-11-13 21:24 UTC: `POST /number/AC%20temperature/set?value=22`
→ frame cool/22/med sent → HA sync automation ran → no re-send from HA.

## Voice (Home Assistant Assist)

- **Power:** `switch.house_ac`, a template switch with aliases (AC, Air
  conditioner, Aircon, Central AC). It toggles only when the assumed state
  differs, so "turn on the AC" when it is already on sends nothing. Don't
  expose `input_boolean.bedroom_ac_on` instead: switching it changes only
  HA's assumption, and no IR is sent.
- **Temperature, fan, mode:** Assist has no built-in intents for helpers, so
  automation `house_ac_voice` adds sentences such as "set the AC to 22", "make
  the AC warmer/cooler", "turn up/down the AC fan", "AC fan high", and
  "switch the AC to heating". Tested with `POST /api/conversation/process`.
- Watch for other exposed entities named "AC". Assist answers "multiple
  devices called AC" and won't act.

## Flashing tutorial: from a new IR Mate to this firmware

You need the IR Mate on USB-C power, a computer with Docker on the same
network, and a clone of this repo. No cable to the computer is needed:
everything goes over WiFi.

### 1. Get the stock device onto your WiFi

Out of the box the IR Mate runs Seeed's own ESPHome firmware and broadcasts a
setup hotspot, `xiao-smart-ir-mate-XXXXXX` (password `12345678`; the LED
blinks white).

- Join that hotspot from a phone or laptop. If the captive portal doesn't
  pop up, browse to `http://192.168.4.1`.
- Pick your **2.4 GHz** network and enter its password. The LED turns solid
  white once the device has joined.
- No browser? This does the same thing:
  ```bash
  curl -G --data-urlencode "ssid=YOUR_SSID" --data-urlencode "psk=YOUR_PASSWORD" \
    http://192.168.4.1/wifisave        # HTTP 302 = saved
  ```

### 2. Find its IP address

Look in your router's DHCP client list for `xiao-smart-ir-mate-XXXXXX`. A
DHCP reservation is worth adding now, so the address never moves. After this
firmware is flashed, the hostname becomes `bedroom-ac-ir`.

### 3. Fill in the secrets

```bash
cp esphome/secrets.example.yaml esphome/secrets.yaml
$EDITOR esphome/secrets.yaml      # your WiFi SSID + password
```

Leave `bedroom_ac_ir_ota_password` at the stock value for the first flash.
The stock firmware only accepts an upload signed with Seeed's published
password. `secrets.yaml` is gitignored.

### 4. Build and flash over WiFi

```bash
tools/flash.sh 192.0.2.10          # your device's IP
tools/flash.sh 192.0.2.10 --logs   # same, then follow the device log
```

`tools/flash.sh` runs the official ESPHome Docker image
(`ghcr.io/esphome/esphome`, pinned to the version this config was tested on;
override it with `ESPHOME_VERSION=...`). It compiles and uploads over the air.
The first build downloads the ESP-IDF toolchain into `esphome/.esphome/`
(about 1 GB, 10-20 minutes). After that, a rebuild plus upload takes a minute
or two, and the upload itself about 5 seconds. Use the same command for every
later update.

Prefer Home Assistant's **ESPHome Device Builder** add-on? Put
`bedroom-ac-ir.yaml` in `/config/esphome/`, add the secrets to its
`secrets.yaml`, and press Install → Wirelessly.

If the new firmware can't join your WiFi, it opens a fallback hotspot,
`Bedroom-AC-IR Fallback` (password `12345678`), where you can re-enter the
credentials.

### 5. Check it

Open `http://<device-ip>/`. You should see the AC controls, the WiFi signal
and the last sent/received frames. Change the temperature by one degree and
the AC should beep. That's the whole test: Electra central units have no
display.

### 6. (Optional) Add it to Home Assistant

1. Settings → Devices & services → Add integration → **ESPHome**, with the
   device's IP and port 6053.
2. Open the entry's **Configure** and enable **"Allow the device to perform
   Home Assistant actions"**. It is enabled on the reference install; whether
   the `homeassistant.event` calls need it hasn't been tested.
3. Copy `home-assistant/bedroom_ac.yaml` to `/config/packages/` (needs
   `homeassistant: packages: !include_dir_named packages`), run
   `ha core check`, then reload all YAML.

Pins (XIAO ESP32-C3): IR TX GPIO3 (D1), IR RX GPIO4 (D2, inverted), WS2812
LED GPIO7 (D5), vibration motor GPIO6 (D4).

## Using it without Home Assistant

Home Assistant is optional. The IR Mate serves its own web page and a small
REST API (the "Local web API" table above) straight over WiFi, so anything
that can make an HTTP request can drive the AC:

- **A browser or phone:** bookmark `http://<device-ip>/` (add it to your
  phone's home screen) and use it as a remote.
- **Shell:** a two-line function does it:
  ```bash
  ac() { curl -s -X POST -d "" "http://<device-ip>/$1"; }
  ac "number/AC%20temperature/set?value=23"
  ac "select/AC%20fan/set?option=high"
  ac "button/AC%20power%20toggle/press"
  ```
- **Schedules:** a cron job on any always-on machine, e.g. `0 22 * * *` set
  the temperature to 21 at night.
- **Other automation tools:** Node-RED, n8n, iOS Shortcuts / Android HTTP
  Shortcuts, a voice assistant webhook. Anything with an "HTTP request" step.

Things to know:

- The API is **unauthenticated** and plain HTTP. Keep the device on a trusted
  LAN or VLAN. To require a login, add `auth: {username: ..., password: ...}`
  under `web_server:` in the YAML and re-flash.
- Power is a **toggle**, and the device doesn't know whether the AC is on.
  Without HA, you (or your script) are the source of truth for on/off.
- If Home Assistant is also running, local commands are reported to it, and
  its helpers follow.

## Caveats

- The Electra unit has no display. HA's power state is *assumed*, and the
  remote sync is what keeps it honest. If someone presses the remote out of
  the IR Mate's line of sight, HA misses that change. In testing, a press
  aimed only at the AC was missed, so put the IR Mate near the AC's IR
  receiver, where it overhears whatever the AC hears.
- A state frame always carries mode, temp **and** fan together, so changing
  one re-asserts the other two from HA's helpers.
- Only cool and heat are implemented. Fan-only and dry exist on some Electra
  remotes and are deliberately left out.

## License

MIT
