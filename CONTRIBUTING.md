# Contributing

The most useful contribution is a **database entry for a package on a phone you own**, so the next
person with that phone does not have to work it out themselves.

Contributing through a coding assistant? [AGENTS.md](AGENTS.md) gives it the same rules, in the
form an agent reads.

---

## What helps most

| Contribution | Why it matters |
|---|---|
| **Packages from your phone that are not in the database** | Coverage is the whole value of this project. A scan that says "not in the database" is a gap someone can close. |
| **A brand profile** | A brand nobody has described yet: Sony, ZTE, Nubia, Meizu, Sharp, Lava, Micromax. |
| **A correction** | A rating that is too generous, or an `if_removed` that turned out to be wrong. These are the most valuable reports of all. |
| **A `special_notes` paragraph** | The thing you learned the hard way about your brand. A tool cannot derive this. |
| **Troubleshooting** | A failure mode and its fix, for [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md). |

---

## Adding a package

### 1. Confirm it is real

```bash
adb shell pm list packages | grep -i <guess>
adb shell dumpsys package <exact.package.name> | head -40
```

Package names are not guessable and they differ between regions and builds. Read it off a phone.

### 2. Find out what it actually does

The name is a hint, not a source. Check the app's label in Settings, what permissions it holds,
and whether anything launches it:

```bash
adb shell cmd package resolve-activity --brief <pkg>
adb shell dumpsys package <pkg> | grep -A3 "requested permissions"
```

### 3. Write `if_removed` first

Before deciding the rating, write the consequence in one sentence that a non-technical person could
act on:

> Bixby voice commands stop working. Google Assistant still works.

Not this:

> ~~May break some functionality.~~

If you cannot write the first kind of sentence, the entry is not ready. This field is the reason
the database exists; everything else is metadata.

### 4. Pick the most cautious rating you can defend

| Rating | Use it when |
|---|---|
| `Recommended` | You are confident nobody loses anything. Ads, telemetry, dead weight. |
| `Advanced` | A minor OEM feature goes with it. |
| `Expert` | An ecosystem feature goes with it, or data has to be moved first. |
| `Unsafe` | It must never be removed. Also add it to `essential_packages.json`. |

When in doubt, go one level more cautious. `Expert` costs a careful user nothing. A wrong
`Recommended` costs someone a working feature, and they will not know which of forty packages did
it.

### 5. Add the row

In [`database/debloat_db.json`](database/debloat_db.json), under `packages`:

```json
{
  "id": "com.example.bloat",
  "brand": "samsung",
  "category": "bloatware",
  "safety": "Recommended",
  "name": "Example Bloat",
  "description": "What it does, one plain sentence",
  "if_removed": "What the phone's owner loses, concretely"
}
```

Field rules are in [docs/DATABASE.md](docs/DATABASE.md).

### 6. Validate

```bash
python tools/validate_db.py
```

This must pass with no errors. It checks the schema, the package-name format, duplicate rows,
ratings that disagree across brands, and — the important one — that nothing on the never-touch list
is rated as removable.

### 7. Test it on your own phone

Not optional for a new entry:

```bash
bash scripts/snapshot.sh before
python tools/scan.py --plan
bash scripts/debloat.sh backups/<session>/plan.txt --dry-run   # read what it says
bash scripts/debloat.sh backups/<session>/plan.txt
```

Then **use the phone for a day**. Calls, texts, camera, the apps you actually open. A package that
breaks something subtle — notifications from one app, a camera mode, emergency alerts — will not
show up in the first five minutes.

If something broke: `bash scripts/restore.sh`, then fix the rating or the `if_removed` text and say
what happened in the pull request. A report that an entry was wrong is worth more than a new entry.

---

## Adding a brand profile

In [`database/brand_profiles.json`](database/brand_profiles.json):

```json
"sony": {
  "display_name": "Sony",
  "aliases": ["sony", "xperia"],
  "detection_prefixes": ["com.sonymobile", "com.sonyericsson"],
  "os_name": "Xperia UI",
  "known_models": ["Xperia 1", "Xperia 5", "Xperia 10"],
  "special_notes": "The thing you would otherwise learn the hard way.",
  "common_safe_removals": ["What people usually want gone"]
}
```

Two things that are easy to get wrong:

- **`aliases` matters.** `ro.product.brand` reports "Redmi" and "POCO", not "Xiaomi"; "iQOO", not
  "vivo". Without the alias the profile is matched by package prefixes alone.
- **Add the brand's own launcher, camera, dialer and keyboard to
  [`essential_packages.json`](database/essential_packages.json)** under the same key. This is what
  stops a plan reaching them, and nobody else can know your brand's package names.

Then add some packages for that brand in the same pull request, or the profile matches a phone and
has nothing to say about it.

---

## Changing the tools

Four rules, all of them from [AGENTS.md](AGENTS.md), and all of them non-negotiable:

1. **Nothing may bypass the never-touch list.** If a change adds a path to a removal that does not
   pass through `block_reason` (shell: `scripts/lib.sh`, PowerShell: `scripts/lib.ps1`, Python:
   `tools/cym.py`), it will not be merged.
2. **No `pm uninstall` without both `-k` and `--user 0`.** No root. No `su`. No writes to a system
   partition.
3. **The protected-name pattern is duplicated in three files on purpose.** Change one, change all
   three. The duplication is the point: no single file being wrong can disarm the guard.
4. **The restore record is written before the first removal.** Not after the last one.

Beyond that: keep the shell and PowerShell twins in step, keep the Python tools on the standard
library only, and check what you changed:

```bash
bash -n scripts/*.sh
python -c "import ast,glob;[ast.parse(open(f,encoding='utf-8').read(),f) for f in glob.glob('tools/*.py')]"
python tools/validate_db.py
python tools/sync_guard.py
python tools/scan.py --from-list <a saved package list>   # no phone needed
```

PowerShell scripts must be **ASCII only**. Windows PowerShell 5.1 reads a file without a
byte-order mark as ANSI, and one emoji breaks the parse before a single line runs. This has
happened here already.

---

## Pull requests

- One topic per pull request. A batch of Samsung entries is one topic; Samsung entries plus a
  script change is two.
- Say which phone you tested on: brand, model, Android version, and the build number.
- Say what you used for a day afterwards.
- `python tools/validate_db.py` passes.

Nothing is expected of you beyond what you can honestly test. "I added this and used the phone for
a day" is a complete report. "I think this is probably safe" is a reason to rate it `Expert`
instead.

## Reporting a problem

Open an issue with:

- brand, model, Android version, build number
- what you ran
- what happened
- the output of `python tools/scan.py --json` if it is relevant

That JSON contains package names only — no personal data, no identifiers. Leave out anything you
would rather not publish.

Security issues go in [SECURITY.md](SECURITY.md) instead, privately.
