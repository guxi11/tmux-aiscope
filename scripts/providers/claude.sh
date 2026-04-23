#!/usr/bin/env bash
# Provider: Claude Code (and claude-family wrappers)
# Output: "model|status|context_tokens|session_name"
#
# Variants are auto-discovered from $HOME/.*claude*/ by list_ai_panes.sh and
# passed via AISCOPE_CLAUDE_VARIANTS ("bin<TAB>data_dir" per line).
#
# Strategy: the unified history index across all variants is the single source
# of truth. Match visible pane prompts against it to get (variant_dir, sid) —
# the JSONL path follows mechanically. No pid/session-file probing needed.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../detect_status.sh"

# ── Init hook: build unified history index across all variants ──
# Format (tab-separated):
#   H<TAB>dir<TAB>sessionId<TAB>project<TAB>display_prefix_80
#   N<TAB>dir<TAB>sessionId<TAB>session_name_300
provider_init() {
  local tmpdir="$1"
  local out="$tmpdir/claude_history_index"
  : > "$out"

  local line dir hfile
  while IFS=$'\t' read -r _ dir; do
    [[ -z "$dir" ]] && continue
    hfile="${dir}/history.jsonl"
    [[ -f "$hfile" ]] || continue
    tail -5000 "$hfile" | DIR="$dir" python3 -c "
import json,os,sys
dir=os.environ['DIR']
seen={}
for line in sys.stdin:
    line=line.strip()
    if not line: continue
    try: d=json.loads(line)
    except: continue
    disp=d.get('display','')
    proj=d.get('project','')
    sid=d.get('sessionId','')
    if not disp or not sid: continue
    print('H\t'+dir+'\t'+sid+'\t'+proj+'\t'+disp[:80])
    if not disp.startswith('/') and ' ' in disp.strip() and sid not in seen:
        seen[sid]=disp[:300]
for sid,disp in seen.items():
    print('N\t'+dir+'\t'+sid+'\t'+disp)
" >> "$out" 2>/dev/null
  done <<< "$AISCOPE_CLAUDE_VARIANTS"

  export _CLAUDE_HISTORY_INDEX="$out"
}

# ── Internal helpers ──

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

# Match visible prompts against the unified history index.
# Scoped to project_path (absolute, as stored by claude's history).
# Returns "data_dir<TAB>project<TAB>sessionId" on match; empty otherwise.
# project is taken verbatim from history (authoritative — don't re-encode pane cwd).
_claude_resolve_session() {
  local prompts="$1" project_path="$2"
  [[ -z "$prompts" || ! -f "$_CLAUDE_HISTORY_INDEX" ]] && return

  local n_prompts
  n_prompts=$(echo "$prompts" | grep -c .)
  local window=1
  while [[ $window -le $n_prompts && $window -le 10 ]]; do
    local votes
    votes=$(echo "$prompts" | tail -"$window" | while IFS= read -r p; do
      local mt="${p:0:40}"
      mt="${mt#"${mt%%[![:space:]]*}"}"
      [[ -n "$mt" ]] && awk -F'\t' -v proj="$project_path" -v text="$mt" \
        '$1=="H" && $4==proj && index($5, text)>0 {print $2"\t"$4"\t"$3}' \
        "$_CLAUDE_HISTORY_INDEX" | sort -u
    done | sort | uniq -c | sort -rn)

    local top_line top_count top_payload second_count
    top_line=$(echo "$votes" | head -1)
    top_count=$(echo "$top_line" | awk '{print $1}')
    top_payload=$(echo "$top_line" | sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+//')
    second_count=$(echo "$votes" | sed -n '2p' | awk '{print $1+0}')
    if [[ -n "$top_payload" && "$top_count" -gt "$second_count" ]]; then
      echo "$top_payload"
      return
    fi
    window=$((window + 1))
  done
}

# Detect status from JSONL file: mtime + last entry type.
_claude_status_from_jsonl() {
  local jsonl="$1"
  [[ -f "$jsonl" ]] || return

  local now mtime age
  now=$(date +%s)
  mtime=$(stat -f '%m' "$jsonl" 2>/dev/null)
  [[ -z "$mtime" ]] && return
  age=$(( now - mtime ))

  if [ "$age" -lt 5 ]; then
    echo "running"
    return
  fi

  local last_line
  last_line=$(tail -1 "$jsonl" 2>/dev/null)
  [[ -z "$last_line" ]] && return

  local entry_type entry_subtype
  entry_type=$(echo "$last_line" | grep -o '"type":"[^"]*"' | head -1 | cut -d'"' -f4)
  entry_subtype=$(echo "$last_line" | grep -o '"subtype":"[^"]*"' | head -1 | cut -d'"' -f4)

  case "$entry_type" in
    system)
      [[ "$entry_subtype" == "turn_duration" ]] && { echo "idle"; return; } ;;
    file-history-snapshot|message)
      echo "idle"; return ;;
  esac

  if [[ "$entry_type" == "assistant" ]] && echo "$last_line" | grep -q '"type":"tool_use"'; then
    [ "$age" -gt 300 ] && { echo "idle"; return; }
    echo "blocked"
    return
  fi

  if [ "$age" -gt 300 ]; then
    echo "idle"
  else
    echo "running"
  fi
}

