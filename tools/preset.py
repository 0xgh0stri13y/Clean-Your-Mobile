#!/usr/bin/env python3
"""Clean Your Mobile - reusable, shareable removal profiles.

A plan from scan.py belongs to one phone and one moment. A preset is the
portable version: a named list of packages you can keep, apply to a second
phone, hand to someone else, or pull back out after a factory reset.

  python tools/preset.py save oneplus-min --from-session   # what you removed
  python tools/preset.py save pixel --from-plan plan.txt --description "..."
  python tools/preset.py save my-phone --from-device        # what is already gone
  python tools/preset.py list
  python tools/preset.py show oneplus-min
  python tools/preset.py apply oneplus-min --out plan.txt
  python tools/preset.py apply oneplus-min --device        # check this phone
  python tools/preset.py export oneplus-min -o share.json
  python tools/preset.py import share.json
  python tools/preset.py delete oneplus-min

A preset stores package names and nothing else. Ratings, descriptions and the
if_removed line are resolved from the database every time it is shown or
applied, so a preset written a year ago picks up today's ratings instead of
carrying a stale copy of them.

--from-device reads a phone that was debloated before this project saw it,
by hand or with another tool: every system package that is uninstalled for
the current user (`pm list packages -u` minus `pm list packages`) becomes the
preset, so the owner finally has a record of what came off, a way to put it
on a second phone, and something to share. Regular apps that were uninstalled
are left out: they have no system copy and this project never touches them.
--include-disabled adds the system packages that are switched off as well.

Safety. A preset is a proposal, never an instruction:

  * every package is put through the same guard as everything else, and one
    that the guard refuses is dropped from the plan with its reason shown;
  * a package the database does not know is reported as unverified and left
    out unless you pass --include-unknown, which marks it as unverified in
    the plan it writes;
  * an imported preset is untrusted input - it ends up in an adb shell command
    - so every package name is checked against a strict pattern and a file
    with one bad name is rejected whole rather than partly applied;
  * the plan this writes still goes through scripts/debloat.sh, which guards
    it again.

Exit codes:
  0  the command did what was asked
  1  it could not (no such preset, nothing valid in it, a refused import)
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import textwrap
from datetime import datetime, timezone
from pathlib import Path
from typing import List, Optional, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cym  # noqa: E402
from cym import C, Adb, Database, Pkg, banner, die, hr, ok, step, warn  # noqa: E402
from scan import CATEGORY_LABEL  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
PRESET_DIR = ROOT / "presets"

SCHEMA = "cym-preset"
SCHEMA_VERSION = "1.0.0"

# Android package names are dot-separated segments of letters, digits and
# underscores. Nothing else is allowed in, which is what keeps a shared preset
# from smuggling a shell metacharacter into `adb shell pm uninstall ...`.
PKG_RE = re.compile(r"[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)*")
MAX_PKG_LEN = 255
MAX_PACKAGES = 2000
NAME_RE = re.compile(r"[a-z0-9][a-z0-9-]*")


# ------------------------------------------------------------------- parsing --
def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="preset.py",
        description="Save, share and apply reusable removal profiles.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    sub = p.add_subparsers(dest="cmd", metavar="COMMAND")

    s = sub.add_parser("save", help="save a preset")
    s.add_argument("name")
    s.add_argument("--from-session", nargs="?", const="", metavar="SESSION",
                   help="packages removed in a session (default: the newest)")
    s.add_argument("--from-plan", metavar="FILE", help="read a plan file")
    s.add_argument("--from-device", action="store_true",
                   help="the system packages already uninstalled for this user on "
                        "the attached phone, by hand or by an earlier run")
    s.add_argument("--include-disabled", action="store_true",
                   help="with --from-device, also take the system packages that are disabled")
    s.add_argument("--packages", nargs="+", metavar="PKG", help="name them directly")
    s.add_argument("--description", default="", help="what this preset is for")
    s.add_argument("--brand", default="", help="brand this was built on")
    s.add_argument("--mode", choices=["remove", "disable"], default="remove",
                   help="how it was applied (default: remove)")
    s.add_argument("--force", action="store_true", help="overwrite an existing preset")

    sub.add_parser("list", help="list saved presets")

    for cmd, helptext in [("show", "resolve a preset against the database"),
                          ("delete", "delete a preset")]:
        q = sub.add_parser(cmd, help=helptext)
        q.add_argument("name")
        if cmd == "show":
            q.add_argument("--json", dest="as_json", action="store_true")

    a = sub.add_parser("apply", help="turn a preset into a reviewed plan")
    a.add_argument("name")
    a.add_argument("--out", metavar="FILE", help="write the plan here")
    a.add_argument("--device", action="store_true",
                   help="also check what is installed on the attached phone")
    a.add_argument("--include-unknown", action="store_true",
                   help="include packages the database does not know, marked unverified")

    e = sub.add_parser("export", help="print a preset as JSON")
    e.add_argument("name")
    e.add_argument("-o", "--out", metavar="FILE", help="write here instead of stdout")

    i = sub.add_parser("import", help="read a preset from JSON")
    i.add_argument("file", help="a .json file, or - for stdin")
    i.add_argument("--name", help="store it under this name instead")
    i.add_argument("--force", action="store_true", help="overwrite an existing preset")

    return p.parse_args()


# -------------------------------------------------------------- preset files --
def slug(text: str) -> str:
    out = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return out or "preset"


def preset_path(name: str) -> Path:
    return PRESET_DIR / f"{slug(name)}.json"


def clean_packages(raw: object, where: str) -> List[str]:
    """Validate a package list from a file someone else may have written.

    Rejects the whole file rather than silently dropping a bad entry: a preset
    that is half-applied is the dangerous kind.
    """
    if not isinstance(raw, list):
        die(f"{where}: 'packages' must be a list.")
    if len(raw) > MAX_PACKAGES:
        die(f"{where}: {len(raw)} packages - refusing anything over {MAX_PACKAGES}.")
    out, seen = [], set()
    for item in raw:
        if not isinstance(item, str):
            die(f"{where}: every package must be a string, got {type(item).__name__}.")
        pid = item.strip()
        if not pid or pid.startswith("#"):
            continue
        if len(pid) > MAX_PKG_LEN:
            die(f"{where}: package name longer than {MAX_PKG_LEN} characters.")
        if not PKG_RE.fullmatch(pid):
            die(f"{where}: {pid!r} is not a valid Android package name. "
                "Refusing the whole file rather than applying part of it.")
        if pid not in seen:
            seen.add(pid)
            out.append(pid)
    if not out:
        die(f"{where}: no packages in it.")
    return out


def load_preset(name: str) -> dict:
    path = preset_path(name)
    if not path.is_file():
        available = sorted(p.stem for p in PRESET_DIR.glob("*.json"))
        hint = f" Saved presets: {', '.join(available)}" if available else ""
        die(f"No preset called {slug(name)!r}.{hint}")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        die(f"{path} is not valid JSON: {exc}")
    if not isinstance(data, dict):
        die(f"{path}: expected a JSON object.")
    data["packages"] = clean_packages(data.get("packages"), str(path))
    return data


def write_preset(name: str, data: dict, force: bool) -> Path:
    PRESET_DIR.mkdir(parents=True, exist_ok=True)
    path = preset_path(name)
    if path.exists() and not force:
        die(f"{path} already exists. Pass --force to overwrite it.")
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n",
                    encoding="utf-8", newline="\n")
    return path


def build(name: str, packages: List[str], description: str = "",
          brand: str = "", mode: str = "remove") -> dict:
    return {
        "schema": SCHEMA,
        "schema_version": SCHEMA_VERSION,
        "name": slug(name),
        "description": description,
        "brand": brand,
        "mode": mode,
        "created": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "packages": packages,
    }


# ------------------------------------------------------------------- sources --
def read_package_lines(path: Path) -> List[str]:
    """Read a plan or a removal record: one package per line, # is a comment."""
    if not path.is_file():
        die(f"No such file: {path}")
    lines = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            lines.append(line)
    return lines


