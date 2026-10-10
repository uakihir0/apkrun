#!/usr/bin/env python3
"""Lock reading, manifest writing, and ELF checks for the guest Mesa build (ADR-0018, #099).

Used by scripts/guest/build-mesa-android.sh and scripts/tests/test_guest_mesa_build.py.
Standard library only. The ELF checks call the NDK's llvm-readelf and llvm-nm.

Subcommands:
  lock-field LOCK NAME FIELD    print a lock field (one line per list item)
  requirements LOCK             print the pip requirements (URL and SHA-256) of the Python tools
  manifest OUT --lock LOCK --readelf BIN --nm BIN [--tool KEY=VALUE ...]
                                write OUT/manifest.json for the four shipped libraries
  verify OUT --lock LOCK --readelf BIN --nm BIN
                                check the manifest, the files, and their ELF properties
"""

import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import sys

SCHEMA_VERSION = 1
COMPONENT = "mesa-android"
LOCK_GROUP = "guest-mesa"
MESA_NAME = "mesa"
PYTHON_TOOLS = ("meson", "mako", "markupsafe", "packaging")
LIB_DIR = "vendor/lib64"
MIN_LOAD_ALIGN = 0x4000  # 16 KB pages (environment-setup §2.5)

# The four libraries the image ships (ADR-0018 Decision 3). Each entry lists the DT_NEEDED
# names that the library may have, and the exports the image relies on.
SHIPPED = {
    "libEGL_mesa.so": {
        "needed": {"libgallium_dri.so", "libdrm.so", "libcutils.so", "libhardware.so", "liblog.so",
                   "libnativewindow.so", "libsync.so", "libm.so", "libdl.so", "libc.so"},
        "exports": {"eglInitialize", "eglGetDisplay", "eglGetPlatformDisplay", "eglCreateContext",
                    "eglCreateWindowSurface", "eglMakeCurrent", "eglSwapBuffers", "eglGetProcAddress",
                    "eglQueryString", "eglTerminate"},
    },
    "libGLESv2_mesa.so": {
        "needed": {"libgallium_dri.so", "libc.so"},
        "exports": {"glClear", "glCreateProgram", "glCreateShader", "glDrawArrays", "glGetError",
                    "glGetString", "glUseProgram", "glViewport"},
    },
    "libGLESv1_CM_mesa.so": {
        "needed": {"libgallium_dri.so", "libc.so"},
        "exports": {"glClear", "glDrawArrays", "glGetError", "glViewport"},
    },
    "libgallium_dri.so": {
        # libz.so is not in the image receipt (IR-487). It stays until the image inventory confirms it.
        "needed": {"libdrm.so", "libcutils.so", "liblog.so", "libsync.so", "libz.so", "libm.so",
                   "libdl.so", "libc.so"},
        "exports": set(),
    },
}

# The Mesa symbols that the shipped libraries import from the guest's libraries and from libdrm
# (IR-488). The VM check (apkrun.test=egl) is the first check that shows whether the guest exports them.
GUEST_SYMBOL_CONTRACT = (
    "AHardwareBuffer_acquire", "AHardwareBuffer_release", "ANativeWindowBuffer_getHardwareBuffer",
    "ANativeWindow_acquire", "ANativeWindow_cancelBuffer", "ANativeWindow_dequeueBuffer",
    "ANativeWindow_getFormat", "ANativeWindow_query", "ANativeWindow_queueBuffer", "ANativeWindow_release",
    "ANativeWindow_setSharedBufferMode", "ANativeWindow_setSwapInterval", "ANativeWindow_setUsage",
    "__android_log_print", "__android_log_write", "atrace_begin_body", "atrace_end_body",
    "atrace_get_enabled_tags", "atrace_init", "drmCloseBufferHandle", "drmCommandWriteRead",
    "drmDevicesEqual", "drmFreeDevice", "drmFreeVersion", "drmGetCap", "drmGetDevice2", "drmGetDevices2",
    "drmGetPrimaryDeviceNameFromFd", "drmGetRenderDeviceNameFromFd", "drmGetVersion", "drmIoctl",
    "drmPrimeFDToHandle", "drmPrimeHandleToFD", "hw_get_module", "property_get", "sync_merge", "sync_wait",
)

_MACHINE_OK = ("AArch64", "EM_AARCH64")


