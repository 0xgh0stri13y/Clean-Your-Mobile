#!/usr/bin/env python3
"""Clean Your Mobile - scan the phone and build a removal plan.

Reads every installed package off the phone, matches each one against the
debloat database, works out the brand, and writes a plan you can read before
anything is touched.

  python tools/scan.py                       # scan, print the findings
  python tools/scan.py --plan                # also write plan.txt
  python tools/scan.py --level recommended   # what goes into the plan
  python tools/scan.py --from-list FILE      # score a list, no phone needed
  python tools/scan.py --json                # machine-readable output

Levels, matching the database's own ratings:
  recommended  safe for everyone, no side effects         (the default)
  advanced     recommended + may break minor OEM features
  expert       advanced + OEM ecosystem features go with it

Nothing rated Unsafe and nothing on the never-touch list ever enters a plan,
at any level.
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cym  # noqa: E402
from cym import C, Adb, Database, banner, die, hr, ok, step, warn  # noqa: E402

LEVELS = {
    "recommended": ["Recommended"],
    "advanced": ["Recommended", "Advanced"],
    "expert": ["Recommended", "Advanced", "Expert"],
}

CATEGORY_LABEL = {
    "ads": "Advertising",
    "tracker": "Trackers",
    "telemetry": "Telemetry and analytics",
    "bloatware": "Preinstalled bloatware",
    "duplicate": "Duplicates of apps you already have",
    "carrier": "Carrier apps",
    "partner": "Partner and third-party preloads",
    "oem_feature": "Manufacturer features",
    "google": "Google extras",
    "essential": "Essential - never removed",
}


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="scan.py",
        description="Scan an Android phone and build a reversible removal plan.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    p.add_argument("--session", help="write into this session directory")
    p.add_argument("--level", choices=sorted(LEVELS), default="recommended",
                   help="how far the plan goes (default: recommended)")
    p.add_argument("--plan", action="store_true", help="write plan.txt in the session")
    p.add_argument("--json", dest="as_json", action="store_true", help="print JSON instead")
    p.add_argument("--from-list", metavar="FILE",
                   help="score a saved package list instead of reading a phone")
    p.add_argument("--brand", help="force a brand profile instead of detecting one")
    p.add_argument("--show-unknown", action="store_true",
                   help="list every package that is not in the database")
    p.add_argument("--all", dest="show_all", action="store_true",
                   help="print every matched package, not just a sample")
    return p.parse_args()


def heuristic_flags(pid: str) -> List[str]:
    """Why an unknown package looks suspicious. Evidence, not a verdict -
    nothing here ever lands in a plan on its own."""
    flags = []
    low = pid.lower()
    for needle, label in [
        ("analytics", "analytics"), ("telemetry", "telemetry"),
        ("tracker", "tracking"), ("adservice", "ad service"),
        (".ads", "ads"), ("adsdk", "ad sdk"), ("msa", "ad framework"),
        ("crashlytics", "crash reporting"), ("partner", "partner preload"),
        ("bloat", "name says bloat"), ("promotion", "promotions"),
        ("recommend", "recommendations"), ("usagestat", "usage statistics"),
        ("datacollect", "data collection"), ("feedback", "feedback upload"),
        ("push", "push service"), ("cloudservice", "cloud service"),
        ("gamecenter", "game store"), ("appstore", "app store"),
        ("themestore", "theme store"), ("browser", "browser duplicate"),
        ("facebook", "Facebook preload"), ("netflix", "preinstalled app"),
        ("booking", "preinstalled app"), ("linkedin", "preinstalled app"),
        ("spotify", "preinstalled app"), ("amazon", "preinstalled app"),
    ]:
        if needle in low:
            flags.append(label)
    return flags


def main() -> int:
    args = parse_args()
    db = Database.load()

    # ---------------------------------------------------------- the input ----
    device = None
    if args.from_list:
        path = Path(args.from_list)
        if not path.is_file():
            die(f"No such file: {path}")
        installed = sorted({
            ln.strip().replace("package:", "").split("=")[-1]
            for ln in path.read_text(encoding="utf-8").splitlines() if ln.strip()
        })
        disabled: List[str] = []
        session = cym.resolve_session(args.session, required=False)
        if not args.as_json:
            banner("scan (from a saved list)")
            print(f" Source : {path}")
    else:
        adb = Adb()
        device = adb.require_device()
        if not args.as_json:
            banner("scan")
            print(f" Device : {device}")
            print(f" Serial : {device.serial}")
        installed = adb.packages()
        disabled = adb.packages("-d")
        session = cym.resolve_session(args.session, required=False) or cym.new_session(device)

    if not installed:
        die("No packages came back. Is the phone unlocked and still connected?")

    brand = args.brand or db.detect_brand(installed, device.brand if device else "")
    profile = db.brands.get(brand, {})
    installed_set = set(installed)
    disabled_set = set(disabled)

    if not args.as_json:
        hr()
        print(f" Installed packages : {len(installed)}")
        print(f" Already disabled   : {len(disabled)}")
        if brand:
            print(f" Brand profile      : {profile.get('display_name', brand)}"
                  f"  ({profile.get('os_name', '?')})")
        else:
            print(" Brand profile      : none matched, using universal entries only")
        print(f" Plan level         : {args.level}")
        hr()

    # ------------------------------------------------------- the matching ----
    allowed_safety = LEVELS[args.level]
    buckets: Dict[str, List[cym.Pkg]] = {s: [] for s in cym.SAFETY_ORDER}
    plan: List[cym.Pkg] = []
    blocked: List[tuple] = []
    unknown: List[str] = []

    for pid in installed:
        entry = db.get(pid)
        if entry is None:
            # A package the database has never heard of is still protected if it
            # is on the never-touch list - report it as kept, not as unknown.
            reason = db.block_reason(pid)
            if reason == "on the never-touch list":
                blocked.append((pid, reason))
            else:
                unknown.append(pid)
            continue
        buckets[entry.safety if entry.safety in buckets else "Expert"].append(entry)

        reason = db.block_reason(pid)
        if reason:
            blocked.append((pid, reason))
            continue
        if pid in disabled_set:
            continue  # already off, nothing to gain
        if entry.safety in allowed_safety:
            plan.append(entry)

    # The phone's live defaults beat any list: never plan the launcher or the
    # keyboard the user is actually using.
    if device is not None:
        live_defaults = {adb.default_home(), adb.default_ime()}
        live_defaults.discard("")
        before = len(plan)
        plan = [p for p in plan if p.id not in live_defaults]
        if len(plan) != before:
            for pid in live_defaults:
                if db.get(pid):
                    blocked.append((pid, "in use right now as your default"))

    plan.sort(key=lambda p: (p.rank, p.category, p.id))
    unknown_flagged = [(pid, heuristic_flags(pid)) for pid in unknown]
    unknown_flagged = [(pid, f) for pid, f in unknown_flagged if f]

    # ----------------------------------------------------------- JSON out ----
    if args.as_json:
        print(json.dumps({
            "scanned": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "device": device.__dict__ if device else None,
            "brand": brand,
            "level": args.level,
            "counts": {
                "installed": len(installed),
                "disabled": len(disabled),
                "matched": sum(len(v) for v in buckets.values()),
                "unknown": len(unknown),
                "planned": len(plan),
                "blocked": len(blocked),
                **{s.lower(): len(v) for s, v in buckets.items()},
            },
            "plan": [p.__dict__ for p in plan],
            "blocked": [{"id": p, "reason": r} for p, r in blocked],
            "unknown_flagged": [{"id": p, "flags": f} for p, f in unknown_flagged],
            "unknown": unknown if args.show_unknown else [],
        }, indent=2))
        return 0

    # ----------------------------------------------------------- report -----
    print()
    step("What the database recognises on this phone")
    for safety in cym.SAFETY_ORDER:
        rows = buckets[safety]
        colour = cym.SAFETY_COLOUR.get(safety, "")
        note = {
            "Recommended": "safe for everyone",
            "Advanced": "safe for most, may touch minor OEM features",
            "Expert": "power users, have replacements ready",
            "Unsafe": "never removed, shown so you know they were seen",
        }[safety]
        print(f"  {colour}{safety:<12}{C.RESET} {len(rows):>4}   {C.DIM}{note}{C.RESET}")
    print(f"  {C.DIM}{'Unknown':<12}{C.RESET} {len(unknown):>4}   "
          f"{C.DIM}not in the database, never planned automatically{C.RESET}")

    print()
    step(f"The plan: {len(plan)} package(s) at level '{args.level}'")
    if not plan:
        print(f"  {C.DIM}Nothing to remove at this level. Try --level advanced.{C.RESET}")
    else:
        by_cat: Dict[str, List[cym.Pkg]] = {}
        for p in plan:
            by_cat.setdefault(p.category, []).append(p)
        for cat in sorted(by_cat, key=lambda c: -len(by_cat[c])):
            rows = by_cat[cat]
            print()
            print(f"  {C.BOLD}{CATEGORY_LABEL.get(cat, cat)}{C.RESET} "
                  f"{C.DIM}({len(rows)}){C.RESET}")
            shown = rows if args.show_all else rows[:8]
            for p in shown:
                colour = cym.SAFETY_COLOUR.get(p.safety, "")
                print(f"    {colour}*{C.RESET} {p.id}")
                print(f"      {p.name or '?'} - {p.description or 'no description'}")
                print(f"      {C.DIM}If removed: {p.if_removed or 'unknown'}{C.RESET}")
            if len(rows) > len(shown):
                print(f"    {C.DIM}... and {len(rows) - len(shown)} more "
                      f"(--all to see them){C.RESET}")

    if blocked:
        print()
        step(f"Kept back: {len(blocked)} package(s)")
        for pid, reason in sorted(set(blocked))[:20]:
            print(f"  {C.RED}x{C.RESET} {pid:<46} {C.DIM}{reason}{C.RESET}")
        if len(set(blocked)) > 20:
            print(f"  {C.DIM}... and {len(set(blocked)) - 20} more{C.RESET}")

    if unknown_flagged:
        print()
        step(f"Not in the database, but worth a look: {len(unknown_flagged)}")
        print(f"  {C.DIM}Manual review only. These are never added to a plan.{C.RESET}")
        for pid, flags in unknown_flagged[:25]:
            print(f"  {C.YELLOW}?{C.RESET} {pid:<46} {C.DIM}{', '.join(flags)}{C.RESET}")
        if len(unknown_flagged) > 25:
            print(f"  {C.DIM}... and {len(unknown_flagged) - 25} more{C.RESET}")

    if args.show_unknown and unknown:
        print()
        step(f"Every package not in the database: {len(unknown)}")
        for pid in unknown:
            print(f"    {pid}")

    if profile.get("special_notes"):
        print()
        step(f"About {profile.get('display_name', brand)}")
        import textwrap
        for line in textwrap.wrap(profile["special_notes"], 72):
            print(f"  {line}")

    # ------------------------------------------------------- write the plan --
    print()
    hr()
    if args.plan and session:
        plan_path = session / "plan.txt"
        with plan_path.open("w", encoding="utf-8", newline="\n") as fh:
            fh.write("# Clean Your Mobile - removal plan\n")
            if device:
                fh.write(f"# Device: {device.brand} {device.model}, Android {device.android}\n")
            fh.write(f"# Brand profile: {profile.get('display_name', brand or 'universal')}\n")
            fh.write(f"# Level: {args.level}\n")
            fh.write(f"# Generated: {datetime.now(timezone.utc).isoformat(timespec='seconds')}\n")
            fh.write("#\n# Read this before you apply it. Delete any line you want to keep.\n")
            fh.write("# Apply with: bash scripts/debloat.sh "
                     f"{plan_path.as_posix()} --dry-run\n#\n")
            current = None
            for p in plan:
                if p.category != current:
                    current = p.category
                    fh.write(f"\n# --- {CATEGORY_LABEL.get(current, current)} ---\n")
                fh.write(f"\n# {p.name or p.id} [{p.safety}]\n")
                fh.write(f"#   {p.description}\n")
                fh.write(f"#   If removed: {p.if_removed}\n")
                fh.write(f"{p.id}\n")
        ok(f"Plan written: {plan_path}")
        print(f" Review it, then: bash scripts/debloat.sh \"{plan_path}\" --dry-run")
    else:
        print(f" Add --plan to write this as a file you can edit and apply.")
    hr()
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print()
        warn("Stopped. Nothing was changed.")
        raise SystemExit(130)
