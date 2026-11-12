# CleanYourMobile — Android app

A Shizuku-based front end for the Clean Your Mobile database, in `android/`
of the [main repository](https://github.com/0xgh0stri13y/Clean-Your-Mobile).
It runs on the phone itself, so no computer is needed once Shizuku is started.

> **This is a reference implementation, not a product.** It exists to show that
> the database and the three-layer guard port cleanly to Android. For everyday
> use on a phone, [Canta](https://github.com/samolego/Canta) is more mature,
> more complete and has thousands of users. The honest comparison is in the
> main repository's README.

## What it does

| | |
|---|---|
| **Reads the real database** | 537 audited packages, copied in from the main repository at build time |
| **Detects the brand** | Same scoring as `tools/cym.py`, including the alias bonus that catches "Redmi" and "iQOO" |
| **Shows what you lose** | Every row carries its `if_removed` line, not just a package name |
| **Refuses what it must** | The same three layers: never-touch list, protected-name pattern, and the launcher and keyboard in use right now |
| **Prioritises by impact** | Advertising and telemetry first, manufacturer features last — a separate axis from the safety rating |
| **Backs up first** | A full snapshot of the phone before the first change, plus an exportable restore record |
| **Disables, never deletes** | `pm disable-user --user 0`. Restore switches everything back on |

## Building

You need **JDK 17** and the **Android SDK** (platform 35, build-tools 34+).
This module lives in `android/` inside the main repository, with `database/`
one level up.

```bash
# from the repository root
gradle -p android assembleDebug      # build only
gradle -p android publishApkDebug    # build, then copy the APK to the root
```

`publishApkDebug` writes **`CleanYourMobile.apk`** beside `README.md` at the
repository root. That is the one APK committed to the repository, so anyone can
download it without building anything.

The database is not committed here. A Gradle task copies it in from the main
repository at build time, so there is one source of truth and the APK cannot
ship a stale copy. If the main repository is somewhere else:

```bash
gradle -p android assembleDebug -PcymDatabaseDir=/path/to/database
```

or put `cymDatabaseDir=/path/to/...` in `gradle.properties`. The build **fails**
rather than producing an APK without a never-touch list.

## Running it

1. Install **Shizuku** — use the
   [GitHub release](https://github.com/RikkaApps/Shizuku/releases), not the Play
   Store build, which is older and has no Android 16 support.
2. Start the Shizuku service: pair over Wireless debugging on Android 11+, or
   start it from a computer over ADB. **Android clears it on every reboot**, so
   this has to be done again after each restart unless the phone is rooted.
3. Open this app and grant it Shizuku access.

## The guard

`Guard.kt` is the **fourth** implementation of the same three checks, alongside
`scripts/lib.sh`, `scripts/lib.ps1` and `tools/cym.py` in the main repository.
The duplication is deliberate — no single file being wrong can disarm the guard
— but it is also a drift risk, so:

- the protected-name pattern in `Guard.kt` is **generated** from `scripts/lib.sh`
- `tools/sync_guard.py` in the main repository verifies all four agree
- **never hand-edit the pattern here**

```bash
# from the repository root
python tools/sync_guard.py
```

## Verified on hardware

OnePlus 10 Pro (NE2213), Android 16, OxygenOS 16.0.3:

scan and brand detection · the guard holding back 112 packages · all four
Shizuku states · the privileged disable (`enabled 0 → 3`) · restore
(`3 → 1`) · the backup snapshot · export · the light/dark toggle

**Not yet exercised:** uninstall mode (the code exists but the UI only calls
disable), batching at scale, the three-consecutive-failure abort, and the
between-batch health check. Every test run so far has been a single package.

## Licence

MIT, same as the main repository. Copyright 2026
[0xgh0stri13y](https://github.com/0xgh0stri13y).
