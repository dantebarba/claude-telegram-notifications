import hashlib
import json
import os
import re
import tempfile
import time
from pathlib import Path

CONFIG_FILENAME = "telegram-notifications.json"
LEGACY_ENABLED_FILENAME = "telegram-notifications.enabled"
PENDING_DIRNAME = "telegram-notifications-pending"
MUTED_DIRNAME = "telegram-notifications-muted"

# Shared by every install that talks to the same bot, so it cannot live under
# CLAUDE_CONFIG_DIR: getUpdates offsets are global to a bot token.
SPOOL_DIRNAME = ".claude-telegram-notifications"

EVENT_TYPES = ("permission", "idle", "finish")

DEFAULT_CONFIG = {
    "enabled": False,
    "delay_seconds": None,
    "buttons": True,
    "events": {event_type: True for event_type in EVENT_TYPES},
}

SESSION_ID_RE = re.compile(r"\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\Z")


def get_state_dir():
    return Path(os.environ.get("CLAUDE_CONFIG_DIR", str(Path.home() / ".claude")))


def config_path(state_dir):
    return state_dir / CONFIG_FILENAME


def legacy_sentinel_path(state_dir):
    return state_dir / LEGACY_ENABLED_FILENAME


def pending_dir(state_dir):
    return state_dir / PENDING_DIRNAME


def pending_file_path(state_dir, session_id):
    return pending_dir(state_dir) / f"{session_id}.json"


def muted_dir(state_dir):
    return state_dir / MUTED_DIRNAME


def muted_file_path(state_dir, session_id):
    return muted_dir(state_dir) / f"{session_id}.json"


