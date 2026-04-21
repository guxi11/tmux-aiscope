#!/usr/bin/env bash
# Interactive AI pane selector inside tmux display-popup.
# j/k or arrows: navigate, Enter: jump, Tab: collapse/expand, q/Esc: close.

_POPUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── All data (immutable after load) ──
all_type=()      # H=header, W=window
all_label=()     # display string (window rows only)
all_sess=()      # session name
all_widx=()      # window index
all_pid=()       # pane id

# ── Visible subset (rebuilt on collapse) ──
vis_type=()
vis_label=()
vis_sess=()
vis_widx=()
vis_pid=()

collapsed=""     # space-separated collapsed session names
selected=0
_SHORTCUT_POOL="0123456789abcdefgimnoprstuvwxyz"
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
      all_type[${#all_type[@]}]="H"
      all_label[${#all_label[@]}]=""
      all_sess[${#all_sess[@]}]="$sess"
      all_widx[${#all_widx[@]}]=""
      all_pid[${#all_pid[@]}]=""
      prev="$sess"
    fi

    # Build window display line
    local icon
    case "$status" in
      running) icon=$(printf '\033[32m●\033[0m') ;;
      blocked) icon=$(printf '\033[33m●\033[0m') ;;
      *)       icon=$(printf '\033[90m○\033[0m') ;;
    esac
    local st_text
    case "$status" in
      running) st_text="running" ;;
      blocked) st_text="blocked" ;;
      *)       st_text="idle   " ;;
    esac
    local line
    line=$(printf ' %s %-7s' "$icon" "$st_text")
    [[ -n "$model" ]] && line="$line  $(printf '\033[36m%s\033[0m' "$model")"
    [[ -n "$ctx" ]]   && line="$line  $(printf '\033[2m%s\033[0m' "$ctx")"
    [[ -n "$sname" ]] && line="$line  $(printf '\033[33m%s\033[0m' "$sname")"

    all_type[${#all_type[@]}]="W"
    all_label[${#all_label[@]}]="$line"
    all_sess[${#all_sess[@]}]="$sess"
    all_widx[${#all_widx[@]}]="$widx"
    all_pid[${#all_pid[@]}]="$pid"
  done <<< "$data"
  return 0
}

# ── Build visible list ──
_rebuild() {
  vis_type=(); vis_label=(); vis_sess=(); vis_widx=(); vis_pid=()
  local i=0
  while [ $i -lt ${#all_type[@]} ]; do
    local t="${all_type[$i]}" s="${all_sess[$i]}"
    if [[ "$t" == "H" ]]; then
      # Count windows: scan forward until next header (O(n) total)
      local n=0 j=$((i+1))
      while [ $j -lt ${#all_type[@]} ] && [[ "${all_type[$j]}" == "W" ]]; do
        n=$((n+1)); j=$((j+1))
      done
      local arrow; _is_collapsed "$s" && arrow="+" || arrow="-"
      vis_type[${#vis_type[@]}]="H"
      vis_label[${#vis_label[@]}]="$(printf ' \033[1m%s %s\033[0m \033[2m(%d)\033[0m' "$arrow" "$s" "$n")"
      vis_sess[${#vis_sess[@]}]="$s"
      vis_widx[${#vis_widx[@]}]=""
      vis_pid[${#vis_pid[@]}]=""
    elif [[ "$t" == "W" ]]; then
      if ! _is_collapsed "$s"; then
        vis_type[${#vis_type[@]}]="W"
        vis_label[${#vis_label[@]}]="  ${all_label[$i]}"
        vis_sess[${#vis_sess[@]}]="$s"
        vis_widx[${#vis_widx[@]}]="${all_widx[$i]}"
        vis_pid[${#vis_pid[@]}]="${all_pid[$i]}"
      fi
    fi
    i=$((i+1))
  done
}

# ── Navigation ──
_move() {
  local dir="$1" n=${#vis_type[@]}
  selected=$(( (selected + dir + n) % n ))
}

_move_prev_session() {
  local i=$((selected - 1)) n=${#vis_type[@]}
  while [ $i -ge 0 ]; do
    [[ "${vis_type[$i]}" == "H" ]] && { selected=$i; return; }
    i=$((i-1))
  done
  # wrap to last header
  i=$((n - 1))
  while [ $i -gt $selected ]; do
    [[ "${vis_type[$i]}" == "H" ]] && { selected=$i; return; }
    i=$((i-1))
  done
}

_default_sel() {
  local i=0
  while [ $i -lt ${#vis_type[@]} ]; do
    if [[ "${vis_type[$i]}" == "W" && "${vis_sess[$i]}" == "$cur_sess" && "${vis_widx[$i]}" == "$cur_widx" ]]; then
      selected=$i; return
    fi
    i=$((i+1))
  done
  i=0
  while [ $i -lt ${#vis_type[@]} ]; do
    [[ "${vis_type[$i]}" == "W" ]] && { selected=$i; return; }
    i=$((i+1))
  done
  selected=0
}

# ── Render ──
_draw() {
  printf '\033[H\033[1m  AI Panes\033[0m  \033[2mh:prev  j/k:nav  l:fold  enter:jump  q:quit\033[0m\n\n'
  local i=0 pool_len=${#_SHORTCUT_POOL}
  while [ $i -lt ${#vis_label[@]} ]; do
    if [ $i -eq $selected ]; then
      local sc=" "
      [ $i -lt $pool_len ] && sc="${_SHORTCUT_POOL:$i:1}"
      printf '\033[7m%s\033[0m%s\033[K\n' "$sc" "${vis_label[$i]}"
    else
      local sc=" "
      [ $i -lt $pool_len ] && sc=$(printf '\033[90m%s\033[0m' "${_SHORTCUT_POOL:$i:1}")
      printf '%s%s\033[K\n' "$sc" "${vis_label[$i]}"
    fi
    i=$((i+1))
  done
  printf '\033[J'
}

# ── Actions ──
_do_toggle() {
  local s="${vis_sess[$selected]}"
  [[ -z "$s" ]] && return
  _toggle_collapse "$s"
  _rebuild
  local i=0
  while [ $i -lt ${#vis_sess[@]} ]; do
    [[ "${vis_sess[$i]}" == "$s" && "${vis_type[$i]}" == "H" ]] && { selected=$i; break; }
    i=$((i+1))
  done
  [ $selected -ge ${#vis_type[@]} ] && selected=$((${#vis_type[@]} - 1))
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
  local key="$1" i=0 n=${#vis_type[@]}
  [ $n -gt ${#_SHORTCUT_POOL} ] && n=${#_SHORTCUT_POOL}
  while [ $i -lt $n ]; do
    if [[ "$key" == "${_SHORTCUT_POOL:$i:1}" ]]; then
      selected=$i
      return 0
    fi
    i=$((i+1))
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
    l|$'\t')     _do_toggle ;;
    '')
      if [[ "${vis_type[$selected]}" == "H" ]]; then
        _do_toggle
      else
        _do_jump && break
      fi ;;
    q|$'\033')   break ;;
    *)           _try_shortcut "$_key" ;;
  esac
  _draw
done

tput cnorm 2>/dev/null
