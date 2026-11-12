#!/usr/bin/env python3
"""Clean Your Mobile - database integrity check.

Run this after editing anything in database/. It is also what a contribution
has to pass.

  python tools/validate_db.py           # check, report, exit non-zero on error
  python tools/validate_db.py --fix     # correct what can be corrected safely
  python tools/validate_db.py --stats   # coverage by brand, safety, category

Checks, in the order a mistake matters:

  error    a package on the never-touch list is not rated Unsafe
  error    a package rated Unsafe is not on the never-touch list
  error    a missing or unknown safety rating, category or required field
  error    a package id that is not a plausible Android package name
  error    two rows for the same id and brand
  error    two rows for the same id that disagree on the safety rating
  warning  _meta.total_packages does not match the real count
  warning  a brand in the database with no profile in brand_profiles.json
  warning  an entry with no if_removed text, which the plan needs to show
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cym  # noqa: E402
from cym import C, DB_DIR, banner, hr, ok  # noqa: E402

PKG_RE = re.compile(r"^[a-z][a-zA-Z0-9_]*(\.[a-zA-Z0-9_]+)+$")
VALID_SAFETY = set(cym.SAFETY_ORDER)
REQUIRED = ("id", "brand", "category", "safety", "name", "description", "if_removed")


def main() -> int:
    ap = argparse.ArgumentParser(prog="validate_db.py", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--fix", action="store_true", help="correct what is safe to correct")
    ap.add_argument("--stats", action="store_true", help="print coverage statistics")
    args = ap.parse_args()

    banner("database check")

    db_path = DB_DIR / "debloat_db.json"
    ess_path = DB_DIR / "essential_packages.json"
    prof_path = DB_DIR / "brand_profiles.json"

    raw = json.loads(db_path.read_text(encoding="utf-8"))
    ess_raw = json.loads(ess_path.read_text(encoding="utf-8"))
    prof_raw = json.loads(prof_path.read_text(encoding="utf-8"))

    rows = raw.get("packages", [])
    meta = raw.get("_meta", {})
    valid_categories = set(meta.get("categories", []))

    essentials = set()
    for key, value in ess_raw.items():
        if key != "_meta" and isinstance(value, list):
            essentials.update(value)

    profiles = prof_raw.get("brands", {})

    errors: list = []
    warnings: list = []
    fixes: list = []

    # -------------------------------------------------------------- checks ----
    by_id_brand = Counter()
    safety_by_id = defaultdict(set)

    for i, row in enumerate(rows):
        pid = row.get("id", f"<row {i}>")
        where = f"packages[{i}] {pid}"

        missing = [f for f in REQUIRED if not row.get(f)]
        if missing:
            if missing == ["if_removed"]:
                warnings.append(f"{where}: no if_removed text")
            else:
                errors.append(f"{where}: missing {', '.join(missing)}")

        if row.get("id") and not PKG_RE.match(row["id"]):
            errors.append(f"{where}: not a plausible Android package name")

        safety = row.get("safety")
        if safety not in VALID_SAFETY:
            errors.append(f"{where}: safety '{safety}' is not one of "
                          f"{', '.join(cym.SAFETY_ORDER)}")
        else:
            safety_by_id[row.get("id")].add(safety)

        category = row.get("category")
        if valid_categories and category not in valid_categories:
            errors.append(f"{where}: category '{category}' is not in _meta.categories")

        # The one that actually protects a phone: anything on the never-touch
        # list must read as Unsafe wherever a tool looks it up.
        if row.get("id") in essentials and safety != "Unsafe":
            errors.append(f"{where}: on the never-touch list but rated '{safety}' - "
                          f"must be Unsafe")
            if args.fix:
                row["safety"] = "Unsafe"
                row["category"] = "essential"
                fixes.append(f"{pid}: safety -> Unsafe, category -> essential")

        # The reverse: the shell and PowerShell guards read only the never-touch
        # list, so an Unsafe row missing from it would be refused by two tools
        # and applied by the other two.
        if safety == "Unsafe" and row.get("id") and row.get("id") not in essentials:
            errors.append(f"{where}: rated Unsafe but not on the never-touch list - "
                          f"scripts/debloat.sh and .ps1 would not refuse it")

        by_id_brand[(row.get("id"), row.get("brand"))] += 1

    # Accessibility services are not a power-user tweak. Someone who depends on
    # a screen reader may be unable to put it back without it, so nothing in
    # this class belongs in a plan below Expert.
    ACCESSIBILITY = ("talkback", "accessibility", "switchaccess", "screenreader",
                     "braille", "livetranscribe", "soundamplifier", ".tts",
                     "texttospeech", "voiceaccess", "selecttospeak")
    for row in rows:
        pid = (row.get("id") or "").lower()
        if any(token in pid for token in ACCESSIBILITY):
            if row.get("safety") in ("Recommended", "Advanced"):
                errors.append(
                    f"{row.get('id')}: looks like an accessibility service but is rated "
                    f"'{row.get('safety')}' - must be Expert or Unsafe")

    for (pid, brand), count in by_id_brand.items():
        if count > 1:
            errors.append(f"{pid}: {count} rows for brand '{brand}' - "
                          f"one row per id per brand")

    for pid, ratings in safety_by_id.items():
        if len(ratings) > 1:
            errors.append(f"{pid}: rated {' and '.join(sorted(ratings))} on different "
                          f"brands - the rating must agree")

    # The published JSON Schema is the contract other tools consume. This check
    # is deliberately a presence-and-shape check only: validating properly needs
    # the `jsonschema` package, and AGENTS.md keeps these tools on the standard
    # library. Consumers validate with a real validator; see docs/DATABASE.md.
    SUPPORTED_SCHEMA_MAJOR = 1
    schema_dir = DB_DIR / "schema"
    for data_name, schema_name, blob in (
        ("debloat_db.json", "debloat_db.schema.json", meta),
        ("essential_packages.json", "essential_packages.schema.json", ess_raw.get("_meta", {})),
    ):
        declared = blob.get("schema_version")
        if not declared:
            errors.append(f"{data_name}: _meta.schema_version is missing")
            continue
        if not re.match(r"^\d+\.\d+\.\d+$", declared):
            errors.append(f"{data_name}: _meta.schema_version '{declared}' is not semver")
            continue
        if int(declared.split(".")[0]) != SUPPORTED_SCHEMA_MAJOR:
            errors.append(f"{data_name}: _meta.schema_version major is "
                          f"{declared.split('.')[0]}, these tools speak "
                          f"{SUPPORTED_SCHEMA_MAJOR}.x")
        if not (schema_dir / schema_name).is_file():
            errors.append(f"{data_name}: declares a schema but "
                          f"database/schema/{schema_name} is missing")

    real_total = len(rows)
    if meta.get("total_packages") != real_total:
        warnings.append(f"_meta.total_packages says {meta.get('total_packages')}, "
                        f"the file holds {real_total}")
        if args.fix:
            meta["total_packages"] = real_total
            fixes.append(f"_meta.total_packages -> {real_total}")

    distinct = len({r.get("id") for r in rows})
    if meta.get("distinct_packages") != distinct:
        if args.fix:
            meta["distinct_packages"] = distinct
            fixes.append(f"_meta.distinct_packages -> {distinct}")

    db_brands = {r.get("brand") for r in rows}
    for brand in sorted(db_brands - set(profiles) - {"universal", "carrier"}):
        warnings.append(f"brand '{brand}' has rows but no profile in brand_profiles.json")

    for pid in sorted(essentials):
        if pid not in {r.get("id") for r in rows}:
            # Not an error: the never-touch list is deliberately broader than
            # the database. Worth saying once, though, at --stats volume.
            pass

    if not PKG_RE.match("com.example.app"):  # self-test of the regex
        errors.append("internal: the package-name pattern is broken")

    # --------------------------------------------------------------- report ---
    hr()
    print(f" Rows                : {real_total}")
    print(f" Distinct packages   : {distinct}")
    print(f" Never-touch entries : {len(essentials)}")
    print(f" Brand profiles      : {len(profiles)}")
    hr()
    print()

    for msg in errors:
        print(f"{C.RED} error {C.RESET}{msg}")
    for msg in warnings:
        print(f"{C.YELLOW} warn  {C.RESET}{msg}")

    if args.fix and fixes:
        raw["_meta"] = meta
        db_path.write_text(json.dumps(raw, indent=2, ensure_ascii=False) + "\n",
                           encoding="utf-8", newline="\n")
        print()
        ok(f"Applied {len(fixes)} fix(es) to {db_path.name}")
        for f in fixes:
            print(f"   {f}")
        print()
        print(" Re-run without --fix to confirm.")
        return 0

    if args.stats:
        print()
        print(f"{C.BOLD} Coverage{C.RESET}")
        print()
        print(f"  {'brand':<14}{'rows':>6}  by safety")
        for brand, count in Counter(r.get("brand") for r in rows).most_common():
            sub = Counter(r.get("safety") for r in rows if r.get("brand") == brand)
            detail = "  ".join(f"{s[:3]} {sub[s]}" for s in cym.SAFETY_ORDER if sub[s])
            print(f"  {brand:<14}{count:>6}  {C.DIM}{detail}{C.RESET}")
        print()
        print(f"  {'category':<14}{'rows':>6}")
        for cat, count in Counter(r.get("category") for r in rows).most_common():
            print(f"  {cat:<14}{count:>6}")
        print()
        print(f"  {'safety':<14}{'rows':>6}")
        for s in cym.SAFETY_ORDER:
            n = sum(1 for r in rows if r.get("safety") == s)
            print(f"  {cym.SAFETY_COLOUR.get(s, '')}{s:<14}{C.RESET}{n:>6}")

    print()
    hr()
    if errors:
        print(f"{C.RED} {len(errors)} error(s){C.RESET}, {len(warnings)} warning(s)")
        if any("never-touch" in e or "total_packages" in e for e in errors + warnings):
            print(" Some of these can be corrected: python tools/validate_db.py --fix")
        hr()
        return 1
    if warnings:
        print(f" No errors, {len(warnings)} warning(s)")
        print(" Correctable ones: python tools/validate_db.py --fix")
    else:
        ok("The database is consistent.")
    hr()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
