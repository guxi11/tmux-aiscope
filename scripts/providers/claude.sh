#!/usr/bin/env bash
# Provider: Claude Code
# Output: "model|status|context_tokens|session_name"
# Uses ~/.claude/history.jsonl (pre-indexed) to map pane → sessionId → JSONL.

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

provider_get_info() {
  local pane_id="$1"
  local content model context status session_name

  content=$(tmux capture-pane -p -t "$pane_id" -S - 2>/dev/null)

  local pane_path
  pane_path=$(tmux display-message -p -t "$pane_id" '#{pane_current_path}' 2>/dev/null)

  # Extract ❯ prompt lines only (no continuation joining — used for matching)
  local prompts
  prompts=$(echo "$content" | grep '^❯ [^/]' | sed 's/^❯ //' | grep -v '^\s*$')

  if [[ -z "$prompts" ]]; then
    status=$(detect_status "$pane_id" "claude" "$content")
    model=$(_claude_model_from_pane "$content")
    echo "${model}|${status}||"
    return
  fi

  # Match prompts against history index to find sessionId → JSONL
  local sid="" jsonl=""

  if [[ -f "$_HISTORY_INDEX" ]]; then
    local n_prompts
    n_prompts=$(echo "$prompts" | grep -c .)
    local window=1
    while [[ $window -le $n_prompts && $window -le 10 ]]; do
      local votes
      votes=$(echo "$prompts" | tail -"$window" | while IFS= read -r p; do
        local mt="${p:0:40}"
        mt="${mt#"${mt%%[![:space:]]*}"}"
        [[ -n "$mt" ]] && awk -F'\t' -v proj="$pane_path" -v text="$mt" \
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

  # Session name: from history (full display, 300 chars) or pane prompt fallback
  if [[ -n "$sid" && -f "$_HISTORY_INDEX" ]]; then
    session_name=$(awk -F'\t' -v sid="$sid" '$1=="N" && $2==sid {print $3}' "$_HISTORY_INDEX" | tail -1)
  fi
  [[ -z "$session_name" ]] && session_name="$(echo "$prompts" | tail -1 | head -c 300)"

  if [[ -n "$sid" ]]; then
    local project_dir
    project_dir=$(_claude_project_dir "$pane_path")
    [[ -n "$project_dir" ]] && jsonl="${project_dir}/${sid}.jsonl"
  fi

  # Model + context from JSONL
  if [[ -f "$jsonl" ]]; then
    model=$(_claude_model_from_jsonl "$jsonl")
    context=$(_claude_context_from_jsonl "$jsonl")
  fi
  [[ -z "$model" ]] && model=$(_claude_model_from_pane "$content")

  # Status from pane content (most accurate for real-time blocked/running detection)
  status=$(detect_status "$pane_id" "claude" "$content")

  echo "${model}|${status}|${context}|${session_name}"
}