def atomic_write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f)
        os.replace(tmp_path, path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def default_events():
    return dict(DEFAULT_CONFIG["events"])


def normalize_events(raw):
    """Missing or malformed per-type flags default to enabled, so configs
    written before per-event toggles existed keep notifying on everything."""
    if not isinstance(raw, dict):
        raw = {}
    return {event_type: bool(raw.get(event_type, True)) for event_type in EVENT_TYPES}


def load_config(state_dir):
    cfg_path = config_path(state_dir)
    if cfg_path.is_file():
        try:
            with open(cfg_path, "r") as f:
                data = json.load(f)
            return {
                "enabled": bool(data.get("enabled", False)),
                "delay_seconds": data.get("delay_seconds"),
                "buttons": bool(data.get("buttons", True)),
                "events": normalize_events(data.get("events")),
            }
        except Exception:
            return {**DEFAULT_CONFIG, "events": default_events()}

    if legacy_sentinel_path(state_dir).is_file():
        return {
            "enabled": True,
            "delay_seconds": None,
            "buttons": True,
            "events": default_events(),
        }

    return {**DEFAULT_CONFIG, "events": default_events()}


def save_config(state_dir, config):
    atomic_write_json(config_path(state_dir), config)
    try:
        legacy_sentinel_path(state_dir).unlink()
    except FileNotFoundError:
        pass
    except Exception:
        pass


def classify_event(hook_event, notification_type):
    """Map a hook payload onto one of EVENT_TYPES, or None when it matches
    none of them (an unclassified event is never filtered out)."""
    if hook_event == "Stop":
        return "finish"
    if notification_type == "idle_prompt":
        return "idle"
    if notification_type == "permission_prompt":
        return "permission"
    return None


def event_enabled(config, event_type):
    if event_type is None:
        return True
    return normalize_events(config.get("events")).get(event_type, True)


def valid_session_id(session_id):
    """Session ids become filenames, and since the button callbacks arrive over
    the network they cannot be trusted the way hook stdin can."""
    if not session_id or session_id == "unknown":
        return False
    return bool(SESSION_ID_RE.match(session_id))


def is_session_muted(state_dir, session_id):
    if not valid_session_id(session_id):
        return False
    return muted_file_path(state_dir, session_id).is_file()


def mute_session(state_dir, session_id):
    if not valid_session_id(session_id):
        return False
    atomic_write_json(muted_file_path(state_dir, session_id), {"muted_at": time.time()})
    return True


def unmute_session(state_dir, session_id):
    """Returns True when a mute was actually lifted."""
    if not valid_session_id(session_id):
        return False
    try:
        muted_file_path(state_dir, session_id).unlink()
        return True
    except FileNotFoundError:
        return False
    except Exception:
        return False


def install_id(state_dir):
    """Stable short id for this install, so a poller can route a button tap to
    the config dir whose notification carried the button."""
    return hashlib.sha256(str(Path(state_dir)).encode()).hexdigest()[:8]


def bot_spool_dir(bot_token):
    digest = hashlib.sha256(bot_token.encode()).hexdigest()[:12]
    return Path.home() / SPOOL_DIRNAME / digest


def cursor_path(spool_dir):
    return spool_dir / "cursor.json"


def lock_path(spool_dir):
    return spool_dir / "poll.lock"


def daemon_lock_path(spool_dir):
    return spool_dir / "daemon.lock"


def daemon_marker_path(spool_dir):
    return spool_dir / "daemon.json"


def daemon_log_path(spool_dir):
    return spool_dir / "daemon.log"


def bin_dir(spool_dir, version):
    return spool_dir / "bin" / version


def inbox_dir(spool_dir, install):
    return spool_dir / "inbox" / install


def installs_dir(spool_dir):
    return spool_dir / "installs"


def sessions_dir(spool_dir):
    return spool_dir / "sessions"


def record_install(spool_dir, install, state_dir, refresh_after=3600):
    """Lets the daemon act on any install's state, not just the one that
    started it. Rewritten only when stale, so it is not a per-hook write."""
    path = installs_dir(spool_dir) / f"{install}.json"
    try:
        if path.is_file() and time.time() - path.stat().st_mtime < refresh_after:
            return
    except OSError:
        pass
    try:
        atomic_write_json(path, {"state_dir": str(state_dir), "last_seen": time.time()})
    except Exception:
        pass


def load_installs(spool_dir):
    found = {}
    try:
        for path in installs_dir(spool_dir).glob("*.json"):
            try:
                with open(path, "r") as f:
                    data = json.load(f)
            except Exception:
                continue
            state_dir = data.get("state_dir")
            if state_dir:
                found[path.stem] = {"state_dir": Path(state_dir), "last_seen": data.get("last_seen", 0)}
    except Exception:
        pass
    return found


def record_session(spool_dir, session_id, install, project, cwd):
    if not valid_session_id(session_id):
        return
    try:
        atomic_write_json(
            sessions_dir(spool_dir) / f"{session_id}.json",
            {
                "install_id": install,
                "project": project,
                "cwd": str(cwd),
                "last_active": time.time(),
            },
        )
    except Exception:
        pass


def load_sessions(spool_dir):
    """Most recently active first - `/mute` with no argument means the top one."""
    found = []
    try:
        for path in sessions_dir(spool_dir).glob("*.json"):
            try:
                with open(path, "r") as f:
                    data = json.load(f)
            except Exception:
                continue
            data["session_id"] = path.stem
            found.append(data)
    except Exception:
        pass
    return sorted(found, key=lambda s: s.get("last_active", 0), reverse=True)


def plugin_version(script_dir):
    try:
        with open(Path(script_dir).resolve().parents[1] / ".claude-plugin" / "plugin.json") as f:
            return str(json.load(f).get("version", "")) or "unknown"
    except Exception:
        return "unknown"


def load_cursor(spool_dir):
    try:
        with open(cursor_path(spool_dir), "r") as f:
            data = json.load(f)
        return {
            "offset": int(data.get("offset", 0)),
            "last_poll": float(data.get("last_poll", 0)),
        }
    except Exception:
        return {"offset": 0, "last_poll": 0.0}


def save_cursor(spool_dir, offset, last_poll):
    atomic_write_json(cursor_path(spool_dir), {"offset": offset, "last_poll": last_poll})


def cleanup_stale_dir(dir_path, max_age_seconds=86400):
    try:
        if not dir_path.is_dir():
            return
        now = time.time()
        for f in dir_path.glob("*.json"):
            try:
                if now - f.stat().st_mtime > max_age_seconds:
                    f.unlink()
            except OSError:
                pass
    except Exception:
        pass
