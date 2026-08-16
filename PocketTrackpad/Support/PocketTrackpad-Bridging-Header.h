//
//  PocketTrackpad-Bridging-Header.h
//  PocketTrackpad
//
//  Exposes the ObjC exception-catching shim to Swift.
//
//  Why this exists: CBPeripheralManager.add(_:) RAISES an
//  NSInternalInconsistencyException — not a Swift error — when the service
//  contains a descriptor iOS refuses to publish (notably the 0x2908 Report
//  Reference descriptor that HID-over-GATT requires). Swift cannot catch an
//  ObjC exception, so without this shim the app terminates instead of falling
//  back to another report topology.
//

#import "PTExceptionCatcher.h"
