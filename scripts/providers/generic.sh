#!/usr/bin/env bash
# Provider: Generic fallback
# Output: "model|status|context_tokens|session_name"
#
# Uses shell prompt detection — works for any interactive CLI.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../detect_status.sh"

provider_get_info() {
  local pane_id="$1"
  local content
  content=$(tmux capture-pane -p -t "$pane_id" 2>/dev/null)
  local status
  status=$(detect_status_by_prompt "$content" '[$#%>❯]\s*$')
  echo "|${status}||"
}
