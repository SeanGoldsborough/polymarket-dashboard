// swift-tools-version: 5.9
//
//  Package.swift
//  PocketTrackpad
//
//  A SECOND way to build the same sources, and the only one that gives a fast
//  feedback loop.
//
//  Why this exists alongside project.yml
//  -------------------------------------
//  The app is an iOS app, so the full thing can only be built by Xcode against
//  the iOS SDK, signed, and run on a device — CoreBluetooth's peripheral role
//  does not work in the Simulator, so even a Simulator build proves little.
//
//  But CoreBluetooth is not iOS-only. It ships on macOS too. That means the
//  entire bit-level half of this codebase — the HID report descriptor, the
//  report encoders, the keycode tables, the peripheral manager, the report
//  pump, the bond store, and the pointer/scroll/gesture math — compiles and
//  tests as a plain library on a Mac with no Xcode project, no simulator, no
//  provisioning profile and no device:
//
//      cd PocketTrackpad && swift test
//
//  That is where the expensive bugs live. A wrong bit count in the report
//  descriptor, a dropped key-up that sticks a modifier down on the host,
//  truncated sub-pixel residue that ruins slow pointing — none of those need a
//  radio to catch, and all of them are miserable to diagnose on device.
//
//  What is deliberately NOT here: everything under Sources/Features and
//  Sources/App. Those are SwiftUI screens built on UIKit types (UIViewRepresentable,
//  UIImpactFeedbackGenerator, UIPasteboard) that have no macOS equivalent, so
//  they cannot join this package. They are covered by the Xcode target only.
//

import PackageDescription

let package = Package(
    name: "PocketTrackpad",
    platforms: [
        // macOS is the point of this manifest — it is what makes `swift test`
        // work from a terminal. iOS is listed so the same targets can be
        // consumed by an iOS build if the app is ever migrated off XcodeGen.
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "PocketTrackpad", targets: ["PocketTrackpad"]),
    ],
    targets: [
        // The ObjC @try/@catch shim. SwiftPM synthesises a module map from the
        // umbrella `include` directory, which is what lets Swift say
        // `import PTExceptionCatcher`. SwiftPM has no bridging-header support,
        // so this module form is mandatory here — the Xcode target reaches the
        // same header through Support/PocketTrackpad-Bridging-Header.h instead.
        .target(
            name: "PTExceptionCatcher",
            path: "Sources/ObjCShim",
            publicHeadersPath: "include"
        ),

        // Named to match the Xcode target so `@testable import PocketTrackpad`
        // resolves identically under both build systems and the test files need
        // no conditional imports.
        .target(
            name: "PocketTrackpad",
            dependencies: ["PTExceptionCatcher"],
            path: "Sources",
            // Everything that needs UIKit. Listing the excluded directories
            // explicitly (rather than listing the included ones) means a new
            // file in Core/HID/Input joins the tested set automatically, which
            // is the direction the mistake should fall.
            exclude: [
                "App",
                "Features",
                "ObjCShim",
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),

        .testTarget(
            name: "PocketTrackpadTests",
            dependencies: ["PocketTrackpad"],
            path: "Tests",
            // The UI-dependent suites cannot compile here because the types
            // they exercise live in the excluded directories above. They run in
            // Xcode against the app target.
            exclude: [
                "RemoteStoreTests.swift",
                "HIDDiagnosticsTests.swift",
            ]
        ),
    ]
)
