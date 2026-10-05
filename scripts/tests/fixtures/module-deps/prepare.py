import pathlib
import shutil
import sys

source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
mode = sys.argv[3]
destination.mkdir(parents=True)

for name in ("Package.swift", "Package.resolved", "project.yml"):
    shutil.copy2(source / name, destination / name)
shutil.copytree(source / "Packages", destination / "Packages")
for name in ("Apps", "CLI", "Daemon"):
    shutil.copytree(source / name, destination / name)
graph = destination / "docs/01-architecture"
graph.mkdir(parents=True)
shutil.copy2(source / "docs/01-architecture/modules.md", graph / "modules.md")

manifest_path = destination / "Package.swift"
manifest = manifest_path.read_text()
diagnostics_source = destination / "Packages/DiagnosticsCore/Sources/DiagnosticsCore/Build/BuildInfo.swift"

if mode == "forbidden-edge":
    manifest = manifest.replace(
        '.target(name: "DiagnosticsCore", path:',
        '.target(name: "DiagnosticsCore", dependencies: ["RuntimeAPI"], path:',
        1,
    )
elif mode == "wrong-trait":
    manifest = manifest.replace(
        '.trait(\n'
        '            name: "EmbeddedRuntime",\n'
        '            description: "Enable in-process runtime commands for development builds."\n'
        '        ),',
        '.trait(\n'
        '            name: "EmbeddedRuntime",\n'
        '            description: "Enable in-process runtime commands for development builds."\n'
        '        ),\n'
        '        .trait(name: "ReviewFixture", description: "Adversarial fixture"),',
        1,
    )
    manifest = manifest.replace(
        '.target(name: "RuntimeHost", condition: .when(traits: ["EmbeddedRuntime"]))',
        '.target(name: "RuntimeHost", condition: .when(traits: ["ReviewFixture"]))',
        1,
    )
elif mode == "third-party-library":
    manifest = manifest.replace(
        '.target(name: "DiagnosticsCore", path:',
        '.target(\n'
        '            name: "DiagnosticsCore",\n'
        '            dependencies: [.product(name: "ArgumentParser", package: "swift-argument-parser")],\n'
        '            path:',
        1,
    )
elif mode == "xcode-forbidden-framework":
    project_path = destination / "project.yml"
    project = project_path.read_text()
    project_path.write_text(
        project.replace(
            "      - package: APKRun\n        product: RuntimeAPI\n",
            "      - package: APKRun\n        product: RuntimeAPI\n"
            "      - sdk: CoreData.framework\n",
            1,
        )
    )
elif mode == "xcode-missing-product":
    project_path = destination / "project.yml"
    project = project_path.read_text()
    project_path.write_text(
        project.replace(
            "packages:\n  APKRun:\n    path: .\n",
            "packages:\n"
            "  APKRun:\n"
            "    path: .\n"
            "  Sparkle:\n"
            "    url: https://github.com/sparkle-project/Sparkle\n"
            "    from: 2.6.4\n",
            1,
        )
    )
elif mode == "helpers-directory":
    helpers = destination / "Packages/DiagnosticsCore/Sources/DiagnosticsCore/Helpers"
    helpers.mkdir()
    (helpers / "Helper.swift").write_text("struct HelperFixture {}\n")
elif mode == "experiments-import":
    experiment_source = destination / "Experiments/Spike/Sources/SpikeKit/Spike.swift"
    experiment_source.parent.mkdir(parents=True)
    experiment_source.write_text("public struct SpikeFixture {}\n")
    diagnostics_source.write_text("import SpikeKit\n" + diagnostics_source.read_text())
