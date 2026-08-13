"""Everything that turns a Telegram update into an action.

Shared by the hook (opportunistic polling) and the daemon (long polling) so the
two cannot drift apart: only the transport differs.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tg_api
import tg_config

ACTION_MUTE = "m"
ACTION_UNMUTE = "u"
ACTION_STATUS = "s"
ACTION_TOGGLE = "t"
ACTION_GLOBAL = "g"
ACTION_MUTE_ALL = "a"

SESSION_ACTIONS = (ACTION_MUTE, ACTION_UNMUTE, ACTION_STATUS)

PANEL_PREFIX = "Claude notifications"

PALETTE = [
    {"command": "status", "description": "Settings panel: events, mute, enable/disable"},
    {"command": "mute", "description": "Silence every conversation"},
    {"command": "unmute", "description": "Bring all conversations back"},
]


class Context:
    """Bundles the bot credentials with a way to reach any install's state."""

    def __init__(self, bot_token, chat_id, local_state_dir=None):
        self.bot_token = bot_token
        self.chat_id = chat_id
        self.spool = tg_config.bot_spool_dir(bot_token)
        self.local_state_dir = Path(local_state_dir) if local_state_dir else None

    def installs(self):
        found = tg_config.load_installs(self.spool)
        if self.local_state_dir is not None:
            found.setdefault(
                tg_config.install_id(self.local_state_dir),
                {"state_dir": self.local_state_dir, "last_seen": 0},
            )
        return found

    def state_dir_for(self, install):
        record = self.installs().get(install)
        return record["state_dir"] if record else None


# ------------------------------------------------------------------ payloads

def callback_data(action, install, arg):
    return f"{action}:{install}:{arg}"


def parse_callback_data(raw):
    parts = (raw or "").split(":")
    if len(parts) != 3:
        return None
    action, install, arg = parts
    if not install:
        return None
    if action in SESSION_ACTIONS:
        if not tg_config.valid_session_id(arg):
            return None
    elif action == ACTION_TOGGLE:
        if arg not in tg_config.EVENT_TYPES:
            return None
    elif action in (ACTION_GLOBAL, ACTION_MUTE_ALL):
        if arg not in ("0", "1"):
            return None
    else:
        return None
    return {"action": action, "install": install, "arg": arg}


# ------------------------------------------------------------------- markup

def notification_markup(install, session_id, muted):
    """The two buttons riding on each notification."""
    if not tg_config.valid_session_id(session_id):
        return None
    toggle = (
        {"text": "🔔 Unmute", "callback_data": callback_data(ACTION_UNMUTE, install, session_id)}
        if muted
        else {"text": "🔕 Mute", "callback_data": callback_data(ACTION_MUTE, install, session_id)}
    )
    return {
        "inline_keyboard": [[
            toggle,
            {"text": "📊 Status", "callback_data": callback_data(ACTION_STATUS, install, session_id)},
        ]]
    }


def status_text(state_dir, config, session_id):
    """Short enough for an answerCallbackQuery alert (200 char cap)."""
    events = tg_config.normalize_events(config.get("events"))
    delay = config.get("delay_seconds")
    if tg_config.is_muted_all(state_dir):
        muted = "all conversations"
    elif tg_config.is_session_muted(state_dir, session_id):
        muted = "this session"
    else:
        muted = "no"
    return "\n".join([
        f"global: {'on' if config.get('enabled') else 'off'}",
        f"delay: {f'{delay}s' if delay else 'off (immediate)'}",
        " ".join(f"{e}={'on' if events[e] else 'off'}" for e in tg_config.EVENT_TYPES),
        f"muted: {muted}",
    ])


def build_panel(ctx, install, state_dir):
    """The /status control panel: current state as text, controls as buttons."""
    config = tg_config.load_config(state_dir)
    events = tg_config.normalize_events(config.get("events"))
    delay = config.get("delay_seconds")

    recent = [s for s in tg_config.load_sessions(ctx.spool) if s.get("install_id") == install]
    session = recent[0] if recent else None
    session_id = session.get("session_id") if session else None
    muted = tg_config.is_session_muted(state_dir, session_id) if session_id else False
    muted_all = tg_config.is_muted_all(state_dir)

    lines = [
        f"{PANEL_PREFIX} — {Path(state_dir).name}",
        f"global: {'on' if config.get('enabled') else 'off'}    "
        f"delay: {f'{delay}s' if delay else 'immediate'}"
        f"{'    muted: all' if muted_all else ''}",
    ]
    if session:
        lines.append(
            f"last session: {session['session_id'][:8]} ({session.get('project', '?')})"
            f"{' — muted' if muted else ''}"
        )
    else:
        lines.append("last session: none yet")

    rows = [[
        {
            "text": f"{'✅' if events[event] else '❌'} {event}",
            "callback_data": callback_data(ACTION_TOGGLE, install, event),
        }
        for event in tg_config.EVENT_TYPES
    ]]
    # Master mute lives on the panel; a single conversation is silenced from the
    # buttons on its own notification, which name the exact session.
    rows.append([{
        "text": "🔔 Unmute all" if muted_all else "🔕 Mute all",
        "callback_data": callback_data(ACTION_MUTE_ALL, install, "0" if muted_all else "1"),
    }])
    rows.append([{
        "text": "⏸ Disable all" if config.get("enabled") else "▶️ Enable all",
        "callback_data": callback_data(ACTION_GLOBAL, install, "0" if config.get("enabled") else "1"),
    }])

    return "\n".join(lines), {"inline_keyboard": rows}


# ------------------------------------------------------------------ dispatch

