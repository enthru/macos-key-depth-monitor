# Key Depth Monitor for macOS

Native SwiftUI prototype that reads per-key Hall-effect depth reports from compatible
MonsGeek/Akko keyboards and displays the values live. It intentionally does **not**
create a virtual game controller yet.

The first supported devices are:

- MonsGeek M1 V5 HE wired (`3151:5030`)
- MonsGeek M1 V5 HE 2.4 GHz dongle (`3151:5038`)
- Unlisted `3151:*` devices exposing the same `FFFF/02` configuration collection
  and a separate vendor input collection

## Run

Requirements: macOS 14 or newer and Xcode 15 or newer.

```sh
swift run
```

Or open `Package.swift` in Xcode and run the `KeyDepthMonitor` scheme.

Connect the keyboard over USB-C for the first test. The application sends the
`1B 01` feature command that enables magnetism/depth reports, then decodes report
ID `05`, event `1B` as:

```text
depth = byte[2] | byte[3] << 8
key index = byte[4]
```

macOS may ask for Input Monitoring permission. If no device is shown after granting
it, quit and relaunch the application, then press **Rescan**.

The diagnostics disclosure at the bottom of the window shows every matching HID
collection, its usage page/usage, advertised input report IDs and maximum report
sizes. The selected pair is marked `[CONFIG]` and `[INPUT]`. It also shows the last
20 lifecycle/error messages. **Raw reports** counts every callback, while **Depth
events** counts only valid `05/1B` packets.

## Configure monitored keys

Open **Settings** from the main window (or use the standard app Settings menu).
Each monitored key has a display name, its hardware key index and the expected
full-press depth used to scale the progress bar. Changes are saved automatically.

The easiest way to add an unknown key is:

1. Connect the keyboard and press the key once.
2. Open **Settings** and click **Use Last Detected (index)**.
3. Enter a name, adjust the full-press value if needed, and click **Add**.

Existing rows can be edited or removed. **Also show detected keys that are not in
the list** is useful while discovering a layout; turn it off for a clean monitoring
table. **Restore Defaults** restores the original W/A/S/D and helper-key set.

## Protocol details

The configuration collection is `FFFF/0002`. On native IOHID, the feature report
ID is supplied separately to `IOHIDDeviceSetReport`, so the buffer is exactly 64
bytes and starts with the command:

```text
enable:  1B 01 00 00 00 00 00 E3 ...   (report ID argument = 0)
disable: 1B 00 00 00 00 00 00 E4 ...   (report ID argument = 0)
```

The 65-byte hidapi representation is different: it prepends `00` as byte zero.
Do not pass that leading byte in the native IOHID buffer.

Depth notifications come from the separate input collection. Some wired/dongle
firmware exposes that endpoint as a boot-keyboard collection even though it sends
vendor report ID `05`, so the app ranks collections by advertised report ID before
usage page. In an IOHID callback, `reportID` is normally supplied as a separate
argument and `bytes[0]` is `1B`; the decoder also accepts captures where `05` is
still embedded as byte zero.

## macOS HID diagnostics

Before launching the app, these read-only commands should show `3151:5030` for
wired mode or `3151:5038` for the paired 2.4 GHz dongle:

```sh
system_profiler SPUSBDataType | rg -i -C 8 'MonsGeek|Akko|3151|5030|5038'
ioreg -p IOUSB -l -w0 | rg -i -C 6 'MonsGeek|Akko|3151|5030|5038'
hidutil list | rg -i 'MonsGeek|Akko|3151|5030|5038'
```

If the USB device exists but the app cannot open its keyboard/input collection,
grant the terminal (for `swift run`) or Xcode Input Monitoring access in **System
Settings → Privacy & Security → Input Monitoring**, quit the process, and relaunch.
An `IOHIDDeviceOpen` or feature-send failure is printed with its hexadecimal
`IOReturn` code in both the terminal and the diagnostics section.

## Hardware acceptance test

