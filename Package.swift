// swift-tools-version:5.8
import PackageDescription

// The trace_attributes-bridge branch references a symbol the published 0.5.1
// xcframework does not contain. To stop the link from failing later in the
// build with a confusing diagnostic, fail the manifest at resolve time when
// the locally rebuilt xcframework is missing. Consumers must run
// `scripts/build_apple.sh arm64-ios-simulator` (etc.) + `scripts/create_xcframework.sh`
// before resolving this package.
import Foundation
let localBinaryPath = "build/apple/valhalla-wrapper.xcframework"
let localBinaryFullPath = Context.packageDirectory + "/" + localBinaryPath
let envOverride = Context.environment["VALHALLA_MOBILE_DEV"].flatMap(Bool.init) ?? false
let localBinaryExists = FileManager.default.fileExists(atPath: localBinaryFullPath)
let useLocalBinary = envOverride || localBinaryExists
if !useLocalBinary {
    fatalError("""
    valhalla-mobile (feat/trace-attributes-bridge): the source references the \
    `trace_attributes` symbol which is not in the published 0.5.1 xcframework. \
    Rebuild the local wrapper before resolving this package:
        scripts/build_apple.sh arm64-ios-simulator
        scripts/build_apple.sh arm64-ios
        scripts/build_apple.sh x64-ios-simulator
        scripts/create_xcframework.sh
    Or set VALHALLA_MOBILE_DEV=true if you already have a binary in place.
    """)
}

// Use the local binary
var binaryTarget: Target = .binaryTarget(
    name: "ValhallaWrapper",
    path: "build/apple/valhalla-wrapper.xcframework"
)

// CI will replace the nils with the actual values when building a release
let version: String = "0.5.1"
let binaryURL: String =
    "https://github.com/Rallista/valhalla-mobile/releases/download/\(version)/valhalla-wrapper.xcframework.zip"
let binaryChecksum: String = "0464877f9297ca9462f57c43f5ffa4825c3fed0653300c2de22cd78422d6d560"

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
            url: "https://github.com/Rallista/valhalla-openapi-models-swift.git", .upToNextMinor(from: "0.2.0")),
        .package(url: "https://github.com/UInt2048/Light-Swift-Untar.git", .upToNextMajor(from: "1.0.4")),
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
