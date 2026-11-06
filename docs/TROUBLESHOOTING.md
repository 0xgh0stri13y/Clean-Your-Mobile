# Troubleshooting

The things that actually go wrong, in the order people hit them.

[Connecting](#connecting) · [Removing](#removing) · [After a removal](#after-a-removal) ·
[Emergency recovery](#emergency-recovery) · [The tools themselves](#the-tools-themselves)

---

## Connecting

### `adb: command not found`

The platform tools are not installed, or not on this terminal's PATH.

```bash
bash scripts/setup_adb.sh                                           # macOS, Linux
powershell -ExecutionPolicy Bypass -File scripts\setup_adb.ps1 -Persist   # Windows
```

If adb is installed somewhere unusual, point the tools at it instead of fighting the PATH:

```bash
export ADB_BINARY=/opt/android/platform-tools/adb     # bash
$env:ADB_BINARY = "C:\Android\platform-tools\adb.exe" # PowerShell
```

### The phone shows as `unauthorized`

The computer has not been trusted yet. Unlock the screen and accept **Allow USB debugging?**.
If the dialog never appears:

1. Revoke and start again: Developer options > **Revoke USB debugging authorizations**.
2. Unplug, replug, and watch the screen while it reconnects.
3. `adb kill-server` then `adb devices` to force a fresh handshake.

The dialog cannot appear while the screen is locked. It also cannot appear on a phone with a
cracked digitizer in the area where the button sits, which is more common than it sounds.

### The phone shows as `offline`

Usually a stale connection. `adb kill-server`, replug, try again. Over Wi-Fi, run
`bash scripts/connect.sh --disconnect` first and pair again: the Wireless debugging port
changes every time the dialog is reopened.

### Windows does not see the phone at all

In order of likelihood:

| Cause | Fix |
|---|---|
| **A charge-only cable** | Many bundled cables carry power and no data. Try another one. |
| **No OEM USB driver** | Install your manufacturer's driver, or Google's generic USB driver from the SDK. |
| **USB mode is "Charging only"** | Pull down the notification shade, tap the USB notification, pick **File transfer** or **MTP**. |
| **A USB hub** | Plug straight into the computer. |

### Wireless pairing fails

The pairing port is **not** the connect port. The Wireless debugging screen shows both, and the
pairing one changes every time you open the dialog. Keep the dialog open while pairing.

Pairing also fails when the computer and the phone are on different networks, which includes a
guest network, a 2.4 GHz and 5 GHz band that are isolated from each other, and most corporate
Wi-Fi. Client isolation on a router blocks it silently.

### macOS says "No route to host" although the phone is reachable

macOS Local Network privacy keeps the terminal app off the local subnet, and the permission
belongs to the *terminal app*, not to adb. Allow Terminal, iTerm2 or VS Code under
**System Settings > Privacy & Security > Local Network**, then quit and reopen it.

### Linux says `no permissions`

A missing udev rule. Install your distribution's `android-udev` package, add yourself to the
`plugdev` group, log out and back in.

---

## Removing

### `Failure [not installed for 0]`

The package is not installed for the current user, so there is nothing to remove. This is the
normal reply for a package that was already removed, or that only exists in a work profile.
Harmless.

### `Failure [DELETE_FAILED_INTERNAL_ERROR]`

The ROM is refusing. Three usual reasons:

1. The package is a **device administrator**. Settings > Security > Device admin apps, turn it off
   first.
2. A **work profile** or MDM owns it. You cannot remove it from user 0.
3. The ROM pins it. Try `--disable` instead, which uses `pm disable-user`:

```bash
bash scripts/debloat.sh plan.txt --disable
```

### `Security exception: Permission Denial`

Samsung and a few others block `pm uninstall` for certain packages on recent One UI builds.
`--disable` usually still works. If both are refused, the package cannot be removed without root,
and this project does not use root.

### Three removals failed in a row and the run stopped

That is the designed behaviour, not a crash. It means something systemic changed: the connection
dropped, the screen locked and the ROM revoked the shell's permissions, or the plan is aimed at
packages this ROM protects. Reconnect, re-run the same plan, and the already-removed packages are
skipped automatically.

### The health check failed mid-run

The script stopped and tried to put that batch back. Then:

```bash
adb reboot                      # almost always enough
bash scripts/restore.sh         # put the whole session back
```

If adb no longer answers at all, see [Emergency recovery](#emergency-recovery).

---

## After a removal

### The phone boots to a black screen or a "no launcher" error

The launcher was removed or disabled. The scripts refuse to touch a launcher, so this normally
means a plan was edited by hand with `CYM_ALLOW_PROTECTED=1`. Over adb:

```bash
adb shell cmd package install-existing com.sec.android.app.launcher   # Samsung
adb shell cmd package install-existing com.miui.home                  # Xiaomi
adb shell cmd package install-existing com.android.launcher3          # AOSP
```

Then `bash scripts/restore.sh`.

### The keyboard is gone

Same shape of problem. `adb shell ime list -a` shows what is left;
`adb shell cmd package install-existing com.google.android.inputmethod.latin` brings Gboard back,
then `adb shell ime enable <id>` and `adb shell ime set <id>`.

### Notifications from one app stopped arriving

A push service went with the removal. On OPPO, OnePlus and realme that is `com.heytap.mcs`; on
vivo `com.vivo.pushservice`; on Xiaomi `com.xiaomi.xmsf`. Apps that use Firebase are unaffected,
which is why this only ever hits preinstalled apps. Restore the one package:

```bash
bash scripts/restore.sh --package com.heytap.mcs
```

### The camera opens to a black preview

A camera *service* was removed while the camera app stayed. Restore the session and remove nothing
matching `camera` next time. The never-touch list covers the common ones.

### Emergency alerts no longer arrive

`com.android.cellbroadcastreceiver` or `com.android.cellbroadcastservice`. Both are on the
never-touch list for exactly this reason. Restore them immediately:

```bash
bash scripts/restore.sh --package com.android.cellbroadcastreceiver
bash scripts/restore.sh --package com.android.cellbroadcastservice
```

### Everything came back after a system update

Expected. An update reinstalls the system image over the cleaned-up one.

```bash
python tools/check.py           # what came back
python tools/check.py --fix     # re-apply
```

See [FIRMWARE.md](FIRMWARE.md).

### Banking or payment apps now refuse to run

Some apps check Play Integrity and dislike a modified system. Removing packages for user 0 does
not normally trip it, but removing Samsung Knox or Google Play Services components can. Restore
the session and remove nothing rated Expert.

---

## Emergency recovery

In order. Stop as soon as the phone is usable again.

| Step | What to do |
|---|---|
| **1. Reboot** | Hold power 10 to 20 seconds. This alone fixes most of it, because `pm uninstall -k --user 0` changes nothing on the system partition. |
| **2. Restore over adb** | `bash scripts/restore.sh` or `powershell -File scripts\restore.ps1`. The record was written before the first removal, so it exists even if the run died. |
| **3. Restore from the phone** | Settings > Apps > show system apps. A disabled app has an **Enable** button. This works with no computer. |
| **4. Safe mode** | Hold power, then long-press **Power off**. Boots with third-party apps off, enough to reach Settings. |
| **5. Recovery wipe cache** | Power + Volume Up into recovery, **Wipe cache partition**. Keeps your data. |
| **6. Factory reset** | The last resort, and it always works: every system package comes back. Your data does not. |

Nothing this project does can brick a phone. There is no root, no partition is written, no boot
image is touched, and the system copy of every removed package stays where it was. A factory reset
is a guaranteed floor.

---

## The tools themselves

### `No session found under backups/`

No before snapshot has been taken yet, or the pointer file was deleted:

```bash
bash scripts/snapshot.sh before
bash scripts/restore.sh --list          # what is on record
CYM_SESSION=samsung-sm-s911b-20261106-120000 bash scripts/snapshot.sh after
```

### `No snapshot_after.json`

Take the after snapshot before asking for the report. The report refuses to invent a comparison
from one snapshot.

### The never-touch list parsed as empty

`database/essential_packages.json` is missing or corrupt. Every tool refuses to run rather than
proceed without a guard. Restore the file from git.

### `python: command not found`

Try `python3`. The Python tools need 3.8 or newer and import nothing outside the standard library.

### The report shows "not measured"

A `dumpsys` section this ROM withholds. The snapshot records an empty value instead of failing, and
the report says so rather than printing a zero that looks like a result. Package counts and
permission counts are the figures to trust.

### Scan says "Brand profile: none matched"

The phone's packages matched no profile. The universal and Google entries still apply. Force one
if you know better:

```bash
python tools/scan.py --brand xiaomi
```

Then add the profile: [CONTRIBUTING.md](../CONTRIBUTING.md).

---

**Still stuck?** Open an issue with the output of `python tools/scan.py --json`, your phone's brand
and model, and the Android version. Leave out anything you would rather not publish; the JSON
contains package names only, no personal data.