1. Connect over USB-C, launch with `swift run`, and expand **HID diagnostics**.
2. Confirm one `FFFF/0002 [CONFIG]` row and a distinct `[INPUT]` row. The input row
   should normally advertise report ID `05`.
3. Slowly press and release W, A, S and D. **Raw reports** and **Depth events** must
   increase, the bars must move smoothly toward roughly `700–720`, and each value
   must return to `0` after release.
4. Confirm the raw line resembles `ID 05 · 1B <low> <high> <key-index>`. If raw
   reports increase but depth events do not, copy the collection rows and raw line.
5. Click **Rescan** and repeat one press. Then unplug/replug the keyboard and repeat;
   the status must reconnect without restarting the app.
6. Quit, disconnect the keyboard, and launch once more. The app should remain open
   and report that no matching collections are visible.

## Tests

```sh
swift test
```

The report decoder is covered for both report layouts observed through hidapi and
IOHID callbacks.

## Scope of this milestone

- Native HID device discovery
- Enable/disable depth streaming
- Re-enable after an idle/sleep gap
- Live key index, raw depth, peak and normalized press percentage
- Wired/dongle product detection
- Hot-plug and manual rescan

The production virtual-gamepad path and key suppression remain later milestones;
the experimental CoreHID probe below exists only to validate macOS compatibility.

## Experimental virtual gamepad

The app now contains a minimal CoreHID gamepad prototype. Click **Gamepad Off** to
try creating a system-wide Generic Desktop/Game Pad device named **Key Depth
Virtual Gamepad**. While enabled, analog W/A/S/D depth controls the left stick:

```text
A/D → Left Stick X
W/S → Left Stick Y
```

The backend uses `IOHIDUserDeviceCreateWithProperties` and a standard report with
four signed 16-bit axes and 16 buttons. It emits a neutral report when stopped,
rescanned or disconnected so the virtual stick cannot remain held.

Current macOS releases require the managed entitlement below:

```text
com.apple.developer.hid.virtual.device
```

The source entitlement is in `KeyDepthMonitor.entitlements`, but SwiftPM command-line
builds do not receive an Apple provisioning profile automatically. Without the
entitlement the UI reports that macOS rejected virtual HID creation. Adding the key
to an ad-hoc signature is not sufficient and macOS terminates that process. To run
the virtual device, use an Apple Developer team, request/enable the HID Virtual
Device capability for the app identifier, and sign an Xcode app target with the
resulting provisioning profile.

For an automated local smoke test after valid signing:

```sh
KEY_DEPTH_AUTOSTART_GAMEPAD=1 path/to/signed/KeyDepthMonitor
hidutil list | rg -i 'Key Depth Virtual Gamepad|F055|4B44'
```

### Blocking the original W/A/S/D events

After enabling the virtual gamepad, use the button in the main-window footer to
enable keyboard suppression. The default and recommended scope is **GeForce NOW
only**. The filter checks the foreground app bundle identifier
`com.nvidia.gfnpc.mall`, so W/A/S/D remain available in Finder, Terminal and other
applications. The installed native GeForce NOW client uses that identifier.

The first attempt requires permission in **System Settings → Privacy & Security →
Accessibility**. Grant access, relaunch if macOS requests it, enable the virtual
gamepad, then enable key blocking again.

Settings also offers **System-wide** scope for diagnostics. Use it carefully:
W/A/S/D remain blocked everywhere until suppression or the virtual gamepad is
turned off. Suppression always stops automatically when the gamepad stops, fails,
or the app exits. If macOS disables the event tap after permission is revoked, the
app fails open: keys pass through and the UI reports the error.

This implementation filters the normal WindowServer event path. If the GeForce NOW
client reads the physical keyboard directly through IOHID and still receives the
keys, the fallback is exclusive `kIOHIDOptionsTypeSeizeDevice` capture plus a
virtual pass-through keyboard. That fallback blocks the entire physical keyboard
collection and is intentionally not enabled without first testing the safer filter.
