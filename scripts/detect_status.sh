#!/usr/bin/env bash
# detect_status pane_id process_name → "running" | "idle" | "blocked"

detect_status() {
  local pane_id="$1" process="$2"
  local content
  content=$(tmux capture-pane -p -t "$pane_id" 2>/dev/null)

  case "$process" in
    claude)
      local tail_lines
      tail_lines=$(echo "$content" | grep -v '^\s*$' | tail -20)

      local last_few
      last_few=$(echo "$tail_lines" | tail -5)

      # blocked: permission prompt waiting for user input
      # the prompt UI is tall, so check the full tail_lines (20 lines)
      # patterns: "requires approval", "Do you want to proceed?",
      #           Yes/No selector, "Allow once", "Esc to cancel"
      if echo "$tail_lines" | grep -qE 'requires approval|Do you want to proceed|Esc to cancel.*Tab to amend|Allow once|Allow always'; then
        echo "blocked"
        return
      fi

      # running: spinner (char + verb + …), tool executing, or Claude streaming text
      # ⏺ in last 3 lines = Claude actively outputting (text or tool call)
      # [spinner] verb… = thinking/working spinner
      # Running… = tool mid-execution
      local last_3
      last_3=$(echo "$tail_lines" | tail -3)
      if echo "$last_3" | grep -qE '⏺ |⎿\s+Running…|esc to int'; then
        echo "running"
        return
      fi
      if echo "$last_few" | grep -qE '[✳✴✵✶✷✸✹✺✻✼✽] .+…'; then
        echo "running"
        return
      fi

      echo "idle"
      ;;
    aider)
      local last
      last=$(echo "$content" | grep -v '^\s*$' | tail -1)

      echo "$last" | grep -qE 'aider[> ]*$' && echo "idle" && return

      echo "$content" | grep -v '^\s*$' | tail -5 \
        | grep -qE '\(y/n\)' \
        && echo "blocked" && return

      echo "running"
      ;;
    *)
      local last
      last=$(echo "$content" | grep -v '^\s*$' | tail -1)
      echo "$last" | grep -qE '[$#%>❯]\s*$' && echo "idle" || echo "running"
      ;;
  esac
}
