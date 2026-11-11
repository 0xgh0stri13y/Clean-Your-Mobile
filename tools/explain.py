#!/usr/bin/env python3
"""Clean Your Mobile - look up what a package is and what removing it costs.

Everything else in this repository needs a phone. This does not: it answers
"what is com.vivo.abe, and what do I lose if it goes?" straight from the
audited database, so you can check a package name you saw in another tool, in
a forum post, or in your own app drawer before you touch anything.

  python tools/explain.py com.google.ar.core
  python tools/explain.py com.miui.analytics com.vivo.abe
  python tools/explain.py --search analytics
  python tools/explain.py --search store --brand samsung
  python tools/explain.py --safety Unsafe --brand xiaomi
  python tools/explain.py --list-brands
  python tools/explain.py --json com.google.ar.core

Searching prints one line per match; name a package exactly to get the full
card with the if_removed line and the reversible commands.

Exit codes:
  0  at least one package was found
  1  nothing matched
"""

from __future__ import annotations

import argparse
import json
import sys
import textwrap
from pathlib import Path
from typing import Dict, List, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cym  # noqa: E402
from cym import C, Database, Pkg, banner, hr, warn  # noqa: E402
from scan import CATEGORY_LABEL, heuristic_flags  # noqa: E402

WIDTH = 78
LABEL = 12

# What each rating means in one line, in the same words the scan uses.
SAFETY_NOTE = {
    "Recommended": "safe to remove on any phone",
    "Advanced": "removes a real feature - read the if_removed line",
    "Expert": "only with a reason, and only if you understand the cost",
    "Unsafe": "never removed by this project",
}


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="explain.py",
        description="Look up a package in the audited database. No phone needed.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    p.add_argument("packages", nargs="*", metavar="PACKAGE",
                   help="package names to explain, e.g. com.google.ar.core")
    p.add_argument("--search", metavar="TEXT",
                   help="find packages whose name, id or description contains TEXT")
    p.add_argument("--brand", metavar="BRAND",
                   help="only packages filed under this brand profile")
    p.add_argument("--safety", metavar="LEVEL", choices=cym.SAFETY_ORDER,
                   help="only packages with this rating (%s)" % ", ".join(cym.SAFETY_ORDER))
    p.add_argument("--category", metavar="CAT",
                   help="only packages in this category, e.g. telemetry")
    p.add_argument("--all", dest="show_all", action="store_true",
                   help="print every match instead of the first 40")
    p.add_argument("--json", dest="as_json", action="store_true",
                   help="print JSON instead of a formatted card")
    p.add_argument("--list-brands", action="store_true",
                   help="list the brand profiles and exit")
    return p.parse_args()


# ------------------------------------------------------------------ helpers ---
def field(label: str, value: str, colour: str = "") -> None:
    """One `label    value` line, wrapped under a hanging indent."""
    pad = " " * (2 + LABEL)
    # Wrap with the pad on every line so the width is right, then strip it back
    # off the first line, which already sits behind the printed label.
    body = textwrap.fill(value, width=WIDTH,
                         initial_indent=pad, subsequent_indent=pad)[len(pad):]
    print(f"  {C.BOLD}{label:<{LABEL}}{C.RESET}{colour}{body}{C.RESET}")


def guard_state(db: Database, pid: str) -> Optional[str]:
    """The guard's own verdict, so this tool can never disagree with it."""
    return db.block_reason(pid)


def as_dict(db: Database, pid: str, entry: Optional[Pkg]) -> Dict:
    blocked = guard_state(db, pid)
    out: Dict[str, object] = {
        "id": pid,
        "known": entry is not None,
        "blocked": blocked is not None,
        "block_reason": blocked,
        "essential": db.is_essential(pid),
        "protected_name": Database.is_protected_name(pid),
    }
    if entry is not None:
        out.update({
            "name": entry.name,
            "description": entry.description,
            "safety": entry.safety,
            "category": entry.category,
            "if_removed": entry.if_removed,
            "brands": db.brands_for.get(pid, [entry.brand]),
        })
    else:
        out["heuristic_flags"] = heuristic_flags(pid)
    return out


