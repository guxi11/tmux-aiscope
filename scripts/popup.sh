#!/usr/bin/env bash
# Interactive AI pane selector inside tmux display-popup.
# j/k or arrows: navigate, Enter: jump, Tab: cycle filter, a/i/r/b: filter, l: fold, q/Esc: close.

_POPUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── All data (immutable after load) ──
all_type=()      # H=header, W=window
all_label=()     # display string (window rows only)
all_sess=()      # session name
all_widx=()      # window index
all_pid=()       # pane id
all_status=()    # idle/running/blocked (windows only)

# ── Visible subset (rebuilt on filter) ──
vis_type=()
vis_label=()
vis_sess=()
vis_widx=()
vis_pid=()

# ── Row append helpers ──
_push_all() { all_type+=("$1"); all_label+=("$2"); all_sess+=("$3"); all_widx+=("$4"); all_pid+=("$5"); all_status+=("$6"); }
_push_vis() { vis_type+=("$1"); vis_label+=("$2"); vis_sess+=("$3"); vis_widx+=("$4"); vis_pid+=("$5"); }

filter_mode="all"  # all|idle|running|blocked
collapsed=""       # space-separated collapsed session names
selected=0
_SHORTCUT_POOL="0123456789cdefgmnopstuvwxyz"
cur_sess="" cur_widx=""

# ── Collapse helpers ──
_is_collapsed() {
  case " $collapsed " in *" $1 "*) return 0 ;; esac
  return 1
}

_toggle_collapse() {
  if _is_collapsed "$1"; then
    collapsed=$(echo " $collapsed " | sed "s/ $1 / /" | sed 's/^ *//;s/ *$//')
  else
    collapsed="$collapsed $1"
  fi
}

# ── Filter helpers ──
_set_filter() {
  filter_mode="$1"
  local prev_sess="${vis_sess[$selected]}" prev_widx="${vis_widx[$selected]}" prev_type="${vis_type[$selected]}"
  _rebuild
  local i
  for ((i=0; i<${#vis_type[@]}; i++)); do
    [[ "${vis_sess[$i]}" == "$prev_sess" && "${vis_widx[$i]}" == "$prev_widx" && "${vis_type[$i]}" == "$prev_type" ]] &&
      { selected=$i; return; }
  done
  for ((i=0; i<${#vis_type[@]}; i++)); do
    [[ "${vis_type[$i]}" == "W" ]] && { selected=$i; return; }
  done
  selected=0
}

_cycle_filter() {
  case "$filter_mode" in
    all)     _set_filter "idle" ;;
    idle)    _set_filter "running" ;;
    running) _set_filter "blocked" ;;
    blocked) _set_filter "all" ;;
  esac
}

# ── Load all data ──
_load() {
  local data
  data=$("$_POPUP_DIR/list_ai_panes.sh")
  [[ -z "$data" ]] && return 1

  cur_sess=$(tmux display-message -p '#{session_name}' 2>/dev/null)
  cur_widx=$(tmux display-message -p '#{window_index}' 2>/dev/null)

  local prev=""
  while IFS=$'\t' read -r sess widx wname pid proc model status ctx sname; do
    [[ "$model" == "-" ]]  && model=""
    [[ "$status" == "-" ]] && status=""
    [[ "$ctx" == "-" ]]    && ctx=""
    [[ "$sname" == "-" ]]  && sname=""

    if [[ "$sess" != "$prev" ]]; then
      _push_all "H" "" "$sess" "" "" ""
      prev="$sess"
    fi

    # Build window display line
    local icon st_text nst
    case "$status" in
      running) icon=$'\033[32m●\033[0m' st_text="running" nst="running" ;;
      blocked) icon=$'\033[33m●\033[0m' st_text="blocked" nst="blocked" ;;
      *)       icon=$'\033[90m○\033[0m' st_text="idle   " nst="idle"    ;;
    esac
    local line
    line=$(printf ' %s %-7s' "$icon" "$st_text")
    [[ -n "$model" ]] && line="$line  $(printf '\033[36m%s\033[0m' "$model")"
    [[ -n "$ctx" ]]   && line="$line  $(printf '\033[2m%s\033[0m' "$ctx")"
    [[ -n "$sname" ]] && line="$line  $(printf '\033[33m%s\033[0m' "$sname")"

    _push_all "W" "$line" "$sess" "$widx" "$pid" "$nst"
  done <<< "$data"
  return 0
}

# ── Build visible list ──
_match_filter() { [[ "$filter_mode" == "all" || "${all_status[$1]}" == "$filter_mode" ]]; }

