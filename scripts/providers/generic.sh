#!/usr/bin/env bash
# Provider: Generic fallback
# Output: "model|status|tokens"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../detect_status.sh"

provider_get_info() {
  local pane_id="$1"
  local cmd
  cmd=$(tmux display-message -p -t "$pane_id" '#{pane_current_command}' 2>/dev/null)
  local status
  status=$(detect_status "$pane_id" "$cmd")
  echo "|${status}|"
}
