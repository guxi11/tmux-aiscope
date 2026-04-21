#!/usr/bin/env bash
# Terminal-based status detection utilities.
# Shared by providers as a fallback when structured logs are unavailable.
#
# Each provider owns its own detection logic and calls these helpers directly.
# This file does NOT dispatch by process name — providers are responsible for
# choosing which helper to call.

# Detect status by checking if pane content contains a prompt-like pattern.
# Usage: detect_status_by_prompt "$content" 'pattern1|pattern2'
# Returns: "idle" if last non-empty line matches pattern, "running" otherwise
detect_status_by_prompt() {
  local content="$1" prompt_pattern="$2"
  local last
  last=$(echo "$content" | grep -v '^\s*$' | tail -1)
  echo "$last" | grep -qE "$prompt_pattern" && echo "idle" || echo "running"
}

# Detect status by checking pane content for blocking patterns (y/n prompts, etc).
# Usage: detect_status_blocked "$content" 'pattern1|pattern2'
# Returns: "blocked" if any of the last 5 non-empty lines match, "" otherwise
detect_status_blocked() {
  local content="$1" block_pattern="$2"
  echo "$content" | grep -v '^\s*$' | tail -5 \
    | grep -qE "$block_pattern" && echo "blocked"
}

# Full terminal-based detection for Claude Code panes.
# Checks blocked → running → idle, using pane content heuristics.
# This is the FALLBACK for when JSONL-based detection is unavailable.
detect_status_claude_terminal() {
  local pane_id="$1" content="$2"
  [[ -z "$content" ]] && content=$(tmux capture-pane -p -t "$pane_id" 2>/dev/null)

  local tail_lines
  tail_lines=$(echo "$content" | grep -v '^\s*$' | tail -20)

  # blocked: permission prompt
  if echo "$tail_lines" | grep -qE 'requires approval|Do you want to proceed|Esc to cancel.*Tab to amend|Allow once|Allow always'; then
    echo "blocked"; return
  fi

  # running: spinner / active output
  local last_3
  last_3=$(echo "$tail_lines" | tail -3)
  if echo "$last_3" | grep -qE '⏺ |⎿\s+Running…|esc to int'; then
    echo "running"; return
  fi
  if echo "$tail_lines" | tail -5 | grep -qE '[✳✴✵✶✷✸✹✺✻✼✽] .+…'; then
    echo "running"; return
  fi

  echo "idle"
}
