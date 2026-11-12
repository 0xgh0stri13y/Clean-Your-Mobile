# Security policy

## Reporting a vulnerability

Report it privately through [Security > Report a vulnerability](https://github.com/0xgh0stri13y/Clean-Your-Mobile/security/advisories/new), not as a public issue. Say what the problem is, how to reproduce it, and what it lets someone do. You will get a reply, and the fix and the credit are made public once it ships.

Only the current `main` branch and the latest published APK are supported.

## In scope

| Report this | Why it matters |
|---|---|
| A path to `pm uninstall` or `pm disable-user` that skips the guard | The never-touch list is the core promise. This applies to the scripts, the Python tools and the app alike. |
| A command injected through a package name, plan file or imported preset | Package names end up in privileged shell commands. Presets come from other people. |
| A change that cannot be undone | `pm uninstall` without `-k` or `--user 0`, a system partition write, or root. |
| A restore record that is wrong or missing | The phone could not be put back. |
| Reading or writing outside the files the user named or `backups/` | |
| Another app using this app's Shizuku privilege | The app runs shell commands on the user's behalf. |
| `setup_adb` fetching from anywhere other than the package manager or `dl.google.com` over HTTPS | |
| A published APK whose signing certificate differs from the digest in the README | |

## Not a vulnerability

- That ADB can remove apps. That is Android's design and the premise of this project.
- That the user can edit a plan. The never-touch list still holds.
- That `CYM_ALLOW_PROTECTED=1` relaxes the name-pattern check. It is opt-in and documented. If it ever relaxes the never-touch list, that **is** a vulnerability.
- That removing a package breaks an OEM feature. That is a database correction: open a normal issue.

## What this project does not do

- No root, no bootloader unlock, no exploit, no write to a system partition.
- No manufacturer software is redistributed. The only APK here is this project's own app, built from `android/` and signed with the certificate listed in the README.
- No telemetry. The Android app does not request the internet permission. The scripts make no network requests, except `setup_adb`, which installs adb through your package manager or from `dl.google.com`, and only when adb is missing.

## Your data

Sessions are written to `backups/` on your own computer and are git-ignored. A session holds package lists, device model and build, measurements, logs and the restore record. It also holds the **device serial**, in `device.serial` and `device.json`. Remove both before sharing a session in a bug report.

The app keeps its snapshot and restore record in its private storage. It writes a file you can share only when you tap Export, and that file does not include the serial.

If you got this code from anywhere other than this repository, diff it against this one before running it. A guard only protects you if nobody edited it.
