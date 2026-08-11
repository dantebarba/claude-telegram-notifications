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

to toggle them on or off, or `/notifications on` / `/notifications off` to set the state explicitly. `/notifications status` prints everything at once. State is stored per-machine in `$CLAUDE_CONFIG_DIR/telegram-notifications.json` (defaults to `~/.claude/telegram-notifications.json`), so it applies across all projects on that machine, not per-project.

```json
{
  "enabled": true,
  "delay_seconds": null,
  "buttons": true,
  "events": {"permission": true, "idle": true, "finish": true}
}
```

If you're upgrading from an older version of this plugin, the legacy `telegram-notifications.enabled` sentinel file is read automatically as a fallback (treated as enabled, delay mode off) until the next time you run `/notifications`, at which point it's migrated to the JSON file above and removed. A config file written before per-event toggles existed keeps notifying on everything: a missing `events` key means all three types are on.

When enabled, you'll get a Telegram message:
- when Claude Code finishes responding (`Stop` event) - useful for delayed/background runs
- when Claude Code is idle waiting for input, or needs permission (`Notification` event)

### Choosing which events notify

Each of the three event types can be turned off on its own, so you can keep the ones you care about and drop the noisy ones:

| Type | Fires when |
|---|---|
| `permission` | Claude needs you to approve a tool call |
| `idle` | Claude is waiting for input |
| `finish` | Claude finished responding (`Stop`) |

```
/notifications off finish       # stop pinging on every completed turn
/notifications on permission    # keep approval prompts
```

Turning a type on also turns the global switch on, since otherwise it would have no effect. The global switch wins over the per-type flags, which in turn win over a per-conversation mute.

### Muting a single conversation

```
/notifications mute      # silence this conversation only
/notifications unmute    # bring it back
```

Mute is scoped to the current session id, leaves your global settings untouched, and also drops any notification already waiting out the delay for that session. Mute state lives in `$CLAUDE_CONFIG_DIR/telegram-notifications-muted/`, one file per session, cleaned up automatically after 24 hours — a session running longer than that unmutes itself.

### Muting from Telegram

Each notification carries two inline buttons, so you don't have to go back to the machine:

```
Claude Code finished
Project: my-app
Session: a1b2c3d4

[ 🔕 Mute ]  [ 📊 Status ]
```

Tapping **Mute** silences that conversation and edits the button into **Unmute**, so the same message can undo it. Tapping **Status** shows your current settings in a popup — nothing is added to the chat.

```
/notifications buttons off   # send plain notifications with no buttons
/notifications buttons on
```

**How taps get picked up.** The plugin has no daemon: it polls Telegram opportunistically from the hooks it already runs. A poll happens right before any notification is sent (so a Mute you just tapped is honoured before the next ping goes out), inside the delay-mode timer, and from a detached child that chases each notification at +5s, +15s and +45s — which covers the usual case of tapping a button seconds after it arrives. Submitting a prompt never waits on the network.

The consequence is that a tap made while nothing is happening in that session sits unprocessed until the next event. The action still applies when it's picked up, but Telegram only accepts a popup response for a few seconds after the tap, so a late-processed **Mute** confirms itself by flipping the button rather than by a popup, and a late **Status** falls back to posting a message.

If you run more than one Claude install against the same bot (say `~/.claude` and a second `CLAUDE_CONFIG_DIR`), they coordinate: Telegram hands out each update exactly once, so one shared spool at `~/.claude-telegram-notifications/<bot>/` holds a poll lock and a cursor, and whichever install polls routes each tap to the install that sent that notification. Callbacks from any chat other than your `TG_CHAT_ID` are discarded.

### Delay mode (debounced notifications)

By default, notifications send immediately. Delay mode instead starts a timer on each qualifying event (finished, idle, permission request) and only sends once that timer runs out with no further qualifying event in the same session resetting it — so a burst of quick back-and-forth activity doesn't produce a notification per event.

```
/notifications delay 120   # enable delay mode: send only after 120s with no new event
/notifications delay off   # disable delay mode: back to sending immediately
```

Each session has at most one pending timer. Any new qualifying event in that session restarts the timer from zero and replaces the pending notification's content; the previous, now-stale timer is dropped silently when it fires — nothing is sent for it. Different sessions never interfere with each other's timers. Submitting a new prompt to Claude also cancels any pending timer for that session outright, since you're already back and engaged.

The timer runs in a detached background process so it survives the hook script exiting, which means it can outlive the `claude` process itself if you close the terminal or kill the session while a notification is still pending. To avoid sending a "finished"/"idle" ping for a session that's already gone, the timer records which `claude` process it belongs to when it starts and re-checks that the process is still running right before sending — if that process has been killed, the pending notification is dropped instead of sent.

Pending (not-yet-sent) notification state lives in `$CLAUDE_CONFIG_DIR/telegram-notifications-pending/`, one file per session. These are cleaned up automatically after a notification sends or after 24 hours, whichever comes first — safe to delete manually if needed.