class CheckError(Exception):
    pass


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_lock(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def lock_component(lock, name):
    for component in lock["components"]:
        if component.get("name") == name:
            return component
    raise CheckError(f"lock has no component '{name}'")


def lock_group_names(lock):
    return sorted(c["name"] for c in lock["components"] if c.get("group") == LOCK_GROUP)


def pip_requirements(lock):
    lines = []
    for name in PYTHON_TOOLS:
        component = lock_component(lock, name)
        if component.get("kind") != "prebuilt" or not component.get("url") or not component.get("sha256"):
            raise CheckError(f"lock entry '{name}' is not a pinned wheel")
        lines.append(f"{component['url']} --hash=sha256:{component['sha256']}")
    return "\n".join(lines) + "\n"


# ELF parsing. The inputs are the text of llvm-readelf and llvm-nm output.

def parse_header(text):
    fields = {}
    for line in text.splitlines():
        match = re.match(r"\s*(Class|Machine):\s*(.+?)\s*$", line)
        if match:
            fields[match.group(1)] = match.group(2)
    return {"class": fields.get("Class"), "machine": fields.get("Machine")}


def parse_dynamic(text):
    needed, runpath, soname = [], [], None
    for line in text.splitlines():
        match = re.search(r"\((NEEDED|SONAME|RUNPATH|RPATH)\)\s.*?\[([^\]]*)\]", line)
        if not match:
            continue
        kind, value = match.group(1), match.group(2)
        if kind == "NEEDED":
            needed.append(value)
        elif kind == "SONAME":
            soname = value
        else:
            runpath.append(value)
    return {"needed": needed, "soname": soname, "runpath": runpath}


def parse_load_alignments(text):
    alignments = []
    for line in text.splitlines():
        fields = line.split()
        if fields and fields[0] == "LOAD" and fields[-1].startswith("0x"):
            alignments.append(int(fields[-1], 16))
    return alignments


def parse_defined_functions(text):
    names = set()
    for line in text.splitlines():
        fields = line.split()
        if len(fields) == 3 and fields[1] == "T":
            names.add(fields[2])
    return names


def run_tool(binary, args):
    result = subprocess.run([binary] + args, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise CheckError(f"{binary} {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout


def elf_record(path, readelf, nm):
    header = parse_header(run_tool(readelf, ["-h", str(path)]))
    dynamic = parse_dynamic(run_tool(readelf, ["-d", str(path)]))
    aligns = parse_load_alignments(run_tool(readelf, ["-l", str(path)]))
    exports = parse_defined_functions(run_tool(nm, ["-D", "--defined-only", str(path)]))
    return {
        "class": header["class"],
        "machine": header["machine"],
        "needed": dynamic["needed"],
        "soname": dynamic["soname"],
        "runpath": dynamic["runpath"],
        "loadAlign": min(aligns) if aligns else 0,
        "definedFunctions": len(exports),
        "_exports": exports,
    }


# Manifest

def shipped_paths(out):
    return [out / LIB_DIR / name for name in SHIPPED]


def write_manifest(out, lock_path, readelf, nm, tools):
    out = pathlib.Path(out)
    lock = load_lock(lock_path)
    mesa = lock_component(lock, MESA_NAME)
    records = []
    for name in SHIPPED:
        path = out / LIB_DIR / name
        if not path.is_file():
            raise CheckError(f"missing shipped library: {path}")
        record = elf_record(path, readelf, nm)
        record.pop("_exports")
        records.append({
            "path": f"{LIB_DIR}/{name}",
            "sha256": sha256_file(path),
            "size": path.stat().st_size,
            **record,
        })
    manifest = {
        "schemaVersion": SCHEMA_VERSION,
        "component": COMPONENT,
        "adr": "0018",
        "mesa": {
            "repository": mesa["repository"],
            "commit": mesa["commit"],
            "version": mesa["version"],
            "license": mesa["license"],
        },
        "lock": {"path": "ThirdParty/ThirdParty.lock.json", "sha256": sha256_file(lock_path), "group": LOCK_GROUP},
        "tools": tools,
        "buildFlags": list(mesa["buildFlags"]),
        "files": records,
    }
    with open(out / "manifest.json", "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2, sort_keys=False)
        handle.write("\n")
    return manifest


def verify(out, lock_path, readelf, nm):
    """Return a list of failures. An empty list means the output passes."""
    out = pathlib.Path(out)
    failures = []
    manifest_path = out / "manifest.json"
    if not manifest_path.is_file():
        return [f"missing {manifest_path}"]
    with open(manifest_path, encoding="utf-8") as handle:
        manifest = json.load(handle)
    lock = load_lock(lock_path)
    mesa = lock_component(lock, MESA_NAME)

    def need(condition, message):
        if not condition:
            failures.append(message)

    need(manifest.get("schemaVersion") == SCHEMA_VERSION, "manifest schemaVersion is not 1")
    need(manifest.get("component") == COMPONENT, "manifest component is not mesa-android")
    need(manifest.get("mesa", {}).get("commit") == mesa["commit"], "manifest Mesa commit differs from the lock")
    need(manifest.get("mesa", {}).get("version") == mesa["version"], "manifest Mesa version differs from the lock")
    need(manifest.get("buildFlags") == mesa["buildFlags"], "manifest buildFlags differ from the lock")
    need(manifest.get("lock", {}).get("sha256") == sha256_file(lock_path),
         "manifest was not built from the current lock (lock SHA-256 differs)")
    ndk_revision = manifest.get("tools", {}).get("ndk", "")
    need(ndk_revision.startswith("28.2.13676358"), "manifest NDK revision is not 28.2.13676358 (r28c)")

    files = {record["path"]: record for record in manifest.get("files", [])}
    expected = {f"{LIB_DIR}/{name}" for name in SHIPPED}
    need(set(files) == expected, f"manifest lists {sorted(files)}, expected {sorted(expected)}")

    for name, spec in SHIPPED.items():
        path = out / LIB_DIR / name
        record = files.get(f"{LIB_DIR}/{name}")
        if not path.is_file():
            failures.append(f"missing {path}")
            continue
        if record is None:
            continue
        need(sha256_file(path) == record.get("sha256"), f"{name}: SHA-256 differs from the manifest")
        need(path.stat().st_size == record.get("size"), f"{name}: size differs from the manifest")
        actual = elf_record(path, readelf, nm)
        exports = run_tool(nm, ["-D", "--defined-only", str(path)])
        need(actual["class"] == "ELF64", f"{name}: not an ELF64 file")
        need(actual["machine"] in _MACHINE_OK, f"{name}: machine is {actual['machine']}, not AArch64")
        need(actual["soname"] == name, f"{name}: SONAME is {actual['soname']}")
        need(not actual["runpath"], f"{name}: has a RUNPATH {actual['runpath']} from the build tree")
        need(actual["loadAlign"] >= MIN_LOAD_ALIGN, f"{name}: LOAD alignment {actual['loadAlign']:#x} is below 16 KB")
        need(set(actual["needed"]) <= spec["needed"],
             f"{name}: DT_NEEDED {sorted(set(actual['needed']) - spec['needed'])} is not allowed")
        need(actual["needed"] == record.get("needed"), f"{name}: DT_NEEDED differs from the manifest")
        defined = parse_defined_functions(exports)
        missing = sorted(spec["exports"] - defined)
        need(not missing, f"{name}: missing exports {missing}")

    gallium = out / LIB_DIR / "libgallium_dri.so"
    if gallium.is_file():
        imports = set()
        for name in SHIPPED:
            path = out / LIB_DIR / name
            if path.is_file():
                imports |= undefined_symbols(path, nm)
        missing_contract = sorted(set(GUEST_SYMBOL_CONTRACT) - imports)
        need(not missing_contract, f"the shipped libraries do not import the contract symbols {missing_contract}")
    return failures


def undefined_symbols(path, nm):
    names = set()
    for line in run_tool(nm, ["-D", "--undefined-only", str(path)]).splitlines():
        fields = line.split()
        if len(fields) >= 2 and fields[-2] == "U":
            names.add(fields[-1])
    return names


def build_parser():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    field = sub.add_parser("lock-field")
    field.add_argument("lock")
    field.add_argument("name")
    field.add_argument("field")

    req = sub.add_parser("requirements")
    req.add_argument("lock")

    group = sub.add_parser("group-names")
    group.add_argument("lock")

    man = sub.add_parser("manifest")
    man.add_argument("out")
    man.add_argument("--lock", required=True)
    man.add_argument("--readelf", required=True)
    man.add_argument("--nm", required=True)
    man.add_argument("--tool", action="append", default=[], metavar="KEY=VALUE")

    ver = sub.add_parser("verify")
    ver.add_argument("out")
    ver.add_argument("--lock", required=True)
    ver.add_argument("--readelf", required=True)
    ver.add_argument("--nm", required=True)
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        if args.command == "lock-field":
            value = lock_component(load_lock(args.lock), args.name).get(args.field)
            if value is None:
                raise CheckError(f"{args.name} has no field {args.field}")
            if isinstance(value, list):
                print("\n".join(str(item) for item in value))
            else:
                print(value)
        elif args.command == "requirements":
            sys.stdout.write(pip_requirements(load_lock(args.lock)))
        elif args.command == "group-names":
            print("\n".join(lock_group_names(load_lock(args.lock))))
        elif args.command == "manifest":
            tools = {}
            for item in args.tool:
                key, separator, value = item.partition("=")
                if not key or not separator:
                    raise CheckError(f"--tool expects KEY=VALUE, got {item!r}")
                tools[key] = value
            write_manifest(args.out, args.lock, args.readelf, args.nm, tools)
        elif args.command == "verify":
            failures = verify(args.out, args.lock, args.readelf, args.nm)
            for failure in failures:
                print(f"FAIL {failure}", file=sys.stderr)
            if failures:
                return 1
            print("verify: passed")
    except (CheckError, OSError, json.JSONDecodeError, subprocess.SubprocessError) as error:
        print(f"mesa_android: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
