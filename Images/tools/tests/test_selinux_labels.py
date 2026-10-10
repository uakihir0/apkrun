"""Tests for the file-context rule that labels the files a rebuild adds (#099, IR-623).

The excerpts in fixtures/selinux are verbatim lines of the stock contexts of build 16373615. The
labels in the stock partition were read with `xattr` from the exported tree, so these tests check
the rule against real data without the full files.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from apkrun_image.erofs import DIRECTORY, REGULAR_FILE, SYMLINK, Entry
from apkrun_image.selinux_labels import (
    ContextsError,
    check_reproduces,
    label_for,
    last_rule_label,
    literal_stem,
    load_contexts,
    parse_contexts,
    vendor_path,
)

FIXTURES = Path(__file__).parent / "fixtures" / "selinux"
PLAT_NAME = "system_a:/system/etc/selinux/plat_file_contexts"
VENDOR_NAME = "vendor_a:/etc/selinux/vendor_file_contexts"


def real_rules() -> list:
    """Return the stock rules: the platform contexts, then the vendor's, in load order."""
    return load_contexts(
        [
            (PLAT_NAME, (FIXTURES / "plat_file_contexts.excerpt").read_text(encoding="utf-8")),
            (VENDOR_NAME, (FIXTURES / "vendor_file_contexts.excerpt").read_text(encoding="utf-8")),
        ]
    )


def test_the_literal_stem_stops_at_the_first_metacharacter() -> None:
    assert literal_stem("/(vendor|system/vendor)(/.*)?") == 1
    assert literal_stem("/vendor/lib(64)?/libdrm.so") == len("/vendor/lib")
    assert literal_stem("/vendor/boot_otas(/.*)?") == len("/vendor/boot_otas")


@pytest.mark.parametrize(
    ("erofs_path", "kind", "stock_label"),
    [
        ("/", DIRECTORY, "u:object_r:vendor_file:s0"),
        ("/etc", DIRECTORY, "u:object_r:vendor_configs_file:s0"),
        ("/etc/selinux/vendor_file_contexts", REGULAR_FILE, "u:object_r:vendor_configs_file:s0"),
        ("/bin/sh", SYMLINK, "u:object_r:vendor_shell_exec:s0"),
        ("/odm", SYMLINK, "u:object_r:vendor_file:s0"),
        ("/lib64/libdrm.so", REGULAR_FILE, "u:object_r:same_process_hal_file:s0"),
        ("/lib64/egl/libEGL_emulation.so", REGULAR_FILE, "u:object_r:same_process_hal_file:s0"),
    ],
)
def test_the_real_rules_give_the_stock_labels(erofs_path: str, kind: str, stock_label: str) -> None:
    rules = real_rules()
    assert label_for(rules, erofs_path, kind) == stock_label
    assert last_rule_label(rules, erofs_path, kind) == stock_label


def test_the_new_mesa_libraries_get_the_egl_label() -> None:
    rules = real_rules()
    for name in (
        "libEGL_mesa.so",
        "libGLESv2_mesa.so",
        "libGLESv1_CM_mesa.so",
        "libgallium_dri.so",
    ):
        path = f"/lib64/egl/{name}"
        assert label_for(rules, path, REGULAR_FILE) == "u:object_r:same_process_hal_file:s0"
        assert last_rule_label(rules, path, REGULAR_FILE) == "u:object_r:same_process_hal_file:s0"


def test_the_longest_stem_beats_a_later_rule_with_a_shorter_stem() -> None:
    rules = load_contexts(
        [
            ("a", "/vendor/lib(64)?/a.so  u:object_r:specific_t:s0\n"),
            ("b", "/(vendor|system/vendor)(/.*)?  u:object_r:generic_t:s0\n"),
        ]
    )
    assert label_for(rules, "/lib64/a.so", REGULAR_FILE) == "u:object_r:specific_t:s0"
    # The last matching rule disagrees, which the rebuild refuses for a file it adds.
    assert last_rule_label(rules, "/lib64/a.so", REGULAR_FILE) == "u:object_r:generic_t:s0"


def test_a_tie_on_the_stem_goes_to_the_later_rule() -> None:
    rules = load_contexts(
        [
            ("a", "/(vendor|system/vendor)(/.*)?  u:object_r:generic_t:s0\n"),
            ("b", "/(vendor|system/vendor)/lib(64)?/egl(/.*)?  u:object_r:egl_t:s0\n"),
        ]
    )
    assert label_for(rules, "/lib64/egl/x.so", REGULAR_FILE) == "u:object_r:egl_t:s0"
    assert label_for(rules, "/bin/x", REGULAR_FILE) == "u:object_r:generic_t:s0"


def test_the_file_type_flag_limits_a_rule_to_one_kind() -> None:
    rules = parse_contexts(
        "t",
        "/vendor/x -f u:object_r:file_t:s0\n/vendor/x -d u:object_r:dir_t:s0\n",
    )
    assert label_for(rules, "/x", REGULAR_FILE) == "u:object_r:file_t:s0"
    assert label_for(rules, "/x", DIRECTORY) == "u:object_r:dir_t:s0"


def test_no_label_is_a_rule_result_and_not_a_missing_match() -> None:
    rules = parse_contexts("t", "/vendor/n <<none>>\n")
    assert label_for(rules, "/n", REGULAR_FILE) is None


def test_a_path_without_a_matching_rule_is_refused() -> None:
    rules = parse_contexts("t", "/vendor/only  u:object_r:x:s0\n")
    with pytest.raises(ContextsError, match="no file context matches"):
        label_for(rules, "/other", REGULAR_FILE)


@pytest.mark.parametrize(
    ("text", "message"),
    [
        ("/vendor/a -f u:object_r:x:s0 extra\n", "expected a pattern and a context"),
        ("/vendor/a -q u:object_r:x:s0\n", "unknown file type"),
        ("/vendor/( u:object_r:x:s0\n", "invalid pattern"),
        ("# only a comment\n", "no rules were found"),
    ],
)
def test_malformed_contexts_are_refused(text: str, message: str) -> None:
    with pytest.raises(ContextsError, match=message):
        parse_contexts("broken", text)


def test_the_contexts_must_reproduce_every_stock_label() -> None:
    rules = real_rules()
    entries = {
        "/lib64/egl/libEGL_emulation.so": Entry(
            path="/lib64/egl/libEGL_emulation.so",
            kind=REGULAR_FILE,
            mode=0o644,
            uid=0,
            gid=0,
            size=1,
            mtime="t",
            label="u:object_r:same_process_hal_file:s0",
        ),
        "/etc": Entry(
            path="/etc",
            kind=DIRECTORY,
            mode=0o755,
            uid=0,
            gid=0,
            size=1,
            mtime="t",
            label="u:object_r:vendor_configs_file:s0",
        ),
    }
    assert check_reproduces(rules, entries) == 2
    entries["/etc"] = Entry(
        path="/etc",
        kind=DIRECTORY,
        mode=0o755,
        uid=0,
        gid=0,
        size=1,
        mtime="t",
        label="u:object_r:vendor_file:s0",
    )
    with pytest.raises(ContextsError, match="give 1 stock labels a different value"):
        check_reproduces(rules, entries)


def test_vendor_paths_get_the_vendor_mount_prefix() -> None:
    assert vendor_path("/") == "/vendor"
    assert vendor_path("/lib64/egl/libEGL_mesa.so") == "/vendor/lib64/egl/libEGL_mesa.so"
