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

Turning a type on also turns the global switch on, since otherwise it would have no effect. The global switch wins over the per-type flags, which in turn win over a mute — whether that is the master mute or a per-conversation one.

### Muting a single conversation

```
/notifications mute      # silence this conversation only
/notifications unmute    # bring it back
```

Mute is scoped to the current session id, leaves your global settings untouched, and also drops any notification already waiting out the delay for that session. Mute state lives in `$CLAUDE_CONFIG_DIR/telegram-notifications-muted/`, one file per session, cleaned up automatically after 24 hours — a session running longer than that unmutes itself.

The master mute is separate: `/mute` in Telegram (or **Mute all** on the panel) writes `$CLAUDE_CONFIG_DIR/telegram-notifications-muted-all.json` and silences every conversation of that install until you unmute. It is never swept by the 24-hour cleanup, and `/unmute` clears it together with the per-session mutes.

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

**How taps get picked up.** Without the daemon (below), the plugin polls Telegram opportunistically from the hooks it already runs: right before any notification is sent, inside the delay-mode timer, and from a detached child chasing each notification at +5s, +15s and +45s. Submitting a prompt never waits on the network.

That works, but a tap made while nothing is happening in that session sits unprocessed until the next event. The action still applies when it's picked up, but Telegram only accepts a popup response for a few seconds after a tap, so a late-processed **Mute** confirms itself by flipping the button rather than by a popup, and a late **Status** falls back to posting a message. Installing the daemon removes this entirely.

If you run more than one Claude install against the same bot (say `~/.claude` and a second `CLAUDE_CONFIG_DIR`), they coordinate: Telegram hands out each update exactly once, so one shared spool at `~/.claude-telegram-notifications/<bot>/` holds a poll lock and a cursor, and whichever install polls routes each tap to the install that sent that notification. Callbacks from any chat other than your `TG_CHAT_ID` are discarded.

## Controlling everything from Telegram

Install the background daemon and the bot gains a command palette, answering taps and commands in under a second:

```
/notifications daemon install     # also registers /status, /mute, /unmute with the bot
/notifications daemon status
/notifications daemon log
/notifications daemon restart
/notifications daemon uninstall   # also clears the palette
```

It runs under launchd (`com.claude-telegram-notifications.daemon`), restarts if it crashes, and logs to `~/.claude-telegram-notifications/<bot>/daemon.log`. Credentials come from the `env` block of the `settings.json` in the config dir you installed from — the same file the hooks use, so the token is never copied anywhere else.

### The /status panel

`/status` in Telegram replies with a live control panel per install:

```
Claude notifications — .claude-personal
global: on    delay: 15s
last session: a1b2c3d4 (my-app)

[ ✅ finish ] [ ✅ idle ] [ ✅ permission ]
[ 🔕 Mute all ]
[ ⏸ Disable all ]
```

Every button edits the message in place, so the panel always shows current truth. Tapping an event type turns that notification kind on or off exactly like `/notifications off finish` would on the machine. **Mute all** is the master mute for that install; **Unmute all** lifts it along with any individual conversation mutes.

### Typed commands

```
/mute      master mute: silence every conversation, on every install
/unmute    bring them all back
/status    the panel above
```

`/mute` is deliberately a master switch — the conversation you happened to be pinged by last is rarely the only one you want quiet. It stays on until you `/unmute` (it never expires by itself), and to silence just one conversation you tap **🔕 Mute** on its own notification.

### Notes

The daemon holds the shared poll lock while long-polling, so the hooks' own polling stands down on its own. If the daemon dies, they resume on the next event — degraded, but nothing breaks. A plugin upgrade is noticed by the next hook, which reinstalls and restarts the daemon so it never keeps running old code.

Only one daemon runs per bot no matter how many installs you have, and it serves all of them: each install records where its config lives in the shared spool.

### Delay mode (debounced notifications)

By default, notifications send immediately. Delay mode instead starts a timer on each qualifying event (finished, idle, permission request) and only sends once that timer runs out with no further qualifying event in the same session resetting it — so a burst of quick back-and-forth activity doesn't produce a notification per event.

```
/notifications delay 120   # enable delay mode: send only after 120s with no new event
/notifications delay off   # disable delay mode: back to sending immediately
```

Each session has at most one pending timer. Any new qualifying event in that session restarts the timer from zero and replaces the pending notification's content; the previous, now-stale timer is dropped silently when it fires — nothing is sent for it. Different sessions never interfere with each other's timers. Submitting a new prompt to Claude also cancels any pending timer for that session outright, since you're already back and engaged.

The timer runs in a detached background process so it survives the hook script exiting, which means it can outlive the `claude` process itself if you close the terminal or kill the session while a notification is still pending. To avoid sending a "finished"/"idle" ping for a session that's already gone, the timer records which `claude` process it belongs to when it starts and re-checks that the process is still running right before sending — if that process has been killed, the pending notification is dropped instead of sent.

Pending (not-yet-sent) notification state lives in `$CLAUDE_CONFIG_DIR/telegram-notifications-pending/`, one file per session. These are cleaned up automatically after a notification sends or after 24 hours, whichever comes first — safe to delete manually if needed.