def from_session(arg: str) -> Tuple[List[str], str]:
    session = cym.resolve_session(arg or None, required=True)
    removed = session / "removed_packages.txt"
    plan = session / "plan.txt"
    if removed.is_file() and read_package_lines(removed):
        return read_package_lines(removed), f"removed in {session.name}"
    if plan.is_file():
        warn(f"{removed.name} is empty - falling back to {plan.name}. "
             "That is the plan, not what actually came off.")
        return read_package_lines(plan), f"planned in {session.name}"
    die(f"{session} has neither a removal record nor a plan.")


def from_device(db: Database, include_disabled: bool) -> Tuple[List[str], str, str, List[str]]:
    """The system packages already uninstalled for user 0 on the attached phone.

    Returns (packages, origin, detected brand, regular apps left out).
    """
    adb = Adb()
    device = adb.require_device()
    installed = set(adb.packages())
    system_ever = set(adb.packages("-u", "-s"))
    everything_ever = set(adb.packages("-u"))
    if not system_ever:
        die("The phone returned no system package list - refusing to guess.")
    removed = sorted(system_ever - installed)
    skipped = sorted((everything_ever - installed) - system_ever)
    packages = list(removed)
    origin = f"uninstalled for user 0 on {device.brand} {device.model}"
    if include_disabled:
        disabled = sorted(set(adb.packages("-d")) & system_ever)
        packages += [p for p in disabled if p not in removed]
        origin += f", plus {len(disabled)} disabled"
    if not packages:
        die("Nothing is uninstalled or disabled for this user on that phone. "
            "There is nothing to save yet.")
    brand = db.detect_brand(everything_ever, device.brand)
    return packages, origin, brand, skipped


