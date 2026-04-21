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

## Architecture

```
tmux-aiscope.tmux
    └─ prefix+A → popup.sh (TUI)
                    │
                    └─ list_ai_panes.sh
                         │
                         ├─ Phase 1: provider_init()  (once per provider)
                         │     claude.sh  → build history index
                         │     aider.sh   → (no-op)
                         │     gemini.sh  → (future: build session index)
                         │
                         └─ Phase 2: provider_get_info()  (parallel, per pane)
                               │
                               ├─ Structured log detection (primary)
                               │     JSONL mtime + last entry type
                               │
                               └─ Terminal capture (fallback)
                                     detect_status.sh helpers
```

### File Structure

```
tmux-aiscope/
├── tmux-aiscope.tmux              # entry point: registers keybinding
├── scripts/
│   ├── list_ai_panes.sh           # scanner: init → parallel pane processing
│   ├── popup.sh                   # TUI: navigate, fold, jump
│   ├── detect_status.sh           # shared terminal detection utilities
│   └── providers/
│       ├── claude.sh              # Claude Code provider
│       ├── aider.sh               # Aider provider
│       └── generic.sh             # fallback: shell prompt detection
├── DEVELOP.md
└── README.md
```

## Provider Interface

Each provider is a self-contained file in `scripts/providers/`. A provider **must** implement `provider_get_info` and **may** implement `provider_init`.

### Required: `provider_get_info`

```bash
# Called once per matching pane (in a background subshell).
# Input:  pane_id  (e.g. %12)
# Output: "model|status|context_tokens|session_name"  (pipe-separated, empty = unknown)
#
# status must be one of: running | idle | blocked
provider_get_info "$pane_id"
```

### Optional: `provider_init`

```bash
# Called once in the parent shell before pane processing begins.
# Use for expensive one-time work: building indexes, caching lookups.
# $1 = tmpdir path (cleaned up automatically after list_ai_panes.sh exits)
# Export env vars here — they are inherited by all parallel pane workers.
provider_init "$tmpdir"
```

### Registration

Add a case to `_provider_for()` in `list_ai_panes.sh`:

```bash
_provider_for() {
  case "$1" in
    claude) echo "claude" ;;
    aider)  echo "aider"  ;;
    gemini) echo "gemini" ;;   # ← new
    *)      echo ""        ;;
  esac
}
```

The `$1` value is `pane_current_command` (the foreground process name in the tmux pane).

---

## Adding a New Provider: Step-by-Step

### 1. Identify the CLI process name

```bash
# Launch the AI CLI in a tmux pane, then check:
tmux list-panes -a -F '#{pane_id} #{pane_current_command}'
# e.g., %5 gemini
```

### 2. Find structured log files (if any)

Most AI CLIs write conversation logs. Check the CLI's data directory:

| CLI | Log location | Format |
|---|---|---|
| Claude Code | `~/.claude/projects/{encoded-cwd}/{sessionId}.jsonl` | JSONL (one JSON object per line) |
| Aider | `.aider.chat.history.md` (in project dir) | Markdown |
| Gemini CLI | `~/.gemini/history/` (check actual location) | Likely JSONL or JSON |

If structured logs exist, use **mtime-based detection** (reliable).
If not, use **terminal capture** (fragile but universal).

### 3. Create the provider file

```bash
# scripts/providers/gemini.sh — example skeleton

#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../detect_status.sh"

# Optional: one-time init (build indexes, export env vars)
provider_init() {
  local tmpdir="$1"
  # Example: export _GEMINI_LOG_DIR="$HOME/.gemini/history"
}

# Required: per-pane info extraction
provider_get_info() {
  local pane_id="$1"
  local model status context session_name

  # --- Model ---
  # Option A: parse from structured log
  # Option B: parse from pane capture
  model=$(_gemini_parse_model "$pane_id")

  # --- Status ---
  # Option A: log mtime-based (preferred)
  #   status=$(_gemini_status_from_log "$log_file")
  # Option B: terminal fallback
  #   local content=$(tmux capture-pane -p -t "$pane_id" 2>/dev/null)
  #   status=$(detect_status_by_prompt "$content" 'gemini>\s*$')
  status=$(_gemini_detect_status "$pane_id")

  # --- Context tokens (optional) ---
  # Parse from log if available

  echo "${model}|${status}|${context}|${session_name}"
}
```

