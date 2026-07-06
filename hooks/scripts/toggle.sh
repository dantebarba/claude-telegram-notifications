#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
STATE_FILE="$STATE_DIR/telegram-notifications.enabled"

mkdir -p "$STATE_DIR"

if [ -f "$STATE_FILE" ]; then
  rm -f "$STATE_FILE"
  echo "disabled"
else
  touch "$STATE_FILE"
  echo "enabled"
fi
