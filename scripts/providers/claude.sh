#!/usr/bin/env bash
# Provider: Claude Code
# Output: "model|status|context_tokens|session_name"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../detect_status.sh"

_claude_project_dir() {
  local pane_path="$1"
  local encoded
  encoded=$(echo "$pane_path" | sed 's|/|-|g')
  local dir="${HOME}/.claude/projects/${encoded}"
  [[ -d "$dir" ]] && echo "$dir"
}

_claude_latest_jsonl() {
  local project_dir="$1"
  ls -1t "${project_dir}"/*.jsonl 2>/dev/null | head -1
}

_claude_project_dir_for_pane() {
  local pane_id="$1"
  local shell_pid claude_pid sess_file cwd
  shell_pid=$(tmux display-message -p -t "$pane_id" '#{pane_pid}' 2>/dev/null)
  [[ -z "$shell_pid" ]] && return
  claude_pid=$(pgrep -P "$shell_pid" 2>/dev/null | head -1)
  [[ -z "$claude_pid" ]] && return
  sess_file="${HOME}/.claude/sessions/${claude_pid}.json"
  [[ -f "$sess_file" ]] || return
  cwd=$(grep -o '"cwd":"[^"]*"' "$sess_file" | head -1 | cut -d'"' -f4)
  [[ -z "$cwd" ]] && return
  local encoded dir
  encoded=$(echo "$cwd" | sed 's|/|-|g')
  dir="${HOME}/.claude/projects/${encoded}"
  [[ -d "$dir" ]] && echo "$dir"
}

_claude_session_name_from_pane() {
  local content="$1"
  local after_clear name
  # Find line number of last /clear
  after_clear=$(echo "$content" | grep -n '^❯ /clear' | tail -1 | cut -d: -f1)
  if [[ -n "$after_clear" ]]; then
    name=$(echo "$content" | tail -n +"$((after_clear + 1))" | grep -m1 '^❯ [^/]' | sed 's/^❯ //')
  else
    name=$(echo "$content" | grep -m1 '^❯ [^/]' | sed 's/^❯ //')
  fi
  [[ -n "$name" ]] && echo "${name:0:60}"
}

_claude_jsonl_by_name() {
  local project_dir="$1" session_name="$2"
  [[ -d "$project_dir" && -n "$session_name" ]] || return
  local match_str="${session_name:0:20}"
  local f first_msg
  for f in $(ls -1t "${project_dir}"/*.jsonl 2>/dev/null); do
    # Find first user message whose content doesn't start with <
    first_msg=$(grep '"type":"user"' "$f" 2>/dev/null \
      | grep -v '"content":"<' \
      | head -1 \
      | grep -oE '"content":"[^"]{0,100}' \
      | head -1 \
      | sed 's/"content":"//')
    if [[ -n "$first_msg" ]] && echo "$first_msg" | grep -qF "$match_str" 2>/dev/null; then
      echo "$f"
      return
    fi
  done
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
  # claude-sonnet-4-6 → 4.6
  local ver
  ver=$(echo "$raw" | sed -E 's/^claude-(opus|sonnet|haiku)-//; s/-[0-9]{8}.*//; s/-/./g')
  echo "${family} ${ver}"
}

_claude_context_from_jsonl() {
  local jsonl="$1"
  [[ -f "$jsonl" ]] || return
  # Context = input_tokens + cache_read + cache_creation (last usage entry)
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

  content=$(tmux capture-pane -p -t "$pane_id" -S -500 2>/dev/null)
  model=$(_claude_model_from_pane "$content")
  session_name=$(_claude_session_name_from_pane "$content")

  # JSONL: match by session name, fall back to latest
  local project_dir jsonl
  project_dir=$(_claude_project_dir_for_pane "$pane_id")
  if [[ -z "$project_dir" ]]; then
    local pane_path
    pane_path=$(tmux display-message -p -t "$pane_id" '#{pane_current_path}' 2>/dev/null)
    project_dir=$(_claude_project_dir "$pane_path")
  fi
  if [[ -n "$project_dir" ]]; then
    if [[ -n "$session_name" ]]; then
      jsonl=$(_claude_jsonl_by_name "$project_dir" "$session_name")
    fi
    # Fallback to latest only if this is the sole claude pane in this project
    if [[ -z "$jsonl" ]]; then
      local n_panes
      n_panes=$(tmux list-panes -a -F '#{pane_current_command}|#{pane_current_path}' 2>/dev/null \
        | grep "^claude|" | grep -c "$(tmux display-message -p -t "$pane_id" '#{pane_current_path}' 2>/dev/null)")
      [[ "$n_panes" -le 1 ]] 2>/dev/null && jsonl=$(_claude_latest_jsonl "$project_dir")
    fi
    [[ -z "$model" && -f "$jsonl" ]] && model=$(_claude_model_from_jsonl "$jsonl")
    [[ -f "$jsonl" ]] && context=$(_claude_context_from_jsonl "$jsonl")
  fi

  # Fallback: parse context from pane status bar ("to save XXK tokens")
  if [[ -z "$context" ]]; then
    local pane_ctx
    pane_ctx=$(echo "$content" | grep -oE 'to save [0-9]+[KkMm]+ tokens' | tail -1 \
      | grep -oE '[0-9]+[KkMm]+')
    if [[ -n "$pane_ctx" ]]; then
      local num unit
      num=$(echo "$pane_ctx" | grep -oE '[0-9]+')
      unit=$(echo "$pane_ctx" | grep -oE '[KkMm]+')
      case "$unit" in
        [Kk]) context=$(( num * 1000 )) ;;
        [Mm]) context=$(( num * 1000000 )) ;;
        *)    context="$num" ;;
      esac
    fi
  fi

  status=$(detect_status "$pane_id" "claude")

  echo "${model}|${status}|${context}|${session_name}"
}
