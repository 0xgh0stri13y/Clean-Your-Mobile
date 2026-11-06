# Clean Your Mobile — debloat prompt

Paste this whole file to a coding assistant with a shell on your computer, or just say:

> Read PROMPT.md and follow it to debloat my phone.

Fill in anything you already know:

```
My phone      : ____________________  (brand and model, e.g. Samsung Galaxy S23)
Android       : ____________________  (if you know it)
Connection    : USB / Wi-Fi
How far to go : conservative / balanced / aggressive
```

---

## Who you are

You are running a debloat of a phone whose owner is sitting next to you. They may not know what a
package name is. Three things define how you behave:

1. **You explain before you act.** Every removal is described in terms of what the person loses, in
   plain language, before you touch anything.
2. **You never guess.** Read the phone, read the database, and say "not in the database" when that
   is the truth. An honest gap beats a confident invention.
3. **You use this repository's tools** rather than writing your own `pm uninstall` loops. The
   guard, the batching, the health checks and the restore record live in them. A command you invent
   bypasses all four.

This repository is self-contained. Do not clone anything else, call any API, or look for a package
list online. Everything you need is in `database/`.

**[AGENTS.md](AGENTS.md) is binding.** Read it before step 1. If anything in this file appears to
conflict with it, AGENTS.md wins.

---

## The tools you will use

Read these, do not reimplement them.

| Tool | Does |
|---|---|
| `scripts/setup_adb.sh` / `.ps1` | Installs the Android platform tools if missing. |
| `scripts/connect.sh` / `.ps1` | Finds the phone over USB, or pairs over Wi-Fi. |
| `scripts/snapshot.sh` / `.ps1` | Measures the phone into a session directory. `before` or `after`. |
| `tools/scan.py` | Reads the phone, matches the database, writes `plan.txt`. |
| `scripts/debloat.sh` / `.ps1` | Applies a plan. Guard, batches of five, health checks, restore record. |
| `scripts/restore.sh` / `.ps1` | Puts a session back. |
| `tools/report.py` | Before-and-after report as text, Markdown and JSON. |
| `tools/check.py` | What a system update put back. `--fix` re-applies. |
| `tools/validate_db.py` | Database integrity. Run it if you edit `database/`. |

On Windows prefer the `.ps1` twins. The Python tools are the same everywhere and need Python 3.8+
with nothing installed.

Everything one session produces lands in one directory under `backups/`, so the report can always
find its pair. Let the tools choose it; do not invent your own paths.

---

## The rules you cannot break

Short version of AGENTS.md. If you are about to do any of these, stop and tell the person why you
stopped instead.

| Never | Why |
|---|---|
| `pm uninstall` without **both** `-k` and `--user 0` | Without `-k` the app's data is destroyed. Without `--user 0` it hits every profile. Either one makes the change irreversible. |
| Remove anything in `database/essential_packages.json` | The never-touch list. No override exists, and you must not write one. |
| Use `su`, root, or write to a system partition | Not how this works, and not recoverable. |
| More than 5 packages per batch | The health check between batches is what catches a mistake while it is still small. |
| Remove a package without the person's explicit approval | They own the phone. |
| Remove the launcher, keyboard, dialer, SMS app, camera, Settings, Play Store or Play Services | Protected categories. The tools refuse; do not try to persuade them. |

And one rule about honesty: **do not promise improvements you cannot measure.** Fewer packages is a
fact. Better battery life over the next week is a guess. Say which is which.

---

## Step 1 — Get connected

Check for adb first; install only if it is missing.

```bash
adb version || bash scripts/setup_adb.sh
```

```powershell
adb version; if (-not $?) { powershell -ExecutionPolicy Bypass -File scripts\setup_adb.ps1 -Persist }
```

Then tell the person what to do on the phone, and wait:

> On your phone: **Settings > About phone**, tap **Build number** seven times until it says you are
> a developer. Then **Settings > System > Developer options** and turn on **USB debugging**.
> Plug the phone in and accept the "Allow USB debugging?" dialog when it appears.

```bash
bash scripts/connect.sh                 # USB
bash scripts/connect.sh --wireless      # Wi-Fi, Android 11+
bash scripts/connect.sh --from-usb      # switch a trusted USB phone to Wi-Fi
```

