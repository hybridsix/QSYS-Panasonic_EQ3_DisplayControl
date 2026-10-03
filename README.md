# Panasonic EQ3 Display Control - Q-SYS Plugin

**Author:** Michael King / Hybridsix  **Version:** 0.1.1  **Platform:** Q-SYS Designer, Panasonic TH-43EQ3W / TH-55EQ3W

A Q-SYS plugin that gives your Core direct control over a Panasonic EQ3 series display on the local network - power, input, volume, mute, backlight, aspect, picture mode, and live status, all from the schematic.

## Features

- Power on / off with live power state feedback
- Input selection (HDMI 1, HDMI 2, HDMI 3, PC, USB) with live feedback
- Volume (0-100) and audio mute, with mute LED
- Backlight (0-50), aspect ratio (Full / Normal / Native / Zoom) and picture mode (Dynamic / Graphic / Sports / Standard)
- Model and serial number read from the display; a warning if the display is not the model selected in Properties
- Optional command protect (Username / Password) - the display's greeting is followed automatically, so nothing needs to be configured when protect is off
- Configurable poll rate, with a temporary high-rate poll after a command until the status changes
- Raw command box for testing a documented command from the schematic
- Automatic reconnect if the display or network drops

## How it works

```
Q-SYS Core  ---- TCP :1024 ---->  Display
            <--- replies, state --
```

The plugin opens one TCP connection to the display and talks Panasonic's native LAN command protocol. All control handlers only queue a request; a single engine sends one request at a time, parses the reply, and updates the controls from what the display actually reports. Feedback is never optimistic. Polling is conservative and driven by power state.

On connect the display sends a greeting (`NTCONTROL <mode> <challenge>`). With command protect off, commands are sent as plain `00<command>`. With command protect on, the plugin derives a SHA-256 (or MD5, as the display requests) hash of `username:password:challenge` once per connection and puts it in front of every command. The hash is cleared when the connection closes.

## Requirements

Q-SYS Core side:

- Q-SYS Designer with plugin support
- Core must be able to reach the display on TCP port 1024 (same LAN or routed)

Display side:

- Panasonic TH-43EQ3W or TH-55EQ3W
- LAN control enabled on the display
- If command protect is on, a Username and Password (see below)

## Installation

### 1. Q-SYS Designer setup

