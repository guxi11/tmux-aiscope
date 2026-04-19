#!/usr/bin/env bash
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

get_opt() {
  local opt="$1" default="$2"
  local val
  val=$(tmux show-option -gqv "@aiscope-${opt}" 2>/dev/null)
  echo "${val:-$default}"
}

KEY=$(get_opt "key" "a")
POPUP_SIZE=$(get_opt "popup-size" "80%")

tmux bind-key "$KEY" display-popup -E \
  -w "$POPUP_SIZE" -h "$POPUP_SIZE" \
  "bash '${PLUGIN_DIR}/scripts/popup.sh'"
