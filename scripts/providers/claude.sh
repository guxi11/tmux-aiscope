#!/usr/bin/env bash
# Provider: Claude Code
# Output: "model|status|context_tokens|session_name"
# Status: primarily from JSONL mtime + last-entry type; terminal fallback for edge cases.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../detect_status.sh"

_claude_project_dir() {
  local pane_path="$1"
  local encoded
  encoded=$(echo "$pane_path" | sed 's|/|-|g')
  local dir="${HOME}/.claude/projects/${encoded}"
  [[ -d "$dir" ]] && echo "$dir"
}

_claude_model_from_pane() {
  echo "$1" | grep -oE '(Opus|Sonnet|Haiku) [0-9]+\.[0-9]+' | head -1
}

_claude_model_from_jsonl() {
  local jsonl="$1"
  local raw
  raw=$(grep -o '"model":"[^"]*"' "$jsonl" 2>/dev/null | tail -1 | cut -d'"' -f4)
  [[ -z "$raw" ]] && return
  local family
  case "$raw" in
    *opus*)   family="Opus" ;;
    *sonnet*) family="Sonnet" ;;
    *haiku*)  family="Haiku" ;;
    *)        echo "$raw"; return ;;
  esac
  local ver
  ver=$(echo "$raw" | sed -E 's/^claude-(opus|sonnet|haiku)-//; s/-[0-9]{8}.*//; s/-/./g')
  echo "${family} ${ver}"
}

_claude_context_from_jsonl() {
  local jsonl="$1"
  [[ -f "$jsonl" ]] || return
  local line
  line=$(tail -50 "$jsonl" 2>/dev/null | grep 'input_tokens' | tail -1)
  [[ -z "$line" ]] && return
  local input cache_read cache_create
  input=$(echo "$line" | grep -oE '"input_tokens":[0-9]+' | head -1 | grep -o '[0-9]*')
  cache_read=$(echo "$line" | grep -oE '"cache_read_input_tokens":[0-9]+' | head -1 | grep -o '[0-9]*')
  cache_create=$(echo "$line" | grep -oE '"cache_creation_input_tokens":[0-9]+' | head -1 | grep -o '[0-9]*')
  echo $(( ${input:-0} + ${cache_read:-0} + ${cache_create:-0} ))
}

# Map tmux pane → claude PID → ~/.claude/sessions/{pid}.json → cwd
# NOTE: sessionId from this file can be stale after /clear or /resume.
#       Use this only for cwd; get sessionId from history index.
_claude_cwd_from_pane() {
  local pane_id="$1"
  local pane_pid
  pane_pid=$(tmux display-message -p -t "$pane_id" '#{pane_pid}' 2>/dev/null)
  [[ -z "$pane_pid" ]] && return

  local claude_pid
  claude_pid=$(ps -ax -o pid,ppid 2>/dev/null | awk -v ppid="$pane_pid" '$2==ppid {print $1; exit}')
  [[ -z "$claude_pid" ]] && return

  local sess_file="${HOME}/.claude/sessions/${claude_pid}.json"
  [[ -f "$sess_file" ]] || return
  grep -o '"cwd":"[^"]*"' "$sess_file" | head -1 | cut -d'"' -f4
}

# Detect status from JSONL file: mtime + last entry type
# Returns: running | blocked | idle | "" (unknown/no file)
_claude_status_from_jsonl() {
  local jsonl="$1"
  [[ -f "$jsonl" ]] || return

  local now mtime age
  now=$(date +%s)
  mtime=$(stat -f '%m' "$jsonl" 2>/dev/null)
  [[ -z "$mtime" ]] && return
  age=$(( now - mtime ))

  # Recently modified → actively streaming or executing tools
  if [ "$age" -lt 5 ]; then
    echo "running"
    return
  fi

  # Check last entry type to distinguish idle vs blocked
  local last_line
  last_line=$(tail -1 "$jsonl" 2>/dev/null)
  [[ -z "$last_line" ]] && return

  local entry_type entry_subtype
  entry_type=$(echo "$last_line" | grep -o '"type":"[^"]*"' | head -1 | cut -d'"' -f4)
  entry_subtype=$(echo "$last_line" | grep -o '"subtype":"[^"]*"' | head -1 | cut -d'"' -f4)

  # Definitive idle: turn completed normally
  # system/turn_duration and file-history-snapshot both appear at turn end
  case "$entry_type" in
    system)
      [[ "$entry_subtype" == "turn_duration" ]] && { echo "idle"; return; } ;;
    file-history-snapshot|message)
      echo "idle"; return ;;
  esac

  # assistant with tool_use as last entry = waiting for permission
  if [[ "$entry_type" == "assistant" ]] && echo "$last_line" | grep -q '"type":"tool_use"'; then
    # Sanity: if stale (>5min), probably a crash, not truly blocked
    [ "$age" -gt 300 ] && { echo "idle"; return; }
    echo "blocked"
    return
  fi

  # user/ or attachment/ as last entry = turn in progress (claude generating)
  # Guard with timeout: if >5min with no JSONL write, likely crashed
  if [ "$age" -gt 300 ]; then
    echo "idle"
  else
    echo "running"
  fi
}

