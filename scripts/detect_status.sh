#!/usr/bin/env bash
# detect_status pane_id process_name → "running" | "idle"

detect_status() {
  local pane_id="$1" process="$2"
  case "$process" in
    claude)
      # Claude Code shows "esc to interrupt" in status bar when running
      tmux capture-pane -p -t "$pane_id" 2>/dev/null \
        | grep -v '^\s*$' | tail -3 | grep -q 'esc to int' \
        && echo "running" || echo "idle"
      ;;
    aider)
      local last
      last=$(tmux capture-pane -p -t "$pane_id" 2>/dev/null | grep -v '^\s*$' | tail -1)
      echo "$last" | grep -qE 'aider[> ]*$' && echo "idle" || echo "running"
      ;;
    *)
      local last
      last=$(tmux capture-pane -p -t "$pane_id" 2>/dev/null | grep -v '^\s*$' | tail -1)
      echo "$last" | grep -qE '[$#%>❯]\s*$' && echo "idle" || echo "running"
      ;;
  esac
}
