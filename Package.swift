// swift-tools-version: 6.0
// FindFamilyiOS SwiftPM manifest — lets xtool (https://github.com/xtool-org/xtool)
// build the app on Linux/WSL/macOS without Xcode.
//
// Layout notes:
//  - The app target reuses the existing `FindFamilyiOS/` directory in place, so the
//    `.xcodeproj` keeps working untouched. `path: "FindFamilyiOS"` + explicit `sources`
//    keeps SwiftPM from tripping over `Info.plist`, `.xcassets`, and `Preview Content`.
//  - `PQCStubs.c` cannot live in a Swift target (SwiftPM forbids mixed sources), so it
//    is a separate `PQCStubs` C target with a public header shim.
//  - `SQLite3` is a system library: `linkedLibrary("sqlite3")` (xtool's Darwin SDK
//    provides libsqlite3 like Xcode does).
//  - `Info.plist` stays the Xcode source of truth; xtool reads bundle metadata
//    (identifier, version, permissions, URL scheme) from its own app config at
//    `xtool.yaml`. Keep the two in sync — see that file.

import PackageDescription

let package = Package(
    name: "FindFamilyiOS",
    platforms: [
        // Mirrors IPHONEOS_DEPLOYMENT_TARGET = 18.0 in project.pbxproj.
        .iOS(.v18),
    ],
    products: [
        // xtool builds the .app bundle around a library product (not an executable
        // target). The `@main` App struct in App/FindFamilyiOSApp.swift is still the
        // entry point — xtool wraps it during `dev build`.
        .library(name: "FindFamilyiOS", targets: ["FindFamilyiOS"]),
    ],
    targets: [
        .target(
            name: "PQCStubs",
            path: "FindFamilyiOS/Crypto",
            sources: ["PQCStubs.c"],
            publicHeadersPath: "PQCStubsHeader"
        ),
        .target(
            name: "FindFamilyiOS",
            dependencies: ["PQCStubs"],
            path: "FindFamilyiOS",
            exclude: [
                "Info.plist",
                "FindFamilyiOS.entitlements",
                "Assets.xcassets",
                "Crypto/PQCStubs.c",
                "Crypto/PQCStubsHeader",
                "Preview Content",
            ],
            sources: [
                "App",
                "Backup",
                "Crypto",
                "Intents",
                "Location",
                "Model",
                "Networking",
                "Persistence",
                "UI",
                "Util",
                "UWB",
            ],
            resources: [
                // NOTE: Assets.xcassets excluded until xtool's actool path works on
                // Linux (see actool probe failure). App builds/runs iconless meanwhile.
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
    ]
)
