#!/usr/bin/env python3
"""Clean Your Mobile - keep the four copies of the guard pattern in step.

The protected-name pattern is written out in four places on purpose, so that no
single file being wrong or missing can disarm the guard (AGENTS.md). The cost of
that choice is drift, and this is what catches it.

  python tools/sync_guard.py            # check all four, exit 1 on a mismatch
  python tools/sync_guard.py --fix      # rewrite the others from scripts/lib.sh

scripts/lib.sh is the source of truth.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

SH = ROOT / "scripts" / "lib.sh"
PS = ROOT / "scripts" / "lib.ps1"
PY = ROOT / "tools" / "cym.py"

# The Android app lives in android/. Point elsewhere with CYM_ANDROID_DIR. If
# it is not there the Kotlin copy is simply skipped, since a checkout that only
# wants the command-line tools has no Android module.
_KT_REL = Path("app/src/main/java/com/cleanyourmobile/Guard.kt")
_ANDROID_CANDIDATES = [
    Path(os.environ["CYM_ANDROID_DIR"]) if os.environ.get("CYM_ANDROID_DIR") else None,
    ROOT / "android",
]
KT = next(
    (base / _KT_REL for base in _ANDROID_CANDIDATES if base and (base / _KT_REL).is_file()),
    ROOT / "android" / _KT_REL,
)


def shell_pattern() -> str:
    m = re.search(r"^PROTECTED_PATTERNS='(.+)'$", SH.read_text(encoding="utf-8"), re.M)
    if not m:
        sys.exit("could not find PROTECTED_PATTERNS in scripts/lib.sh")
    return m.group(1)


def ps_pattern() -> str | None:
    m = re.search(r"^\$script:ProtectedPattern = '(.+)'$", PS.read_text(encoding="utf-8"), re.M)
    return m.group(1) if m else None


def kt_pattern() -> str | None:
    if not KT.is_file():
        return None
    m = re.search(r'const val PROTECTED_PATTERN_SOURCE = """(.*?)"""',
                  KT.read_text(encoding="utf-8"), re.S)
    return m.group(1) if m else None


def py_alternatives() -> list[str]:
    """tools/cym.py keeps the pattern as a list of alternatives, so compare the
    set of branches rather than one string."""
    text = PY.read_text(encoding="utf-8")
    block = re.search(r"PROTECTED_PATTERNS = \[(.*?)\]", text, re.S)
    if not block:
        return []
    return re.findall(r'r"([^"]*)"', block.group(1))


PRESET_PY = ROOT / "tools" / "preset.py"
_PRESET_KT_REL = Path("app/src/main/java/com/cleanyourmobile/Preset.kt")
PRESET_KT = next(
    (base / _PRESET_KT_REL for base in _ANDROID_CANDIDATES
     if base and (base / _PRESET_KT_REL).is_file()),
    ROOT / "android" / _PRESET_KT_REL,
)


def check_preset_pattern() -> list[str]:
    """The preset package-name check, duplicated in Python and Kotlin.

    Returns the problems found. A missing file is not a problem: a checkout
    without the Android module, or without preset.py, is legitimate.
    """
    if not PRESET_PY.is_file():
        return []

    py_text = PRESET_PY.read_text(encoding="utf-8")
    m = re.search(r'^PKG_RE\s*=\s*re\.compile\(r"(.+?)"\)\s*$', py_text, re.M)
    if not m:
        return ["tools/preset.py: could not find PKG_RE"]
    want = m.group(1)

    caps = {}
    for key in ("MAX_PKG_LEN", "MAX_PACKAGES"):
        c = re.search(rf"^{key}\s*=\s*(\d+)\s*$", py_text, re.M)
        if not c:
            return [f"tools/preset.py: could not find {key}"]
        caps[key] = c.group(1)

    if not PRESET_KT.is_file():
        print(" Preset.kt       : absent (the Android app is not beside this checkout)")
        return []

    kt_text = PRESET_KT.read_text(encoding="utf-8")
    k = re.search(r'PACKAGE_PATTERN_SOURCE\s*=\s*"""(.+?)"""', kt_text, re.S)
    if not k:
        return [f"{PRESET_KT}: could not find PACKAGE_PATTERN_SOURCE"]

    problems = []
    if k.group(1) != want:
        problems.append(
            f"{PRESET_KT}: package pattern differs from tools/preset.py"
        )
    for key, value in caps.items():
        kt_key = {"MAX_PKG_LEN": "MAX_PKG_LEN", "MAX_PACKAGES": "MAX_PACKAGES"}[key]
        c = re.search(rf"const val {kt_key}\s*=\s*(\d+)", kt_text)
        if not c:
            problems.append(f"{PRESET_KT}: could not find {kt_key}")
        elif c.group(1) != value:
            problems.append(
                f"{PRESET_KT}: {kt_key} is {c.group(1)}, tools/preset.py says {value}"
            )
    if not problems:
        print(" Preset.kt       : matches (package-name check and caps)")
    return problems


def branches(pattern: str) -> list[str]:
    return pattern.strip("()").split("|")


def main() -> int:
    ap = argparse.ArgumentParser(prog="sync_guard.py", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--fix", action="store_true",
                    help="rewrite the PowerShell and Kotlin copies from scripts/lib.sh")
    args = ap.parse_args()

    want = shell_pattern()
    want_branches = branches(want)
    problems: list[str] = []

    print(f" source of truth : scripts/lib.sh ({len(want_branches)} branches)")

    # --- PowerShell: one string, must match exactly -------------------------
    got = ps_pattern()
    if got is None:
        problems.append("scripts/lib.ps1: could not find $script:ProtectedPattern")
    elif got != want:
        problems.append("scripts/lib.ps1: pattern differs from scripts/lib.sh")
        if args.fix:
            PS.write_text(
                re.sub(r"^\$script:ProtectedPattern = '.+'$",
                       "$script:ProtectedPattern = '" + want + "'",
                       PS.read_text(encoding="utf-8"), flags=re.M),
                encoding="utf-8", newline="\n")
            print("  fixed scripts/lib.ps1")
    else:
        print(" scripts/lib.ps1 : matches")

    # --- Kotlin: one raw string, must match exactly -------------------------
    got = kt_pattern()
    if got is None:
        print(" Guard.kt        : absent (the Android app is not beside this checkout)")
    elif got != want:
        problems.append(f"{KT}: pattern differs from scripts/lib.sh")
        if args.fix:
            KT.write_text(
                re.sub(r'(const val PROTECTED_PATTERN_SOURCE = """).*?(""")',
                       lambda m: m.group(1) + want + m.group(2),
                       KT.read_text(encoding="utf-8"), flags=re.S),
                encoding="utf-8", newline="\n")
            print(f"  fixed {KT}")
    else:
        print(" Guard.kt        : matches")

    # --- Python: a list of branches, compare as a set -----------------------
    py = py_alternatives()
    if not py:
        problems.append("tools/cym.py: could not find PROTECTED_PATTERNS")
    else:
        missing = [b for b in want_branches if b not in py]
        extra = [b for b in py if b not in want_branches]
        if missing or extra:
            for b in missing:
                problems.append(f"tools/cym.py: missing branch {b!r}")
            for b in extra:
                problems.append(f"tools/cym.py: has extra branch {b!r}")
        else:
            print(f" tools/cym.py    : matches ({len(py)} branches)")

    # --- the preset format's package-name check -----------------------------
    # Second duplicated pattern in the project, for the same reason: an
    # imported preset is untrusted input that reaches a privileged pm call, and
    # the phone validates it without asking a computer. tools/preset.py is the
    # source of truth; android/.../Preset.kt must agree.
    problems.extend(check_preset_pattern())

    print()
    if problems:
        for p in problems:
            print(f" MISMATCH  {p}")
        print()
        if not args.fix:
            print(" Run with --fix to rewrite the PowerShell and Kotlin copies")
            print(" of the GUARD pattern. tools/cym.py is a list and must be")
            print(" edited by hand, and so must Preset.kt's copy of the preset")
            print(" package-name check - --fix does not touch either.")
        return 1
    print(" All copies of the guard pattern agree.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
