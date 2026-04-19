#!/usr/bin/env bash
# Scan all panes for AI processes.
# Output (tab-separated): session  win_idx  win_name  pane_id  process  model  status  context

_LIST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_provider_for() {
  case "$1" in
    claude) echo "claude" ;;
    aider)  echo "aider"  ;;
    *)      echo ""        ;;
  esac
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
  while IFS='|' read -r session win_idx win_name pane_id cmd; do
    _process_pane "$session" "$win_idx" "$win_name" "$pane_id" "$cmd"
  done < <(tmux list-panes -a \
    -F '#{session_name}|#{window_index}|#{window_name}|#{pane_id}|#{pane_current_command}')
}

main "$@"
