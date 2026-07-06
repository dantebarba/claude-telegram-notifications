#!/usr/bin/env python3
import json
import os
import ssl
import sys
import urllib.request
from pathlib import Path

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

STATE_DIR = Path(os.environ.get("CLAUDE_CONFIG_DIR", str(Path.home() / ".claude")))
STATE_FILE = STATE_DIR / "telegram-notifications.enabled"

if not STATE_FILE.is_file():
    sys.exit(0)

MAX_CLAUDE_MSG = 1000

hook_input = json.loads(sys.stdin.read())

session_id = hook_input.get("session_id", "unknown")
cwd = hook_input.get("cwd", "unknown")
hook_event = hook_input.get("hook_event_name", "")
notification_type = hook_input.get("notification_type", "unknown")
message = hook_input.get("message", "")
transcript_path = hook_input.get("transcript_path", "")

project_name = Path(cwd).name
short_session = session_id[:8]

claude_message = ""
if transcript_path and Path(transcript_path).is_file():
    try:
        with open(transcript_path, "r") as f:
            lines = f.readlines()
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
                claude_message = "\n".join(parts)[:MAX_CLAUDE_MSG]
                break
    except Exception:
        pass

if hook_event == "Stop":
    text = f"Claude Code finished\nProject: {project_name}\nSession: {short_session}"
    if claude_message:
        text += f"\n\n{claude_message}"
elif notification_type == "idle_prompt":
    text = f"Claude Code waiting for input\nProject: {project_name}\nSession: {short_session}"
    if claude_message:
        text += f"\n\n{claude_message}"
elif notification_type == "permission_prompt":
    safe_message = message[:300]
    text = f"Permission required\nProject: {project_name}\nSession: {short_session}\n\n{safe_message}"
    if claude_message:
        text += f"\n\nClaude said:\n{claude_message}"
else:
    text = f"Claude Code: {message}"
    if claude_message:
        text += f"\n\n{claude_message}"

payload = json.dumps({"chat_id": CHAT_ID, "text": text}).encode()
req = urllib.request.Request(
    f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage",
    data=payload,
    headers={"Content-Type": "application/json"},
)

try:
    urllib.request.urlopen(req, timeout=10, context=SSL_CONTEXT)
except Exception:
    pass