# ── Provider entry point ──

provider_get_info() {
  local pane_id="$1"
  local content model context status session_name

  local pane_path
  pane_path=$(tmux display-message -p -t "$pane_id" '#{pane_current_path}' 2>/dev/null)

  content=$(tmux capture-pane -p -t "$pane_id" -S - 2>/dev/null)

  # Extract full prompts, joining wrapped continuation lines back onto ❯ lines.
  # On `/clear`, drop everything seen so far — the visible conversation after
  # clear has nothing to do with prior sessions, and old prompts still sit
  # in scrollback.
  local prompts
  prompts=$(echo "$content" | awk '
    function flush() { if (buf != "") { prompts[n++]=buf; buf="" } }
    /^❯ \/clear/         { flush(); n=0; delete prompts; next }
    /^❯ [^\/]/           { flush(); sub(/^❯ /, "", $0); buf=$0; next }
    /^❯ /                { flush(); next }
    /^[╭╰│►▸✓✗●○┌└├─╌⎿⏺✻⚠]/ || /^  / || /^[[:space:]]*$/ || /^[A-Z][a-z]+ [0-9]/ {
      flush(); next
    }
    buf { gsub(/^[[:space:]]+/,"",$0); buf=buf " " $0 }
    END { flush(); for (i=0; i<n; i++) print prompts[i] }
  ' | grep -v '^\s*$')

  # Resolve (variant_dir, project, sessionId) purely via history-index match.
  local variant_dir="" project="" sid=""
  if [[ -n "$prompts" ]]; then
    local r
    r=$(_claude_resolve_session "$prompts" "$pane_path")
    if [[ -n "$r" ]]; then
      variant_dir="${r%%$'\t'*}"; r="${r#*$'\t'}"
      project="${r%%$'\t'*}"
      sid="${r#*$'\t'}"
    fi
  fi

  # No history match → terminal-only fallback
  if [[ -z "$variant_dir" || -z "$sid" ]]; then
    status=$(detect_status_claude_terminal "$pane_id" "$content")
    model=$(_claude_model_from_pane "$content")
    echo "${model}|${status}||"
    return
  fi

  # JSONL path: encode the history-provided project (authoritative, not pane cwd).
  local encoded jsonl
  encoded=$(echo "$project" | sed 's|/|-|g')
  jsonl="${variant_dir}/projects/${encoded}/${sid}.jsonl"

  # Session name from history index
  session_name=$(awk -F'\t' -v dir="$variant_dir" -v sid="$sid" \
    '$1=="N" && $2==dir && $3==sid {print $4}' "$_CLAUDE_HISTORY_INDEX" | tail -1)

  # Model + context from JSONL
  if [[ -f "$jsonl" ]]; then
    model=$(_claude_model_from_jsonl "$jsonl")
    context=$(_claude_context_from_jsonl "$jsonl")
  fi
  [[ -z "$model" ]] && model=$(_claude_model_from_pane "$content")

  status=$(_claude_status_from_jsonl "$jsonl")
  [[ -z "$status" ]] && status=$(detect_status_claude_terminal "$pane_id" "$content")

  echo "${model}|${status}|${context}|${session_name}"
}
