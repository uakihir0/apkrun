// swift-tools-version: 6.2

import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let virglRuntimeCache =
    packageRoot
    .appendingPathComponent("ThirdParty/out/virgl-runtime/current")
    .resolvingSymlinksInPath()
let virglRuntimeIncludePath =
    virglRuntimeCache
    .appendingPathComponent("include")
    .path

let ubsanRuntimePath: String = {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["clang", "--print-file-name=libclang_rt.ubsan_osx_dynamic.dylib"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            FileManager.default.fileExists(atPath: path)
        else {
            fatalError("xcrun could not locate Clang's macOS Undefined Behavior Sanitizer runtime")
        }
        return URL(fileURLWithPath: path).deletingLastPathComponent().path
    } catch {
        fatalError("xcrun could not locate Clang's macOS Undefined Behavior Sanitizer runtime: \(error)")
    }
}()

let package = Package(
    name: "APKRun",
    defaultLocalization: "en",
    platforms: [
        .macOS("27.0")
    ],
    products: [
        .library(name: "DiagnosticsCore", type: .static, targets: ["DiagnosticsCore"]),
        .library(name: "VirtioDeviceCore", type: .static, targets: ["VirtioDeviceCore"]),
        .library(name: "VirtualMachineCore", type: .static, targets: ["VirtualMachineCore"]),
        .library(name: "GraphicsCore", type: .static, targets: ["GraphicsCore"]),
        .library(name: "InputCore", type: .static, targets: ["InputCore"]),
        .library(name: "WindowingCore", type: .static, targets: ["WindowingCore"]),
        .library(name: "GuestProtocol", type: .static, targets: ["GuestProtocol"]),
        .library(name: "ImageCore", type: .static, targets: ["ImageCore"]),
        .library(name: "RuntimeAPI", type: .static, targets: ["RuntimeAPI"]),
        .library(name: "RuntimeCore", type: .static, targets: ["RuntimeCore"]),
        .library(name: "RuntimeClient", type: .static, targets: ["RuntimeClient"]),
        .library(name: "RuntimeHost", type: .static, targets: ["RuntimeHost"]),
        .library(name: "APKStoreCore", type: .static, targets: ["APKStoreCore"]),
        .library(name: "UpdateCore", type: .static, targets: ["UpdateCore"]),
        .library(name: "WrapperCore", type: .static, targets: ["WrapperCore"]),
        .library(name: "IntegrationCore", type: .static, targets: ["IntegrationCore"]),
        .executable(name: "apkrun", targets: ["apkrun"]),
    ],
    traits: [
        .trait(
            name: "EmbeddedRuntime",
            description: "Enable in-process runtime commands for development builds."
        ),
        .trait(
            name: "TestReadback",
            description: "Compile the test-only readback mode of the VirGL replay test (graphics.md §12, #022)."
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            exact: "1.8.2"
        ),
        .package(
            url: "https://github.com/apple/swift-protobuf.git",
            exact: "1.38.1"
        ),
        .package(
            url: "https://github.com/weichsel/ZIPFoundation.git",
            exact: "0.9.20"
        ),
    ],
    targets: [
        .target(name: "DiagnosticsCore", path: "Packages/DiagnosticsCore/Sources/DiagnosticsCore"),
        .target(
            name: "VirtioDeviceCore",
            dependencies: ["DiagnosticsCore"],
            path: "Packages/VirtioDeviceCore/Sources/VirtioDeviceCore"
        ),
        .target(
            name: "VirtualMachineCore",
            dependencies: ["VirtioDeviceCore", "DiagnosticsCore"],
            path: "Packages/VirtualMachineCore/Sources/VirtualMachineCore"
        ),
        .target(
            name: "GraphicsBridge",
            path: "Packages/GraphicsCore/Sources/GraphicsBridge",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-I", virglRuntimeIncludePath]),
                .define("DEBUG", .when(configuration: .debug)),
                .unsafeFlags(["-fobjc-arc"]),
            ],
            linkerSettings: [
                .linkedFramework("Foundation"),
                // SwiftPM instruments C targets but omits the UBSan runtime at link time.
                .unsafeFlags(
                    [
                        "-L", ubsanRuntimePath,
                        "-lclang_rt.ubsan_osx_dynamic",
                        "-Xlinker", "-rpath",
                        "-Xlinker", ubsanRuntimePath,
                    ], .when(configuration: .debug)),
            ]
        ),
        .target(
            name: "GraphicsCore",
            dependencies: ["VirtioDeviceCore", "DiagnosticsCore", "GraphicsBridge"],
            path: "Packages/GraphicsCore/Sources/GraphicsCore",
            swiftSettings: [
                .define("APKRUN_TEST_READBACK", .when(traits: ["TestReadback"]))
            ],
            linkerSettings: [
                .linkedFramework("Metal")
            ]
        ),
        .target(
            name: "InputCore",
            dependencies: ["DiagnosticsCore"],
            path: "Packages/InputCore/Sources/InputCore"
        ),
        .target(
            name: "WindowingCore",
            dependencies: ["InputCore", "DiagnosticsCore"],
            path: "Packages/WindowingCore/Sources/WindowingCore"
        ),
        .target(
            name: "GuestProtocol",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf")
            ],
            path: "Packages/GuestProtocol/Sources/GuestProtocol"
        ),
        .target(
            name: "ImageCore",
            dependencies: ["VirtualMachineCore", "DiagnosticsCore"],
            path: "Packages/ImageCore/Sources/ImageCore"
        ),
        .target(name: "RuntimeAPI", path: "Packages/RuntimeAPI/Sources/RuntimeAPI"),
        .target(
            name: "RuntimeCore",
            dependencies: [
                "VirtualMachineCore",
                "GraphicsCore",
                "InputCore",
                "GuestProtocol",
                "ImageCore",
                "RuntimeAPI",
                "DiagnosticsCore",
            ],
            path: "Packages/RuntimeCore/Sources/RuntimeCore"
        ),
        .target(
            name: "RuntimeClient",
            dependencies: ["RuntimeAPI", "DiagnosticsCore"],
            path: "Packages/RuntimeClient/Sources/RuntimeClient"
        ),
        .target(
            name: "RuntimeHost",
            dependencies: [
                "RuntimeCore",
                "APKStoreCore",
                "UpdateCore",
                "WrapperCore",
                "IntegrationCore",
                "ImageCore",
                "InputCore",
                "RuntimeAPI",
                "DiagnosticsCore",
            ],
            path: "Packages/RuntimeHost/Sources/RuntimeHost"
        ),
        .target(
            name: "APKStoreCore",
            dependencies: [
                "GuestProtocol",
                "RuntimeAPI",
                "DiagnosticsCore",
                .product(name: "ZIPFoundation", package: "zipfoundation"),
            ],
            path: "Packages/APKStoreCore/Sources/APKStoreCore"
        ),
        .target(
            name: "UpdateCore",
            dependencies: [
                "APKStoreCore",
                "RuntimeAPI",
                "DiagnosticsCore",
                .product(name: "ZIPFoundation", package: "zipfoundation"),
            ],
            path: "Packages/UpdateCore/Sources/UpdateCore"
        ),
        .target(
            name: "WrapperCore",
            dependencies: ["RuntimeAPI", "DiagnosticsCore"],
            path: "Packages/WrapperCore/Sources/WrapperCore"
        ),
        .target(
            name: "IntegrationCore",
            dependencies: ["GuestProtocol", "RuntimeAPI", "DiagnosticsCore"],
            path: "Packages/IntegrationCore/Sources/IntegrationCore"
        ),
        .executableTarget(
            name: "apkrun",
            dependencies: [
                "RuntimeClient",
                "RuntimeAPI",
                "DiagnosticsCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .target(name: "RuntimeHost", condition: .when(traits: ["EmbeddedRuntime"])),
                .target(name: "WindowingCore", condition: .when(traits: ["EmbeddedRuntime"])),
                .target(name: "InputCore", condition: .when(traits: ["EmbeddedRuntime"])),
            ],
            path: "CLI/apkrun",
            exclude: ["Tests", "apkrun-dev.entitlements"],
            swiftSettings: [
                .define("APKRUN_EMBEDDED_RUNTIME", .when(traits: ["EmbeddedRuntime"]))
            ]
        ),
        .testTarget(
            name: "DiagnosticsCoreTests",
            dependencies: ["DiagnosticsCore", "DiagnosticsCoreTestSupport"],
            path: "Packages/DiagnosticsCore/Tests/DiagnosticsCoreTests",
            resources: [
                .copy("Fixtures")
            ]
        ),
        .target(
            name: "DiagnosticsCoreTestSupport",
            dependencies: ["DiagnosticsCore"],
            path: "Packages/DiagnosticsCore/Tests/DiagnosticsCoreTestSupport"
        ),
        .testTarget(
            name: "DiagnosticsCoreSystemTests",
            dependencies: ["DiagnosticsCore", "DiagnosticsCoreTestSupport"],
            path: "Packages/DiagnosticsCore/Tests/DiagnosticsCoreSystemTests"
        ),
        .testTarget(
            name: "VirtioDeviceCoreTests",
            dependencies: ["VirtioDeviceCore", "VirtioDeviceCoreTestSupport"],
            path: "Packages/VirtioDeviceCore/Tests/VirtioDeviceCoreTests"
        ),
        .target(
            name: "VirtioDeviceCoreTestSupport",
            dependencies: ["VirtioDeviceCore"],
            path: "Packages/VirtioDeviceCore/Tests/VirtioDeviceCoreTestSupport"
        ),
        .testTarget(
            name: "VirtualMachineCoreTests",
            dependencies: [
                "DiagnosticsCore",
                "DiagnosticsCoreTestSupport",
                "VirtualMachineCore",
                "VirtioDeviceCore",
                "VirtualMachineCoreTestSupport",
            ],
            path: "Packages/VirtualMachineCore/Tests/VirtualMachineCoreTests",
            resources: [
                .copy("Fixtures/kernel-headers")
            ]
        ),
        .testTarget(
            name: "VirtualMachineCoreSystemTests",
            dependencies: [
                "DiagnosticsCore",
                "VirtualMachineCore",
                "VirtualMachineCoreTestSupport",
            ],
            path: "Packages/VirtualMachineCore/Tests/VirtualMachineCoreSystemTests"
        ),
        .target(
            name: "VirtualMachineCoreTestSupport",
            dependencies: ["DiagnosticsCore", "VirtualMachineCore", "VirtioDeviceCore"],
            path: "Packages/VirtualMachineCore/Tests/VirtualMachineCoreTestSupport"
        ),
        .testTarget(
            name: "GraphicsCoreTests",
            dependencies: ["GraphicsCore", "VirtioDeviceCore", "VirtioDeviceCoreTestSupport"],
            path: "Packages/GraphicsCore/Tests/GraphicsCoreTests"
        ),
        .testTarget(
            name: "GraphicsCoreSystemTests",
            dependencies: ["GraphicsCore", "GraphicsBridge"],
            path: "Packages/GraphicsCore/Tests/GraphicsCoreSystemTests",
            swiftSettings: [
                .define("APKRUN_TEST_READBACK", .when(traits: ["TestReadback"]))
            ]
        ),
        .testTarget(
            name: "InputCoreTests",
            dependencies: ["InputCore"],
            path: "Packages/InputCore/Tests/InputCoreTests"
        ),
        .testTarget(
            name: "WindowingCoreTests",
            dependencies: ["WindowingCore"],
            path: "Packages/WindowingCore/Tests/WindowingCoreTests"
        ),
        .testTarget(
            name: "GuestProtocolTests",
            dependencies: ["GuestProtocol"],
            path: "Packages/GuestProtocol/Tests/GuestProtocolTests"
        ),
        .testTarget(
            name: "ImageCoreTests",
            dependencies: ["ImageCore", "DiagnosticsCore", "DiagnosticsCoreTestSupport", "VirtualMachineCore"],
            path: "Packages/ImageCore/Tests/ImageCoreTests"
        ),
        .testTarget(
            name: "RuntimeAPITests",
            dependencies: ["RuntimeAPI"],
            path: "Packages/RuntimeAPI/Tests/RuntimeAPITests"
        ),
        .testTarget(
            name: "RuntimeCoreTests",
            dependencies: ["RuntimeCore"],
            path: "Packages/RuntimeCore/Tests/RuntimeCoreTests",
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "RuntimeClientTests",
            dependencies: ["RuntimeClient"],
            path: "Packages/RuntimeClient/Tests/RuntimeClientTests"
        ),
        .testTarget(
            name: "RuntimeHostTests",
            dependencies: ["RuntimeHost"],
            path: "Packages/RuntimeHost/Tests/RuntimeHostTests"
        ),
        .testTarget(
            name: "RuntimeHostSystemTests",
            dependencies: ["RuntimeHost", "DiagnosticsCore"],
            path: "Packages/RuntimeHost/Tests/RuntimeHostSystemTests"
        ),
        .testTarget(
            name: "APKStoreCoreTests",
            dependencies: ["APKStoreCore"],
            path: "Packages/APKStoreCore/Tests/APKStoreCoreTests"
        ),
        .testTarget(
            name: "UpdateCoreTests",
            dependencies: ["UpdateCore"],
            path: "Packages/UpdateCore/Tests/UpdateCoreTests"
        ),
        .testTarget(
            name: "WrapperCoreTests",
            dependencies: ["WrapperCore"],
            path: "Packages/WrapperCore/Tests/WrapperCoreTests"
        ),
        .testTarget(
            name: "IntegrationCoreTests",
            dependencies: ["IntegrationCore"],
            path: "Packages/IntegrationCore/Tests/IntegrationCoreTests"
        ),
        // The per-run resources of the VM tests (test-strategy §3.10). The same helper is compiled into the
        // IntegrationTests and AcceptanceTests bundles, which exclude this file.
        .testTarget(
            name: "VMRunResourcesTests",
            dependencies: ["DiagnosticsCore"],
            path: "Tests/IntegrationTests/RunResources"
        ),
        .testTarget(
            name: "apkrunTests",
            dependencies: ["apkrun", "DiagnosticsCore", "DiagnosticsCoreTestSupport"],
            path: "CLI/apkrun/Tests",
            resources: [
                .copy("Golden")
            ],
            swiftSettings: [
                .define("APKRUN_EMBEDDED_RUNTIME", .when(traits: ["EmbeddedRuntime"]))
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