# ------------------------------------------------------------------ resolving --
class Resolved:
    """A preset's packages sorted into what can and cannot be acted on."""

    def __init__(self) -> None:
        self.ready: List[Pkg] = []
        self.refused: List[Tuple[str, str]] = []
        self.unknown: List[str] = []
        self.missing: List[str] = []   # not installed on the attached phone
        self.already: List[str] = []   # already gone or disabled


def resolve(db: Database, packages: List[str],
            installed: Optional[set] = None,
            disabled: Optional[set] = None) -> Resolved:
    out = Resolved()
    for pid in packages:
        blocked = db.block_reason(pid)
        if blocked:
            out.refused.append((pid, blocked))
            continue
        if installed is not None:
            # A disabled package is still installed, so check that first.
            if pid in (disabled or set()):
                out.already.append(pid)
                continue
            if pid not in installed:
                out.missing.append(pid)
                continue
        entry = db.get(pid)
        if entry is None:
            out.unknown.append(pid)
        else:
            out.ready.append(entry)
    out.ready.sort(key=lambda e: (e.rank, e.id))
    return out


def report(db: Database, res: Resolved, on_device: bool) -> None:
    if res.refused:
        print()
        step(f"Refused by the guard: {len(res.refused)}")
        for pid, why in res.refused:
            print(f"  {C.RED}x{C.RESET} {pid:<45} {C.DIM}{why}{C.RESET}")
        print(f"  {C.DIM}Dropped. No flag overrides this.{C.RESET}")

    if res.already:
        print()
        step(f"Already off this phone: {len(res.already)}")
        for pid in res.already:
            print(f"  {C.GREEN}-{C.RESET} {pid}")

    if on_device and res.missing:
        print()
        step(f"Not on this phone: {len(res.missing)}")
        for pid in res.missing:
            print(f"  {C.DIM}.{C.RESET} {pid}")
        print(f"  {C.DIM}This preset was built on a different phone. Skipped.{C.RESET}")

    if res.unknown:
        print()
        step(f"Not in the database: {len(res.unknown)}")
        for pid in res.unknown:
            print(f"  {C.YELLOW}?{C.RESET} {pid}")
        print(f"  {C.DIM}Unverified - manual review needed. Left out unless you "
              f"pass --include-unknown.{C.RESET}")

    if res.ready:
        print()
        step(f"Ready to apply: {len(res.ready)}")
        current = None
        for entry in res.ready:
            if entry.safety != current:
                current = entry.safety
                colour = cym.SAFETY_COLOUR.get(current, "")
                print(f"  {colour}{current}{C.RESET}")
            print(f"    {entry.id}")
            detail = (f"{entry.name or '-'} - "
                      f"{entry.if_removed or 'consequence not recorded'}")
            print(textwrap.fill(detail, width=78, initial_indent="      " + C.DIM,
                                subsequent_indent="      ") + C.RESET)


