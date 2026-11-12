"""Clean Your Mobile - shared helpers for the Python tools.

Standard library only, so `python tools/scan.py` works on a fresh machine with
nothing installed but Python 3.8+ and the Android platform tools.

Three things live here:
  * Adb      - a thin, quiet wrapper around the adb binary
  * Database - the debloat database, the never-touch list and brand profiles
  * sessions - finding and reading the backups/<session>/ directories
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence

ROOT = Path(__file__).resolve().parent.parent
DB_DIR = ROOT / "database"


def from_msys(text: str) -> str:
    """Translate a Git Bash / MSYS path into something Windows can open.

    The shell scripts write native paths now, but a pointer written by an older
    version - or by a shell without cygpath - still says /e/Clean Your Mobile.
    Accepting both costs nothing and saves a confusing FileNotFoundError.
    """
    if os.name != "nt" or not text:
        return text
    match = re.match(r"^/([A-Za-z])/(.*)$", text.replace("\\", "/"))
    if match:
        return f"{match.group(1).upper()}:/{match.group(2)}"
    return text


BACKUP_ROOT = Path(from_msys(os.environ.get("CYM_BACKUP_ROOT", "")) or (ROOT / "backups"))

SAFETY_ORDER = ["Recommended", "Advanced", "Expert", "Unsafe"]
SAFETY_RANK = {name: i for i, name in enumerate(SAFETY_ORDER)}

# Package names that mean "do not touch" on their own, for whatever the
# never-touch list misses on an unusual ROM. Kept in step with the same list in
# scripts/lib.sh - see docs/DATABASE.md.
PROTECTED_PATTERNS = [
    r"^android$", r"^oplus$", r"systemui", r"^com\.android\.settings", r"telecom",
    r"telephony", r"dialer", r"incallui", r"\.mms", r"messaging",
    r"inputmethod", r"latin", r"keyboard", r"^com\.android\.vending$",
    r"^com\.google\.android\.gms", r"^com\.google\.android\.gsf",
    r"setupwizard", r"provision", r"keystore", r"keychain",
    r"permissioncontroller", r"packageinstaller", r"networkstack",
    r"\.wifi", r"bluetooth", r"^com\.android\.camera", r"launcher",
    r"\.home$",
    # Build-time infrastructure, not apps: runtime resource overlays, framework
    # resources, GPU drivers and graphics layers. A OnePlus 10 Pro carries 30+
    # of these. None was installed by anyone, and removing one can cost you the
    # display.
    r"overlay", r"\.rro\.", r"_rro$", r"frameworkres", r"gpudrivers",
    r"vulkan", r"\.resources$", r"^android\.auto_generated",
]
_PROTECTED_RE = re.compile("|".join(PROTECTED_PATTERNS))


# --------------------------------------------------------------- terminal ----
class C:
    """ANSI colours, switched off when the output is not a terminal."""

    _on = sys.stdout.isatty() and not os.environ.get("NO_COLOR")
    RESET = "\033[0m" if _on else ""
    BOLD = "\033[1m" if _on else ""
    DIM = "\033[2m" if _on else ""
    RED = "\033[0;31m" if _on else ""
    GREEN = "\033[0;32m" if _on else ""
    YELLOW = "\033[1;33m" if _on else ""
    CYAN = "\033[0;36m" if _on else ""
    MAGENTA = "\033[0;35m" if _on else ""


RULE = "-" * 60

SAFETY_COLOUR = {
    "Recommended": C.GREEN,
    "Advanced": C.CYAN,
    "Expert": C.YELLOW,
    "Unsafe": C.RED,
}


def banner(title: str) -> None:
    print(C.DIM + RULE + C.RESET)
    print(f" {C.BOLD}Clean Your Mobile{C.RESET} - {title}")
    print(C.DIM + RULE + C.RESET)


def hr() -> None:
    print(C.DIM + RULE + C.RESET)


def step(msg: str) -> None:
    print(f"{C.CYAN}{msg}{C.RESET}")


def ok(msg: str) -> None:
    print(f"{C.GREEN}  ok  {C.RESET}{msg}")


def warn(msg: str) -> None:
    sys.stdout.flush()  # keep stderr in order with what was already printed
    print(f"{C.YELLOW} warn {C.RESET}{msg}", file=sys.stderr)


def fail(msg: str) -> None:
    sys.stdout.flush()
    print(f"{C.RED} fail {C.RESET}{msg}", file=sys.stderr)


def die(msg: str, code: int = 1) -> "NoReturn":  # type: ignore[name-defined]
    fail(msg)
    raise SystemExit(code)


# -------------------------------------------------------------------- adb ----
ADB_CANDIDATES = [
    Path.home() / "platform-tools" / "adb",
    Path.home() / "platform-tools" / "adb.exe",
    Path.home() / "Android" / "Sdk" / "platform-tools" / "adb",
    Path.home() / "Library" / "Android" / "sdk" / "platform-tools" / "adb",
    Path(os.environ.get("LOCALAPPDATA", "")) / "Android" / "Sdk" / "platform-tools" / "adb.exe",
    Path("/usr/local/bin/adb"),
    Path("/opt/homebrew/bin/adb"),
]


def find_adb() -> Optional[str]:
    named = os.environ.get("ADB_BINARY")
    if named:
        found = shutil.which(named)
        if found:
            return found
        if Path(named).is_file():
            return named
        # An ADB_BINARY the caller set explicitly must not fall through to a
        # different adb found elsewhere: silently using the wrong binary is
        # worse than failing.
        die(f"ADB_BINARY is set to {named!r}, which is not executable.\n"
            f"        Unset it to search the usual locations instead.")
    found = shutil.which("adb")
    if found:
        return found
    for candidate in ADB_CANDIDATES:
        try:
            if candidate.is_file():
                return str(candidate)
        except OSError:
            continue
    return None


@dataclass
class Device:
    serial: str = ""
    brand: str = ""
    model: str = ""
    device: str = ""
    android: str = ""
    sdk: str = ""
    build: str = ""
    security_patch: str = ""

    def __str__(self) -> str:
        return f"{self.brand} {self.model} ({self.device}), Android {self.android} / API {self.sdk}"


class Adb:
    """A quiet adb wrapper. Every call returns text, never raises on a device
    error - the caller decides what a missing answer means."""

    def __init__(self, serial: Optional[str] = None, binary: Optional[str] = None):
        self.binary = binary or find_adb()
        if not self.binary:
            die("adb not found. Run: bash scripts/setup_adb.sh "
                "(or powershell -File scripts/setup_adb.ps1 on Windows)")
        self.serial = serial or os.environ.get("ANDROID_SERIAL") or None
        self.device = Device()

    # -- plumbing ----------------------------------------------------------
    def _argv(self, args: Sequence[str]) -> List[str]:
        argv = [self.binary]
        if self.serial:
            argv += ["-s", self.serial]
        return argv + list(args)

    def run(self, *args: str, timeout: int = 120) -> str:
        try:
            proc = subprocess.run(
                self._argv(args),
                capture_output=True, text=True, timeout=timeout,
                encoding="utf-8", errors="replace",
            )
        except subprocess.TimeoutExpired:
            warn(f"adb {' '.join(args)} timed out after {timeout}s")
            return ""
        except OSError as exc:
            die(f"could not run adb: {exc}")
        return (proc.stdout or "").replace("\r", "")

    def shell(self, command: str, timeout: int = 120) -> str:
        return self.run("shell", command, timeout=timeout)

    def lines(self, command: str, timeout: int = 120) -> List[str]:
        return [ln for ln in (l.strip() for l in self.shell(command, timeout).splitlines()) if ln]

    def prop(self, name: str) -> str:
        return self.shell(f"getprop {name}").strip()

    # -- device ------------------------------------------------------------
    def list_devices(self) -> List[tuple]:
        out = self.run("devices")
        rows = []
        for line in out.splitlines()[1:]:
            if not line.strip():
                continue
            parts = line.split("\t")
            if len(parts) >= 2:
                rows.append((parts[0].strip(), parts[1].strip()))
        return rows

    def require_device(self) -> Device:
        rows = self.list_devices()
        if not rows:
            die("No device found. Plug the phone in, or run: bash scripts/connect.sh")
        for serial, state in rows:
            if state == "unauthorized":
                warn(f"{serial} is unauthorized - accept the Allow USB debugging prompt.")
            elif state == "offline":
                warn(f"{serial} is offline - replug it, or re-run scripts/connect.sh.")
        ready = [s for s, st in rows if st == "device"]
        if not ready:
            die("No device is ready. See the warnings above.")
        if len(ready) > 1 and not self.serial:
            fail("More than one device is connected:")
            for s in ready:
                print(f"    {s}", file=sys.stderr)
            die("Pick one with ANDROID_SERIAL=<serial>")
        if not self.serial:
            self.serial = ready[0]

        self.device = Device(
            serial=self.serial,
            brand=self.prop("ro.product.brand"),
            model=self.prop("ro.product.model"),
            device=self.prop("ro.product.device"),
            android=self.prop("ro.build.version.release"),
            sdk=self.prop("ro.build.version.sdk"),
            build=self.prop("ro.build.display.id"),
            security_patch=self.prop("ro.build.version.security_patch"),
        )
        if not self.device.model:
            die("The device answered but reported no model. Is the screen unlocked?")
        return self.device

    # -- packages ----------------------------------------------------------
    def packages(self, *flags: str) -> List[str]:
        cmd = "pm list packages" + ("".join(f" {f}" for f in flags))
        return sorted(
            ln[len("package:"):] for ln in self.lines(cmd) if ln.startswith("package:")
        )

    def home_launchers(self) -> List[str]:
        out = self.shell(
            "cmd package query-activities --brief "
            "-a android.intent.action.MAIN -c android.intent.category.HOME"
        )
        return sorted({m.split("/")[0] for m in re.findall(r"[\w.]+/[\w.$]+", out)})

    def default_home(self) -> str:
        out = self.shell(
            "cmd package resolve-activity --brief "
            "-a android.intent.action.MAIN -c android.intent.category.HOME"
        ).strip().splitlines()
        return out[-1].split("/")[0] if out else ""

    def default_ime(self) -> str:
        return self.shell("settings get secure default_input_method").strip().split("/")[0]


# --------------------------------------------------------------- database ----
@dataclass
class Pkg:
    """One row of the debloat database."""

    id: str
    brand: str = "universal"
    category: str = "bloatware"
    safety: str = "Expert"
    name: str = ""
    description: str = ""
    if_removed: str = ""

    @property
    def rank(self) -> int:
        return SAFETY_RANK.get(self.safety, len(SAFETY_ORDER))


@dataclass
class Database:
    packages: Dict[str, Pkg] = field(default_factory=dict)
    essentials: set = field(default_factory=set)
    essentials_by_brand: Dict[str, List[str]] = field(default_factory=dict)
    brands: Dict[str, dict] = field(default_factory=dict)
    meta: dict = field(default_factory=dict)
    # A package listed under several brands (HeyTap on OPPO, OnePlus and
    # realme) is stored once, with every brand it was seen under.
    brands_for: Dict[str, List[str]] = field(default_factory=dict)

    @classmethod
    def load(cls, db_dir: Path = DB_DIR) -> "Database":
        db = cls()

        raw = _read_json(db_dir / "debloat_db.json")
        db.meta = raw.get("_meta", {})
        for row in raw.get("packages", []):
            pid = row.get("id")
            if not pid:
                continue
            brand = row.get("brand", "universal")
            db.brands_for.setdefault(pid, [])
            if brand not in db.brands_for[pid]:
                db.brands_for[pid].append(brand)
            existing = db.packages.get(pid)
            incoming = Pkg(
                id=pid,
                brand=brand,
                category=row.get("category", "bloatware"),
                safety=row.get("safety", "Expert"),
                name=row.get("name", ""),
                description=row.get("description", ""),
                if_removed=row.get("if_removed", ""),
            )
            # When two rows disagree, keep the more cautious rating.
            if existing is None or incoming.rank > existing.rank:
                db.packages[pid] = incoming

        ess = _read_json(db_dir / "essential_packages.json")
        for key, value in ess.items():
            if key == "_meta" or not isinstance(value, list):
                continue
            db.essentials_by_brand[key] = value
            db.essentials.update(value)
        if not db.essentials:
            die("The never-touch list is empty - refusing to continue.")

        profiles = _read_json(db_dir / "brand_profiles.json")
        db.brands = profiles.get("brands", {})
        return db

    # -- lookups -----------------------------------------------------------
    def get(self, pid: str) -> Optional[Pkg]:
        return self.packages.get(pid)

    def is_essential(self, pid: str) -> bool:
        return pid in self.essentials

    @staticmethod
    def is_protected_name(pid: str) -> bool:
        return bool(_PROTECTED_RE.search(pid))

    def block_reason(self, pid: str, allow_protected: bool = False) -> Optional[str]:
        """Why this package must be kept, or None when it may be touched."""
        if self.is_essential(pid):
            return "on the never-touch list"
        entry = self.get(pid)
        if entry and entry.safety == "Unsafe":
            return "rated Unsafe in the database"
        if self.is_protected_name(pid) and not allow_protected:
            return "name matches a protected category"
        return None

    def detect_brand(self, installed: Iterable[str], device_brand: str = "") -> str:
        """Pick the brand profile that fits this phone, by prefix hit count."""
        installed = list(installed)
        scores: Dict[str, int] = {}
        for key, profile in self.brands.items():
            prefixes = profile.get("detection_prefixes", [])
            scores[key] = sum(
                1 for p in installed if any(p.startswith(pre) for pre in prefixes)
            )
        if device_brand:
            low = device_brand.lower()
            for key, profile in self.brands.items():
                aliases = [key] + profile.get("aliases", [])
                if any(a.lower() in low or low in a.lower() for a in aliases):
                    scores[key] = scores.get(key, 0) + 25
        best = max(scores, key=lambda k: scores[k], default="")
        return best if scores.get(best, 0) > 0 else ""


def _read_json(path: Path) -> dict:
    if not path.is_file():
        die(f"Missing {path}")
    try:
        with path.open(encoding="utf-8") as fh:
            return json.load(fh)
    except json.JSONDecodeError as exc:
        die(f"{path.name} is not valid JSON: {exc}")


# -------------------------------------------------------------- sessions -----
def latest_session() -> Optional[Path]:
    pointer = BACKUP_ROOT / ".last-session"
    if pointer.is_file():
        candidate = Path(from_msys(pointer.read_text(encoding="utf-8").strip()))
        if candidate.is_dir():
            return candidate
    dirs = [d for d in BACKUP_ROOT.glob("*") if d.is_dir()]
    if not dirs:
        return None
    return max(dirs, key=lambda d: d.stat().st_mtime)


def resolve_session(arg: Optional[str], required: bool = True) -> Optional[Path]:
    """Turn --session into a directory: a path, a name under backups/, or the
    newest session when nothing was given."""
    if arg:
        arg = from_msys(arg)
        candidate = Path(arg)
        if not candidate.is_dir():
            candidate = BACKUP_ROOT / arg
        if not candidate.is_dir():
            die(f"No such session: {arg}")
        return candidate
    found = latest_session()
    if found is None and required:
        die(f"No session found under {BACKUP_ROOT}. Run: bash scripts/snapshot.sh before")
    return found


def new_session(device: Device) -> Path:
    from datetime import datetime, timezone

    def slug(text: str) -> str:
        return re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", (text or "").lower())).strip("-") or "unknown"

    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    path = BACKUP_ROOT / f"{slug(device.brand)}-{slug(device.model)}-{stamp}"
    path.mkdir(parents=True, exist_ok=True)
    BACKUP_ROOT.mkdir(parents=True, exist_ok=True)
    (BACKUP_ROOT / ".last-session").write_text(str(path) + "\n", encoding="utf-8")
    (path / "device.serial").write_text((device.serial or "") + "\n", encoding="utf-8")
    return path


def read_snapshot(session: Path, phase: str) -> Optional[dict]:
    path = session / f"snapshot_{phase}.json"
    if not path.is_file():
        return None
    try:
        with path.open(encoding="utf-8") as fh:
            return json.load(fh)
    except json.JSONDecodeError:
        warn(f"{path.name} is not valid JSON - ignoring it.")
        return None


def read_lines(path: Path) -> List[str]:
    if not path.is_file():
        return []
    return [ln.strip() for ln in path.read_text(encoding="utf-8").splitlines() if ln.strip()]