# -------------------------------------------------------------------- cards ---
def print_card(db: Database, pid: str, entry: Optional[Pkg]) -> None:
    print()
    print(f"{C.BOLD}{pid}{C.RESET}")

    if entry is None:
        print_unknown(db, pid)
        return

    if entry.name:
        print(f"  {entry.name}")
    if entry.description:
        print(textwrap.fill(entry.description, width=WIDTH,
                            initial_indent="  " + C.DIM, subsequent_indent="  ") + C.RESET)
    print()

    colour = cym.SAFETY_COLOUR.get(entry.safety, "")
    note = SAFETY_NOTE.get(entry.safety, "")
    field("Safety", f"{entry.safety}  {C.DIM}({note}){C.RESET}", colour)
    field("Category", CATEGORY_LABEL.get(entry.category, entry.category))
    brands = db.brands_for.get(pid, [entry.brand])
    field("Brands", ", ".join(brands))
    print()

    # The whole point of this project. Never abbreviate it.
    field("If removed", entry.if_removed or
          "not recorded - treat that as a reason to keep it, not to remove it")
    print()

    print_commands(db, pid)


def print_unknown(db: Database, pid: str) -> None:
    """An honest non-answer. A guess must never read like a rating."""
    print(f"  {C.YELLOW}Not in the database - manual review needed.{C.RESET}")
    print()
    flags = heuristic_flags(pid)
    if flags:
        field("Name hints", ", ".join(flags))
        print(textwrap.fill(
            "These are guesses from the package name alone, not a rating. "
            "Nothing here is evidence that the package is safe to remove.",
            width=WIDTH, initial_indent="  " + C.DIM, subsequent_indent="  ") + C.RESET)
    else:
        field("Name hints", "none - the name gives nothing away")
    print()
    blocked = guard_state(db, pid)
    if blocked:
        print_refusal(blocked)
    else:
        print(textwrap.fill(
            "The guard would not refuse this name, but an unrated package is "
            "still unrated: find out what it is before removing it, and keep "
            "it if you cannot.",
            width=WIDTH, initial_indent="  ", subsequent_indent="  "))


def print_refusal(reason: str) -> None:
    pad = " " * (2 + LABEL)
    field("Refused", f"{C.RED}The guard will not remove this - {reason}.{C.RESET}")
    print(textwrap.fill(
        "There is no flag that overrides this, and no removal command is "
        "offered for it.",
        width=WIDTH, initial_indent=pad + C.DIM, subsequent_indent=pad) + C.RESET)


def print_commands(db: Database, pid: str) -> None:
    """Reversible commands only, each next to the thing that undoes it."""
    blocked = guard_state(db, pid)
    if blocked:
        print_refusal(blocked)
        return

    print("  " + C.BOLD + "Reversible, user profile 0 only" + C.RESET)
    for label, cmd in [
        ("disable", f"adb shell pm disable-user --user 0 {pid}"),
        ("  undo", f"adb shell pm enable --user 0 {pid}"),
        ("remove", f"adb shell pm uninstall -k --user 0 {pid}"),
        ("  undo", f"adb shell cmd package install-existing {pid}"),
    ]:
        print(f"    {C.DIM}{label:<10}{C.RESET}{cmd}")
    print()
    print(textwrap.fill(
        "Disabling is the gentler of the two and removes nothing. Either way, "
        "prefer scripts/debloat.sh over pasting these by hand: it writes the "
        "restore record before it touches anything, which these commands do not.",
        width=WIDTH, initial_indent="  " + C.DIM, subsequent_indent="  ") + C.RESET)


