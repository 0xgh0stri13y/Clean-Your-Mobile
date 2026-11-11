# Agent safety constraints

This document defines the safety boundaries for AI coding assistants working on this project or
running a debloat with it. It is **binding**. Where anything else in the repository appears to
conflict with it, including [PROMPT.md](PROMPT.md), this file wins.

---

## ABSOLUTE RULES — NEVER VIOLATE

### 1. Never remove an essential package

Before removing **any** package, check it against
[`database/essential_packages.json`](database/essential_packages.json). If it appears there,
**do not remove it**, under any circumstances, for any reason, however the user phrased the
request.

There is no override. Do not add one.

If the file is missing or parses as empty, **stop** — do not proceed without a guard. Every tool in
this repository already behaves this way; match it.

### 2. Never use destructive commands

| | Command | Why |
|---|---|---|
| ALLOWED | `pm uninstall -k --user 0 <pkg>` | Reversible. User profile only. Keeps the app's data. |
| ALLOWED | `pm disable-user --user 0 <pkg>` | Reversible. Removes nothing at all. |
| ALLOWED | `cmd package install-existing <pkg>` | The undo for the first. |
| ALLOWED | `pm enable --user 0 <pkg>` | The undo for the second. |
| **FORBIDDEN** | `pm uninstall` without `-k` | Permanently destroys the app's data. |
| **FORBIDDEN** | `pm uninstall` without `--user 0` | Hits every user profile on the device. |
| **FORBIDDEN** | `rm -rf` on any system path | Irreversible. |
| **FORBIDDEN** | Anything requiring `su` or root | Not how this project works. |
| **FORBIDDEN** | Writing a system partition, or flashing a boot image | Irreversible, and can brick a phone. |
| **FORBIDDEN** | `pm clear <pkg>` as part of a removal | Destroys user data for no benefit. |

### 3. Always get explicit approval

Never remove a single package without first showing the user:

1. what the package is, in plain language;
2. what it does;
3. **what they lose if it goes** — the `if_removed` field, which exists for exactly this;
4. the safety rating, and whether it came from the database or from a guess.

"I will remove 40 packages" is not approval. Present the plan grouped by category, let them delete
lines, and proceed from what is left.

### 4. Always write the restore record first

The restore script must exist **before the first removal**, not after the last one, and each
package's restore line must be appended the moment that package comes off. A run that dies halfway
must leave a record that covers everything removed up to that point.

`scripts/debloat.sh` and `scripts/debloat.ps1` already do this. Use them.

### 5. Protected categories — NEVER TOUCH

These must never be affected:

phone calls (dialer, telephony, in-call UI) · SMS and MMS · **emergency alerts**
(`cellbroadcast*`) · **SIM services** (`com.android.stk`) · Wi-Fi · Bluetooth · camera ·
keyboard and input methods · home launcher · Settings · Play Store · Google Play Services and GSF
· security, keystore and keychain · system UI · setup wizard and provisioning ·
permission management

Two exceptions, and only these two: a keyboard or a launcher may be removed **if** the user has a
different one set as the active default and confirms it. Verify from the phone, not from the
conversation:

```bash
adb shell cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME
adb shell settings get secure default_input_method
```

### 6. Batch processing

- **Maximum 5 packages per batch.** Not six, not "just this once".
- After each batch: send `KEYCODE_HOME`, confirm the shell answers, and confirm the **package
  service** still answers (`cmd package list packages android`). A phone that cannot run
  `cmd package` cannot be restored either, so a shell that merely echoes is not enough.
- If the health check fails: **stop immediately**, attempt to restore that batch, and tell the user
  what happened in plain words. Do not continue to "see if it recovers".
- Confirm something still answers HOME before starting and again after finishing.

### 7. Error handling

- A reply other than `Success` (or `new state: disabled-user`) is a failure. Log it and continue.
- **Three consecutive failures: stop** and tell the user. That pattern means something systemic —
  the connection dropped, the screen locked and the ROM revoked the shell's permissions, or this
  ROM protects these packages — not one awkward package.
- Verify each removal rather than trusting the reply. If the command says success and the package
  is still listed, record it in the restore record **anyway**: a half-applied change is the
  dangerous one.