def _refresh_message(ctx, install, state_dir, message, session_id=None, muted=False,
                     force_panel=False):
    """Re-render whatever the tap came from: a panel rewrites its whole body,
    a notification only swaps its buttons so the message text is preserved.

    Toggle and global taps pass force_panel, since those buttons only ever live
    on a panel - relying on the text sniff would leave them without feedback if
    the body were ever reworded.
    """
    chat_id = (message.get("chat") or {}).get("id")
    message_id = message.get("message_id")
    if chat_id is None or message_id is None:
        return
    if force_panel or (message.get("text") or "").startswith(PANEL_PREFIX):
        text, markup = build_panel(ctx, install, state_dir)
        tg_api.edit_message_text(ctx.bot_token, chat_id, message_id, text, markup)
        return
    markup = notification_markup(install, session_id, muted)
    if markup:
        tg_api.edit_message_reply_markup(ctx.bot_token, chat_id, message_id, markup)


def handle_callback(ctx, callback):
    parsed = parse_callback_data(callback.get("data"))
    if not parsed:
        return
    install, action, arg = parsed["install"], parsed["action"], parsed["arg"]
    state_dir = ctx.state_dir_for(install)
    if state_dir is None:
        return

    query_id = callback.get("id")
    message = callback.get("message") or {}
    config = tg_config.load_config(state_dir)

    if action == ACTION_STATUS:
        text = status_text(state_dir, config, arg)
        if not tg_api.answer_callback_query(ctx.bot_token, query_id, text, show_alert=True):
            # The query expired before we reached it; a message is the only
            # way the answer still lands.
            tg_api.send_message(ctx.bot_token, ctx.chat_id, text)
        return

    if action == ACTION_TOGGLE:
        events = tg_config.normalize_events(config.get("events"))
        events[arg] = not events[arg]
        config["events"] = events
        if events[arg]:
            config["enabled"] = True
        tg_config.save_config(state_dir, config)
        tg_api.answer_callback_query(
            ctx.bot_token, query_id, f"{arg} {'on' if events[arg] else 'off'}"
        )
        _refresh_message(ctx, install, state_dir, message, force_panel=True)
        return

    if action == ACTION_GLOBAL:
        config["enabled"] = arg == "1"
        tg_config.save_config(state_dir, config)
        tg_api.answer_callback_query(
            ctx.bot_token, query_id, "notifications on" if config["enabled"] else "notifications off"
        )
        _refresh_message(ctx, install, state_dir, message, force_panel=True)
        return

    if action == ACTION_MUTE_ALL:
        mute = arg == "1"
        if mute:
            tg_config.mute_all(state_dir)
            tg_config.clear_pending(state_dir)
        else:
            tg_config.unmute_all(state_dir)
        tg_api.answer_callback_query(
            ctx.bot_token, query_id,
            "🔕 All conversations muted" if mute else "🔔 All conversations unmuted",
        )
        _refresh_message(ctx, install, state_dir, message, force_panel=True)
        return

    muted = action == ACTION_MUTE
    if muted:
        tg_config.mute_session(state_dir, arg)
        try:
            tg_config.pending_file_path(state_dir, arg).unlink()
        except FileNotFoundError:
            pass
        except Exception:
            pass
    else:
        tg_config.unmute_session(state_dir, arg)
    tg_api.answer_callback_query(
        ctx.bot_token, query_id,
        "🔕 Muted this conversation" if muted else "🔔 Unmuted this conversation",
    )
    _refresh_message(ctx, install, state_dir, message, session_id=arg, muted=muted)


# ------------------------------------------------------------------ commands

def send_panels(ctx):
    installs = ctx.installs()
    if not installs:
        tg_api.send_message(ctx.bot_token, ctx.chat_id, "No Claude installs have notified yet.")
        return
    for install, record in sorted(installs.items(), key=lambda kv: str(kv[1]["state_dir"])):
        text, markup = build_panel(ctx, install, record["state_dir"])
        tg_api.send_message(ctx.bot_token, ctx.chat_id, text, markup)


def handle_message(ctx, message):
    text = (message.get("text") or "").strip()
    if not text.startswith("/"):
        return
    command = text.split()[0].lstrip("/").split("@")[0].lower()

    if command == "status":
        send_panels(ctx)
        return

    if command not in ("mute", "unmute"):
        return

    # Typed here, mute is a master switch over every install this bot knows: the
    # inline buttons on a notification are how you silence one conversation.
    installs = ctx.installs()
    if not installs:
        tg_api.send_message(ctx.bot_token, ctx.chat_id, "No Claude installs have notified yet.")
        return

    for record in installs.values():
        state_dir = record["state_dir"]
        if command == "mute":
            tg_config.mute_all(state_dir)
            tg_config.clear_pending(state_dir)
        else:
            tg_config.unmute_all(state_dir)

    tg_api.send_message(
        ctx.bot_token, ctx.chat_id,
        "🔕 Muted all conversations" if command == "mute" else "🔔 Unmuted all conversations",
    )


def handle_update(ctx, update):
    """Single entry point for both transports. Anything from another chat is
    dropped here - typed commands are a remote control for this plugin."""
    callback = update.get("callback_query")
    if callback:
        chat = (callback.get("message") or {}).get("chat") or {}
        if str(chat.get("id", "")) != str(ctx.chat_id):
            return
        handle_callback(ctx, callback)
        return

    message = update.get("message")
    if message:
        chat = message.get("chat") or {}
        if str(chat.get("id", "")) != str(ctx.chat_id):
            return
        handle_message(ctx, message)