# ------------------------------------------------------------------ commands --
def cmd_save(args: argparse.Namespace, db: Database) -> int:
    sources = [bool(args.from_session is not None), bool(args.from_plan),
               bool(args.packages), bool(args.from_device)]
    if sum(sources) != 1:
        die("Pick exactly one of --from-session, --from-plan, --from-device or --packages.")
    if args.include_disabled and not args.from_device:
        die("--include-disabled only means something with --from-device.")

    skipped_regular: List[str] = []
    brand = args.brand
    if args.packages:
        raw, origin = args.packages, "named on the command line"
    elif args.from_plan:
        raw, origin = read_package_lines(Path(args.from_plan)), args.from_plan
    elif args.from_device:
        raw, origin, detected, skipped_regular = from_device(db, args.include_disabled)
        brand = brand or detected
    else:
        raw, origin = from_session(args.from_session)

    packages = clean_packages(raw, origin)
    data = build(args.name, packages, args.description, brand, args.mode)
    path = write_preset(args.name, data, args.force)

    banner("preset - save")
    ok(f"{path.relative_to(ROOT).as_posix()} - {len(packages)} packages")
    print(f" Source: {origin}")
    if args.from_device:
        print(f" Brand : {brand or 'none detected'}")
        if skipped_regular:
            print(f" {C.DIM}Left out {len(skipped_regular)} regular app(s) that were also "
                  f"uninstalled: no system copy, so this project never touches them.{C.RESET}")
    res = resolve(db, packages)
    if res.refused:
        warn(f"{len(res.refused)} of them the guard will refuse - kept in the "
             "preset for the record, but they will never be applied.")
    if args.from_device and res.unknown:
        warn(f"{len(res.unknown)} of them are not in the database. They stay in the "
             "preset as a record of this phone, but `apply` leaves them out unless "
             "you pass --include-unknown. Each one is a database entry waiting to "
             "be written: see CONTRIBUTING.md.")
    hr()
    print(f" Apply it with: python tools/preset.py apply {data['name']} --device")
    if args.from_device:
        print(f" See it:        python tools/preset.py show {data['name']}")
    hr()
    return 0


def cmd_list() -> int:
    banner("preset - saved profiles")
    files = sorted(PRESET_DIR.glob("*.json"))
    if not files:
        print()
        print(f" No presets yet. Build one from a session:")
        print(f"   {C.DIM}python tools/preset.py save my-phone --from-session{C.RESET}")
        print()
        return 0
    print()
    for path in files:
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            print(f"  {C.RED}{path.stem:<24}{C.RESET} unreadable JSON")
            continue
        pkgs = data.get("packages") or []
        created = str(data.get("created", ""))[:10]
        brand = data.get("brand") or "-"
        print(f"  {C.BOLD}{path.stem:<24}{C.RESET}{len(pkgs):>4} packages  "
              f"{C.DIM}{brand:<10} {created}  {data.get('mode', '')}{C.RESET}")
        if data.get("description"):
            print(f"  {' ' * 24}{C.DIM}{data['description']}{C.RESET}")
    print()
    hr()
    print(f" {len(files)} preset" + ("" if len(files) == 1 else "s") +
          f" in {PRESET_DIR.relative_to(ROOT).as_posix()}/")
    hr()
    return 0


def cmd_show(args: argparse.Namespace, db: Database) -> int:
    data = load_preset(args.name)
    res = resolve(db, data["packages"])
    if args.as_json:
        print(json.dumps({
            "name": data.get("name"),
            "description": data.get("description", ""),
            "created": data.get("created", ""),
            "mode": data.get("mode", ""),
            "total": len(data["packages"]),
            "ready": [e.id for e in res.ready],
            "refused": [{"id": p, "reason": r} for p, r in res.refused],
            "unknown": res.unknown,
        }, indent=2, ensure_ascii=False))
        return 0
    banner(f"preset - {data.get('name', args.name)}")
    if data.get("description"):
        print(f" {data['description']}")
    print(f" {len(data['packages'])} packages, mode {data.get('mode', 'remove')}, "
          f"created {str(data.get('created', ''))[:10]}")
    report(db, res, on_device=False)
    print()
    hr()
    print(f" {len(res.ready)} applicable, {len(res.refused)} refused, "
          f"{len(res.unknown)} unverified")
    hr()
    return 0


def cmd_apply(args: argparse.Namespace, db: Database) -> int:
    data = load_preset(args.name)
    banner(f"preset - apply {data.get('name', args.name)}")

    installed = disabled = None
    if args.device:
        adb = Adb()
        device = adb.require_device()
        print(f" Phone: {device}")
        installed = set(adb.packages())
        disabled = set(adb.packages("-d"))

    res = resolve(db, data["packages"], installed, disabled)
    report(db, res, on_device=args.device)

    plan_ids = [e.id for e in res.ready]
    if args.include_unknown:
        plan_ids += res.unknown

    print()
    hr()
    if not plan_ids:
        print(" Nothing to apply.")
        hr()
        return 1

    if args.out:
        out = Path(args.out)
        write_plan(out, data, res, args.include_unknown)
        ok(f"Plan written: {out}")
        print(f" Review it, then: bash scripts/debloat.sh \"{out}\" --dry-run")
    else:
        print(f" {len(plan_ids)} package(s) would go into a plan.")
        print(f" Add --out plan.txt to write it.")
    hr()
    return 0