elif mode == "experiments-nested-package":
    package_path = destination / "Experiments/HiddenExperiment"
    (package_path / "Sources/Core").mkdir(parents=True)
    (package_path / "Package.swift").write_text(
        "// swift-tools-version: 6.2\n"
        "import PackageDescription\n"
        "let package = Package(\n"
        '    name: "HiddenExperiment",\n'
        '    products: [.library(name: "SwiftProtobuf", targets: ["HiddenExperiment"])],\n'
        '    targets: [.target(name: "HiddenExperiment", path: "Sources/Core")]\n'
        ")\n"
    )
    (package_path / "Sources/Core/Hidden.swift").write_text(
        "public struct HiddenExperimentFixture {}\n"
    )
    manifest = manifest.replace(
        '        .package(\n'
        '            url: "https://github.com/weichsel/ZIPFoundation.git",\n'
        '            exact: "0.9.20"\n'
        "        ),",
        '        .package(\n'
        '            url: "https://github.com/weichsel/ZIPFoundation.git",\n'
        '            exact: "0.9.20"\n'
        "        ),\n"
        '        .package(path: "Experiments/HiddenExperiment"),',
        1,
    )
    manifest = manifest.replace(
        '.product(name: "SwiftProtobuf", package: "swift-protobuf")',
        '.product(name: "SwiftProtobuf", package: "HiddenExperiment")',
        1,
    )
    guest_protocol_source = (
        destination / "Packages/GuestProtocol/Sources/GuestProtocol/GuestProtocol.swift"
    )
    guest_protocol_source.write_text(
        "import HiddenExperiment\n" + guest_protocol_source.read_text()
    )
elif mode == "unclassified-target":
    marker = "\n    ],\n    swiftLanguageModes:"
    insertion = (
        '\n        .executableTarget(\n'
        '            name: "HiddenFixture",\n'
        '            dependencies: ["RuntimeCore"],\n'
        '            path: "Packages/DiagnosticsCore/Sources/HiddenFixture"\n'
        "        ),"
    )
    insertion_point = manifest.rfind(marker)
    if insertion_point < 0:
        raise SystemExit("could not add unclassified target to fixture manifest")
    manifest = manifest[:insertion_point] + insertion + manifest[insertion_point:]
    hidden_source = destination / "Packages/DiagnosticsCore/Sources/HiddenFixture/HiddenFixture.swift"
    hidden_source.parent.mkdir(parents=True)
    hidden_source.write_text("import RuntimeCore\npublic struct HiddenFixture {}\n")
elif mode == "experiment-target-name-mismatch":
    marker = "\n    ],\n    swiftLanguageModes:"
    insertion = (
        '\n        .target(\n'
        '            name: "HiddenExperiment",\n'
        '            path: "Experiments/Spike/Sources/Core"\n'
        "        ),"
    )
    insertion_point = manifest.rfind(marker)
    if insertion_point < 0:
        raise SystemExit("could not add mismatched experiment target to fixture manifest")
    manifest = manifest[:insertion_point] + insertion + manifest[insertion_point:]
    experiment_source = destination / "Experiments/Spike/Sources/Core/Spike.swift"
    experiment_source.parent.mkdir(parents=True)
    experiment_source.write_text("public struct SpikeFixture {}\n")
    diagnostics_source.write_text("import HiddenExperiment\n" + diagnostics_source.read_text())
elif mode == "backtick-import":
    diagnostics_source.write_text("import `RuntimeCore`\n" + diagnostics_source.read_text())
elif mode == "production-nested-tests-import":
    hidden_source = (
        destination / "Packages/RuntimeHost/Sources/RuntimeHost/Tests/Hidden.swift"
    )
    hidden_source.parent.mkdir(parents=True)
    hidden_source.write_text("import GraphicsCore\n")
elif mode == "target-owner-path-mismatch":
    target_start = manifest.find('.target(\n            name: "GraphicsCore",')
    old_path = 'path: "Packages/GraphicsCore/Sources/GraphicsCore"'
    path_start = manifest.find(old_path, target_start)
    if target_start < 0 or path_start < 0:
        raise SystemExit("could not relocate GraphicsCore target in fixture manifest")
    new_path = 'path: "Packages/RuntimeCore/Sources/GraphicsCore"'
    manifest = manifest[:path_start] + new_path + manifest[path_start + len(old_path):]
    old_source = destination / "Packages/GraphicsCore/Sources/GraphicsCore"
    moved_source = destination / "Packages/RuntimeCore/Sources/GraphicsCore"
    shutil.copytree(old_source, moved_source)
    moved_module = moved_source / "GraphicsCore.swift"
    moved_module.write_text("import RuntimeAPI\n" + moved_module.read_text())
elif mode == "forbidden-import":
    diagnostics_source.write_text("@_implementationOnly import RuntimeCore\n" + diagnostics_source.read_text())
elif mode != "valid":
    raise SystemExit(f"unknown module dependency fixture: {mode}")

manifest_path.write_text(manifest)