1. Download [PanasonicEQ3DisplayControl.qplug](https://github.com/hybridsix/QSYS-Panasonic_EQ3_DisplayControl/releases/latest/download/PanasonicEQ3DisplayControl.qplug) from the latest [release](https://github.com/hybridsix/QSYS-Panasonic_EQ3_DisplayControl/releases/latest), or use the copy in `dist/`
2. Copy it to: `%USERPROFILE%\Documents\QSC\Q-Sys Designer\Plugins\QSYS Panasonic EQ3 Display Control\`
3. Restart Q-SYS Designer (or use Manage Plugins to reload)
4. Drag Displays -> Panasonic -> EQ3 Display Control from the component library onto your schematic
5. Open the plugin's Properties panel and fill in:

| Property | Description |
|---|---|
| Model | Auto, TH-43EQ3W or TH-55EQ3W. Auto reads the model from the display. |
| Name | Optional device name or ID (for example PRJ-201). Shown on the block in the schematic in place of the plugin title. |
| IP Address | The display's IP address |
| Port | Must match the display's command port (default 1024) |
| Username | Only needed if command protect is on |
| Password | Only needed if command protect is on. Stored as a plain string property, so it is visible in the design file. |
| Normal Poll Interval (s) | How often power and input are polled while the display is on (default 2) |
| High Poll Interval (s) | Poll interval used right after a command, until the status changes (default 1) |
| High Poll Timeout (s) | Give up on the high-rate poll after this long (default 30) |
| Debug Print | None / Tx/Rx / All - use Tx/Rx when commissioning. Credentials and hashes are never printed. |

## Controls and pins

All pins are available in the Control Pins section of the Properties panel.

| Control | Direction | Type | Description |
|---|---|---|---|
| Power On / Power Off | Input | Button | Power the display on / off |
| Power State | Output | LED | true when the display is on |
| Power State Text | Output | Text | On / Standby / Unknown |
| Input | Both | Combo box | Select / report the active input |
| Volume | Both | Knob | 0-100 (`AVL`). Drags are coalesced; only the final value is sent. |
| Audio Mute | Both | Toggle button | true sends `AMT:1`, false sends `AMT:0` |
| Mute LED | Output | LED | Mute state as reported by the display |
| Backlight | Both | Knob | 0-50 (`VPC:BLT`) |
| Aspect | Both | Combo box | Full / Normal / Native / Zoom (`DAM`) |
| Picture Mode | Both | Combo box | Dynamic / Graphic / Sports / Standard (`VPC:MEN`) |
| Connected | Output | LED | true when the display is reachable |
| Status | Output | Status | Connection state, including authentication problems |
| Model, Serial Number, IP Address | Output | Text | What this block is talking to |
| Detail, Last Command, Last Reply, Last Error, Queue Depth | Output | Text | Diagnostics |
| Raw Command, Send, Reply | Both / Input / Output | Text, Button | Send one documented command and see the reply. It is never retried. |

## Polling

- Display in standby: power every 10 seconds.
- Display on: power and input at the Normal Poll Interval; volume and mute every 5 s; backlight, aspect and picture mode every 10 s.
- Model and serial number are queried once after connect (retried every 10 s until they succeed).
- After a command the affected status is polled at the High Poll Interval until the display reports the expected value or the High Poll Timeout passes.
- An unrecognized or malformed reply keeps the last good value and the raw reply is shown in Detail. An unknown input code is shown as the raw code.

## Troubleshooting

| Problem | Fix |
|---|---|
| Status never reaches Connected | Ping the display from another device. Check the IP Address and Port properties. Confirm LAN control is enabled on the display. |
| Status asks for Username and Password | Command protect is on. Fill in the Username and Password properties. |
| Status shows an authentication error | Username or Password is wrong (display replied `ERRA`). |
| Last Error shows `Display Busy (ERR3)` | The display is busy (for example warming up). Try again shortly. |
| Detail shows a model mismatch | The Model property does not match the display. Set it to Auto or the correct model. |
| Commands are ignored or time out | Set Debug Print to Tx/Rx and compare the traffic with the display's documentation. |

## Build from source

```powershell
npm install        # once; installs the Lua test VM (fengari)
npm run build      # writes dist/PanasonicEQ3DisplayControl.qplug
npm test           # builds, then runs the Lua tests
```

## File reference

| File | Purpose |
|---|---|
| `src/info.lua` | `PluginInfo` (version injected from `package.json`) |
| `src/plugin.lua` | Design-time: properties, controls, layout, pages |
| `src/runtime.lua` | Runtime wiring between controls, engine and socket |
| `src/engine.lua` | Connection state machine, serialized queue, authentication, timeouts, reconnect |
| `src/poller.lua` | Conservative polling schedule driven by power state |
| `src/protocol.lua` | Framing, greeting parsing, auth hashing, reply parsers, error codes |
| `src/commands.lua` | Command builders, input / aspect / picture mode lists, ranges |
| `src/models.lua` | Model table and `QID` mapping |
| `src/hash.lua` | Pure-Lua SHA-256 and MD5 |
| `build.js` | Bundles `src/` into one `.qplug` |
| `test/` | Lua tests, run under fengari (no Lua install needed) |

Q-SYS plugins are a single Lua file, so `build.js` wraps each module and provides a local `require`.

## Design rules

- One shared engine; model differences live in `src/models.lua`.
- Control handlers only enqueue. One request is in flight at a time; commands go ahead of queries.
- Feedback is parsed, never assumed. Non-idempotent commands are not retried.
- Credentials are never logged, shown in controls, or kept after the connection closes.
- Only commands from the supplied Panasonic references are used.

## Not yet verified on real hardware

Settle these in the lab; each is isolated so the fix is local.

1. **Hash case**: the hash is sent as lowercase hex. Confirm the display accepts it.
2. **Greeting mode 0**: assumed to mean command protect is off (no hash, no credentials).
3. **`QID` reply format**: model detection assumes the reply contains the model digits (for example `55EQ3W`).
4. **Knob layout**: confirm the Volume and Backlight knobs render and behave correctly in Designer.
5. **Socket reconnect**: the plugin sets `ReconnectTimeout = 0` and reconnects from the engine. Confirm that disables the socket's own reconnect.
6. **Standby behavior**: which queries the display answers while in standby.
7. **Pure-Lua hashing on a Core**: tested under fengari only; confirm the hash is accepted by a protected display.

## Not in version 1

- PJLink (picture mute, firmware, signal info)
- RS-232
- Temperature, runtime and fan readouts
