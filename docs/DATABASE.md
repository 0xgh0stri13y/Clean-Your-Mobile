# The database

Three files in [`database/`](../database/) decide what this project will and will not touch.
Everything else reads them.

| File | What it is |
|---|---|
| [`debloat_db.json`](../database/debloat_db.json) | What each package is, and how safe it is to remove. |
| [`essential_packages.json`](../database/essential_packages.json) | The never-touch list. A hard stop with no override. |
| [`brand_profiles.json`](../database/brand_profiles.json) | How to recognise a manufacturer, and what to know about it. |

Check your edits before opening a pull request:

```bash
python tools/validate_db.py            # errors and warnings
python tools/validate_db.py --fix      # correct what is safe to correct
python tools/validate_db.py --stats    # coverage by brand, safety and category
```

---

## debloat_db.json

```json
{
  "id": "com.samsung.android.bixby.agent",
  "brand": "samsung",
  "category": "bloatware",
  "safety": "Recommended",
  "name": "Bixby Voice Agent",
  "description": "Main Bixby voice assistant backend",
  "if_removed": "Bixby voice commands stop working. Google Assistant still works."
}
```

Every field is required.

| Field | Rules |
|---|---|
| `id` | The exact Android package name. Validated against `^[a-z][a-zA-Z0-9_]*(\.[a-zA-Z0-9_]+)+$`. |
| `brand` | One key from `brand_profiles.json`, or `universal` for anything cross-brand, or `carrier`. |
| `category` | One of the categories in `_meta.categories`. |
| `safety` | `Recommended`, `Advanced`, `Expert` or `Unsafe`. |
| `name` | What a person would call it, not the package name again. |
| `description` | What it does, in one plain sentence. |
| `if_removed` | **The field that matters.** What the owner of the phone loses, concretely. |

### `if_removed` is the whole point

A debloat list is only useful if someone can decide from it. "May break functionality" tells
nobody anything. Write the consequence:

> Bixby voice commands stop working. Google Assistant still works.

> The lock screen stops rotating sponsored wallpapers.

> Transit cards stored on the phone stop working. Move them off first.

If you cannot say what breaks, the entry is not ready, and the safety rating is probably too
generous.

### Safety ratings

| Rating | Means | Enters a plan at level |
|---|---|---|
| `Recommended` | No side effects for anyone. Ads, telemetry, dead weight. | `recommended` and up |
| `Advanced` | Safe for most people. A minor OEM feature goes with it. | `advanced` and up |
| `Expert` | An ecosystem feature goes with it. Have a replacement ready. | `expert` only |
| `Unsafe` | Never removed. Listed so a scan can report that it saw it. | never |

Rate conservatively. `Expert` costs a cautious user nothing; a wrong `Recommended` costs someone
their phone's camera.

### Categories

| Category | For |
|---|---|
| `ads` | Serves advertising. The first thing people want gone. |
| `tracker` | Sends identifiable behaviour off the device. |
| `telemetry` | Reports diagnostics and usage to the manufacturer. |
| `bloatware` | Preinstalled software with no system role. |
| `duplicate` | Does a job an app you already have does better. |
| `carrier` | Added by a network operator. |
| `partner` | A third-party preload: Facebook, Netflix, a game. |
| `oem_feature` | A real manufacturer feature someone might use. |
| `google` | A Google app beyond the required Play Services. |
| `essential` | Never removed. Pairs with `safety: Unsafe`. |

### One package, several brands

OPPO, OnePlus and realme share the HeyTap and ColorOS packages, so the same `id` appears once per
brand, with wording suited to that phone:

```json
{ "id": "com.heytap.market", "brand": "oppo",    "name": "HeyTap App Market", ... }
{ "id": "com.heytap.market", "brand": "realme",  "name": "HeyTap App Market", ... }
```

Two rules, both enforced by the validator:

- One row per `id` per `brand`. Two rows for the same pair is an error.
- Rows sharing an `id` must agree on `safety`. A package cannot be `Recommended` on realme and
  `Advanced` on OPPO.

