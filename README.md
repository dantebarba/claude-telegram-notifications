# Claude Code Telegram Notifications

Get notified in Telegram when Claude Code finishes a task or needs your input.

```
Claude Code --> hook --> Telegram Bot --> your phone
```

> Fork of [mikhailrojo/claude-telegram-notifications](https://github.com/mikhailrojo/claude-telegram-notifications) adding a `Stop`-event notification (task finished) and a `/notifications` toggle command.

## Installation

### 1. Create a Telegram bot

- Open [@BotFather](https://t.me/BotFather), send `/newbot`
- Copy the bot token
- Send any message to your bot, then open `https://api.telegram.org/bot<TOKEN>/getUpdates` to get your chat ID

### 2. Install the plugin

```
/plugin marketplace add dantebarba/claude-telegram-notifications
/plugin install telegram-notifications@claude-telegram-notifications
```

### 3. Add your credentials to `~/.claude/settings.json`

```json
{
  "env": {
    "TG_BOT_TOKEN": "your-bot-token",
    "TG_CHAT_ID": "your-chat-id"
  }
}
```

Restart Claude Code once credentials are set.

## Usage

Notifications are **off by default**. Run:

```
/notifications
```

to toggle them on or off. The command reports the new state. State is stored per-machine in `$CLAUDE_CONFIG_DIR/telegram-notifications.json` (defaults to `~/.claude/telegram-notifications.json`), so the toggle applies across all projects on that machine, not per-project.

```json
{"enabled": true, "auto_seconds": null}
```

If you're upgrading from an older version of this plugin, the legacy `telegram-notifications.enabled` sentinel file is read automatically as a fallback (treated as enabled, auto mode off) until the next time you run `/notifications`, at which point it's migrated to the JSON file above and removed.

When enabled, you'll get a Telegram message:
- when Claude Code finishes responding (`Stop` event) - useful for auto-mode/background runs
- when Claude Code is idle waiting for input, or needs permission (`Notification` event)

### Auto mode (debounced notifications)

By default, notifications send immediately. Auto mode instead waits until a session has been quiet for a configurable number of seconds before sending, so a burst of quick back-and-forth activity doesn't produce a notification per event.

```
/notifications auto 120   # enable auto mode: send only after 120s of inactivity
/notifications auto off   # disable auto mode: back to sending immediately
```

Auto mode maintains one shared debounce timer per Claude Code session, covering all notification types (finished, idle, permission request). Any new qualifying event in that session resets the timer; a message is only actually sent once the window elapses with no further activity in that session. Different sessions never interfere with each other's timers.

Pending (not-yet-sent) notification state lives in `$CLAUDE_CONFIG_DIR/telegram-notifications-pending/`, one file per session. These are cleaned up automatically after a notification sends or after 24 hours, whichever comes first — safe to delete manually if needed.
