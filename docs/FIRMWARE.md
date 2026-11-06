# After a system update

A system update installs a fresh copy of the system image over the one you cleaned up. Three things
happen at once:

1. Packages you removed for user 0 are **installed again** and enabled.
2. Packages you disabled are often **re-enabled**.
3. **New preloads** appear that no plan mentions, because the OEM added them in this build.

None of this means anything broke. It is what a system update is.

## Check what came back

```bash
python tools/check.py
```

```
 Device  : samsung SM-S911B (dm1q), Android 14 / API 34
 Against : backups/samsung-sm-s911b-20261106-143022/removed_packages.txt
 In plan : 47

38 package(s) came back
  A system update is the usual reason. Patch level now: 2026-11-01

  ! com.samsung.android.bixby.agent            Bixby Voice Agent
  ! com.samsung.android.arzone                 AR Zone
  ...

  Still off: 9
```

Exit codes, so this can live in a scheduled job:

| Code | Means |
|---|---|
| `0` | The phone still matches the plan. |
| `1` | Some packages came back. |
| `2` | The check could not run: no device, no session, no plan. |

## Put it back

```bash
python tools/check.py --fix
```

Re-applies the same method the session used, through the same guard: anything on the never-touch
list is still refused, even from a hand-edited plan. The result is appended to the session's
`debloat.log` with the new patch level, so the history of a phone stays in one place.

To review before acting, the package names `check.py` prints are themselves a valid plan file:

```bash
python tools/check.py > /tmp/came-back.txt     # edit it, delete what you want to keep
bash scripts/debloat.sh /tmp/came-back.txt --dry-run
```

## Find the new preloads too

`check.py` only knows about the plan that was applied. A fresh scan finds what the update *added*:

```bash
bash scripts/snapshot.sh before          # a new session
python tools/scan.py --plan
```

Then compare against the old session if you want the exact delta:

```bash
diff <(sort backups/<old-session>/packages_after.txt) \
     <(sort backups/<new-session>/packages_before.txt)
```

## Checking automatically

Nothing in this repository runs on a schedule by itself. If you want it to, `check.py --quiet` is
built for that: it prints nothing and sets only the exit code.

```bash
# every Monday at 09:00, phone connected over Wi-Fi
0 9 * * 1 cd ~/clean-your-mobile && python tools/check.py --quiet || notify-send "Bloat is back"
```

Prefer `check.py --quiet` over `--fix` on a schedule. A phone that changed because of an update is
worth a human look: the update may have renamed packages, and re-applying blindly tells you nothing
about what else changed.

## Updates that stop arriving

Some entries in the database remove the OEM's updater, and they say so in `if_removed`:

| Package | Brand |
|---|---|
| `com.motorola.ccc.ota` | Motorola |
| `com.samsung.android.app.updatecenter` | Samsung |
| `com.huawei.android.hwouc` | Huawei |
| `com.asus.dm` | ASUS |

Removing one of these means the phone stops receiving **security** patches, not just feature
updates. All four are rated Expert or Advanced and are never in a `recommended` plan. If you took
one off deliberately and want updates back:

```bash
bash scripts/restore.sh --package com.motorola.ccc.ota
```

Google Play system updates arrive through Play Services and are unaffected by any of this.

## Before you accept a large update

Worth doing once on a phone you have cleaned heavily:

```bash
bash scripts/snapshot.sh after    # record the current state into the session
```

Then after the update, `check.py` has something exact to compare against, and the report in that
session still describes the phone as it was.
