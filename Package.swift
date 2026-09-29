// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "APKRun",
    defaultLocalization: "en",
    platforms: [
        .macOS("27.0"),
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
            name: "GraphicsCore",
            dependencies: ["VirtioDeviceCore", "DiagnosticsCore"],
            path: "Packages/GraphicsCore/Sources/GraphicsCore"
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
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
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
                .define("APKRUN_EMBEDDED_RUNTIME", .when(traits: ["EmbeddedRuntime"])),
            ]
        ),
        .testTarget(
            name: "DiagnosticsCoreTests",
            dependencies: ["DiagnosticsCore"],
            path: "Packages/DiagnosticsCore/Tests/DiagnosticsCoreTests"
        ),
        .testTarget(
            name: "VirtioDeviceCoreTests",
            dependencies: ["VirtioDeviceCore"],
            path: "Packages/VirtioDeviceCore/Tests/VirtioDeviceCoreTests"
        ),
        .testTarget(
            name: "VirtualMachineCoreTests",
            dependencies: ["VirtualMachineCore"],
            path: "Packages/VirtualMachineCore/Tests/VirtualMachineCoreTests"
        ),
        .testTarget(
            name: "GraphicsCoreTests",
            dependencies: ["GraphicsCore"],
            path: "Packages/GraphicsCore/Tests/GraphicsCoreTests"
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
            dependencies: ["ImageCore"],
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
            path: "Packages/RuntimeCore/Tests/RuntimeCoreTests"
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
        .testTarget(
            name: "apkrunTests",
            dependencies: ["apkrun"],
            path: "CLI/apkrun/Tests",
            resources: [
                .copy("Golden"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