_rebuild() {
  vis_type=(); vis_label=(); vis_sess=(); vis_widx=(); vis_pid=()
  local i t s
  for ((i=0; i<${#all_type[@]}; i++)); do
    t="${all_type[$i]}" s="${all_sess[$i]}"
    if [[ "$t" == "H" ]]; then
      # Count matching windows under this header
      local n=0 j
      for ((j=i+1; j<${#all_type[@]}; j++)); do
        [[ "${all_type[$j]}" != "W" ]] && break
        _match_filter $j && ((n++))
      done
      if ((n > 0)); then
        local arrow; _is_collapsed "$s" && arrow="+" || arrow="-"
        _push_vis "H" "$(printf ' \033[1m%s %s\033[0m \033[2m(%d)\033[0m' "$arrow" "$s" "$n")" "$s" "" ""
      fi
    elif [[ "$t" == "W" ]]; then
      ! _is_collapsed "$s" && _match_filter $i &&
        _push_vis "W" "  ${all_label[$i]}" "$s" "${all_widx[$i]}" "${all_pid[$i]}"
    fi
  done
}

# ── Navigation ──
_move() {
  local dir="$1" n=${#vis_type[@]}
  selected=$(( (selected + dir + n) % n ))
}

_move_prev_session() {
  local i n=${#vis_type[@]}
  for ((i=selected-1; i>=0; i--)); do
    [[ "${vis_type[$i]}" == "H" ]] && { selected=$i; return; }
  done
  # wrap to last header
  for ((i=n-1; i>selected; i--)); do
    [[ "${vis_type[$i]}" == "H" ]] && { selected=$i; return; }
  done
}

_default_sel() {
  local i
  for ((i=0; i<${#vis_type[@]}; i++)); do
    [[ "${vis_type[$i]}" == "W" && "${vis_sess[$i]}" == "$cur_sess" && "${vis_widx[$i]}" == "$cur_widx" ]] &&
      { selected=$i; return; }
  done
  for ((i=0; i<${#vis_type[@]}; i++)); do
    [[ "${vis_type[$i]}" == "W" ]] && { selected=$i; return; }
  done
  selected=0
}

# ── Render ──
_draw() {
  printf '\033[H\033[1m  aiscope\033[0m  \033[2mj/k:nav  h:prev  l:fold  enter:jump  q:quit\033[0m\n'
  printf '  \033[2m─────────────────────────────────────────────────\033[0m\n'
  local fi=""
  for m in all:a idle:i running:r blocked:b; do
    local name="${m%%:*}" key="${m##*:}"
    if [[ "$name" == "$filter_mode" ]]; then
      fi="$fi\033[7m ${name}(\033[1m${key}\033[22m) \033[0m "
    else
      fi="$fi\033[2m${name}(\033[22;1m${key}\033[22;2m)\033[0m "
    fi
  done
  printf '  %b \033[2mtab:cycle\033[0m\n\n' "$fi"
  local i pool_len=${#_SHORTCUT_POOL} sc
  for ((i=0; i<${#vis_label[@]}; i++)); do
    sc=" "
    if ((i == selected)); then
      ((i < pool_len)) && sc="${_SHORTCUT_POOL:$i:1}"
      printf '\033[7m%s\033[0m%s\033[K\n' "$sc" "${vis_label[$i]}"
    else
      ((i < pool_len)) && sc=$(printf '\033[90m%s\033[0m' "${_SHORTCUT_POOL:$i:1}")
      printf '%s%s\033[K\n' "$sc" "${vis_label[$i]}"
    fi
  done
  printf '\033[J'
}

# ── Actions ──
_do_toggle() {
  local s="${vis_sess[$selected]}"
  [[ -z "$s" ]] && return
  _toggle_collapse "$s"
  _rebuild
  local i
  for ((i=0; i<${#vis_sess[@]}; i++)); do
    [[ "${vis_sess[$i]}" == "$s" && "${vis_type[$i]}" == "H" ]] && { selected=$i; break; }
  done
  ((selected >= ${#vis_type[@]})) && selected=$((${#vis_type[@]} - 1))
}

_do_jump() {
  [[ "${vis_type[$selected]}" != "W" ]] && return 1
  local s="${vis_sess[$selected]}" w="${vis_widx[$selected]}" p="${vis_pid[$selected]}"
  [[ -z "$p" ]] && return 1
  tmux switch-client -t "$s" 2>/dev/null
  tmux select-window -t "${s}:${w}" 2>/dev/null
  tmux select-pane -t "$p" 2>/dev/null
  return 0
}

_try_shortcut() {
  local key="$1" i n=${#vis_type[@]}
  ((n > ${#_SHORTCUT_POOL})) && n=${#_SHORTCUT_POOL}
  for ((i=0; i<n; i++)); do
    [[ "$key" == "${_SHORTCUT_POOL:$i:1}" ]] && { selected=$i; return 0; }
  done
  return 1
}

# ── Key reading (bash 3.2 compatible) ──
_readkey() {
  _key=""
  IFS= read -rsn1 _key
  if [[ "$_key" == $'\033' ]]; then
    # Try to read escape sequence; -t 1 works on bash 3.2 (integer seconds)
    IFS= read -rsn1 -t 1 _c1 2>/dev/null
    if [[ "$_c1" == "[" ]]; then
      IFS= read -rsn1 -t 1 _c2 2>/dev/null
      _key="${_key}${_c1}${_c2}"
    elif [[ -n "$_c1" ]]; then
      _key="${_key}${_c1}"
    fi
    # bare escape: _key stays as \033
  fi
}

# ── Main ──
_load || { echo "  No AI panes found."; sleep 1; exit 0; }
_rebuild
_default_sel

tput civis 2>/dev/null
printf '\033[2J'
_draw

while true; do
  _readkey
  case "$_key" in
    $'\033[A'|k) _move -1 ;;
    $'\033[B'|j) _move 1 ;;
    h)           _move_prev_session ;;
    $'\t')       _cycle_filter ;;
    l)           _do_toggle ;;
    a)           _set_filter "all" ;;
    i)           _set_filter "idle" ;;
    r)           _set_filter "running" ;;
    b)           _set_filter "blocked" ;;
    '')          _do_jump && break ;;
    q|$'\033')   break ;;
    *)           _try_shortcut "$_key" && _do_jump && break ;;
  esac
  _draw
done

tput cnorm 2>/dev/null
