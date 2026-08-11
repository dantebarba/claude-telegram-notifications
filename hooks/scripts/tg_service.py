"""launchd lifecycle for the daemon: install, uninstall, status, restart.

The plugin lives in a version-stamped cache directory that gets pruned on
upgrade, so the plist can never point at it. Install copies what the daemon
needs into the spool and points launchd there instead.
"""
import json
import os
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tg_api
import tg_config

LABEL = "com.claude-telegram-notifications.daemon"
DAEMON_FILES = ("daemon.sh", "tg_api.py", "tg_config.py", "tg_handlers.py")
THROTTLE_SECONDS = 10

APP_NAME = "Claude Telegram Notifications"
APP_EXECUTABLE = "claude-telegram-notifications"


SYSTEM_PYTHON = "/usr/bin/python3"


def plist_path():
    return Path.home() / "Library" / "LaunchAgents" / f"{LABEL}.plist"


def daemon_python():
    """Prefer the system interpreter over whatever happened to run the install.

    sys.executable is often a Homebrew/MacPorts python that moves or disappears
    on upgrade, which would leave launchd unable to start the daemon at all.
    /usr/bin/python3 always exists on macOS; the daemon is stdlib-only and runs
    on 3.9, so there is nothing to gain from a newer one.
    """
    try:
        result = subprocess.run(
            [SYSTEM_PYTHON, "-c", "import sys; print(sys.version_info >= (3, 8))"],
            capture_output=True, text=True, timeout=10,
        )
        if result.returncode == 0 and result.stdout.strip() == "True":
            return SYSTEM_PYTHON
    except Exception:
        pass
    return sys.executable


def read_credentials(state_dir):
    try:
        with open(Path(state_dir) / "settings.json", "r") as f:
            env = json.load(f).get("env", {})
    except Exception:
        return None, None
    return env.get("TG_BOT_TOKEN") or None, env.get("TG_CHAT_ID") or None


def _launchctl(*args):
    try:
        result = subprocess.run(
            ["launchctl", *args], capture_output=True, text=True, timeout=20
        )
        return result.returncode, (result.stdout + result.stderr).strip()
    except Exception as exc:
        return 1, repr(exc)


def _domain():
    return f"gui/{os.getuid()}"


def _bootout():
    code, _ = _launchctl("bootout", f"{_domain()}/{LABEL}")
    if code != 0 and plist_path().is_file():
        _launchctl("unload", "-w", str(plist_path()))


def _bootstrap():
    code, output = _launchctl("bootstrap", _domain(), str(plist_path()))
    if code != 0:
        code, output = _launchctl("load", "-w", str(plist_path()))
    return code, output


def is_loaded():
    code, output = _launchctl("list", LABEL)
    if code != 0:
        return None
    for line in output.splitlines():
        if '"PID"' in line:
            digits = "".join(c for c in line if c.isdigit())
            return int(digits) if digits else None
    return None


def app_bundle_path(spool_dir):
    """Deliberately *not* under bin/<version>: macOS identifies a background
    item by path, so a version-stamped bundle would appear as a new, unapproved
    Login Item on every upgrade."""
    return spool_dir / f"{APP_NAME}.app"


def write_app_bundle(spool_dir, python, daemon_path, state_dir):
    """Wrap the daemon in a minimal app bundle.

    launchd names a background item after whatever it launches, so pointing it
    straight at an interpreter shows up in Login Items as a bare "python3".
    Launching a bundle instead gives it the bundle's name.
    """
    bundle = app_bundle_path(spool_dir)
    macos_dir = bundle / "Contents" / "MacOS"
    macos_dir.mkdir(parents=True, exist_ok=True)

    with open(bundle / "Contents" / "Info.plist", "wb") as f:
        plistlib.dump({
            "CFBundleName": APP_NAME,
            "CFBundleDisplayName": APP_NAME,
            "CFBundleIdentifier": LABEL,
            "CFBundleExecutable": APP_EXECUTABLE,
            "CFBundlePackageType": "APPL",
            "CFBundleInfoDictionaryVersion": "6.0",
            "LSBackgroundOnly": True,
            "LSUIElement": True,
        }, f)

    launcher = macos_dir / APP_EXECUTABLE
    launcher.write_text(
        "#!/bin/sh\n"
        f'exec "{python}" "{daemon_path}" --state-dir "{state_dir}"\n'
    )
    os.chmod(launcher, 0o755)

    # Ad-hoc signature: this cannot make it a known developer, but it gives the
    # bundle a stable identity so macOS stops re-prompting after each rewrite.
    try:
        subprocess.run(
            ["codesign", "--force", "--sign", "-", str(bundle)],
            capture_output=True, timeout=30,
        )
    except Exception:
        pass
    return launcher