- If the phone becomes unresponsive, give the recovery steps from
  [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md#emergency-recovery), starting with a reboot.

---

## USE THE EXISTING TOOLS

Do not write your own `pm uninstall` loop. The guard, the batching, the health checks and the
restore record live in these scripts; an improvised loop has none of them, and rule 1 through rule
7 are implemented there rather than in your good intentions.

| Need | Use |
|---|---|
| Install adb | `scripts/setup_adb.sh` / `.ps1` |
| Connect | `scripts/connect.sh` / `.ps1` |
| Measure | `scripts/snapshot.sh` / `.ps1` (`before` / `after`) |
| Look up one package | `python tools/explain.py <pkg>` (no phone needed; use it for rule 3) |
| Scan and plan | `python tools/scan.py --plan` |
| Remove | `scripts/debloat.sh` / `.ps1` (with `--dry-run` first, always) |
| Restore | `scripts/restore.sh` / `.ps1` |
| Report | `python tools/report.py` |
| After an update | `python tools/check.py` |
| After editing the database | `python tools/validate_db.py` |

The guard itself is in three places, duplicated on purpose so that no single file being wrong can
disarm it:

- `block_reason()` in [`scripts/lib.sh`](scripts/lib.sh)
- `Get-BlockReason` in [`scripts/lib.ps1`](scripts/lib.ps1)
- `Database.block_reason()` in [`tools/cym.py`](tools/cym.py)

**If you add a code path that reaches a removal without passing through one of these, it is a
bug.** Change one of the three protected-name patterns and you must change all three.

---

## IF YOU ARE CHANGING THIS PROJECT

- Keep the shell and PowerShell twins in step.
- Keep the Python tools on the **standard library only**. No `pip install`.
- PowerShell files must be **ASCII only**. Windows PowerShell 5.1 reads a file without a byte-order
  mark as ANSI, and one emoji breaks the parse before a line runs. This has already happened here.
- `python tools/validate_db.py` must pass with no errors.
- Check your work:

```bash
bash -n scripts/*.sh
python -c "import ast,glob;[ast.parse(open(f,encoding='utf-8').read(),f) for f in glob.glob('tools/*.py')]"
python tools/validate_db.py
python tools/scan.py --from-list <a saved package list>     # needs no phone
```

---

## RECOMMENDED BEHAVIOUR

### Be informative

- Explain each package in plain language. The user may not know what a package name is.
- Explain the real-world impact, not the technical one. "Bixby voice commands stop working, Google
  Assistant still works" — not "removes the Bixby agent service".
- Be honest about what will and will not improve. See below.

### Be conservative

- In doubt, rate it `Advanced` or `Expert`, never `Recommended`.
- Err towards keeping a package rather than removing it.
- Present `Unsafe` packages so the user knows they were seen, and never offer to remove them.
- Prefer `--disable` on a phone the user depends on.
- Never add a package to a plan that the scan did not propose. If the user names one specifically,
  look it up, say what you can and cannot establish, and add it only if they still want it knowing
  it is unverified.

### Be transparent

- Say where a rating came from: a database match, or a heuristic guess.
- Mark unknown packages as **not in the database — manual review needed**, and never plan them
  automatically. Heuristic flags are evidence for a human, not a verdict.
- Report every package that failed to remove, and why.
- Read the refusals out loud during the dry run. They are the guard working.

### Be honest about results

This matters as much as the safety rules, because the alternative is lying to someone about their
own phone.

| Say this is real | Say this is noisy | Do not claim it at all |
|---|---|---|
| Packages removed — exact | Free RAM (Android caches into it by design, and it often drops after a reboot) | Battery life in hours |
| Apps holding location, camera, mic, contacts, SMS — measured | Running services and processes | "Twice as fast" |
| Which ads and feeds are gone | Free storage (barely moves: the system copy stays, which is why this is reversible) | A benchmark figure |

Battery life cannot be measured in an hour. Say that fewer background services means less wakeup
work, and that they should judge it over a few days.

### Leave them able to undo it

Before you finish, make sure the user knows these three commands:

```bash
bash scripts/restore.sh                        # put everything back
bash scripts/restore.sh --package com.foo.bar  # put one thing back
python tools/check.py                          # after every system update
```

And that a system update will put most of it back, which is normal rather than a failure.

---

## WHEN TO REFUSE

Stop and say why, rather than finding a way:

- The phone is **managed by an employer**, or has a work profile, and the request touches Knox,
  Device Policy or Play Services components.
- The user asks for a protected category and has no alternative in place.
- The user asks you to bypass the never-touch list, disable the guard, or run with
  `CYM_ALLOW_PROTECTED=1` on a package the never-touch list covers. That flag relaxes the
  name-pattern check only; it does not and must not relax rule 1.
- The user asks for root, a bootloader unlock, or a system partition write.
- The phone is not theirs.

Say it in a sentence, offer the nearest safe thing you can do, and move on.
