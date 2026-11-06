# Restoring

Nothing this project removes is gone. This page explains why that is true, and the four ways to
put things back.

## Why it is reversible

Two commands do all the work, and both are reversible by design:

| Command | What it does | Undo |
|---|---|---|
| `pm uninstall -k --user 0 <pkg>` | Removes the app **for the current user only**. `-k` keeps its data. The copy on the read-only system partition is untouched. | `cmd package install-existing <pkg>` |
| `pm disable-user --user 0 <pkg>` | Marks the app disabled. Nothing is removed at all. | `pm enable --user 0 <pkg>` |

Neither needs root. Neither writes to a system partition. Neither touches the boot image. This is
the same mechanism as **Settings > Apps > Disable**, driven from a shell instead of a screen.

Which one a session used is recorded, and the generated restore script uses the matching undo.

## The record comes first

Before the first removal, `debloat.sh` writes the restore script. Not after the last one — before
the first. If the run dies halfway, if the cable is pulled, if the phone locks up, the record on
disk already covers everything removed up to that point, because each package's restore line is
appended the moment that package comes off.

A session directory holds:

```
backups/samsung-sm-s911b-20261106-143022/
├── device.json                 # which phone, which build, which patch level
├── snapshot_before.{txt,json}  # what it looked like
├── packages_before.txt         # every package name, before
├── plan.txt                    # what was proposed
├── removed_packages.txt        # what actually came off  <- the record
├── failed_packages.txt         # what refused, and why
├── debloat.log                 # timestamped, every step
├── restore.sh                  # generated, bash
├── restore.ps1                 # generated, PowerShell
├── snapshot_after.{txt,json}
└── report.{md,json,txt}
```

`removed_packages.txt` is the file that matters. The two restore scripts are conveniences generated
from it; `scripts/restore.sh` reads the record itself, so it still works if those were edited or
deleted.

---

## Four ways back

### 1. The restore script

```bash
bash backups/<session>/restore.sh
powershell -ExecutionPolicy Bypass -File backups\<session>\restore.ps1
```

Self-contained. Copy it to another computer and it still works.

### 2. The restore tool

```bash
bash scripts/restore.sh                            # the newest session
bash scripts/restore.sh backups/<session>          # a specific session
bash scripts/restore.sh --all                      # every session, oldest first
bash scripts/restore.sh --package com.foo.bar      # one package
bash scripts/restore.sh --list                     # what is on record
```

```powershell
powershell -ExecutionPolicy Bypass -File scripts\restore.ps1
powershell -ExecutionPolicy Bypass -File scripts\restore.ps1 -Package com.foo.bar
powershell -ExecutionPolicy Bypass -File scripts\restore.ps1 -List
```

This reads the record rather than replaying a script, and it **verifies** each package afterwards:
a package counts as restored only when it is installed for user 0 *and* not disabled. It tries both
undo routes, since running the wrong one is harmless.

### 3. From the phone, with no computer

Settings > Apps > (menu) **Show system apps**. A disabled app has an **Enable** button.
A removed-for-this-user app often shows as **Install** or appears greyed out with the option to
restore it.

Slow for forty packages, but it needs nothing but the phone — worth knowing if the phone is the
thing that stopped cooperating.

### 4. Factory reset

The guaranteed floor. Every system package comes back, because they were never deleted. Your data
does not come back, so back it up first.

Settings > System > Reset > Erase all data.

---

## One command, by hand

```bash
adb shell cmd package install-existing com.samsung.android.bixby.agent   # if uninstalled
adb shell pm enable --user 0 com.samsung.android.bixby.agent             # if disabled
```

Run both if you are not sure which was used. The wrong one is a no-op.

---

## When a package will not come back

In order:

1. **Reboot and try again.** A package the system is holding open often restores on the second
   attempt. This is the common case.
2. **Check it exists on the system partition:** `adb shell pm list packages -u | grep <pkg>`.
   `-u` includes uninstalled-but-present packages. If it is there, `install-existing` will work
   eventually.
3. **Check for a work profile.** `adb shell pm list users`. A package owned by a managed profile
   cannot be restored into user 0.
4. **A system update may have replaced it** under a different package name. Check the OEM's current
   name for the app.
5. **Factory reset.** Always works.

A package that was never on the system partition — something you installed from the Play Store and
then removed through a plan — has to be reinstalled from the Play Store. The project's plans only
ever contain preinstalled packages, so this comes up only with a hand-edited plan.

---

## After a system update

An update reinstalls the system image over the cleaned-up one: removed packages return, and new
preloads appear. This is expected and is not a failure of the restore record.

```bash
python tools/check.py           # what came back
python tools/check.py --fix     # re-apply the same plan
```

See [FIRMWARE.md](FIRMWARE.md).

---

## What a restore cannot undo

Honesty matters more here than reassurance:

- **App data deleted by the app itself.** `-k` keeps the data directory, but an app that cleared
  its own data on first run after restore cannot be helped.
- **Accounts signed out.** Removing an OEM account service signs you out. The account still exists;
  you sign in again.
- **Secure Folder and Knox containers.** If `com.samsung.knox.securefolder` was removed with data
  inside it, that data is encrypted against a container that is gone. Move data out *before*
  removing it. This is why it is rated Expert.
- **NFC transit and access cards.** Cards provisioned to the secure element through an OEM wallet
  are tied to it. Move them off first. Also rated Expert.
- **Animation and settings changes.** Those are `settings put global` changes, not package changes,
  so the restore script does not revert them. Put them back by hand:

```bash
adb shell settings put global window_animation_scale 1.0
adb shell settings put global transition_animation_scale 1.0
adb shell settings put global animator_duration_scale 1.0
```

The before snapshot records the original values, in `snapshot_before.txt` under
**Animation scales**.