At runtime the loader keeps one entry per `id` and, if the ratings ever disagree, the **most
cautious** one wins.

---

## essential_packages.json

The stop of last resort. Grouped by brand, with `universal` applying to every phone.

```json
{
  "universal": ["android", "com.android.systemui", "com.android.cellbroadcastreceiver"],
  "samsung":   ["com.sec.android.app.launcher", "com.samsung.android.app.camera"]
}
```

A package on this list is refused by every tool in the repository, with no flag to override it.
`CYM_ALLOW_PROTECTED=1` relaxes the *name pattern* check described below; it does not relax this.

This list is deliberately **broader** than the database. A false positive here costs someone one
feature. A false negative costs them a working phone.

The protected categories, from [`AGENTS.md`](../AGENTS.md):

phone calls · SMS and MMS · emergency alerts · SIM services · Wi-Fi · Bluetooth · camera ·
keyboard · home launcher · settings · Play Store · Play Services · security and keystore ·
system UI · setup wizard · permission management

Anything on this list must also be rated `Unsafe` in `debloat_db.json` if it appears there at all.
The validator treats a mismatch as an error, because a tool that looks the package up in the
database and sees `Expert` would offer to remove something the other guard refuses.

### The name pattern, as a second net

An unusual ROM will have packages no list has ever seen. All three implementations also refuse
anything whose *name* matches a protected category:

```
^android$ · ^oplus$ · systemui · ^com\.android\.settings · telecom · telephony · dialer · incallui
\.mms · messaging · inputmethod · latin · keyboard · ^com\.android\.vending$
^com\.google\.android\.gms · ^com\.google\.android\.gsf · setupwizard · provision
keystore · keychain · permissioncontroller · packageinstaller · networkstack
\.wifi · bluetooth · ^com\.android\.camera · launcher · \.home$
```

This pattern is duplicated in three places on purpose, so that no single file being wrong or
missing can disarm the guard:

- [`scripts/lib.sh`](../scripts/lib.sh) — `PROTECTED_PATTERNS`
- [`scripts/lib.ps1`](../scripts/lib.ps1) — `$script:ProtectedPattern`
- [`tools/cym.py`](../tools/cym.py) — `PROTECTED_PATTERNS`

**Change one, change all three.** The pattern is blunt and catches things that are safe to remove,
such as a theme store called `com.example.launcher.themes`. That is the intended trade: the
database already covers what is genuinely removable, and this net only has to be wrong in the safe
direction.

---

## brand_profiles.json

```json
"xiaomi": {
  "display_name": "Xiaomi / Redmi / POCO",
  "aliases": ["xiaomi", "redmi", "poco", "mi"],
  "detection_prefixes": ["com.miui", "com.xiaomi", "com.mi."],
  "os_name": "MIUI / HyperOS",
  "known_models": ["Redmi Note", "POCO", "Mi"],
  "special_notes": "Xiaomi devices are infamous for system-level ads...",
  "common_safe_removals": ["MSA (ad framework)", "Mi Browser", "Analytics"]
}
```

| Field | Used for |
|---|---|
| `detection_prefixes` | Scoring: how many installed packages start with one of these. |
| `aliases` | Matching `ro.product.brand`, which reports "Redmi" or "POCO", not "Xiaomi". |
| `special_notes` | Printed by `scan.py`. This is where the judgement goes. |
| `os_name`, `known_models`, `display_name` | Shown to the person reading the scan. |

`scan.py` picks a profile by prefix hit count, then adds a large bonus to whichever profile's name
or alias matches `ro.product.brand`. Without `aliases`, a Redmi phone matches no profile by name
and relies on prefixes alone.

`special_notes` is the most valuable field in this file, and the only one a tool cannot derive. Put
the thing someone would otherwise learn the hard way:

> Recent Huawei phones ship without Google Play Services, so AppGallery and Huawei ID are doing the
> work the Play Store does elsewhere. Removing them on such a phone leaves it with no way to
> install or update anything.