def install(state_dir, script_dir):
    token, chat = read_credentials(state_dir)
    if not token or not chat:
        return f"error: no TG_BOT_TOKEN/TG_CHAT_ID in {Path(state_dir) / 'settings.json'}"

    version = tg_config.plugin_version(script_dir)
    spool_dir = tg_config.bot_spool_dir(token)
    target = tg_config.bin_dir(spool_dir, version)
    try:
        target.mkdir(parents=True, exist_ok=True)
        for name in DAEMON_FILES:
            shutil.copy2(Path(script_dir) / name, target / name)
        os.chmod(target / "daemon.sh", 0o755)
    except Exception as exc:
        return f"error: could not stage daemon files ({exc})"

    try:
        launcher = write_app_bundle(
            spool_dir, daemon_python(), target / "daemon.sh", state_dir
        )
    except Exception as exc:
        return f"error: could not build the app bundle ({exc})"

    log_path = tg_config.daemon_log_path(spool_dir)
    plist = {
        "Label": LABEL,
        "ProgramArguments": [str(launcher)],
        "RunAtLoad": True,
        "KeepAlive": True,
        "ThrottleInterval": THROTTLE_SECONDS,
        "StandardOutPath": str(log_path),
        "StandardErrorPath": str(log_path),
    }
    try:
        plist_path().parent.mkdir(parents=True, exist_ok=True)
        with open(plist_path(), "wb") as f:
            plistlib.dump(plist, f)
    except Exception as exc:
        return f"error: could not write {plist_path()} ({exc})"

    _bootout()
    code, output = _bootstrap()
    if code != 0:
        return f"error: launchctl failed ({output})"

    tg_config.atomic_write_json(tg_config.daemon_marker_path(spool_dir), {
        "version": version,
        "bin_path": str(target),
        "state_dir": str(state_dir),
        "label": LABEL,
    })
    return f"daemon-installed:{version}"


def uninstall(state_dir):
    token, _ = read_credentials(state_dir)
    _bootout()
    try:
        plist_path().unlink()
    except FileNotFoundError:
        pass
    except Exception as exc:
        return f"error: could not remove {plist_path()} ({exc})"

    if token:
        tg_api.delete_my_commands(token)
        spool_dir = tg_config.bot_spool_dir(token)
        try:
            tg_config.daemon_marker_path(spool_dir).unlink()
        except FileNotFoundError:
            pass
        except Exception:
            pass
        shutil.rmtree(spool_dir / "bin", ignore_errors=True)
        shutil.rmtree(app_bundle_path(spool_dir), ignore_errors=True)
    return "daemon-uninstalled"


def restart(state_dir):
    if not plist_path().is_file():
        return "error: daemon is not installed"
    _bootout()
    code, output = _bootstrap()
    return "daemon-restarted" if code == 0 else f"error: launchctl failed ({output})"


def marker(state_dir):
    token, _ = read_credentials(state_dir)
    if not token:
        return {}
    try:
        with open(tg_config.daemon_marker_path(tg_config.bot_spool_dir(token)), "r") as f:
            return json.load(f)
    except Exception:
        return {}


def status(state_dir, script_dir):
    installed = plist_path().is_file()
    pid = is_loaded()
    info = marker(state_dir)
    lines = [
        "daemon-status",
        f"installed: {'yes' if installed else 'no'}",
        f"running: {'yes (pid ' + str(pid) + ')' if pid else 'no'}",
    ]
    if info:
        lines.append(f"version: {info.get('version', '?')} (plugin {tg_config.plugin_version(script_dir)})")
        lines.append(f"state-dir: {info.get('state_dir', '?')}")
    return "\n".join(lines)


def tail_log(state_dir, lines=40):
    token, _ = read_credentials(state_dir)
    if not token:
        return "error: no credentials, cannot locate the log"
    path = tg_config.daemon_log_path(tg_config.bot_spool_dir(token))
    try:
        content = path.read_text().splitlines()
    except Exception:
        return f"error: no log at {path}"
    return "\n".join(content[-lines:]) or "(log is empty)"


def needs_reinstall(state_dir, script_dir):
    """True when a plugin upgrade left the daemon running older code."""
    info = marker(state_dir)
    if not info:
        return False
    return info.get("version") != tg_config.plugin_version(script_dir)
