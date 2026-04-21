#!/usr/bin/env bash
# Provider: Aider
# Output: "model|status|context_tokens|session_name"
#
# Status detection: terminal-based (Aider does not write structured logs).
# TODO: Aider writes chat history to .aider.chat.history.md — mtime-based
#       detection could be added similar to the Claude JSONL approach.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../detect_status.sh"

_aider_parse_model() {
  local pane_id="$1"
  tmux capture-pane -p -t "$pane_id" -S -200 2>/dev/null \
    | grep -oE 'Model: [a-zA-Z0-9._/-]+' \
    | head -1 | sed 's/Model: //'
}

_aider_detect_status() {
  local pane_id="$1" content="$2"
  [[ -z "$content" ]] && content=$(tmux capture-pane -p -t "$pane_id" 2>/dev/null)

  # blocked: y/n confirmation prompt
  local blocked
  blocked=$(detect_status_blocked "$content" '\(y/n\)')
  [[ -n "$blocked" ]] && { echo "blocked"; return; }

  # idle: aider prompt (e.g., "aider> " or "> ")
  detect_status_by_prompt "$content" 'aider[> ]*$'
}

provider_get_info() {
  local pane_id="$1"
  local model status

  model=$(_aider_parse_model "$pane_id")
  status=$(_aider_detect_status "$pane_id")

  echo "${model}|${status}||"
}
