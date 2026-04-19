# Development Guide

## Local Setup

Clone and point tmux at your working copy directly — no TPM needed:

```bash
git clone https://github.com/Guxi11/tmux-aiscope ~/develop/tmux-aiscope
```

Add to `~/.tmux.conf`:

```bash
run-shell "~/develop/tmux-aiscope/tmux-aiscope.tmux"
```

Reload after every change:

```bash
tmux source ~/.tmux.conf
```

> macOS ships bash 3.2. The plugin requires bash 4+ for associative arrays.
> `brew install bash` then verify: `bash --version`

## File Structure

```
tmux-aiscope/
├── tmux-aiscope.tmux          # entry point: registers keybinding
├── scripts/
│   ├── list_ai_panes.sh       # scan all panes, emit tab-separated rows
│   ├── popup.sh               # fzf popup + jump-on-select
│   ├── detect_status.sh       # idle vs active heuristic
│   └── providers/
│       ├── claude.sh          # Claude Code: model + tokens from pane + JSONL
│       ├── aider.sh           # Aider: model from pane capture
│       └── generic.sh         # fallback: status only
```

## Provider Interface

Each provider sources `detect_status.sh` and implements one function:

```bash
# Input:  pane_id  (e.g. %12)
# Output: "model|status|tokens"   (pipe-separated; empty field = unknown)
provider_get_info "$pane_id"
```

Example output: `claude-opus-4-5|active|18432`

To add a new provider:

1. Create `scripts/providers/<name>.sh` implementing `provider_get_info`
2. Add an entry to `PROVIDER_MAP` in `scripts/list_ai_panes.sh`

## Testing Scripts Manually

Always run scripts under bash 4+:

```bash
# What panes are detected right now?
bash scripts/list_ai_panes.sh

# Test a specific provider (get pane IDs from above)
bash -c 'source scripts/detect_status.sh; source scripts/providers/claude.sh; provider_get_info %3'

# Test status detection alone
bash -c 'source scripts/detect_status.sh; detect_status %3 claude'

# Test fzf formatting without the popup
bash scripts/list_ai_panes.sh | bash scripts/popup.sh --format-only | \
  fzf --ansi --delimiter=$'\t' --with-nth=1
```

## Data Flow

```
tmux-aiscope.tmux
    └─ prefix+A → popup.sh
                    ├─ list_ai_panes.sh
                    │     ├─ tmux list-panes -a
                    │     ├─ PROVIDER_MAP lookup
                    │     └─ providers/<name>.sh → provider_get_info
                    │             └─ detect_status.sh
                    └─ fzf (--format-only on ctrl-r reload)
                            └─ enter → switch-client + select-window + select-pane
```

## Status Detection Heuristic

`detect_status.sh` captures the last 5 lines of the pane:

- Contains spinner chars (`⠋⠙⠹…`) → **active**
- Last non-empty line matches a known prompt pattern → **idle**
- Otherwise → **active**

Prompt patterns are defined per-process in `IDLE_PATTERNS`. Add new patterns there when onboarding a new provider.

## Claude Token Parsing

`providers/claude.sh` tries two sources in order:

1. **Pane capture** — regex for `claude-(opus|sonnet|haiku)-*` in last 50 lines
2. **JSONL** — `~/.claude/projects/<encoded-path>/sessions/*.jsonl`
   - Encoded path: absolute path with `/` → `-` (leading slash stripped)
   - Reads last `"input_tokens"` and `"model"` fields from the most recent session file

## Adding Config Options

All options are read lazily at runtime via:

```bash
tmux show-option -gqv "@aiscope-<option>"
```

No restart required — changes take effect on the next `prefix+A`.
