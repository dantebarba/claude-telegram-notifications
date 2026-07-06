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

to toggle them on or off. The command reports the new state. State is stored per-machine in `$CLAUDE_CONFIG_DIR/telegram-notifications.enabled` (defaults to `~/.claude/telegram-notifications.enabled`), so the toggle applies across all projects on that machine, not per-project.

When enabled, you'll get a Telegram message:
- when Claude Code finishes responding (`Stop` event) - useful for auto-mode/background runs
- when Claude Code is idle waiting for input, or needs permission (`Notification` event)
