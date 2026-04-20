# tmux-aiscope

A tmux plugin that shows a popup listing all AI sessions across windows — like `prefix-s` but for AI CLIs.

```
▶ session: main
    ◆ window 1: feat/auth    claude-opus-4.5   ● running   ~18k tokens
    ◇ window 3: debug        claude-sonnet-4   ○ idle      ~6k tokens
▶ session: work
    ◆ window 2: refactor     aider/gpt-4       ● running   ~45k tokens
```

Press `prefix + a` → pick a pane → jumps straight to it.

## Requirements

- tmux ≥ 3.2
- bash ≥ 4.0 (`brew install bash` on macOS)

## Install

**TPM (recommended)**

```bash
set -g @plugin 'Guxi11/tmux-aiscope'
```

Then `prefix + I` to install.

**Manual**

```bash
git clone https://github.com/Guxi11/tmux-aiscope ~/.tmux/plugins/tmux-aiscope
```

Add to `~/.tmux.conf`:

```bash
run-shell ~/.tmux/plugins/tmux-aiscope/tmux-aiscope.tmux
```

## Configuration

```bash
set -g @aiscope-key          'a'            # keybinding (default: a)
set -g @aiscope-popup-size   '80%'          # popup dimensions (default: 80%)
set -g @aiscope-providers    'claude aider' # enabled providers (default: claude aider)
set -g @aiscope-show-idle    'on'           # show idle sessions (default: on)
```

## Supported Providers

| Tool | Model detection | Token count |
|------|----------------|-------------|
| Claude Code | pane capture + `~/.claude/` JSONL | ✓ |
| Aider | pane capture (startup banner) | — |
| Generic | process name only | — |

## Keybindings (inside popup)

| Key | Action |
|-----|--------|
| `Enter` | Jump to selected pane |
| `j` / `↓` | Move down |
| `k` / `↑` | Move up |
| `Tab` | Collapse/expand session |
| `q` / `Esc` | Close |

## License

MIT
