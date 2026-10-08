#!/usr/bin/env python3
import json
import pathlib
import shutil
import subprocess
import tempfile


REPOSITORY = pathlib.Path(__file__).resolve().parents[2]


def make_fixture(root: pathlib.Path) -> pathlib.Path:
    script = root / "scripts" / "errorgen.swift"
    errors = root / "Packages/DiagnosticsCore/ErrorCatalog/errors.json"
    generated = root / (
        "Packages/DiagnosticsCore/Sources/DiagnosticsCore/Errors/"
        "ErrorCatalog.generated.swift"
    )
    markdown = root / "docs/03-reference/error-catalog.md"
    for path in (script, errors, generated, markdown):
        path.parent.mkdir(parents=True, exist_ok=True)

    shutil.copy2(REPOSITORY / "scripts/errorgen.swift", script)
    shutil.copy2(REPOSITORY / "Packages/DiagnosticsCore/ErrorCatalog/errors.json", errors)
    shutil.copy2(
        REPOSITORY
        / "Packages/DiagnosticsCore/Sources/DiagnosticsCore/Errors/"
        "ErrorCatalog.generated.swift",
        generated,
    )
    shutil.copy2(REPOSITORY / "docs/03-reference/error-catalog.md", markdown)
    return script


def run_errorgen(script: pathlib.Path, *arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["swift", str(script), *arguments],
        check=False,
        capture_output=True,
        text=True,
    )


def entry(document: dict, code: str) -> dict:
    return next(item for item in document["errors"] if item["code"] == code)


with tempfile.TemporaryDirectory(prefix="apkrun-errorgen-") as temporary:
    fixture_root = pathlib.Path(temporary)
    script = make_fixture(fixture_root)
    errors_path = (
        fixture_root / "Packages/DiagnosticsCore/ErrorCatalog/errors.json"
    )
    document = json.loads(errors_path.read_text())

    # Both are documented exit codes even though no current catalog entry uses them.
    for code, exit_code in (("cli.invalidArguments", 2), ("cli.versionSkew", 3)):
        catalog_entry = entry(document, code)
        catalog_entry["cliExit"] = exit_code
        catalog_entry.setdefault("doc", {})["exitDisplay"] = str(exit_code)
    errors_path.write_text(json.dumps(document, indent=2) + "\n")

    generated = run_errorgen(script)
    if generated.returncode != 0:
        raise SystemExit(generated.stderr or generated.stdout)
    generated_markdown = run_errorgen(script, "--markdown")
    if generated_markdown.returncode != 0:
        raise SystemExit(generated_markdown.stderr or generated_markdown.stdout)
    checked = run_errorgen(script, "--check")
    if checked.returncode != 0:
        raise SystemExit(checked.stderr or checked.stdout)

    document = json.loads(errors_path.read_text())
    entry(document, "cli.invalidArguments")["cliExit"] = 200
    errors_path.write_text(json.dumps(document, indent=2) + "\n")
    invalid = run_errorgen(script)
    if invalid.returncode == 0 or "unsupported cliExit 200" not in invalid.stderr:
        raise SystemExit("errorgen did not reject unsupported exit code 200")

    document = json.loads(errors_path.read_text())
    entry(document, "cli.invalidArguments")["cliExit"] = True
    errors_path.write_text(json.dumps(document, indent=2) + "\n")
    boolean = run_errorgen(script)
    if boolean.returncode == 0 or ".cliExit must be an integer or" not in boolean.stderr:
        raise SystemExit("errorgen did not reject a boolean cliExit")

    document = json.loads(errors_path.read_text())
    entry(document, "cli.invalidArguments")["cliExit"] = 64
    entry(document, "vm.configurationInvalid")["retired"] = True
    errors_path.write_text(json.dumps(document, indent=2) + "\n")
    retired = run_errorgen(script)
    if retired.returncode != 0:
        raise SystemExit(retired.stderr or retired.stdout)
    generated_path = (
        fixture_root
        / "Packages/DiagnosticsCore/Sources/DiagnosticsCore/Errors/"
        "ErrorCatalog.generated.swift"
    )
    generated_source = generated_path.read_text()
    generated_entry = next(
        (
            line
            for line in generated_source.splitlines()
            if '"vm.configurationInvalid": ErrorCatalogEntry(' in line
        ),
        "",
    )
    if not generated_entry or "retired: true" not in generated_entry:
        raise SystemExit("errorgen did not retain the last presentation for a retired code")

print(
    "PASS errorgen accepts documented exit codes 2 and 3, rejects invalid values, "
    "and retains retired entries"
)