### 4. Register the process name

In `list_ai_panes.sh`, add the case to `_provider_for()`.

### 5. Test

```bash
# Full pipeline
bash scripts/list_ai_panes.sh

# Single provider (isolated)
bash -c '
  source scripts/detect_status.sh
  source scripts/providers/gemini.sh
  provider_get_info %5
'
```

---

## Status Detection

### Three-State Model

| State | Meaning | Indicator |
|---|---|---|
| **running** | Actively streaming, executing tools, or API call in flight | Green `●` |
| **blocked** | Waiting for user input (permission prompt, y/n) | Yellow `●` |
| **idle** | Turn completed, waiting for next user message | Gray `○` |

### Strategy: Structured Logs (Primary)

If the CLI writes logs, status can be derived from **file mtime** + **last entry type**.

This pattern is generalizable across any CLI that appends to a log file:

```
mtime < threshold  →  running (file being written)
last entry = terminal marker  →  idle (turn/conversation complete)
last entry = pending action  →  blocked (waiting for user)
stale (> timeout)  →  idle (crash/disconnect safety net)
```

**Claude Code implementation** (`_claude_status_from_jsonl`):

| mtime age | Last JSONL entry | Status |
|---|---|---|
| < 5s | (any) | running |
| >= 5s | `system/turn_duration` | idle |
| >= 5s | `file-history-snapshot` | idle |
| >= 5s | `assistant` + `tool_use` | blocked |
| >= 5s | `user/` or `attachment/` | running |
| > 300s | (any non-idle) | idle (stale timeout) |

**Applying this to Aider** (future):

Aider writes to `.aider.chat.history.md`. A potential approach:
- `mtime < 5s` → running
- Last line matches `> ` (user prompt marker) and mtime > 5s → idle
- Contains `(y/n)` near end → blocked

**Applying this to Gemini CLI** (future):

Check `~/.gemini/` for session logs, apply the same mtime + last-entry pattern.

### Strategy: Terminal Capture (Fallback)

`detect_status.sh` provides shared utilities for pane content parsing:

```bash
# Check if last line looks like a prompt → idle
detect_status_by_prompt "$content" 'pattern'

# Check if recent lines contain a blocking prompt → blocked
detect_status_blocked "$content" 'pattern'

# Claude-specific full terminal detection (blocked → running → idle)
detect_status_claude_terminal "$pane_id" "$content"
```

Terminal capture is fragile (ANSI codes, line wrapping, UI version changes).
Use it only when structured logs are unavailable.

---

## Claude Code Session Resolution

### Problem

Claude Code's `~/.claude/sessions/{pid}.json` contains `sessionId`, but this
becomes stale after `/clear` or `/resume`. The file is written once at process
start and never updated.

### Solution

```
tmux pane
    ├─ PID path:     pane_pid → child PID → sessions/{pid}.json → cwd (stable)
    └─ History path:  capture prompts → match history.jsonl → sessionId (current)
```

The history index is built once per scan by `provider_init()`, then shared with
all parallel workers via `$_CLAUDE_HISTORY_INDEX`.

### Platform Notes

| Issue | macOS | Linux |
|---|---|---|
| Child PID lookup | `ps -ax \| awk` (`pgrep -P` unreliable due to sandbox) | `pgrep -P` works |
| File mtime | `stat -f '%m'` | `stat -c '%Y'` (needs compat shim) |

---

## Testing Scripts Manually

```bash
# Full scan
bash scripts/list_ai_panes.sh

# Test a specific provider
bash -c '
  source scripts/detect_status.sh
  source scripts/providers/claude.sh
  provider_get_info %3
'

# Test JSONL status detection
bash -c '
  source scripts/providers/claude.sh
  _claude_status_from_jsonl ~/.claude/projects/-Users-you-project/SESSION_ID.jsonl
'

# Test terminal fallback
bash -c '
  source scripts/detect_status.sh
  detect_status_claude_terminal %3
'
```

## Adding Config Options

All options are read lazily at runtime via:

```bash
tmux show-option -gqv "@aiscope-<option>"
```

No restart required — changes take effect on the next `prefix+A`.
