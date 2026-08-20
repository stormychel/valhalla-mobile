// swift-tools-version:5.8
import PackageDescription

// This fork adds two C++ → Swift bridge symbols the upstream 0.5.1 xcframework
// does not carry: `trace_attributes` and `trace_route` (Valhalla's map matcher).
// Both are in the fork's own published xcframework, so a consumer needs NO local
// build — resolving this package pulls the binary below. A locally built
// xcframework still wins when present, which is what you want while iterating on
// the wrapper:
//     scripts/build_apple.sh arm64-ios-simulator
//     scripts/build_apple.sh arm64-ios
//     scripts/build_apple.sh x64-ios-simulator
//     scripts/create_xcframework.sh
// `VALHALLA_MOBILE_DEV=true` forces the local path even if the directory check fails.
import Foundation
let localBinaryPath = "build/apple/valhalla-wrapper.xcframework"
let localBinaryFullPath = Context.packageDirectory + "/" + localBinaryPath
let envOverride = Context.environment["VALHALLA_MOBILE_DEV"].flatMap(Bool.init) ?? false
let localBinaryExists = FileManager.default.fileExists(atPath: localBinaryFullPath)
let useLocalBinary = envOverride || localBinaryExists

// Use the local binary
var binaryTarget: Target = .binaryTarget(
    name: "ValhallaWrapper",
    path: "build/apple/valhalla-wrapper.xcframework"
)

// Points at THIS fork's release, which carries the two extra bridge symbols.
let version: String = "0.5.1-trace.1"
let binaryURL: String =
    "https://github.com/stormychel/valhalla-mobile/releases/download/\(version)/valhalla-wrapper.xcframework.zip"
let binaryChecksum: String = "653479082af9fecd6bf3efbec0b44f7af811665b682331c74d5931a186c8b37c"

if !useLocalBinary {
    binaryTarget = .binaryTarget(
        name: "ValhallaWrapper",
        url: binaryURL,
        checksum: binaryChecksum
    )
}

let package = Package(
    name: "ValhallaMobile",
    platforms: [
        .iOS("16.4")
        // .tvOS(.v13),
        // .watchOS(.v6),
        // .macOS(.v10_13)
    ],
    products: [
        .library(
            name: "Valhalla",
            targets: ["Valhalla"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/Rallista/valhalla-openapi-models-swift.git",
            .upToNextMinor(from: "0.3.0")),
        .package(
            url: "https://github.com/UInt2048/Light-Swift-Untar.git", .upToNextMajor(from: "1.0.4")),
        .package(url: "https://github.com/apple/swift-docc-plugin", .upToNextMajor(from: "1.0.0")),
    ],
    targets: [
        .target(
            name: "Valhalla",
            dependencies: [
                "ValhallaObjc",
                "ValhallaWrapper",
                .product(name: "ValhallaConfigModels", package: "valhalla-openapi-models-swift"),
                .product(name: "ValhallaModels", package: "valhalla-openapi-models-swift"),
                .product(name: "Light-Swift-Untar", package: "Light-Swift-Untar"),
            ],
            path: "apple/Sources/Valhalla",
            resources: [
                .process("SupportData")
            ]
        ),
        .target(
            name: "ValhallaObjc",
            dependencies: ["ValhallaWrapper"],
            path: "apple/Sources/ValhallaObjc",
            linkerSettings: [.linkedLibrary("z")]
        ),
        binaryTarget,
        .testTarget(
            name: "ValhallaTests",
            dependencies: ["Valhalla"],
            path: "apple/Tests/ValhallaTests",
            resources: [.copy("TestData")]
        ),
    ],
    cLanguageStandard: .gnu17,
    cxxLanguageStandard: .cxx20
)
