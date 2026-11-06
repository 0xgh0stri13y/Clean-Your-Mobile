# Security

## Reporting a vulnerability

Report it privately through the repository's **Security** tab ("Report a vulnerability"), not as a
public issue.

Please include what the problem is, how to reproduce it, and what it lets someone do. You will get
an acknowledgement, and the fix and the credit will be public once it is out.

## What counts as a vulnerability here

This project runs commands against a phone the user owns, over a debug bridge the user enabled. The
things that matter:

| Report this | Because |
|---|---|
| **A path to a removal that skips the never-touch list** | This is the one that matters most. Any route to `pm uninstall` or `pm disable-user` that does not pass through `block_reason` is a bug, whatever the surrounding conditions. |
| **A command injected through a package name or plan file** | Package names end up in shell commands. A crafted name that escapes its context is a real finding. |
| **A plan file or session directory that escapes its intended path** | Writing outside `backups/`, or reading a file the user did not name. |
| **A restore record that is wrong or incomplete** | A removal recorded as something it was not, or not recorded at all, leaves a phone that cannot be put back. |
| **Anything that makes a change irreversible** | `pm uninstall` without `-k`, without `--user 0`, a system partition write, or a root escalation. |
| **A `setup_adb` script that fetches from somewhere other than Google** | Or over plain HTTP, or without the user's knowledge. |

### What is not a vulnerability

- **That ADB can remove apps.** That is Android's own design and the entire premise.
- **That the user can edit a plan file.** They own the phone. The never-touch list still holds.
- **That `CYM_ALLOW_PROTECTED=1` relaxes the name-pattern check.** It is documented, it is opt-in,
  and it does *not* relax the never-touch list. If you find that it does, that **is** a
  vulnerability — report it.
- **That a removed package breaks an OEM feature.** That is a database accuracy problem. Open a
  normal issue: see [CONTRIBUTING.md](CONTRIBUTING.md).
- **That the phone is less secure with its OEM security suite removed.** Those packages are rated
  Expert or Unsafe and say so.

## What this project does not do

Stated plainly, because it defines the attack surface:

- **No root, and no attempt to get it.** No `su`, no exploit, no bootloader unlock.
- **No writes to any system partition**, and no firmware or boot image is touched.
- **No DRM or lock bypass** of any kind.
- **No manufacturer software is redistributed.** This repository contains no APK, no firmware and
  no OEM binary.
- **No network calls from the phone.** The tools read the phone and write files on your computer.
- **No telemetry.** Nothing here reports anything anywhere. The only outbound request in the whole
  project is `setup_adb` downloading the platform tools from `dl.google.com`, and only if adb is
  missing.

Everything works through switches Android offers the owner of the device: Developer options, ADB
debugging, and `pm disable-user` / `pm uninstall --user 0` — the same mechanism as
**Settings > Apps > Disable**.

## Where your data goes

Nowhere. Sessions are written to `backups/` on your own computer and `.gitignore` keeps them out of
git.

A session directory contains package names, package counts, memory and storage figures, battery
level, and permission counts. It does not contain messages, contacts, photos, accounts or
credentials. If you share a session for a bug report, that is the full extent of what you are
sharing — but read it first, since a package list does say which apps you have installed.

## Running the scripts

Read them before you run them. They are plain shell, PowerShell and Python, with no build step and
no dependencies outside the standard library, specifically so that reading them is practical.

If you cloned this from somewhere other than the canonical repository, diff it against the
canonical one first. A guard is only a guard if nobody edited it.
