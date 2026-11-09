<!--
Thanks for this. Keep one topic per pull request: a batch of database entries is
one topic, database entries plus a script change is two.
-->

## What this changes

<!-- One or two sentences. -->

## What phone did you test on?

<!--
Brand, model, Android version, build number. "I did not test on a phone" is a
fine answer for a docs or tooling change — just say so.
-->

- **Phone:**
- **Android / build:**
- **What I used it for afterwards:**

---

## Checks

- [ ] `python tools/validate_db.py` passes with no errors

<!-- If you touched anything under scripts/, tools/ or android/: -->

- [ ] `bash -n scripts/*.sh`
- [ ] `python -c "import ast,glob;[ast.parse(open(f,encoding='utf-8').read(),f) for f in glob.glob('tools/*.py')]"`
- [ ] `python tools/sync_guard.py` — all four copies of the guard pattern agree

## If this adds or changes a database entry

- [ ] `if_removed` says what the owner of the phone **loses**, concretely — not "may break functionality"
- [ ] The rating is the most cautious one I can defend
- [ ] I removed it on a phone I own, then **used that phone for a day**
- [ ] Calls, texts, camera, emergency alerts and the apps I actually use still work

## If this changes the tools

These four come from [AGENTS.md](../blob/main/AGENTS.md) and are not negotiable.
Tick them or explain why they do not apply.

- [ ] **Nothing bypasses the never-touch list.** Every path to a removal still goes through `block_reason` / `Get-BlockReason` / `Database.block_reason` / `Guard.blockReason`
- [ ] **No `pm uninstall` without both `-k` and `--user 0`.** No root, no `su`, no system partition writes
- [ ] **The protected-name pattern is still identical in all four files.** `scripts/lib.sh` is the source of truth; `tools/sync_guard.py` verifies it
- [ ] **The restore record is still written before the first removal**, not after the last one
- [ ] Shell and PowerShell twins are in step
- [ ] Python tools still import nothing outside the standard library
- [ ] Any `.ps1` I touched is still **ASCII only** — PowerShell 5.1 reads a BOM-less file as ANSI, and one emoji breaks the parse before a line runs

---

<!--
A report that an entry was WRONG is worth more than a new entry. If you are
here because something broke, say exactly what broke — that is the most
valuable thing in this repository.
-->
