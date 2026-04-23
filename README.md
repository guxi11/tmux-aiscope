# tmux-aiscope

A tmux plugin that shows a popup listing all AI sessions across windows — like `prefix-s` but for AI CLIs.

Press `prefix + a` → pick a pane → jumps straight to it.

![demo](assets/demo.jpg)

## Requirements

- tmux ≥ 3.2
- bash ≥ 4.0 (`brew install bash` on macOS)

## Install

**TPM (recommended)**

If you don't have TPM yet:

```bash
git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
```

Add to the **bottom** of `~/.tmux.conf`:

```bash
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'tmux-plugins/tmux-sensible'
set -g @plugin 'Guxi11/tmux-aiscope'

run '~/.tmux/plugins/tpm/tpm'
```

Reload tmux config, then install plugins:

```bash
tmux source ~/.tmux.conf
# inside tmux: prefix + I
```

**Manual**

```bash
git clone https://github.com/Guxi11/tmux-aiscope ~/.tmux/plugins/tmux-aiscope
```

Add to `~/.tmux.conf`:

```bash
run ~/.tmux/plugins/tmux-aiscope/tmux-aiscope.tmux
```

## Configuration

```bash
set -g @aiscope-key          'a'    # keybinding (default: a)
set -g @aiscope-popup-size   '80%'  # popup dimensions (default: 80%)
```

## Supported Providers

| Tool | Model detection | Token count |
|------|----------------|-------------|
| Claude Code | pane capture + `~/.claude/` JSONL | ✓ |

Claude wrappers are auto-detected: any `~/.*claude*/` directory is treated as
a variant's data dir (binary name = dir name without the leading dot). Zero
config — install a fork like `claude-internal` and it just shows up.

## Keybindings (inside popup)

| Key | Action |
|-----|--------|
| `Enter` | Jump to selected pane |
| `j` / `↓` | Move down |
| `k` / `↑` | Move up |
| `h` | Previous session |
| `l` | Fold/unfold session |
| `Tab` | Cycle filter |
| `a` `i` `r` `b` | Filter: all / idle / running / blocked |
| `0-9` | Shortcut jump |
| `q` / `Esc` | Close |

## License

MIT
