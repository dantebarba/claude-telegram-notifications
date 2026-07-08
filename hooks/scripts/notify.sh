#!/usr/bin/env python3
import json
import os
import ssl
import subprocess
import sys
import time
import urllib.request
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tg_config

SSL_CONTEXT = ssl.create_default_context()
try:
    import certifi
    SSL_CONTEXT.load_verify_locations(certifi.where())
except Exception:
    SSL_CONTEXT.check_hostname = False
    SSL_CONTEXT.verify_mode = ssl.CERT_NONE

BOT_TOKEN = os.environ.get("TG_BOT_TOKEN", "")
CHAT_ID = os.environ.get("TG_CHAT_ID", "")

if not BOT_TOKEN or not CHAT_ID:
    sys.exit(0)

MAX_CLAUDE_MSG = 1000

BACKGROUND_TOOL_NAMES = {"Agent", "Task"}
PENDING_STATUSES = {"async_launched", "remote_launched", "teammate_spawned"}


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


def send_telegram_message(bot_token, chat_id, text, ssl_context):
    payload = json.dumps({"chat_id": chat_id, "text": text}).encode()
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{bot_token}/sendMessage",
        data=payload,
        headers={"Content-Type": "application/json"},
    )
    try:
        urllib.request.urlopen(req, timeout=10, context=ssl_context)
    except Exception:
        pass


def send_notification(hook_event, notification_type, message, cwd, session_id, transcript_path, state_dir):
    project_name = Path(cwd).name
    short_session = session_id[:8]
    account_email = read_account_email(state_dir)
    claude_message = read_last_claude_message(transcript_path)
    text = build_notification_text(
        hook_event, notification_type, message, project_name, short_session, account_email, claude_message
    )
    send_telegram_message(BOT_TOKEN, CHAT_ID, text, SSL_CONTEXT)


def cleanup_stale_pending(state_dir, max_age_seconds=86400):
    try:
        pdir = tg_config.pending_dir(state_dir)
        if not pdir.is_dir():
            return
        now = time.time()
        for f in pdir.glob("*.json"):
            try:
                if now - f.stat().st_mtime > max_age_seconds:
                    f.unlink()
            except OSError:
                pass
    except Exception:
        pass


def spawn_flush_child(session_id, generation, auto_seconds):
    script_path = str(Path(__file__).resolve())
    subprocess.Popen(
        [sys.executable, script_path, "--flush", session_id, generation, str(auto_seconds)],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def main_hook():
    state_dir = tg_config.get_state_dir()
    cleanup_stale_pending(state_dir)

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

    if hook_event == "Stop" or notification_type == "idle_prompt":
        if has_pending_background_agents(transcript_path):
            return

    auto_seconds = config.get("auto_seconds")
    if auto_seconds is not None and session_id and session_id != "unknown":
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
        }
        tg_config.atomic_write_json(tg_config.pending_file_path(state_dir, session_id), pending)
        spawn_flush_child(session_id, generation, auto_seconds)
        return

    send_notification(hook_event, notification_type, message, cwd, session_id, transcript_path, state_dir)


def main_flush(session_id, generation, auto_seconds):
    time.sleep(auto_seconds)

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
        hook_event = pending.get("hook_event", "")
        notification_type = pending.get("notification_type", "unknown")
        message = pending.get("message", "")
        cwd = pending.get("cwd", "unknown")
        transcript_path = pending.get("transcript_path", "")

        if hook_event == "Stop" or notification_type == "idle_prompt":
            if has_pending_background_agents(transcript_path):
                return

        send_notification(hook_event, notification_type, message, cwd, session_id, transcript_path, state_dir)
    finally:
        try:
            pending_path.unlink()
        except FileNotFoundError:
            pass
        except Exception:
            pass


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--flush":
        main_flush(sys.argv[2], sys.argv[3], int(sys.argv[4]))
    else:
        main_hook()
