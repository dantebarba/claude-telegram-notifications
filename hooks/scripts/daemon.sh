#!/usr/bin/env python3
"""Long-polls Telegram so taps and commands land in under a second.

Runs under launchd. While it is alive it holds the shared poll lock through
each long poll, so the hooks' opportunistic polling finds the lock busy and
stands down; kill the daemon and they resume on the next event. That is the
whole fallback story - there is no second code path.
"""
import argparse
import fcntl
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tg_api
import tg_config
import tg_handlers

LONG_POLL_SECONDS = 30
ERROR_BACKOFF_SECONDS = 5
MAX_LOG_BYTES = 1_000_000


_REDACT = []


def log(message):
    """The bot token is embedded in every API URL, so anything that ever
    carries one into an exception must not reach this plaintext log."""
    text = str(message)
    for secret in _REDACT:
        if secret:
            text = text.replace(secret, "<redacted>")
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {text}", flush=True)


def truncate_log(spool_dir):
    path = tg_config.daemon_log_path(spool_dir)
    try:
        if path.is_file() and path.stat().st_size > MAX_LOG_BYTES:
            path.write_text("")
    except Exception:
        pass


def read_credentials(state_dir):
    """The hooks get these from the environment Claude sets up; launchd has no
    such environment, so read the same settings.json the env block lives in."""
    try:
        with open(Path(state_dir) / "settings.json", "r") as f:
            env = json.load(f).get("env", {})
    except Exception:
        return None, None
    return env.get("TG_BOT_TOKEN", ""), env.get("TG_CHAT_ID", "")


def resolve_credentials(state_dir):
    token, chat = read_credentials(state_dir)
    if token and chat:
        return token, chat
    # The install that started us may not be the one holding the credentials.
    for record in tg_config.load_installs(tg_config.bot_spool_dir(token or "")).values():
        token, chat = read_credentials(record["state_dir"])
        if token and chat:
            return token, chat
    return None, None


def poll_cycle(ctx, spool_dir, lock_file):
    cursor = tg_config.load_cursor(spool_dir)
    try:
        fcntl.flock(lock_file, fcntl.LOCK_EX)
        updates = tg_api.get_updates(
            ctx.bot_token,
            cursor["offset"] + 1,
            timeout=LONG_POLL_SECONDS + 10,
            long_poll=LONG_POLL_SECONDS,
        )
    finally:
        try:
            fcntl.flock(lock_file, fcntl.LOCK_UN)
        except Exception:
            pass

    if updates is None:
        return False

    offset = cursor["offset"]
    for update in updates:
        try:
            offset = max(offset, int(update.get("update_id", 0)))
        except (TypeError, ValueError):
            continue
        try:
            tg_handlers.handle_update(ctx, update)
        except Exception as exc:
            log(f"handler error: {exc!r}")
    if offset != cursor["offset"]:
        tg_config.save_cursor(spool_dir, offset, time.time())
        log(f"handled {len(updates)} update(s), offset now {offset}")
    return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state-dir", required=True)
    args = parser.parse_args()

    token, chat = resolve_credentials(args.state_dir)
    if not token or not chat:
        log(f"no TG_BOT_TOKEN/TG_CHAT_ID in {args.state_dir}/settings.json - exiting")
        return 1
    _REDACT.append(token)

    spool_dir = tg_config.bot_spool_dir(token)
    spool_dir.mkdir(parents=True, exist_ok=True)
    truncate_log(spool_dir)

    singleton = open(tg_config.daemon_lock_path(spool_dir), "w")
    try:
        fcntl.flock(singleton, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        log("another daemon already holds the lock - exiting")
        return 0

    ctx = tg_handlers.Context(token, chat, local_state_dir=args.state_dir)
    tg_api.set_my_commands(token, tg_handlers.PALETTE)
    log(f"daemon up (state-dir {args.state_dir}, long poll {LONG_POLL_SECONDS}s)")

    poll_lock = open(tg_config.lock_path(spool_dir), "w")
    while True:
        try:
            if not poll_cycle(ctx, spool_dir, poll_lock):
                time.sleep(ERROR_BACKOFF_SECONDS)
        except KeyboardInterrupt:
            log("interrupted - exiting")
            return 0
        except Exception as exc:
            log(f"poll error: {exc!r}")
            time.sleep(ERROR_BACKOFF_SECONDS)


if __name__ == "__main__":
    sys.exit(main())
