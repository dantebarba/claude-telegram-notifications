#!/usr/bin/env python3
import fcntl
import json
import os
import subprocess
import sys
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tg_api
import tg_config
import tg_handlers

BOT_TOKEN = os.environ.get("TG_BOT_TOKEN", "")
CHAT_ID = os.environ.get("TG_CHAT_ID", "")

if not BOT_TOKEN or not CHAT_ID:
    sys.exit(0)

MAX_CLAUDE_MSG = 1000

BACKGROUND_TOOL_NAMES = {"Agent", "Task"}
PENDING_STATUSES = {"async_launched", "remote_launched", "teammate_spawned"}

MAX_ANCESTOR_HOPS = 8

# Blocking poll on a path that is about to send: the Stop/Notification hooks
# get 15s, so 2s of network is affordable and a tap lands before the next ping.
POLL_TIMEOUT = 2
MIN_POLL_INTERVAL = 3
# Without the daemon, a tap almost always happens seconds after the ping
# arrives, so chase the notification with a detached child rather than waiting
# for the next hook.
POST_SEND_POLL_DELAYS = (5, 15, 45)


def _ps_field(pid, field):
    try:
        result = subprocess.run(
            ["ps", "-o", f"{field}=", "-p", str(pid)],
            capture_output=True, text=True, timeout=3,
        )
    except Exception:
        return None
    if result.returncode != 0:
        return None
    value = result.stdout.strip()
    return value or None


def find_claude_process_fingerprint(start_pid):
    """Walk the process ancestry from start_pid looking for the claude CLI
    process. Captured while the hook runs synchronously (still a descendant
    of claude), so a later detached flush child can check it's still alive.
    """
    pid = start_pid
    for _ in range(MAX_ANCESTOR_HOPS):
        ppid_str = _ps_field(pid, "ppid")
        if not ppid_str:
            return None
        try:
            ppid = int(ppid_str)
        except ValueError:
            return None
        if ppid <= 1:
            return None
        comm = _ps_field(ppid, "comm") or ""
        if "claude" in comm.lower():
            return {"pid": ppid, "lstart": _ps_field(ppid, "lstart")}
        pid = ppid
    return None


def claude_process_still_alive(fingerprint):
    pid = fingerprint.get("pid")
    if not pid:
        return None
    comm = _ps_field(pid, "comm")
    if not comm or "claude" not in comm.lower():
        return False
    expected_lstart = fingerprint.get("lstart")
    if expected_lstart and _ps_field(pid, "lstart") != expected_lstart:
        return False
    return True


def read_account_email(state_dir):
    try:
        with open(state_dir / ".claude.json", "r") as f:
            return json.load(f).get("oauthAccount", {}).get("emailAddress", "")
    except Exception:
        return ""


def has_pending_background_agents(transcript_path):
    if not transcript_path or not Path(transcript_path).is_file():
        return False
    try:
        with open(transcript_path, "r") as f:
            lines = f.readlines()
    except Exception:
        return False

    tracked_ids = set()
    expected_background_ids = set()
    for line in lines:
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if entry.get("type") != "assistant":
            continue
        for block in entry.get("message", {}).get("content", []):
            if block.get("type") == "tool_use" and block.get("name") in BACKGROUND_TOOL_NAMES:
                tool_id = block.get("id")
                tracked_ids.add(tool_id)
                if block.get("input", {}).get("run_in_background") is not False:
                    expected_background_ids.add(tool_id)

    if not tracked_ids:
        return False

    resolved_ids = set()
    saw_pending_status = False
    for line in lines:
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if entry.get("type") != "user":
            continue
        content = entry.get("message", {}).get("content")
        if not isinstance(content, list):
            continue
        matched = False
        for block in content:
            if isinstance(block, dict) and block.get("type") == "tool_result" and block.get("tool_use_id") in tracked_ids:
                matched = True
                resolved_ids.add(block["tool_use_id"])
                if block.get("is_error") is True:
                    saw_pending_status = True
        if matched:
            status = (entry.get("toolUseResult") or {}).get("status")
            if status in PENDING_STATUSES:
                saw_pending_status = True

    if saw_pending_status:
        return True
    return any(tool_id not in resolved_ids for tool_id in expected_background_ids)


