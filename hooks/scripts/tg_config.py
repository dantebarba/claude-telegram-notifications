import json
import os
import tempfile
from pathlib import Path

CONFIG_FILENAME = "telegram-notifications.json"
LEGACY_ENABLED_FILENAME = "telegram-notifications.enabled"
PENDING_DIRNAME = "telegram-notifications-pending"

DEFAULT_CONFIG = {"enabled": False, "auto_seconds": None}


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


def load_config(state_dir):
    cfg_path = config_path(state_dir)
    if cfg_path.is_file():
        try:
            with open(cfg_path, "r") as f:
                data = json.load(f)
            return {
                "enabled": bool(data.get("enabled", False)),
                "auto_seconds": data.get("auto_seconds"),
            }
        except Exception:
            return dict(DEFAULT_CONFIG)

    if legacy_sentinel_path(state_dir).is_file():
        return {"enabled": True, "auto_seconds": None}

    return dict(DEFAULT_CONFIG)


def save_config(state_dir, config):
    atomic_write_json(config_path(state_dir), config)
    try:
        legacy_sentinel_path(state_dir).unlink()
    except FileNotFoundError:
        pass
    except Exception:
        pass
