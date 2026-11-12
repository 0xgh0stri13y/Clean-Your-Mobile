#!/usr/bin/env python3
"""Clean Your Mobile - what a system update put back.

A system update installs over the cleaned-up system: packages you removed come
back, and new preloads appear that no plan mentions. This compares the phone
against the plan that was applied.

  python tools/check.py                    # the newest session
  python tools/check.py --session <name>
  python tools/check.py --plan plan.txt    # check against a specific plan
  python tools/check.py --fix              # remove the ones that came back
  python tools/check.py --quiet            # exit code only, for a cron job

Exit codes:
  0  the phone still matches the plan
  1  some packages came back (or --fix could not finish)
  2  the check itself could not run (no device, no session, no plan)
"""

from __future__ import annotations

import argparse
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import List

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cym  # noqa: E402
from cym import C, Adb, Database, banner, hr, ok, step, warn  # noqa: E402


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(prog="check.py", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--session", help="session directory or name under backups/")
    p.add_argument("--plan", help="a plan file to check against")
    p.add_argument("--fix", action="store_true", help="re-apply the plan to what came back")
    p.add_argument("--disable", action="store_true",
                   help="with --fix, use pm disable-user instead of pm uninstall -k")
    p.add_argument("--quiet", "-q", action="store_true", help="print nothing, set the exit code")
    return p.parse_args()


def read_plan(path: Path) -> List[str]:
    out, seen = [], set()
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if line and line not in seen:
            seen.add(line)
            out.append(line)
    return out


def main() -> int:
    args = parse_args()
    quiet = args.quiet

    if not quiet:
        banner("check")

    # ------------------------------------------------------- what to expect --
    expected: List[str] = []
    source = ""
    if args.plan:
        plan_path = Path(args.plan)
        if not plan_path.is_file():
            if not quiet:
                cym.fail(f"No such plan: {plan_path}")
            return 2
        expected = read_plan(plan_path)
        source = str(plan_path)
    else:
        session = cym.resolve_session(args.session, required=False)
        if session is None:
            if not quiet:
                cym.fail(f"No session under {cym.BACKUP_ROOT}, and no --plan given.")
            return 2
        # Prefer what was actually removed, then fall back to the plan. An
        # existing-but-empty file does not count: a dry run used to leave a
        # zero-byte removed_packages.txt behind, which otherwise shadowed a
        # perfectly good plan.txt and reported the session as unusable.
        for candidate in ("removed_packages.txt", "plan.txt"):
            path = session / candidate
            if not path.is_file():
                continue
            found = read_plan(path) if candidate == "plan.txt" else cym.read_lines(path)
            if found:
                expected, source = found, str(path)
                break
        if not expected:
            if not quiet:
                cym.fail(f"{session} has no removed_packages.txt or plan.txt.")
            return 2

    # ------------------------------------------------------------ the phone --
    try:
        adb = Adb()
        device = adb.require_device()
    except SystemExit:
        return 2

    installed = set(adb.packages("--user", "0"))
    disabled = set(adb.packages("-d"))
    system = set(adb.packages("-s"))
    if not system:
        if not quiet:
            cym.fail("The phone returned no system package list - refusing to continue.")
        return 2
    db = Database.load()

    # A package counts as "back" when it is installed for user 0 and enabled.
    # A regular app is never "back" and never re-removed: it has no system copy.
    present = [p for p in expected if p in installed and p not in disabled]
    regular = sorted(p for p in present if p not in system)
    back = sorted(p for p in present if p in system)
    still_off = [p for p in expected if p not in back and p not in regular]

    if not quiet:
        hr()
        print(f" Device  : {device}")
        print(f" Against : {source}")
        print(f" In plan : {len(expected)}")
        hr()
        print()

    if regular and not quiet:
        step(f"{len(regular)} regular app(s) in the plan, left alone")
        print(f"  {C.DIM}Not system apps, so this tool never removes them. Uninstall them")
        print(f"  from the home screen like any other app if you want them gone.{C.RESET}")
        for pid in regular:
            entry = db.get(pid)
            print(f"  {C.DIM}-{C.RESET} {pid:<46} {C.DIM}{entry.name if entry else ''}{C.RESET}")
        print()

    if not back:
        if not quiet:
            ok(f"All {len(expected) - len(regular)} package(s) are still off. Nothing came back.")
            print(f"   Patch level: {device.security_patch or 'unknown'}")
        return 0

    if not quiet:
        step(f"{len(back)} package(s) came back")
        print(f"  {C.DIM}A system update is the usual reason. "
              f"Patch level now: {device.security_patch or 'unknown'}{C.RESET}")
        print()
        for pid in back:
            entry = db.get(pid)
            name = entry.name if entry else "not in the database"
            print(f"  {C.YELLOW}!{C.RESET} {pid:<46} {C.DIM}{name}{C.RESET}")
        print()
        print(f"  Still off: {len(still_off)}")

    if not args.fix:
        if not quiet:
            print()
            hr()
            print(" Re-apply with:  python tools/check.py --fix")
            print(" Or review first: the names above are a valid plan file.")
            hr()
        return 1

    # ---------------------------------------------------------------- --fix --
    # Every package --fix removes goes into a session's removal record the
    # moment it comes off, so scripts/restore.sh can put it back.
    record_session = cym.resolve_session(args.session, required=False)
    if record_session is None:
        if not quiet:
            cym.fail("--fix needs a session to keep a restore record in. "
                     "Run scripts/snapshot.sh before, or pass --session.")
        return 2
    record = record_session / "removed_packages.txt"
    recorded = set(cym.read_lines(record))

    if not quiet:
        print()
        step("Re-applying")

    done = failed = refused = 0
    for pid in back:
        reason = db.block_reason(pid)
        if reason:
            # Should not happen - a plan cannot contain these - but a hand-edited
            # plan can, and the guard holds everywhere.
            if not quiet:
                print(f"  {C.RED}x{C.RESET} {pid:<46} refused: {reason}")
            refused += 1
            continue
        if args.disable:
            reply = adb.shell(f"pm disable-user --user 0 {pid}").strip()
            good = "disabled-user" in reply
        else:
            reply = adb.shell(f"pm uninstall -k --user 0 {pid}").strip()
            good = "Success" in reply
        if good:
            if pid not in recorded:
                with record.open("a", encoding="utf-8") as fh:
                    fh.write(pid + "\n")
                recorded.add(pid)
            if not quiet:
                print(f"  {C.GREEN}ok{C.RESET}   {pid}")
            done += 1
        else:
            if not quiet:
                print(f"  {C.RED}fail{C.RESET} {pid:<46} {reply.splitlines()[0] if reply else 'no reply'}")
            failed += 1

    # Record what the fix did, next to the session it came from.
    stamp = datetime.now(timezone.utc).isoformat(timespec="seconds")
    with (record_session / "debloat.log").open("a", encoding="utf-8") as fh:
        fh.write(f"{stamp} CHECK-FIX reapplied={done} failed={failed} "
                 f"refused={refused} patch={device.security_patch}\n")

    if not quiet:
        print()
        hr()
        print(f" Re-applied : {done}")
        print(f" Failed     : {failed}")
        if refused:
            print(f" Refused    : {refused}")
        hr()
        if failed:
            warn("Some packages would not come off again. Reboot and try once more.")
    return 0 if failed == 0 and refused == 0 else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print()
        raise SystemExit(130)
