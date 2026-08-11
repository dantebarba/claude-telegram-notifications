---
description: Toggle Telegram notifications, enable/disable them per event type (permission|idle|finish), set a delay, or mute the current conversation
---

Run `${CLAUDE_PLUGIN_ROOT}/hooks/scripts/toggle.sh $ARGUMENTS` via Bash. Based on its stdout, report the result to the user in one short line:
- `enabled` -> "Telegram notifications enabled."
- `disabled` -> "Telegram notifications disabled."
- `event-enabled:<type>` -> "Notifications for <type> events enabled."
- `event-disabled:<type>` -> "Notifications for <type> events disabled."
- `delay-enabled:<seconds>` -> "Delay mode enabled: notifications will be sent after <seconds>s with no new event resetting the timer."
- `delay-disabled` -> "Delay mode disabled: notifications will be sent immediately again."
- `muted` -> "Notifications muted for this conversation."
- `unmuted` -> "Notifications unmuted for this conversation."
- `status` -> relay the remaining lines as-is, without rewording them.
- anything starting with `error:` -> relay that message as-is.
Do not do anything else.
