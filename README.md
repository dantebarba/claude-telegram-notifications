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
{"enabled": true, "delay_seconds": null}
```

If you're upgrading from an older version of this plugin, the legacy `telegram-notifications.enabled` sentinel file is read automatically as a fallback (treated as enabled, delay mode off) until the next time you run `/notifications`, at which point it's migrated to the JSON file above and removed.

When enabled, you'll get a Telegram message:
- when Claude Code finishes responding (`Stop` event) - useful for delayed/background runs
- when Claude Code is idle waiting for input, or needs permission (`Notification` event)

### Delay mode (debounced notifications)

By default, notifications send immediately. Delay mode instead starts a timer on each qualifying event (finished, idle, permission request) and only sends once that timer runs out with no further qualifying event in the same session resetting it — so a burst of quick back-and-forth activity doesn't produce a notification per event.

```
/notifications delay 120   # enable delay mode: send only after 120s with no new event
/notifications delay off   # disable delay mode: back to sending immediately
```

Each session has at most one pending timer. Any new qualifying event in that session restarts the timer from zero and replaces the pending notification's content; the previous, now-stale timer is dropped silently when it fires — nothing is sent for it. Different sessions never interfere with each other's timers. Submitting a new prompt to Claude also cancels any pending timer for that session outright, since you're already back and engaged.

The timer runs in a detached background process so it survives the hook script exiting, which means it can outlive the `claude` process itself if you close the terminal or kill the session while a notification is still pending. To avoid sending a "finished"/"idle" ping for a session that's already gone, the timer records which `claude` process it belongs to when it starts and re-checks that the process is still running right before sending — if that process has been killed, the pending notification is dropped instead of sent.

Pending (not-yet-sent) notification state lives in `$CLAUDE_CONFIG_DIR/telegram-notifications-pending/`, one file per session. These are cleaned up automatically after a notification sends or after 24 hours, whichever comes first — safe to delete manually if needed.