---

## Adding a package

1. Confirm the package is on a real phone: `adb shell pm list packages | grep <name>`.
2. Find out what it actually does. The package name is a hint, not a source.
3. Write `if_removed` first. If you cannot, you are not ready to add it.
4. Pick the most cautious rating you can defend.
5. `python tools/validate_db.py`.
6. Test it on a phone you own: `python tools/scan.py --plan`, then
   `bash scripts/debloat.sh <plan> --dry-run`, then for real, then use the phone for a day.

Full process in [CONTRIBUTING.md](../CONTRIBUTING.md).

## Consuming this database from another tool

The database is MIT-licensed and versioned so that other projects can build on it — a phone app, a
Shizuku front end, a different desktop tool. You do not need to ask, and attribution is welcome
rather than required.

Two JSON Schema files describe the contract:

| File | Describes |
|---|---|
| [`database/schema/debloat_db.schema.json`](../database/schema/debloat_db.schema.json) | `debloat_db.json` |
| [`database/schema/essential_packages.schema.json`](../database/schema/essential_packages.schema.json) | `essential_packages.json` |

Both are JSON Schema draft 2020-12. Validate with any standard validator:

```bash
pip install check-jsonschema
check-jsonschema --schemafile database/schema/debloat_db.schema.json database/debloat_db.json
check-jsonschema --schemafile database/schema/essential_packages.schema.json database/essential_packages.json
```

The repository's own `tools/validate_db.py` does **not** use these schemas, because AGENTS.md keeps
the Python tools on the standard library with nothing to `pip install`. It hand-rolls equivalent
checks plus the semantic ones a schema cannot express, such as "nothing on the never-touch list may
be rated below Unsafe". It does verify that `_meta.schema_version` is present, is semver, and has a
major version these tools understand.

### Versioning

`_meta.schema_version` follows semver and describes the **shape** of the file, not the data in it:

| Change | Bump |
|---|---|
| A package added, removed, or re-rated | `version`, not `schema_version` |
| A new optional field | minor |
| A new required field, a field removed or renamed, a field's type or allowed values narrowed | **major** |

Pin the major version. If you read a file whose `schema_version` major is higher than you were
built against, stop and tell the user rather than guessing — a major bump means something you rely
on has changed.

### If you are building a front end

Three things in this data are easy to get wrong, and getting them wrong is how someone's phone
breaks:

1. **`essential_packages.json` is not advisory.** It is the stop of last resort, and it is
   deliberately broader than the debloat database. Refuse these outright rather than warning about
   them. Do not offer an override.
2. **`total_packages` is a row count, not a package count.** A package shared across OPPO, OnePlus
   and realme appears once per brand. Quote `distinct_packages`. Match on `id`, never on `brand`.
3. **If two rows share an `id`, take the most cautious `safety`.** The repository's validator
   rejects rows that disagree, but a consumer should not assume a file it did not validate is
   clean.

And one thing that is not in the data: the **live device state**. The launcher and keyboard the
phone is using right now must come out of any plan whatever their rating says, and no list can tell
you which those are. Read them from the device:

```
cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME
settings get secure default_input_method
```

The three protections this repository applies are described in
[the guard section of the README](../README.md#safety). A front end that implements only the first
is materially less safe than one that implements all three.

### The field that matters

`if_removed` is the reason this database exists. Any list can tell someone a package is "safe to
remove"; this one tells them what they lose. If your interface has room for one line per package,
show that one.

## Sources

The ratings here draw on, and credit, the long-running community lists:

- [Universal Android Debloater (UAD-ng)](https://github.com/Universal-Debloater-Alliance/universal-android-debloater-next-generation)
- [MuntashirAkon/android-debloat-list](https://github.com/MuntashirAkon/android-debloat-list)
- [samolego/Canta](https://github.com/samolego/Canta)

Where they disagree, this database takes the more cautious rating.
