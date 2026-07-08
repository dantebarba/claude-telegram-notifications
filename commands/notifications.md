---
description: Toggle Telegram notifications on/off, or configure auto mode (debounced) with /notifications auto <seconds> | /notifications auto off
---

Run `${CLAUDE_PLUGIN_ROOT}/hooks/scripts/toggle.sh $ARGUMENTS` via Bash. Based on its stdout, report the result to the user in one short line:
- `enabled` -> "Telegram notifications enabled."
- `disabled` -> "Telegram notifications disabled."
- `auto-enabled:<seconds>` -> "Auto mode enabled: notifications will be sent after <seconds>s of inactivity."
- `auto-disabled` -> "Auto mode disabled: notifications will be sent immediately again."
- anything starting with `error:` -> relay that message as-is.
Do not do anything else.
