# Pocket Trackpad

An iPhone that presents itself to a Mac as a Bluetooth keyboard, trackpad and
media remote. No helper app on the Mac, no shared Wi-Fi network — the phone is
a real BLE HID-over-GATT (HOGP) peripheral, and macOS pairs with it the same
way it pairs with a Magic Trackpad.

This is a clone of the product shape at <https://bluetooth.mobilemouse.com/>.

---

## Status: unproven spike, complete implementation

Read this section before anything else.

The entire product rests on a single undocumented behaviour, and **it has not
been verified on hardware**. The code here was written on a Linux container
with no Swift toolchain, no Xcode and no iPhone. It has never been compiled.
Treat the first `xcodegen generate && open` as the beginning of the work, not
the end of it.

What is unverified, in the order you will hit it:

1. **Publishing the HID service at all.** `CBPeripheralManager.add(_:)` rejects
   `CBUUID(string: "1812")` with *"The specified UUID is not allowed for this
   operation."* Passing the fully expanded 128-bit form —
   `00001812-0000-1000-8000-00805F9B34FB` — is reported to slip past the check.
   Every UUID in this codebase goes through `HIDUUID.expand(_:)` for that
   reason; there is no short form anywhere.

2. **Report Reference descriptors — the wall you actually hit.** HOGP wants one
   Report characteristic per report ID, each carrying a `0x2908` descriptor
   whose value is `[reportID, reportType]`. That descriptor is how the host
   learns which report a characteristic carries. But `CBMutableDescriptor` on
   iOS accepts only `kCBUUIDCharacteristicUserDescriptionString` and
   `kCBUUIDCharacteristicFormatString`. Anything else raises
   `NSInternalInconsistencyException` when the service is added.

   That is an Objective-C exception, so Swift cannot catch it and the app dies.
   `Sources/ObjCShim/PTExceptionCatcher.m` wraps the add in `@try/@catch` so a
   rejection becomes a recoverable `HIDError` instead of a crash.

3. **Whether macOS accepts whatever does publish.** Getting the service onto the
   air is not the same as macOS binding it as an input device.

Because (2) has no clean answer, the report layout is a **swappable strategy**
(`ReportTopology`) rather than a fixed design:

| Topology | What it does | Cost if it works |
| --- | --- | --- |
| `perReportCharacteristic` | Spec-correct. One characteristic per report ID with `0x2908` descriptors. | Nothing — full mouse + keyboard + consumer. |
| `singleCharacteristicPrefixed` | One report characteristic, no descriptor, report ID prefixed as byte 0. | Non-conformant. Host may ignore it. Free to try. |
| `bootProtocolOnly` | Boot keyboard (`0x2A22`) + boot mouse (`0x2A33`). No report IDs, so no descriptors needed. | **Loses the consumer page** — the Remotes tab's volume and playback keys have to be re-expressed as F-key equivalents. |

`bootProtocolOnly` is the fallback that most likely works, and it is also the
one that costs you a feature. Knowing which of the three you get is the whole
question, so there is a screen dedicated to answering it.

### Run the spike first

Before touching the UI, on a real iPhone and a real Mac:

```
cd PocketTrackpad
brew install xcodegen
xcodegen generate
open PocketTrackpad.xcodeproj
```

Build to a **physical device** — CoreBluetooth peripheral mode does not
function in the Simulator, and the app substitutes `StubHIDSender` there and
shows a badge saying so. Then open the settings sheet and reach Diagnostics
either from the **stethoscope button on the Connection tab** or from
**General ▸ Advanced ▸ Diagnostics**, and hit **Run All Probes**. While it
runs, open Bluetooth settings on the Mac and click Connect when the phone
appears.

**Unpair the Mac between probes.** macOS caches the GATT database for bonded
devices, and the peripheral role has no way to invalidate that cache —
invalidation requires a Service Changed indication (0x2A05) from the
system-owned GATT service, which `CBPeripheralManager` gives no access to. A
sweep run against an already-bonded Mac will keep using the *stale* service
layout, so it can report results that describe the previous topology rather
than the one under test. Sweep against a Mac that has never bonded, or remove
the device in System Settings ▸ Bluetooth between attempts.

Also note that `start(topology:)` returning without throwing is **not**
success. Descriptor rejection is synchronous and throws; other rejections
(short-form UUID, duplicate publish) arrive later via
`peripheralManager(_:didAdd:error:)` and surface as `connectionState ==
.failed`. A topology is only viable once a `didAdd` success has landed *and* a
central has subscribed.

`HIDDiagnostics` walks all three topologies, records for each whether the
service published, whether a central subscribed, and which reports stuck, then
hands you a shareable plain-text report. That output is the go/no-go for the
product. If all three fail, the product shape changes and no amount of UI
polish rescues it.

---

## Architecture

```
Sources/
  Core/        Shared contract — UUIDs, report types, topologies, settings,
               the HIDSending protocol, and a stub for previews and tests.
  ObjCShim/    @try/@catch bridge so descriptor rejection is recoverable.
  HID/         Report descriptor DSL, keycode tables, CBPeripheralManager,
               the coalescing report pump, bond persistence.
  Input/       Pointer acceleration, scroll quantisation, gesture state
               machine. No UIKit — fully unit-testable.
  Features/    Trackpad, Connection, General, Remotes, About, Diagnostics.
  App/         Entry point, root view, settings sheet, theme.
Tests/         XCTest. Runs without a device.
```

Two decisions worth knowing about:

**The report pump coalesces, but asymmetrically.** Mouse reports are
*relative*, so a dropped one loses distance permanently — the pump accumulates
`dx/dy/wheel/pan` across a blocked window instead of discarding. Keyboard and
consumer reports are *stateful*: dropping a key-up sticks a key down, so those
are delivered in order without coalescing. Backpressure comes from
`updateValue` returning `false`, and flushing resumes on
`peripheralManagerIsReady(toUpdateSubscribers:)`.

**Sub-pixel residue is carried, not truncated.** HID deltas are `Int8`.
Rounding fractional movement to zero every frame destroys slow, precise
pointing; clamping a fast flick at ±127 and discarding the excess destroys
fast pointing. `PointerEngine` carries both the fractional remainder and the
overflow forward, and the caller drains until empty.

---

## Known limitations

- **Backgrounding.** With `bluetooth-peripheral` in `UIBackgroundModes`, iOS
  moves advertised service UUIDs into the advertisement *overflow area* when
  the app is backgrounded. macOS generally will not surface the device in its
  Bluetooth list from there. The background mode does keep an
  already-connected session alive, which is the part that matters in practice
  — but "lock the phone, then pair" will not work.
- **Forgetting a device is cosmetic.** CoreBluetooth owns the bonding keys.
  `forget(_:)` drops the app's remembered name; the user must also unpair in
  macOS System Settings for a clean re-pair. The UI says this.
- **Encryption.** HOGP expects report characteristics to require encryption
  (`.readEncryptionRequired`). That changes the pairing dance and interacts
  with the descriptor problem, so it sits behind a `requireEncryption` flag —
  another axis the diagnostics run should sweep once the basic topology
  question is settled.

## App Review

Worth deciding before investing further, not after. An app that captures
keystrokes and transmits them to another machine has keylogger optics, and
this one reaches the App Store only by way of an API gap Apple has not
documented and could close in any point release. The reference product ships
today, so the path exists — but the risk is real and it is a business
decision, not a technical one.

## License

Unlicensed / private.