def write_plan(path: Path, data: dict, res: Resolved, include_unknown: bool) -> None:
    """Write a plan in the same shape scan.py writes, so debloat.sh takes it."""
    with path.open("w", encoding="utf-8", newline="\n") as fh:
        fh.write("# Clean Your Mobile - removal plan\n")
        fh.write(f"# From preset: {data.get('name', '')}\n")
        if data.get("description"):
            fh.write(f"# {data['description']}\n")
        fh.write(f"# Generated: "
                 f"{datetime.now(timezone.utc).isoformat(timespec='seconds')}\n")
        fh.write("#\n# Read this before you apply it. Delete any line you want to keep.\n")
        fh.write(f"# Apply with: bash scripts/debloat.sh {path.as_posix()} --dry-run\n#\n")
        current = None
        for entry in res.ready:
            if entry.category != current:
                current = entry.category
                fh.write(f"\n# --- {CATEGORY_LABEL.get(current, current)} ---\n")
            fh.write(f"\n# {entry.name or entry.id} [{entry.safety}]\n")
            fh.write(f"#   {entry.description}\n")
            fh.write(f"#   If removed: {entry.if_removed}\n")
            fh.write(f"{entry.id}\n")
        if include_unknown and res.unknown:
            fh.write("\n# --- Not in the database: unverified ---\n")
            fh.write("#   No rating and no recorded consequence. You asked for\n")
            fh.write("#   these with --include-unknown. Check each one.\n")
            for pid in res.unknown:
                fh.write(f"\n# {pid} [unverified]\n{pid}\n")


def cmd_export(args: argparse.Namespace) -> int:
    data = load_preset(args.name)
    text = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
    if args.out:
        Path(args.out).write_text(text, encoding="utf-8", newline="\n")
        banner("preset - export")
        ok(f"{args.out} - {len(data['packages'])} packages")
        print(" It holds package names only: no serial, no device, nothing personal.")
        hr()
    else:
        sys.stdout.write(text)
    return 0


def cmd_import(args: argparse.Namespace, db: Database) -> int:
    if args.file == "-":
        raw = sys.stdin.read()
        where = "stdin"
    else:
        path = Path(args.file)
        if not path.is_file():
            die(f"No such file: {path}")
        raw = path.read_text(encoding="utf-8")
        where = str(path)

    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        die(f"{where} is not valid JSON: {exc}")
    if not isinstance(data, dict):
        die(f"{where}: expected a JSON object.")
    if data.get("schema") not in (None, SCHEMA):
        die(f"{where}: not a Clean Your Mobile preset (schema {data.get('schema')!r}).")

    packages = clean_packages(data.get("packages"), where)
    name = args.name or data.get("name") or Path(args.file).stem
    stored = build(name, packages, str(data.get("description", "")),
                   str(data.get("brand", "")),
                   data.get("mode") if data.get("mode") in ("remove", "disable") else "remove")
    path = write_preset(name, stored, args.force)

    banner("preset - import")
    ok(f"{path.relative_to(ROOT).as_posix()} - {len(packages)} packages")
    print(" Every package name was checked against a strict pattern before this")
    print(" was saved. Nothing in it has been applied to anything yet.")
    res = resolve(db, packages)
    report(db, res, on_device=False)
    print()
    hr()
    print(f" {len(res.ready)} applicable, {len(res.refused)} the guard refuses, "
          f"{len(res.unknown)} unverified")
    print(f" Check it against your phone: python tools/preset.py apply "
          f"{stored['name']} --device")
    hr()
    return 0


def cmd_delete(args: argparse.Namespace) -> int:
    path = preset_path(args.name)
    if not path.is_file():
        die(f"No preset called {slug(args.name)!r}.")
    path.unlink()
    banner("preset - delete")
    ok(f"Deleted {path.relative_to(ROOT).as_posix()}")
    print(" Nothing on any phone changed: a preset is only a list.")
    hr()
    return 0


# ---------------------------------------------------------------------- main --
def main() -> int:
    args = parse_args()
    if not args.cmd:
        warn("Name a command: save, list, show, apply, export, import, delete. "
             "See --help.")
        return 1
    # Guard in force here as everywhere: this refuses an empty never-touch list.
    db = Database.load()

    if args.cmd == "save":
        return cmd_save(args, db)
    if args.cmd == "list":
        return cmd_list()
    if args.cmd == "show":
        return cmd_show(args, db)
    if args.cmd == "apply":
        return cmd_apply(args, db)
    if args.cmd == "export":
        return cmd_export(args)
    if args.cmd == "import":
        return cmd_import(args, db)
    if args.cmd == "delete":
        return cmd_delete(args)
    return 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print()
        raise SystemExit(130)
