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

## Setup from a new IR Mate

1. **WiFi.** Out of the box it broadcasts `xiao-smart-ir-mate-XXXXXX`
   (password `12345678`). Join it, open `http://192.168.4.1`, and save your
   2.4 GHz network. Or skip the browser:
   `curl -G --data-urlencode ssid=... --data-urlencode psk=... http://192.168.4.1/wifisave`
   (HTTP 302 means it was saved).
2. **Flash this firmware over the air.** Put `bedroom-ac-ir.yaml` and your
   `secrets.yaml` in an ESPHome config dir. The first OTA must use Seeed's stock
   OTA password (see `secrets.example.yaml`). With Docker:
   ```bash
   docker run --rm --network host -v "$PWD":/config ghcr.io/esphome/esphome:2026.10.2 \
     run bedroom-ac-ir.yaml --device <ip>
   ```
   The ESPHome Device Builder add-on works too: drop the file into `/config/esphome/`.
3. **Add to Home Assistant.** Use Settings → Devices → Add integration →
   ESPHome, with the device's IP and port 6053. Then open the entry's
   **Configure** and enable **"Allow the device to perform Home Assistant
   actions"**. It is enabled on the reference install. Whether the
   `homeassistant.event` calls need it hasn't been tested, so enable it to be
   safe.
4. **Install the package:** copy `home-assistant/bedroom_ac.yaml` to
   `/config/packages/`, run `ha core check`, then reload all YAML.

Pins (XIAO ESP32-C3): IR TX GPIO3 (D1), IR RX GPIO4 (D2, inverted), WS2812
LED GPIO7 (D5), vibration motor GPIO6 (D4).

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
