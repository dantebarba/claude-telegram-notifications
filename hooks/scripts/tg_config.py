import json
import os
import tempfile
import time
from pathlib import Path

CONFIG_FILENAME = "telegram-notifications.json"
LEGACY_ENABLED_FILENAME = "telegram-notifications.enabled"
PENDING_DIRNAME = "telegram-notifications-pending"
MUTED_DIRNAME = "telegram-notifications-muted"

EVENT_TYPES = ("permission", "idle", "finish")

DEFAULT_CONFIG = {
    "enabled": False,
    "delay_seconds": None,
    "events": {event_type: True for event_type in EVENT_TYPES},
}


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
                "events": normalize_events(data.get("events")),
            }
        except Exception:
            return {**DEFAULT_CONFIG, "events": default_events()}

    if legacy_sentinel_path(state_dir).is_file():
        return {"enabled": True, "delay_seconds": None, "events": default_events()}

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


def is_session_muted(state_dir, session_id):
    if not session_id or session_id == "unknown":
        return False
    return muted_file_path(state_dir, session_id).is_file()


def mute_session(state_dir, session_id):
    atomic_write_json(muted_file_path(state_dir, session_id), {"muted_at": time.time()})


def unmute_session(state_dir, session_id):
    """Returns True when a mute was actually lifted."""
    try:
        muted_file_path(state_dir, session_id).unlink()
        return True
    except FileNotFoundError:
        return False
    except Exception:
        return False


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
