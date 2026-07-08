---
description: Toggle Telegram notifications on/off, or configure a notification delay with /notifications delay <seconds> | /notifications delay off
---

Run `${CLAUDE_PLUGIN_ROOT}/hooks/scripts/toggle.sh $ARGUMENTS` via Bash. Based on its stdout, report the result to the user in one short line:
- `enabled` -> "Telegram notifications enabled."
- `disabled` -> "Telegram notifications disabled."
- `delay-enabled:<seconds>` -> "Delay mode enabled: notifications will be sent after <seconds>s with no new event resetting the timer."
- `delay-disabled` -> "Delay mode disabled: notifications will be sent immediately again."
- anything starting with `error:` -> relay that message as-is.
Do not do anything else.
