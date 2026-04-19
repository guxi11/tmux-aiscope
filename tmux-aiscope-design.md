# tmux-aiscope

A tmux plugin that shows a fzf-powered popup listing all AI sessions across windows — like `prefix-s` but for AI CLIs.

## UI

```
▶ session: main
    ◆ window 1: feat/auth    claude-opus-4.5   ● active   ~18k tokens
    ◇ window 3: debug        claude-sonnet-4   ○ idle     ~6k tokens
▶ session: work
    ◆ window 2: refactor     aider/gpt-4       ● active   ~45k tokens
```

Select → `switch-client` + `select-window` jumps to that pane.

## Stack

- **Language**: bash + fzf (zero deps, TPM-native)
- **UI**: `tmux popup` + fzf with preview
- **Distribution**: TPM primary, Homebrew formula secondary

## File Structure

```
tmux-aiscope/
├── tmux-aiscope.tmux          # entry: register keybinding (default: prefix + A)
├── scripts/
│   ├── list_ai_panes.sh       # scan all sessions/windows/panes for AI processes
│   ├── popup.sh               # render fzf popup + handle selection/jump
│   ├── detect_status.sh       # idle vs active detection via pane cursor state
│   └── providers/
│       ├── claude.sh          # Claude Code: parse model/tokens from pane + ~/.claude/
│       ├── aider.sh           # Aider: parse model from pane content
│       └── generic.sh         # fallback: process name only, no extra info
└── README.md
```

## Provider Interface

Each provider must implement:

```bash
# Input:  pane_id (e.g. %12)
# Output: "model|status|context_tokens"  (pipe-separated, empty field = unknown)
# Example: "claude-opus-4.5|active|18432"
provider_get_info "$pane_id"
```

Provider is selected by matching `pane_current_command` against a registry:
```bash
declare -A PROVIDER_MAP=(
  ["claude"]="claude"
  ["aider"]="aider"
  # extend here
)
```

## Detection Strategy

### Process detection
```bash
tmux list-panes -a \
  -F '#{session_name}|#{window_index}|#{window_name}|#{pane_id}|#{pane_current_command}'
```
Filter by known AI process names.

### Claude Code specifics
- **Model**: parse from pane capture (status bar shows model name) or `~/.claude/projects/<hash>/sessions/*.jsonl`
- **Tokens**: last `usage` entry in session JSONL, or regex from pane status line
- **Status**: check if pane ends with input prompt (idle) vs spinner/partial output (active)

### Status detection (generic)
- Read last N lines of pane via `tmux capture-pane -p -S -5`
- If ends with a known prompt pattern → idle
- If contains spinner chars or mid-sentence output → active

## Config Options (tmux.conf)

```bash
set -g @aiscope-key          'A'           # keybinding
set -g @aiscope-popup-size   '80%'         # fzf popup dimensions
set -g @aiscope-providers    'claude aider' # enabled providers
set -g @aiscope-show-idle    'on'          # include idle AI sessions
```

## Install

```bash
# TPM
set -g @plugin 'yourname/tmux-aiscope'

# Manual
git clone https://github.com/yourname/tmux-aiscope ~/.tmux/plugins/tmux-aiscope
~/.tmux/plugins/tmux-aiscope/tmux-aiscope.tmux
```

## Implementation Order

1. `list_ai_panes.sh` — process detection, build data rows
2. `popup.sh` — fzf popup skeleton, jump-on-select
3. `providers/claude.sh` — model + token parsing
4. `detect_status.sh` — idle/active heuristic
5. `providers/aider.sh` + `generic.sh`
6. Config options wiring
7. TPM publish + README
