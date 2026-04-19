#!/usr/bin/env bash
# Provider: Aider
# Output: "model|status|tokens"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../detect_status.sh"

_aider_parse_model_from_pane() {
  local pane_id="$1"
  # Aider prints "Model: gpt-4o with ..." or "Model: claude-..." at startup
  tmux capture-pane -p -t "$pane_id" -S -200 2>/dev/null \
    | grep -oE 'Model: [a-zA-Z0-9._/-]+' \
    | head -1 | sed 's/Model: //'
}

provider_get_info() {
  local pane_id="$1"
  local model status

  model=$(_aider_parse_model_from_pane "$pane_id")
  status=$(detect_status "$pane_id" "aider")

  echo "${model}|${status}|"
}