provider_get_info() {
  local pane_id="$1"
  local content model context status session_name

  local pane_path
  pane_path=$(tmux display-message -p -t "$pane_id" '#{pane_current_path}' 2>/dev/null)

  # ── Resolve project dir (PID session file for cwd, or pane path) ──
  local project_dir sess_cwd
  sess_cwd=$(_claude_cwd_from_pane "$pane_id")
  project_dir=$(_claude_project_dir "${sess_cwd:-$pane_path}")

  # ── Find sessionId via history index (reliable after /clear) ──
  local sid="" jsonl=""
  content=$(tmux capture-pane -p -t "$pane_id" -S - 2>/dev/null)
  local prompts
  prompts=$(echo "$content" | grep '^❯ [^/]' | sed 's/^❯ //' | grep -v '^\s*$')

  if [[ -z "$prompts" && -z "$project_dir" ]]; then
    status=$(detect_status "$pane_id" "claude" "$content")
    model=$(_claude_model_from_pane "$content")
    echo "${model}|${status}||"
    return
  fi

  if [[ -n "$prompts" && -f "$_HISTORY_INDEX" ]]; then
    local n_prompts
    n_prompts=$(echo "$prompts" | grep -c .)
    local window=1
    while [[ $window -le $n_prompts && $window -le 10 ]]; do
      local votes
      votes=$(echo "$prompts" | tail -"$window" | while IFS= read -r p; do
        local mt="${p:0:40}"
        mt="${mt#"${mt%%[![:space:]]*}"}"
        [[ -n "$mt" ]] && awk -F'\t' -v proj="${sess_cwd:-$pane_path}" -v text="$mt" \
          '$1=="H" && $3==proj && index($4, text)>0 {print $2}' \
          "$_HISTORY_INDEX" | sort -u
      done | sort | uniq -c | sort -rn)
      local top_count top_sid second_count
      top_count=$(echo "$votes" | head -1 | awk '{print $1}')
      top_sid=$(echo "$votes" | head -1 | awk '{print $2}')
      second_count=$(echo "$votes" | sed -n '2p' | awk '{print $1+0}')
      if [[ -n "$top_sid" && "$top_count" -gt "$second_count" ]]; then
        sid="$top_sid"
        break
      fi
      window=$((window + 1))
    done
  fi

  # JSONL from history match
  if [[ -n "$sid" && -n "$project_dir" ]]; then
    jsonl="${project_dir}/${sid}.jsonl"
  fi

  # No latest-JSONL fallback: multiple panes can share a project dir,
  # so picking the most recent JSONL would conflate different sessions.

  # ── Session name ──
  if [[ -n "$sid" && -f "$_HISTORY_INDEX" ]]; then
    session_name=$(awk -F'\t' -v sid="$sid" '$1=="N" && $2==sid {print $3}' "$_HISTORY_INDEX" | tail -1)
  fi
  [[ -z "$session_name" ]] && session_name="$(echo "$prompts" | tail -1 | head -c 300)"

  # ── Model + context from JSONL ──
  if [[ -f "$jsonl" ]]; then
    model=$(_claude_model_from_jsonl "$jsonl")
    context=$(_claude_context_from_jsonl "$jsonl")
  fi
  [[ -z "$model" ]] && model=$(_claude_model_from_pane "$content")

  # ── Status: JSONL-based (primary) → terminal fallback ──
  status=$(_claude_status_from_jsonl "$jsonl")
  [[ -z "$status" ]] && status=$(detect_status "$pane_id" "claude" "$content")

  echo "${model}|${status}|${context}|${session_name}"
}