def read_last_claude_message(transcript_path, max_len=MAX_CLAUDE_MSG):
    if not transcript_path or not Path(transcript_path).is_file():
        return ""
    try:
        with open(transcript_path, "r") as f:
            lines = f.readlines()
    except Exception:
        return ""
    for line in reversed(lines):
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if entry.get("type") == "assistant":
            parts = []
            for block in entry.get("message", {}).get("content", []):
                if block.get("type") == "text":
                    parts.append(block["text"])
            return "\n".join(parts)[:max_len]
    return ""


def build_notification_text(hook_event, notification_type, message, project_name, short_session, account_email, claude_message):
    account_line = f"\nAccount: {account_email}" if account_email else ""
    if hook_event == "Stop":
        text = f"Claude Code finished\nProject: {project_name}\nSession: {short_session}{account_line}"
        if claude_message:
            text += f"\n\n{claude_message}"
    elif notification_type == "idle_prompt":
        text = f"Claude Code waiting for input\nProject: {project_name}\nSession: {short_session}{account_line}"
        if claude_message:
            text += f"\n\n{claude_message}"
    elif notification_type == "permission_prompt":
        safe_message = message[:300]
        text = f"Permission required\nProject: {project_name}\nSession: {short_session}{account_line}\n\n{safe_message}"
        if claude_message:
            text += f"\n\nClaude said:\n{claude_message}"
    else:
        text = f"Claude Code: {message}{account_line}"
        if claude_message:
            text += f"\n\n{claude_message}"
    return text


def context(state_dir):
    return tg_handlers.Context(BOT_TOKEN, CHAT_ID, local_state_dir=state_dir)


def send_notification(hook_event, notification_type, message, cwd, session_id, transcript_path, state_dir, config=None):
    project_name = Path(cwd).name
    short_session = session_id[:8]
    account_email = read_account_email(state_dir)
    claude_message = read_last_claude_message(transcript_path)
    text = build_notification_text(
        hook_event, notification_type, message, project_name, short_session, account_email, claude_message
    )
    install = tg_config.install_id(state_dir)
    spool_dir = tg_config.bot_spool_dir(BOT_TOKEN)
    # Recorded before sending so a command arriving moments later can resolve
    # "the conversation that just pinged me".
    tg_config.record_session(spool_dir, session_id, install, project_name, cwd)

    reply_markup = None
    if (config or {}).get("buttons", True):
        reply_markup = tg_handlers.notification_markup(install, session_id, False)
    tg_api.send_message(BOT_TOKEN, CHAT_ID, text, reply_markup)
    if reply_markup and not daemon_is_running(spool_dir):
        # With the daemon up, taps arrive within a second and chasing the
        # notification would just duplicate its work.
        spawn_poll_child()


def cleanup_stale_state(state_dir, max_age_seconds=86400):
    tg_config.cleanup_stale_dir(tg_config.pending_dir(state_dir), max_age_seconds)
    tg_config.cleanup_stale_dir(tg_config.muted_dir(state_dir), max_age_seconds)
    spool_dir = tg_config.bot_spool_dir(BOT_TOKEN)
    tg_config.cleanup_stale_dir(
        tg_config.inbox_dir(spool_dir, tg_config.install_id(state_dir)), max_age_seconds
    )
    tg_config.cleanup_stale_dir(tg_config.sessions_dir(spool_dir), max_age_seconds)
    tg_config.cleanup_stale_dir(tg_config.installs_dir(spool_dir), 30 * max_age_seconds)


def heal_daemon_if_stale(state_dir):
    """A plugin upgrade swaps the cache directory out from under the daemon, so
    whoever notices the version drift reinstalls it - detached, never blocking
    the hook."""
    try:
        import tg_service
        if tg_service.needs_reinstall(state_dir, Path(__file__).resolve().parent):
            spawn_detached("--heal")
    except Exception:
        pass