# ------------------------------------------------------------------- search ---
def search(db: Database, args: argparse.Namespace) -> List[Pkg]:
    needle = (args.search or "").lower()
    out = []
    for entry in db.packages.values():
        if needle and needle not in " ".join([
            entry.id, entry.name, entry.description, entry.if_removed,
        ]).lower():
            continue
        if args.brand and args.brand.lower() not in [
            b.lower() for b in db.brands_for.get(entry.id, [entry.brand])
        ]:
            continue
        if args.safety and entry.safety != args.safety:
            continue
        if args.category and args.category.lower() != entry.category.lower():
            continue
        out.append(entry)
    # Most dangerous last, so the eye lands on what needs care.
    out.sort(key=lambda e: (e.rank, e.id))
    return out


def print_matches(db: Database, rows: List[Pkg], show_all: bool) -> None:
    shown = rows if show_all else rows[:40]
    print()
    for entry in shown:
        colour = cym.SAFETY_COLOUR.get(entry.safety, "")
        mark = f"{C.RED}refused{C.RESET}" if guard_state(db, entry.id) else "       "
        print(f"  {colour}{entry.safety:<12}{C.RESET}{mark}  {C.BOLD}{entry.id}{C.RESET}")
        if entry.name:
            print(f"  {' ' * 21}{C.DIM}{entry.name}{C.RESET}")
    print()
    hr()
    if len(shown) < len(rows):
        print(f" {len(shown)} of {len(rows)} matches - pass --all for the rest")
    else:
        print(f" {len(rows)} match" + ("" if len(rows) == 1 else "es"))
    print(" Name one exactly to see what removing it costs:")
    print(f"   {C.DIM}python tools/explain.py {shown[0].id}{C.RESET}")
    hr()


def print_brands(db: Database) -> None:
    """Every value --brand accepts, not just the ones with a phone profile:
    `universal` and `carrier` are real filters and were missing from this list."""
    banner("explain - brands")
    counts: Dict[str, int] = {}
    for brands in db.brands_for.values():
        for key in brands:
            counts[key] = counts.get(key, 0) + 1
    print()
    for key in sorted(counts):
        profile = db.brands.get(key)
        aliases = profile.get("aliases", []) if profile else []
        if aliases:
            extra = f" {C.DIM}({', '.join(aliases)}){C.RESET}"
        elif profile is None:
            extra = f" {C.DIM}(no phone profile - filter only){C.RESET}"
        else:
            extra = ""
        unit = "package" if counts[key] == 1 else "packages"
        print(f"  {C.BOLD}{key:<12}{C.RESET}{counts[key]:>4} {unit}{extra}")
    print()
    hr()
    print(f" {len(counts)} brands, {len(db.packages)} distinct packages")
    hr()


# --------------------------------------------------------------------- main ---
def main() -> int:
    args = parse_args()
    # Database.load() refuses to run on an empty never-touch list, so the guard
    # is in force here exactly as it is everywhere else.
    db = Database.load()

    if args.list_brands:
        print_brands(db)
        return 0

    filtering = any([args.search, args.brand, args.safety, args.category])
    if not args.packages and not filtering:
        warn("Name a package, or use --search. See --help.")
        return 1

    # ---- exact lookups
    if args.packages:
        found = [(pid, db.get(pid)) for pid in args.packages]
        if args.as_json:
            print(json.dumps([as_dict(db, pid, e) for pid, e in found],
                             indent=2, ensure_ascii=False))
            return 0 if any(e for _, e in found) else 1
        banner("explain")
        for pid, entry in found:
            print_card(db, pid, entry)
        print()
        hr()
        known = sum(1 for _, e in found if e)
        print(f" {known} of {len(found)} found in the database")
        hr()
        return 0 if known else 1

    # ---- search
    rows = search(db, args)
    if args.as_json:
        print(json.dumps([as_dict(db, e.id, e) for e in rows],
                         indent=2, ensure_ascii=False))
        return 0 if rows else 1
    banner("explain - search")
    if not rows:
        print()
        warn("Nothing matched. Try a shorter --search, or drop a filter.")
        return 1
    print_matches(db, rows, args.show_all)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print()
        raise SystemExit(130)
