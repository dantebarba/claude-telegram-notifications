"""Every Telegram Bot API call the plugin makes.

Errors are swallowed everywhere: a notification plugin must never break the
hook it runs inside, and a failed call is always recoverable on the next event.
"""
import json
import ssl
import urllib.request

SSL_CONTEXT = ssl.create_default_context()
try:
    import certifi
    SSL_CONTEXT.load_verify_locations(certifi.where())
except Exception:
    SSL_CONTEXT.check_hostname = False
    SSL_CONTEXT.verify_mode = ssl.CERT_NONE

DEFAULT_TIMEOUT = 10


def call(bot_token, method, payload, timeout=DEFAULT_TIMEOUT):
    """Returns the parsed `result` on success, None on any failure."""
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{bot_token}/{method}",
        data=data,
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=SSL_CONTEXT) as response:
            body = json.loads(response.read().decode())
    except Exception:
        return None
    if not body.get("ok"):
        return None
    return body.get("result")


def send_message(bot_token, chat_id, text, reply_markup=None, timeout=DEFAULT_TIMEOUT):
    payload = {"chat_id": chat_id, "text": text}
    if reply_markup:
        payload["reply_markup"] = reply_markup
    return call(bot_token, "sendMessage", payload, timeout)


DEFAULT_UPDATE_TYPES = ["callback_query", "message"]


def get_updates(bot_token, offset, timeout=DEFAULT_TIMEOUT, limit=100, long_poll=0,
                allowed_updates=None):
    """`long_poll` is the server-side wait in seconds; the daemon holds the
    request open with it, while hook-driven polls pass 0 and return at once."""
    return call(
        bot_token,
        "getUpdates",
        {
            "offset": offset,
            "limit": limit,
            "timeout": long_poll,
            "allowed_updates": allowed_updates or DEFAULT_UPDATE_TYPES,
        },
        timeout,
    )


def answer_callback_query(bot_token, callback_query_id, text=None, show_alert=False,
                          timeout=DEFAULT_TIMEOUT):
    """Fails once the query is more than a few seconds old - callers must treat
    a False return as normal and fall back to something durable."""
    payload = {"callback_query_id": callback_query_id, "show_alert": bool(show_alert)}
    if text:
        payload["text"] = text[:200]
    return call(bot_token, "answerCallbackQuery", payload, timeout) is not None


def edit_message_reply_markup(bot_token, chat_id, message_id, reply_markup,
                              timeout=DEFAULT_TIMEOUT):
    return call(
        bot_token,
        "editMessageReplyMarkup",
        {"chat_id": chat_id, "message_id": message_id, "reply_markup": reply_markup},
        timeout,
    )


def edit_message_text(bot_token, chat_id, message_id, text, reply_markup=None,
                      timeout=DEFAULT_TIMEOUT):
    payload = {"chat_id": chat_id, "message_id": message_id, "text": text}
    if reply_markup:
        payload["reply_markup"] = reply_markup
    return call(bot_token, "editMessageText", payload, timeout)


def set_my_commands(bot_token, commands, timeout=DEFAULT_TIMEOUT):
    return call(bot_token, "setMyCommands", {"commands": commands}, timeout)


def delete_my_commands(bot_token, timeout=DEFAULT_TIMEOUT):
    return call(bot_token, "deleteMyCommands", {}, timeout)