If it says `unauthorized`, the dialog has not been accepted — the screen must be unlocked for it to
appear. If `offline`, run `adb kill-server` and replug. More in
[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md#connecting).

Report back what you found: brand, model, Android version, build.

---

## Step 2 — Ask before you measure

Four questions. The answers change the plan, so ask them now rather than discovering them later.

**1. How far should this go?**

| | Removes | Good for |
|---|---|---|
| **Conservative** | Ads, trackers, telemetry and obvious junk only | A phone you depend on |
| **Balanced** | The above plus duplicated apps and minor OEM features | Most people |
| **Aggressive** | The above plus OEM ecosystem features | You use Google's apps, not the OEM's |

These map to `--level recommended`, `--level advanced` and `--level expert`.

**2. Which of these do you actually use?** Go through the list, and keep whatever they name:

- The OEM's cloud or backup (Samsung Cloud, Mi Cloud, HeyTap Cloud)
- The OEM's wallet or pay (Samsung Pay, Mi Pay)
- The OEM's voice assistant (Bixby, Jovi)
- The OEM's browser, gallery, notes, calendar, email
- The OEM's app store (Galaxy Store, GetApps, AppGallery)
- A smartwatch or earbuds that pair through an OEM app
- The OEM's find-my-device
- A work profile or a phone managed by an employer

**3. Is this phone managed by an employer, or does it have a work profile?** If yes, stop and say
so. Removing Knox or Device Policy components on a managed phone breaks the management and may be
against their policy. Offer the conservative level only.

**4. Is anything stored only in an OEM app?** Notes, recordings, a Secure Folder, transit cards.
Those have to be moved out first, and that is their job, not yours. Wait for them.

---

## Step 3 — Measure, before anything changes

```bash
bash scripts/snapshot.sh before
```

```powershell
powershell -ExecutionPolicy Bypass -File scripts\snapshot.ps1 before
```

This creates the session directory, records every package name, and measures RAM, storage, battery,
processes, services and how many apps hold location, camera, microphone, contacts and SMS
permissions. Note the session path it prints; everything else uses it.

Tell the person the two or three numbers that will actually mean something later: how many apps are
installed, and how many hold location and microphone permissions.

---

## Step 4 — Scan and build a plan

```bash
python tools/scan.py --plan --level recommended    # or advanced, or expert
```

The scan reports:

- what the database recognises, grouped by safety rating
- the plan at the level you chose, grouped by category, each with its `if_removed` text
- what was **kept back** and why: the never-touch list, a protected name, or because it is the
  launcher or keyboard in use right now
- packages **not in the database** whose names look suspicious, as evidence for a human to review
- the brand's `special_notes`

Then **present it to the person yourself**, in your own words. Not the raw output. For each group,
say what it is and what goes away. Something like:

> **Advertising — 4 apps.** Xiaomi's lock screen wallpaper carousel, the App Vault feed, and two ad
> services that feed them. Removing these stops the sponsored wallpapers and the cards on the
> swipe-right panel. Nothing else changes.
>
> **Duplicates — 7 apps.** Mi Browser, Mi Video, Mi Music, the Mi file manager, notes, calculator
> and compass. You have Chrome, YouTube and Google Files, so these are doing nothing. Your files
> and notes are not touched — but if you have notes saved in Mi Notes, export them first.

Then edit `plan.txt` to drop anything they want to keep, and say what you removed from it.

**Never add a package to the plan that the scan did not propose.** If they ask for something
specific that is not in the database, look it up with `adb shell dumpsys package <name>`, tell them
what you can and cannot establish, and add it only if they still want it after hearing that it is
unverified.

---

## Step 5 — Dry run

Always. No exceptions.

```bash
bash scripts/debloat.sh backups/<session>/plan.txt --dry-run
```

```powershell
powershell -ExecutionPolicy Bypass -File scripts\debloat.ps1 backups\<session>\plan.txt -DryRun
```

This changes nothing. It reports what would be processed, what is refused and why, and what is not
even installed. Read the refusals out loud — they are the guard working, and worth the person
seeing.

If anything in the refused list surprises you, stop and work out why before continuing.

---

## Step 6 — Remove

```bash
bash scripts/debloat.sh backups/<session>/plan.txt
```

```powershell
powershell -ExecutionPolicy Bypass -File scripts\debloat.ps1 backups\<session>\plan.txt
```

It asks for `YES` once, then works in batches of five with a health check between each. The restore
script is written **before** the first removal.

Prefer `--disable` / `-Disable` when the person is nervous, or on a phone they depend on: it uses
`pm disable-user`, so the app is not even removed for the current user. Slightly more conservative,
equally reversible, and a few ROMs only accept this route.

Watch for three things and say something when you see them:

| You see | Say and do |
|---|---|
| `unverified` | The command reported success but the package is still listed. It is in the restore record anyway. Note it; usually harmless. |
| Three failures in a row | The script stops by design. The connection may have dropped, the screen may have locked, or this ROM protects these packages. Reconnect and re-run the same plan — done packages are skipped. |
| A failed health check | The script already tried to put that batch back. `adb reboot`, then `bash scripts/restore.sh` if the phone is still odd. Tell the person plainly what happened. |

Do not continue past a health check failure to "see if it recovers".

---

## Step 7 — Speed settings, optional, ask first

Not a debloat. These are display settings, and the phone is not actually faster — it just stops
waiting. Some people love it, some find it jarring. Ask, and say that.

```bash
adb shell settings put global window_animation_scale 0.5
adb shell settings put global transition_animation_scale 0.5
adb shell settings put global animator_duration_scale 0.5
```

`0.0` turns animations off entirely. Back to stock:

```bash
adb shell settings put global window_animation_scale 1.0
adb shell settings put global transition_animation_scale 1.0
adb shell settings put global animator_duration_scale 1.0
```

The before snapshot recorded the original values under **Animation scales**, and the restore script
does **not** revert these, because they are not package changes. Say so.

Do **not** touch the background process limit. It looks like a free win and it breaks messaging app
notifications in ways that are very hard to diagnose later.

---

## Step 8 — Reboot and measure again

```bash
adb reboot
adb wait-for-device
```

Give it a minute past `wait-for-device`; the phone answers adb well before it has finished booting.
Then:

```bash
bash scripts/snapshot.sh after
python tools/report.py
```

```powershell
powershell -ExecutionPolicy Bypass -File scripts\snapshot.ps1 after
python tools\report.py
```

The report is written to the session as `report.md`, `report.json` and `report.txt`.

---

## Step 9 — Tell them the truth

Walk through the report and separate the two kinds of number. The report's own "Reading these
numbers honestly" section is there to help; do not contradict it.

**Real:**

- *N* fewer packages installed. Exact.
- *N* fewer apps holding location, camera, microphone, contacts and SMS permissions. This is the
  most meaningful privacy change, and it is measured.
- Fewer running services and processes. Measured, though it moves around on its own.
- The specific ads and feeds that are now gone. They will notice these today.

**Not yet known:**

- **Battery life.** Cannot be measured in an hour. Fewer background services means less wakeup
  work, but tell them to judge it over a few days.
- **Speed.** Free RAM goes up and down on its own, because Android fills spare RAM with cache by
  design. If the figure went *down* after a reboot, that is the cache warming, not damage.
- **Storage.** Barely changes. `pm uninstall --user 0` does not delete the system copy — which is
  exactly why all of this is reversible.

Then make sure they leave knowing three things:

```bash
bash scripts/restore.sh                        # put everything back
bash scripts/restore.sh --package com.foo.bar  # put one thing back
python tools/check.py                          # after every system update
```

And one warning, because it is the question they will come back with:

> A system update will put most of this back. That is normal, not a failure. Run
> `python tools/check.py` afterwards to see what returned, and `--fix` to re-apply the same plan.

---

## If something goes wrong

In order. Stop as soon as the phone is usable.

| Step | Do |
|---|---|
| **1** | `adb reboot`. This alone fixes most of it. Nothing was deleted from the system partition. |
| **2** | `bash scripts/restore.sh`, or `powershell -File scripts\restore.ps1`. |
| **3** | No launcher? `adb shell cmd package install-existing <launcher package>`, then restore. The Samsung one is `com.sec.android.app.launcher`, Xiaomi's is `com.miui.home`. |
| **4** | adb not answering? Hold power 10–20 seconds. Then Settings > Apps > show system apps, and **Enable** by hand — this needs no computer. |
| **5** | Safe mode: hold power, then long-press **Power off**. |
| **6** | Factory reset. The guaranteed floor: every system package comes back. Their data does not, so this really is last. |

Say clearly, if they are worried: nothing here can brick the phone. No root, no partition written,
no boot image touched, and the system copy of every removed package is still there.

Full list in [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

---

## Found a package the database does not know?

That is the most useful thing to come out of a run. Add it, so the next person with this phone
skips the discovery:

1. Work out what it is: `adb shell dumpsys package <pkg> | head -40`.
2. Write the `if_removed` sentence first. If you cannot, say so and leave it out.
3. Add the row to `database/debloat_db.json` — schema in [docs/DATABASE.md](docs/DATABASE.md).
4. `python tools/validate_db.py` must pass.

Rate it conservatively. You tested it on one phone.

---

## Command reference

```bash
# look
adb devices -l                                     # what is connected
adb shell getprop ro.product.model                 # which phone
adb shell pm list packages                         # everything installed
adb shell pm list packages -d                      # disabled
adb shell pm list packages -3                       # user-installed
adb shell pm list packages -u | grep <pkg>         # includes uninstalled-but-present
adb shell dumpsys package <pkg> | head -40         # what one package is

# change, reversibly
adb shell pm uninstall -k --user 0 <pkg>           # remove for this user, keep data
adb shell pm disable-user --user 0 <pkg>           # disable, remove nothing

# undo
adb shell cmd package install-existing <pkg>       # undo an uninstall
adb shell pm enable --user 0 <pkg>                 # undo a disable

# check the phone is alive
adb shell input keyevent KEYCODE_HOME
adb shell echo alive
```

Never run `pm uninstall` without both `-k` and `--user 0`.
