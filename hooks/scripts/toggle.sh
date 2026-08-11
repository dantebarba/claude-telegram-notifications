#!/usr/bin/env python3
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tg_config

USAGE = (
    "error: usage: /notifications [on|off] | /notifications on|off <permission|idle|finish> | "
    "/notifications delay <seconds> | /notifications delay off | /notifications buttons on|off | "
    "/notifications mute | /notifications unmute | /notifications status"
)


def usage_error():
    print(USAGE)


def current_session_id():
    return os.environ.get("CLAUDE_CODE_SESSION_ID", "").strip()


def print_global(enabled):
    print("enabled" if enabled else "disabled")


def print_status(state_dir, config):
    delay = config.get("delay_seconds")
    events = tg_config.normalize_events(config.get("events"))
    session_id = current_session_id()

    if not session_id:
        session_line = "unknown (no session id)"
    elif tg_config.is_session_muted(state_dir, session_id):
        session_line = "muted"
    else:
        session_line = "active"

    print("status")
    print(f"global: {'on' if config.get('enabled') else 'off'}")
    print(f"delay: {f'{delay}s' if delay else 'off (immediate)'}")
    print("events: " + " ".join(
        f"{event_type}={'on' if events[event_type] else 'off'}"
        for event_type in tg_config.EVENT_TYPES
    ))
    print(f"buttons: {'on' if config.get('buttons', True) else 'off'}")
    print(f"session: {session_line}")


def set_event(state_dir, config, event_type, value):
    if event_type not in tg_config.EVENT_TYPES:
        usage_error()
        return
    events = tg_config.normalize_events(config.get("events"))
    events[event_type] = value
    config["events"] = events
    if value:
        # Enabling a type while the global switch is off would silently do
        # nothing, so turn it on - same as `delay <seconds>` does.
        config["enabled"] = True
    tg_config.save_config(state_dir, config)
    print(f"event-{'enabled' if value else 'disabled'}:{event_type}")


def handle_mute(state_dir, mute):
    session_id = current_session_id()
    if not session_id:
        print("error: no session id available (CLAUDE_CODE_SESSION_ID unset)")
        return

    if mute:
        tg_config.mute_session(state_dir, session_id)
        # Drop anything already waiting out the delay for this session.
        try:
            tg_config.pending_file_path(state_dir, session_id).unlink()
        except FileNotFoundError:
            pass
        except Exception:
            pass
        print("muted")
        return

    tg_config.unmute_session(state_dir, session_id)
    print("unmuted")


def main(argv):
    state_dir = tg_config.get_state_dir()
    config = tg_config.load_config(state_dir)

    if not argv:
        config["enabled"] = not config.get("enabled", False)
        tg_config.save_config(state_dir, config)
        print_global(config["enabled"])
        return

    if len(argv) == 1:
        command = argv[0]

        if command in ("on", "off"):
            config["enabled"] = command == "on"
            tg_config.save_config(state_dir, config)
            print_global(config["enabled"])
            return

        if command in ("mute", "unmute"):
            handle_mute(state_dir, command == "mute")
            return

        if command == "status":
            print_status(state_dir, config)
            return

        usage_error()
        return

    if len(argv) == 2 and argv[0] in ("on", "off"):
        set_event(state_dir, config, argv[1], argv[0] == "on")
        return

    if len(argv) == 2 and argv[0] == "buttons" and argv[1] in ("on", "off"):
        config["buttons"] = argv[1] == "on"
        tg_config.save_config(state_dir, config)
        print(f"buttons-{'enabled' if config['buttons'] else 'disabled'}")
        return

    if len(argv) == 2 and argv[0] == "delay":
        if argv[1] == "off":
            config["delay_seconds"] = None
            tg_config.save_config(state_dir, config)
            print("delay-disabled")
            return

        try:
            seconds = int(argv[1])
        except ValueError:
            usage_error()
            return

        if seconds <= 0:
            usage_error()
            return

        config["delay_seconds"] = seconds
        config["enabled"] = True
        tg_config.save_config(state_dir, config)
        print(f"delay-enabled:{seconds}")
        return

    usage_error()


if __name__ == "__main__":
    main(sys.argv[1:])