def spawn_detached(*args):
    script_path = str(Path(__file__).resolve())
    subprocess.Popen(
        [sys.executable, script_path, *args],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def spawn_flush_child(session_id, generation, delay_seconds):
    spawn_detached("--flush", session_id, generation, str(delay_seconds))


def spawn_poll_child():
    spawn_detached("--poll")


def daemon_is_running(spool_dir):
    """The daemon holds its lock for its whole life, so failing to take it is
    proof it is alive - no pidfile to go stale."""
    try:
        probe = open(tg_config.daemon_lock_path(spool_dir), "a")
    except Exception:
        return False
    try:
        fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(probe, fcntl.LOCK_UN)
        return False
    except OSError:
        return True
    finally:
        try:
            probe.close()
        except Exception:
            pass


def poll_once(state_dir):
    """Drain new updates: callbacks into per-install inboxes, typed commands
    handled on the spot.

    Only one process polls at a time: getUpdates offsets are global to the bot
    token, so two installs sharing a bot would otherwise consume each other's
    updates. Callback routing happens here rather than at drain time, which is
    why an install can never starve its sibling. When the daemon is up it holds
    this lock through every long poll, so this quietly does nothing.
    """
    spool_dir = tg_config.bot_spool_dir(BOT_TOKEN)
    try:
        spool_dir.mkdir(parents=True, exist_ok=True)
        lock_file = open(tg_config.lock_path(spool_dir), "w")
    except Exception:
        return

    try:
        try:
            fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return  # another process (or the daemon) is already polling

        cursor = tg_config.load_cursor(spool_dir)
        now = time.time()
        if now - cursor["last_poll"] < MIN_POLL_INTERVAL:
            return

        updates = tg_api.get_updates(BOT_TOKEN, cursor["offset"] + 1, timeout=POLL_TIMEOUT)
        if updates is None:
            tg_config.save_cursor(spool_dir, cursor["offset"], now)
            return

        ctx = context(state_dir)
        offset = cursor["offset"]
        for update in updates:
            try:
                update_id = int(update.get("update_id", 0))
            except (TypeError, ValueError):
                continue
            offset = max(offset, update_id)

            message = update.get("message")
            if message:
                # A typed command names no install, and the handler resolves
                # its target from the session registry, so whoever polls can
                # serve it directly.
                chat = message.get("chat") or {}
                if str(chat.get("id", "")) == str(CHAT_ID):
                    try:
                        tg_handlers.handle_message(ctx, message)
                    except Exception:
                        pass
                continue

            callback = update.get("callback_query") or {}
            chat = (callback.get("message") or {}).get("chat") or {}
            if str(chat.get("id", "")) != str(CHAT_ID):
                continue  # not our chat - never act on it

            parsed = tg_handlers.parse_callback_data(callback.get("data"))
            if not parsed:
                continue

            try:
                tg_config.atomic_write_json(
                    tg_config.inbox_dir(spool_dir, parsed["install"]) / f"{update_id}.json",
                    {"callback": callback, "parsed": parsed},
                )
            except Exception:
                pass

        tg_config.save_cursor(spool_dir, offset, now)
    finally:
        try:
            lock_file.close()
        except Exception:
            pass


def drain_inbox(state_dir, config):
    spool_dir = tg_config.bot_spool_dir(BOT_TOKEN)
    box = tg_config.inbox_dir(spool_dir, tg_config.install_id(state_dir))
    if not box.is_dir():
        return
    ctx = context(state_dir)
    for path in sorted(box.glob("*.json")):
        try:
            with open(path, "r") as f:
                entry = json.load(f)
        except Exception:
            entry = None
        try:
            path.unlink()
        except Exception:
            pass
        if entry and entry.get("callback"):
            try:
                tg_handlers.handle_callback(ctx, entry["callback"])
            except Exception:
                pass


def sync_callbacks(state_dir, config):
    """Pick up taps before acting on them. Callers are always either about to
    send a notification or running detached, never a latency-sensitive hook."""
    if not config.get("buttons", True):
        return
    poll_once(state_dir)
    drain_inbox(state_dir, config)


def main_hook():
    state_dir = tg_config.get_state_dir()
    cleanup_stale_state(state_dir)
    # Lets the daemon act on this install even though it was started by another.
    tg_config.record_install(tg_config.bot_spool_dir(BOT_TOKEN), tg_config.install_id(state_dir), state_dir)
    heal_daemon_if_stale(state_dir)

    config = tg_config.load_config(state_dir)
    if not config.get("enabled"):
        return

    hook_input = json.loads(sys.stdin.read())

    session_id = hook_input.get("session_id", "unknown")
    cwd = hook_input.get("cwd", "unknown")
    hook_event = hook_input.get("hook_event_name", "")
    notification_type = hook_input.get("notification_type", "unknown")
    message = hook_input.get("message", "")
    transcript_path = hook_input.get("transcript_path", "")

    if hook_event == "UserPromptSubmit":
        if session_id and session_id != "unknown":
            try:
                tg_config.pending_file_path(state_dir, session_id).unlink()
            except FileNotFoundError:
                pass
            except Exception:
                pass
        # This hook gets only 5s, so never poll inline here.
        if config.get("buttons", True):
            spawn_poll_child()
        return

    event_type = tg_config.classify_event(hook_event, notification_type)
    if not tg_config.event_enabled(config, event_type):
        return

    sync_callbacks(state_dir, config)

    if tg_config.is_session_muted(state_dir, session_id):
        return

    if hook_event == "Stop" or notification_type == "idle_prompt":
        if has_pending_background_agents(transcript_path):
            return

    delay_seconds = config.get("delay_seconds")
    if delay_seconds is not None and session_id and session_id != "unknown":
        generation = uuid.uuid4().hex
        pending = {
            "generation": generation,
            "queued_at": time.time(),
            "hook_event": hook_event,
            "notification_type": notification_type,
            "message": message,
            "cwd": cwd,
            "transcript_path": transcript_path,
            "session_id": session_id,
            "claude_fingerprint": find_claude_process_fingerprint(os.getpid()),
        }
        tg_config.atomic_write_json(tg_config.pending_file_path(state_dir, session_id), pending)
        spawn_flush_child(session_id, generation, delay_seconds)
        return

    send_notification(hook_event, notification_type, message, cwd, session_id, transcript_path, state_dir, config)


def main_flush(session_id, generation, delay_seconds):
    time.sleep(delay_seconds)

    state_dir = tg_config.get_state_dir()
    config = tg_config.load_config(state_dir)
    if not config.get("enabled"):
        return

    pending_path = tg_config.pending_file_path(state_dir, session_id)
    try:
        with open(pending_path, "r") as f:
            pending = json.load(f)
    except Exception:
        return

    if pending.get("generation") != generation:
        return

    try:
        fingerprint = pending.get("claude_fingerprint")
        if fingerprint and claude_process_still_alive(fingerprint) is False:
            return

        hook_event = pending.get("hook_event", "")
        notification_type = pending.get("notification_type", "unknown")
        message = pending.get("message", "")
        cwd = pending.get("cwd", "unknown")
        transcript_path = pending.get("transcript_path", "")

        event_type = tg_config.classify_event(hook_event, notification_type)
        if not tg_config.event_enabled(config, event_type):
            return

        sync_callbacks(state_dir, config)

        if tg_config.is_session_muted(state_dir, session_id):
            return

        if hook_event == "Stop" or notification_type == "idle_prompt":
            if has_pending_background_agents(transcript_path):
                return

        send_notification(hook_event, notification_type, message, cwd, session_id, transcript_path, state_dir, config)
    finally:
        try:
            pending_path.unlink()
        except FileNotFoundError:
            pass
        except Exception:
            pass


def main_poll():
    """Chase a just-sent notification, so a tap made while looking at it is
    picked up in seconds rather than at the next hook."""
    state_dir = tg_config.get_state_dir()
    elapsed = 0
    for delay in POST_SEND_POLL_DELAYS:
        time.sleep(delay - elapsed)
        elapsed = delay
        config = tg_config.load_config(state_dir)
        if not config.get("enabled") or not config.get("buttons", True):
            return
        poll_once(state_dir)
        drain_inbox(state_dir, config)


def main_heal():
    import tg_service
    state_dir = tg_config.get_state_dir()
    script_dir = Path(__file__).resolve().parent
    if tg_service.needs_reinstall(state_dir, script_dir):
        tg_service.install(tg_service.marker(state_dir).get("state_dir", str(state_dir)), script_dir)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--flush":
        main_flush(sys.argv[2], sys.argv[3], int(sys.argv[4]))
    elif len(sys.argv) > 1 and sys.argv[1] == "--poll":
        main_poll()
    elif len(sys.argv) > 1 and sys.argv[1] == "--heal":
        main_heal()
    else:
        main_hook()
