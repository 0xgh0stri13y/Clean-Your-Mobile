#!/usr/bin/env python3
"""Clean Your Mobile - before and after report.

Reads the two snapshots in a session directory, diffs the package lists, and
writes the result as text, Markdown and JSON.

  python tools/report.py                      # the newest session
  python tools/report.py --session <name>     # a named session
  python tools/report.py --markdown           # print the Markdown to stdout

The report is deliberately honest: it reports what was measured and says so
when a number cannot be compared, rather than inventing an improvement.
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import List, Optional, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cym  # noqa: E402
from cym import C, Database, banner, die, hr, ok, step, warn  # noqa: E402


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(prog="report.py", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--session", help="session directory or name under backups/")
    p.add_argument("--markdown", action="store_true", help="print the Markdown report")
    p.add_argument("--json", dest="as_json", action="store_true", help="print the JSON report")
    return p.parse_args()


# A row of the comparison table. `good` says which direction is an improvement:
# -1 means lower is better, +1 means higher is better, 0 means neither.
ROWS: List[Tuple[str, str, List[str], str, int]] = [
    ("Installed packages", "packages.total", [], "", -1),
    ("Disabled packages", "packages.disabled", [], "", +1),
    ("RAM available", "memory_kb.available", [], "MB", +1),
    ("RAM used", "memory_kb.used", [], "MB", -1),
    ("Free storage on /data", "storage_kb.data_free", [], "MB", +1),
    ("Running processes", "runtime.processes", [], "", -1),
    ("Running services", "runtime.services", [], "", -1),
    ("Apps with location access", "permissions.location", [], "", -1),
    ("Apps with camera access", "permissions.camera", [], "", -1),
    ("Apps with microphone access", "permissions.microphone", [], "", -1),
    ("Apps with contacts access", "permissions.contacts", [], "", -1),
    ("Apps that can read SMS", "permissions.sms", [], "", -1),
]

KB_FIELDS = {"memory_kb", "storage_kb"}


def dig(blob: Optional[dict], dotted: str):
    if not blob:
        return None
    node = blob
    for part in dotted.split("."):
        if not isinstance(node, dict) or part not in node:
            return None
        node = node[part]
    return node


def scale(dotted: str, value):
    """Kilobyte fields are reported in MB; everything else is a plain count."""
    if value is None:
        return None
    if dotted.split(".")[0] in KB_FIELDS:
        return round(value / 1024)
    return value


def fmt(value, unit: str) -> str:
    if value is None:
        return "not measured"
    return f"{value:,}{(' ' + unit) if unit else ''}"


def delta(before, after, good: int) -> Tuple[str, str]:
    """Returns (text, verdict) where verdict is better / worse / same / n/a."""
    if before is None or after is None:
        return "-", "n/a"
    diff = after - before
    if diff == 0:
        return "no change", "same"
    sign = "+" if diff > 0 else ""
    pct = f" ({sign}{diff / before * 100:.0f}%)" if before else ""
    verdict = "same"
    if good:
        verdict = "better" if (diff > 0) == (good > 0) else "worse"
    return f"{sign}{diff:,}{pct}", verdict


VERDICT_COLOUR = {"better": C.GREEN, "worse": C.RED, "same": C.DIM, "n/a": C.DIM}


def main() -> int:
    args = parse_args()
    session = cym.resolve_session(args.session)
    assert session is not None

    before = cym.read_snapshot(session, "before")
    after = cym.read_snapshot(session, "after")

    quiet = args.as_json or args.markdown
    if not quiet:
        banner("report")
        print(f" Session : {session}")

    if before is None:
        die(f"No snapshot_before.json in {session}.\n"
            f"        Run: bash scripts/snapshot.sh before")
    if after is None:
        die(f"No snapshot_after.json in {session}.\n"
            f"        Run: adb reboot, wait for the phone, then "
            f"bash scripts/snapshot.sh after")

    device = before.get("device", {})

    # ------------------------------------------------------------- the diff --
    pkgs_before = set(cym.read_lines(session / "packages_before.txt"))
    pkgs_after = set(cym.read_lines(session / "packages_after.txt"))
    recorded = cym.read_lines(session / "removed_packages.txt")
    # failed_packages.txt is appended to, so re-running a plan leaves one row
    # per attempt. Keep the last attempt per package: that is the current state,
    # and an older row may predate a fix to the error reporting itself.
    _latest: dict = {}
    for _row in cym.read_lines(session / "failed_packages.txt"):
        _latest[_row.split("\t", 1)[0]] = _row
    failed_rows = list(_latest.values())

    # `pm list packages` lists disabled packages too, so a session run with
    # --disable leaves every one of its packages in packages_after.txt. Without
    # the disabled list below, all of them were reported as "came back on their
    # own - a system update usually did this", which is a false alarm telling
    # someone their work was undone when it was not.
    disabled_before = set(cym.read_lines(session / "packages_before_disabled.txt"))
    disabled_after = set(cym.read_lines(session / "packages_after_disabled.txt"))

    gone = sorted(pkgs_before - pkgs_after)
    appeared = sorted(pkgs_after - pkgs_before)
    # Packages this session switched off rather than uninstalled.
    disabled_now = sorted((set(recorded) & disabled_after) - disabled_before)
    # Still present AND enabled: those genuinely came back. An OTA or the ROM
    # put them there, and that is worth knowing.
    came_back = sorted((set(recorded) & pkgs_after) - disabled_after)

    db = Database.load()

    # --------------------------------------------------------------- tables --
    table = []
    for label, key, _, unit, good in ROWS:
        b = scale(key, dig(before, key))
        a = scale(key, dig(after, key))
        text, verdict = delta(b, a, good)
        table.append({
            "label": label, "key": key, "unit": unit,
            "before": b, "after": a, "delta": text, "verdict": verdict,
        })

    anim_before = dig(before, "animation") or {}
    anim_after = dig(after, "animation") or {}
    home_before = before.get("home_launcher", "unknown")
    home_after = after.get("home_launcher", "unknown")

    payload = {
        "generated": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "session": str(session),
        "device": device,
        "snapshots": {"before": before.get("taken"), "after": after.get("taken")},
        "metrics": table,
        "packages": {
            "removed_count": len(gone),
            "removed": gone,
            "disabled_count": len(disabled_now),
            "disabled": disabled_now,
            "recorded_in_log": len(recorded),
            "reappeared": came_back,
            "new_since_before": appeared,
            "failed": failed_rows,
        },
        "home_launcher": {"before": home_before, "after": home_after},
        "animation": {"before": anim_before, "after": anim_after},
    }

    if args.as_json:
        print(json.dumps(payload, indent=2))
        _write_files(session, payload, table, db, gone, came_back, appeared,
                     failed_rows, device, before, after, disabled_now)
        return 0

    md = _markdown(payload, table, db, gone, came_back, appeared, failed_rows,
                   disabled_now)
    if args.markdown:
        print(md)
        _write_files(session, payload, table, db, gone, came_back, appeared,
                     failed_rows, device, before, after, disabled_now)
        return 0

    # -------------------------------------------------------- terminal view --
    hr()
    print(f" Device  : {device.get('brand', '?')} {device.get('model', '?')}")
    print(f" Android : {device.get('android', '?')} (API {device.get('sdk', '?')})")
    print(f" Before  : {before.get('taken', '?')}")
    print(f" After   : {after.get('taken', '?')}")
    hr()
    print()

    step("Measured")
    print(f"  {'':<29}{'before':>14}{'after':>14}{'change':>18}")
    for row in table:
        colour = VERDICT_COLOUR[row["verdict"]]
        print(f"  {row['label']:<29}"
              f"{fmt(row['before'], row['unit']):>14}"
              f"{fmt(row['after'], row['unit']):>14}"
              f"{colour}{row['delta']:>18}{C.RESET}")

    print()
    step(f"Packages removed: {len(gone)}")
    if gone:
        for pid in gone[:40]:
            entry = db.get(pid)
            name = entry.name if entry else "not in the database"
            print(f"  {C.GREEN}-{C.RESET} {pid:<46} {C.DIM}{name}{C.RESET}")
        if len(gone) > 40:
            print(f"  {C.DIM}... and {len(gone) - 40} more, all listed in report.md{C.RESET}")
    elif disabled_now:
        print(f"  {C.DIM}None - this session used --disable, so nothing was "
              f"uninstalled.{C.RESET}")
    else:
        print(f"  {C.DIM}The two package lists are identical.{C.RESET}")

    if disabled_now:
        print()
        step(f"Packages disabled: {len(disabled_now)}")
        print(f"  {C.DIM}Still installed but switched off, and they stay off "
              f"across reboots.{C.RESET}")
        for pid in disabled_now[:40]:
            entry = db.get(pid)
            name = entry.name if entry else "not in the database"
            print(f"  {C.GREEN}o{C.RESET} {pid:<46} {C.DIM}{name}{C.RESET}")
        if len(disabled_now) > 40:
            print(f"  {C.DIM}... and {len(disabled_now) - 40} more, all listed "
                  f"in report.md{C.RESET}")

    if came_back:
        print()
        step(f"Came back on their own: {len(came_back)}")
        print(f"  {C.DIM}Removed during this session but present again. A system"
              f" update usually did this.{C.RESET}")
        for pid in came_back:
            print(f"  {C.YELLOW}!{C.RESET} {pid}")

    if appeared:
        print()
        step(f"New since the before snapshot: {len(appeared)}")
        for pid in appeared[:15]:
            print(f"  {C.CYAN}+{C.RESET} {pid}")
        if len(appeared) > 15:
            print(f"  {C.DIM}... and {len(appeared) - 15} more{C.RESET}")

    if failed_rows:
        print()
        step(f"Would not come off: {len(failed_rows)}")
        for row in failed_rows[:15]:
            parts = row.split("\t")
            print(f"  {C.RED}x{C.RESET} {parts[0]:<46} "
                  f"{C.DIM}{parts[1] if len(parts) > 1 else ''}{C.RESET}")

    print()
    step("Still as it should be")
    print(f"  Home launcher   {home_before} -> {home_after}"
          f"{'  ' + C.GREEN + 'unchanged' + C.RESET if home_before == home_after else '  ' + C.YELLOW + 'CHANGED' + C.RESET}")
    print(f"  Animations      window {anim_before.get('window', '?')} -> "
          f"{anim_after.get('window', '?')}")

    print()
    step("Honest reading of these numbers")
    for line in _honest_notes(table, gone, came_back, disabled_now):
        print(f"  {line}")

    paths = _write_files(session, payload, table, db, gone, came_back, appeared,
                         failed_rows, device, before, after, disabled_now)
    print()
    hr()
    ok("Report written")
    for p in paths:
        print(f"   {p}")
    hr()
    return 0


def _honest_notes(table, gone, came_back, disabled_now=()) -> List[str]:
    notes = []
    by_key = {r["key"]: r for r in table}

    pkg = by_key.get("packages.total", {})
    if disabled_now:
        # Everything below needs this caveat first, or the rows of "no change"
        # read as a failure when they are the expected result of --disable.
        notes.append(f"{len(disabled_now)} package(s) were disabled, not uninstalled, so the")
        notes.append("installed count and the permission counts are unchanged by design:")
        notes.append("a disabled app is still installed and still holds its grants, it")
        notes.append("just cannot run. The figure that moved is 'Disabled packages'.")
    elif pkg.get("before") and pkg.get("after") is not None:
        removed = pkg["before"] - pkg["after"]
        notes.append(f"{removed} fewer packages is the one number that is exactly true.")

    mem = by_key.get("memory_kb.available", {})
    if mem.get("verdict") == "better":
        notes.append("More free RAM is real, but Android fills free RAM with cache by")
        notes.append("design, so this figure drifts on its own. Measure it twice.")
    elif mem.get("verdict") == "worse":
        notes.append("Free RAM went down. That is normal right after a reboot while")
        notes.append("the system warms its caches; it is not a sign anything broke.")

    if any(r["key"].startswith("permissions.") and r["verdict"] == "better" for r in table):
        notes.append("Fewer apps holding location, camera, mic and contacts is the")
        notes.append("most meaningful privacy change here.")

    notes.append("Battery life cannot be measured in minutes. Fewer background")
    notes.append("services means less wakeup work, but judge it over a few days.")

    proc = by_key.get("runtime.processes", {})
    if proc.get("verdict") == "better":
        notes.append("The process and service drop is real but flattered by the reboot:")
        notes.append("the after snapshot was taken on a freshly booted phone that has")
        notes.append("not opened anything yet. Re-measure after a day of normal use.")

    if came_back:
        notes.append(f"{len(came_back)} package(s) returned. Run tools/check.py after")
        notes.append("every system update and re-apply the plan.")
    return notes


def _markdown(payload, table, db, gone, came_back, appeared, failed_rows,
              disabled_now=()) -> str:
    d = payload["device"]
    out = []
    out.append(f"# Clean Your Mobile - {d.get('brand', '?')} {d.get('model', '?')}")
    out.append("")
    out.append(f"Android {d.get('android', '?')} (API {d.get('sdk', '?')}), "
               f"build `{d.get('build', '?')}`  ")
    out.append(f"Before: {payload['snapshots']['before']} · "
               f"After: {payload['snapshots']['after']}")
    out.append("")
    out.append("## What changed")
    out.append("")
    out.append("| Measure | Before | After | Change |")
    out.append("|---|---:|---:|---:|")
    for r in table:
        out.append(f"| {r['label']} | {fmt(r['before'], r['unit'])} | "
                   f"{fmt(r['after'], r['unit'])} | {r['delta']} |")
    out.append("")
    out.append(f"## Packages removed ({len(gone)})")
    out.append("")
    if gone:
        out.append("| Package | What it was | If you want it back |")
        out.append("|---|---|---|")
        for pid in gone:
            entry = db.get(pid)
            name = entry.name if entry else "not in the database"
            out.append(f"| `{pid}` | {name} | `adb shell cmd package install-existing {pid}` |")
    elif disabled_now:
        out.append("Nothing was uninstalled: this session used `--disable`.")
    else:
        out.append("Nothing was removed in this session.")

    if disabled_now:
        out.append("")
        out.append(f"## Packages disabled ({len(disabled_now)})")
        out.append("")
        out.append("Still installed but switched off, and they stay off across reboots.")
        out.append("")
        out.append("| Package | What it was | If you want it back |")
        out.append("|---|---|---|")
        for pid in disabled_now:
            entry = db.get(pid)
            name = entry.name if entry else "not in the database"
            out.append(f"| `{pid}` | {name} | `adb shell pm enable --user 0 {pid}` |")

    if came_back:
        out.append("")
        out.append(f"## Came back on their own ({len(came_back)})")
        out.append("")
        out.append("These were removed during this session but are installed again, "
                   "which a system update usually explains.")
        out.append("")
        for pid in came_back:
            out.append(f"- `{pid}`")
    if failed_rows:
        out.append("")
        out.append(f"## Would not come off ({len(failed_rows)})")
        out.append("")
        for row in failed_rows:
            parts = row.split("\t")
            out.append(f"- `{parts[0]}` - {parts[1] if len(parts) > 1 else 'no reason given'}")
    if appeared:
        out.append("")
        out.append(f"## New since the before snapshot ({len(appeared)})")
        out.append("")
        for pid in appeared:
            out.append(f"- `{pid}`")
    out.append("")
    out.append("## Reading these numbers honestly")
    out.append("")
    for line in _honest_notes(table, gone, came_back, disabled_now):
        out.append(f"{line}")
    out.append("")
    out.append("## Putting it back")
    out.append("")
    out.append("```bash")
    out.append("bash scripts/restore.sh                  # this session")
    out.append("bash scripts/restore.sh --list           # every session on record")
    out.append("```")
    out.append("")
    return "\n".join(out)


def _write_files(session: Path, payload, table, db, gone, came_back, appeared,
                 failed_rows, device, before, after, disabled_now=()) -> List[Path]:
    written = []

    md_path = session / "report.md"
    md_path.write_text(_markdown(payload, table, db, gone, came_back, appeared,
                                 failed_rows, disabled_now),
                       encoding="utf-8", newline="\n")
    written.append(md_path)

    json_path = session / "report.json"
    json_path.write_text(json.dumps(payload, indent=2), encoding="utf-8", newline="\n")
    written.append(json_path)

    txt_path = session / "report.txt"
    lines = [
        "CLEAN YOUR MOBILE - BEFORE AND AFTER",
        f"Device  : {device.get('brand', '?')} {device.get('model', '?')}",
        f"Android : {device.get('android', '?')} (API {device.get('sdk', '?')})",
        f"Before  : {before.get('taken', '?')}",
        f"After   : {after.get('taken', '?')}",
        "",
        f"{'Measure':<30}{'before':>14}{'after':>14}{'change':>18}",
        "-" * 76,
    ]
    for r in table:
        lines.append(f"{r['label']:<30}{fmt(r['before'], r['unit']):>14}"
                     f"{fmt(r['after'], r['unit']):>14}{r['delta']:>18}")
    lines += ["", f"Packages removed: {len(gone)}"]
    lines += [f"  - {p}" for p in gone]
    if came_back:
        lines += ["", f"Came back on their own: {len(came_back)}"]
        lines += [f"  ! {p}" for p in came_back]
    if failed_rows:
        lines += ["", f"Would not come off: {len(failed_rows)}"]
        lines += [f"  x {r}" for r in failed_rows]
    lines += ["", "Restore: bash scripts/restore.sh"]
    txt_path.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    written.append(txt_path)
    return written


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print()
        warn("Stopped.")
        raise SystemExit(130)
