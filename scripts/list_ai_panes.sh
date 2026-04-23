#!/usr/bin/env bash
# Scan all panes for AI processes.
# Output (tab-separated): session  win_idx  win_name  pane_id  process  model  status  context  sess_name

_LIST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Zero-config claude-family discovery: any $HOME/.*claude*/ directory is
# assumed to be a claude-wrapped binary's data dir. Binary name is the dir
# name minus leading dot. Emits "binary<TAB>abs_dir" per line.
_aiscope_build_claude_variants() {
  local d name
  shopt -s nullglob dotglob
  for d in "$HOME"/.*claude*/; do
    name="${d%/}"; name="${name##*/}"; name="${name#.}"
    [[ -n "$name" ]] && printf '%s\t%s\n' "$name" "${d%/}"
  done
  shopt -u nullglob dotglob
}

# Space-separated list of claude-family binary names.
_aiscope_claude_bins() {
  awk -F'\t' 'NF>=1 && $1!="" {printf "%s ", $1}' <<< "$AISCOPE_CLAUDE_VARIANTS"
}

# Fast path: pane_current_command is any claude-family binary.
_provider_for() {
  local cmd="$1" bin
  for bin in $(_aiscope_claude_bins); do
    [[ "$cmd" == "$bin" ]] && { echo "claude"; return; }
  done
}

# Fallback: walk pane process subtree and match any argv containing "claude".
# Catches node/python wrappers and oddly-named forks; the provider figures
# out which variant data-dir owns the session.
_provider_from_subtree() {
  local pane_id="$1"
  local pane_pid
  pane_pid=$(tmux display-message -p -t "$pane_id" '#{pane_pid}' 2>/dev/null)
  [[ -z "$pane_pid" ]] && return

  ps -ax -o pid=,ppid=,args= 2>/dev/null | awk -v root="$pane_pid" '
    {
      pid=$1; ppid=$2; $1=""; $2=""; args=$0; gsub(/^ +/,"",args)
      parent[pid]=ppid; cmdline[pid]=args
    }
    END {
      tree[root]=1
      do {
        changed=0
        for (p in parent) {
          if ((parent[p] in tree) && !(p in tree)) { tree[p]=1; changed=1 }
        }
      } while (changed)
      for (p in tree) {
        if (cmdline[p] ~ /claude/) { print "claude"; exit }
      }
    }
  '
}

_fmt_context() {
  local t="$1"
  [[ -z "$t" || "$t" == "0" ]] && return
  if [ "$t" -ge 1000000 ] 2>/dev/null; then
    printf "%dM" $(( t / 1000000 ))
  elif [ "$t" -ge 1000 ] 2>/dev/null; then
    printf "~%dk" $(( t / 1000 ))
  else
    printf "%d" "$t"
  fi
}

_process_pane() {
  local session="$1" win_idx="$2" win_name="$3" pane_id="$4" cmd="$5"
  local process="${cmd##*/}"

  local provider_name
  provider_name=$(_provider_for "$process")
  [[ -z "$provider_name" ]] && provider_name=$(_provider_from_subtree "$pane_id")
  [[ -z "$provider_name" ]] && return

  local provider_script="${_LIST_DIR}/providers/${provider_name}.sh"
  [[ -f "$provider_script" ]] || provider_script="${_LIST_DIR}/providers/generic.sh"
  source "$provider_script"

  local info model status context sess_name
  info=$(provider_get_info "$pane_id")
  model="${info%%|*}"; info="${info#*|}"
  status="${info%%|*}"; info="${info#*|}"
  context="${info%%|*}"
  sess_name="${info#*|}"

  local ctx_fmt
  ctx_fmt=$(_fmt_context "$context")

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$session" "$win_idx" "$win_name" "$pane_id" "$process" \
    "${model:--}" "${status:--}" "${ctx_fmt:--}" "${sess_name:--}"
}

main() {
  local tmpdir
  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' EXIT

  # Build claude-variant table once, export for subshells & providers.
  export AISCOPE_CLAUDE_VARIANTS
  AISCOPE_CLAUDE_VARIANTS=$(_aiscope_build_claude_variants)

  # ── Phase 1: Provider init hooks ──
  # Each provider can implement provider_init() to prepare shared data
  # (e.g., build indexes, cache lookups). Runs once in the parent shell
  # so env vars are inherited by all parallel pane workers.
  for _provider_script in "$_LIST_DIR"/providers/*.sh; do
    source "$_provider_script"
    if declare -f provider_init >/dev/null 2>&1; then
      provider_init "$tmpdir"
    fi
    unset -f provider_init provider_get_info 2>/dev/null
  done

  # ── Phase 2: Process panes in parallel ──
  local pane_data
  pane_data=$(tmux list-panes -a \
    -F '#{session_name}|#{window_index}|#{window_name}|#{pane_id}|#{pane_current_command}')

  local outdir="$tmpdir/out"
  mkdir -p "$outdir"

  local idx=0
  while IFS='|' read -r session win_idx win_name pane_id cmd; do
    (
      _process_pane "$session" "$win_idx" "$win_name" "$pane_id" "$cmd"
    ) > "$outdir/$(printf '%04d' $idx)" &
    idx=$((idx+1))
  done <<< "$pane_data"

  wait
  cat "$outdir"/* 2>/dev/null
}

main "$@"
