# tmux-aiscope — Design Document

A tmux plugin that shows an interactive popup listing all AI sessions across windows — like `prefix-s` but for AI CLIs.

## UI

```
  AI Panes  h:prev  j/k:nav  l:fold  enter:jump  q:quit

  - main (3)
    ● running  Opus 4.6  ~42k  implement auth middleware
    ○ idle     Sonnet 4.6  ~18k  fix lint errors
    ● blocked  Opus 4.6  ~95k  refactor database layer
  + work (2)
```

Status indicators: `●` green = running, `●` yellow = blocked, `○` gray = idle.

## Stack

- **Language**: bash (4+) — zero external deps, TPM-native
- **UI**: `tmux display-popup` with custom TUI
- **Distribution**: TPM primary, manual install secondary

## Provider Plugin Architecture

### Overview

The core scanner (`list_ai_panes.sh`) is AI-tool-agnostic. All tool-specific
logic lives in **provider plugins** under `scripts/providers/`. The scanner
discovers AI panes via process name, dispatches to the matching provider, and
collects results in parallel.

```
                    ┌──────────────────────────────────────┐
                    │           popup.sh (TUI)             │
                    └─────────────────┬────────────────────┘
                                      │
                    ┌─────────────────▼────────────────────┐
                    │        list_ai_panes.sh              │
                    │                                      │
                    │  Phase 1: provider_init() per file   ���
                    │  Phase 2: provider_get_info() ║ pane │
                    └──┬──────────┬──────────┬─────────────┘
                       │          │          │
              ┌────────▼──┐ ┌────▼────┐ ┌───▼──────┐
              │ claude.sh │ │ aider.sh│ │generic.sh│
              └─────┬─────┘ └────┬────┘ └────┬─────┘
                    │            │            │
          ┌─────────┤       pane capture   pane capture
          │         │
     JSONL mtime  history.jsonl
     (primary)    (session ID)
```

### Lifecycle

```
 list_ai_panes.sh main()
     │
     ├── Phase 1: for each providers/*.sh
     │     source → call provider_init(tmpdir) if defined → unset
     │     Runs in parent shell: env vars are inherited by workers
     │
     └── Phase 2: for each tmux pane (parallel)
           match pane_current_command → provider name
           source providers/{name}.sh
           call provider_get_info(pane_id)
           collect output
```

### Provider Contract

```bash
# OPTIONAL: One-time initialization.
# $1 = tmpdir (auto-cleaned). Export env vars for workers here.
provider_init() { ... }

# REQUIRED: Per-pane info extraction. Called in a background subshell.
# Output: "model|status|context_tokens|session_name"
# status ∈ { running, idle, blocked }
# Empty fields are OK (e.g., "||" if no model/context).
provider_get_info() { ... }
```

### Registration

`_provider_for()` maps process name → provider file:

```bash
_provider_for() {
  case "$1" in
    claude) echo "claude" ;;
    aider)  echo "aider"  ;;
    gemini) echo "gemini" ;;
    *)      echo ""        ;;
  esac
}
```

The value of `$1` comes from tmux's `#{pane_current_command}`.

### Shared Utilities (`detect_status.sh`)

Providers own their detection logic but can use shared helpers:

| Function | Purpose |
|---|---|
| `detect_status_by_prompt "$content" 'pattern'` | Check if last non-empty line matches prompt → idle |
| `detect_status_blocked "$content" 'pattern'` | Check if recent lines match a blocking prompt → blocked |
| `detect_status_claude_terminal "$pane_id" "$content"` | Claude-specific terminal heuristic (fallback) |

## Status Detection

### Three-State Model

| State | Meaning | Trigger |
|---|---|---|
| **running** | AI is generating, streaming, or executing tools | Log mtime < 5s, or mid-turn entry in log |
| **blocked** | AI stopped, waiting for user action (permission, y/n) | Pending tool_use in log, or prompt in terminal |
| **idle** | Turn completed, waiting for next user message | Terminal turn marker in log, or prompt in terminal |

### Detection Strategy Matrix

| | Structured Logs | Terminal Capture |
|---|---|---|
| **Reliability** | High (structured data, no rendering) | Low (ANSI, line wrap, version coupling) |
| **Latency** | ~1 stat + 1 tail | ~1 capture-pane + regex |
| **Blocked detection** | Last entry = tool_use without result | Regex for prompt UI patterns |
| **Availability** | Requires log files | Always available |

**Rule**: Use structured logs when available; fall back to terminal capture.

### Structured Log Detection Pattern

Generalizable across any CLI that appends to a log file:

```
┌─────────────────────────────────────────────────┐
│  Is the file being written right now?            │
│  mtime < threshold  →  RUNNING                  │
├─────────────────────────────────────────────────┤
│  What is the last entry?                         │
│  turn-complete marker  →  IDLE                   │
│  pending-action marker →  BLOCKED                │
│  user-input marker     →  RUNNING (mid-turn)     │
├─────���───────────────────────────────────────────┤
│  Is the file stale?                              │
│  mtime > timeout  →  IDLE (crash safety net)     │
└──���──────────────────────────────────────────────┘
```

**Claude Code** (`~/.claude/projects/{path}/{sessionId}.jsonl`):

| mtime | Last entry type | → Status |
|---|---|---|
| < 5s | (any) | running |
| ≥ 5s | `system/turn_duration` | idle |
| ≥ 5s | `file-history-snapshot` | idle |
| ≥ 5s | `assistant` + `tool_use` | blocked |
| ≥ 5s | `user/` or `attachment/` | running |
| > 300s | (non-idle) | idle |

## Session Resolution (Claude Code)

### Problem

`~/.claude/sessions/{pid}.json` contains `sessionId`, but becomes stale after
`/clear` or `/resume` (written once at startup, never updated).

### Solution

| Data | Source | Reliability |
|---|---|---|
| **cwd** | `sessions/{pid}.json` | Stable (process doesn't change cwd) |
| **sessionId** | History index (prompt matching) | Current (reflects /clear, /resume) |

History index is built from `~/.claude/history.jsonl` (last 5000 lines) by
`provider_init()`. Prompt matching uses a sliding-window majority vote over
the most recent 1–10 visible prompts in the pane.

## Supported Providers

### Claude Code — `providers/claude.sh`

| Feature | Source | Method |
|---|---|---|
| Model | JSONL `"model"` field, or pane capture | grep |
| Status | JSONL mtime + last entry type | stat + tail |
| Context tokens | JSONL `input_tokens` + cache tokens | tail + grep |
| Session name | History index `N` records | awk |

### Aider — `providers/aider.sh`

| Feature | Source | Method |
|---|---|---|
| Model | Pane capture (`Model: ...`) | grep |
| Status | Pane capture (prompt / y/n detection) | Terminal |
| Context tokens | — | Not available |
| Session name | — | Not available |

### Generic — `providers/generic.sh`

Shell prompt detection only. Catches any unrecognized AI CLI.

## Guide: Adding a New Provider

### Example: Gemini CLI

**1. Identify the process name**

```bash
tmux list-panes -a -F '#{pane_id} #{pane_current_command}'
# → %5 gemini
```

**2. Find structured logs**

```bash
ls ~/.gemini/          # check data directory
# Look for: session logs, conversation history, JSONL files
```

**3. Create `scripts/providers/gemini.sh`**

```bash
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../detect_status.sh"

# ── Init: build session index if Gemini writes logs ──
provider_init() {
  local tmpdir="$1"
  # Example: scan ~/.gemini/sessions/ and build a lookup table
  # export _GEMINI_SESSION_DIR="$HOME/.gemini/sessions"
}

# ── Helpers ──
_gemini_find_log() {
  local pane_id="$1"
  # Map pane → log file path
  # Approach depends on how Gemini organizes its logs
}

_gemini_status_from_log() {
  local log="$1"
  [[ -f "$log" ]] || return

  local age
  age=$(( $(date +%s) - $(stat -f '%m' "$log") ))

  [ "$age" -lt 5 ] && { echo "running"; return; }

  # Parse last entry — adapt to Gemini's log format
  local last_line
  last_line=$(tail -1 "$log")

  # Map Gemini's turn-complete markers to idle
  # Map Gemini's pending-action markers to blocked
  # Default: check age for running vs idle

  [ "$age" -gt 300 ] && echo "idle" || echo "running"
}

_gemini_parse_model() {
  local pane_id="$1"
  # Option A: from log file metadata
  # Option B: from pane capture
  tmux capture-pane -p -t "$pane_id" -S -100 2>/dev/null \
    | grep -oE 'gemini-[a-z0-9.-]+' | head -1
}

# ── Entry point ──
provider_get_info() {
  local pane_id="$1"
  local model status context session_name

  local log
  log=$(_gemini_find_log "$pane_id")

  model=$(_gemini_parse_model "$pane_id")

  # Primary: log-based detection
  status=$(_gemini_status_from_log "$log")

  # Fallback: terminal detection
  if [[ -z "$status" ]]; then
    local content
    content=$(tmux capture-pane -p -t "$pane_id" 2>/dev/null)
    status=$(detect_status_by_prompt "$content" '>\s*$')
  fi

  echo "${model}|${status}|${context}|${session_name}"
}
```

**4. Register in `list_ai_panes.sh`**

```bash
_provider_for() {
  case "$1" in
    claude) echo "claude" ;;
    aider)  echo "aider"  ;;
    gemini) echo "gemini" ;;   # ← add this
    *)      echo ""        ;;
  esac
}
```

**5. Test**

```bash
bash scripts/list_ai_panes.sh
bash -c 'source scripts/detect_status.sh; source scripts/providers/gemini.sh; provider_get_info %5'
```

### Checklist for Any New Provider

- [ ] Process name identified (`pane_current_command`)
- [ ] Log file location documented
- [ ] `provider_get_info` implemented with `model|status|context|name` output
- [ ] `provider_init` implemented if one-time work is needed
- [ ] Status returns one of: `running`, `idle`, `blocked`
- [ ] Case added to `_provider_for()` in `list_ai_panes.sh`
- [ ] Terminal fallback for when logs are unavailable
- [ ] Tested with `bash scripts/list_ai_panes.sh`

## Platform Compatibility

| Issue | macOS | Linux |
|---|---|---|
| Bash version | 3.2 bundled — needs `brew install bash` for 4+ | Usually 4+ |
| Child PID lookup | `ps -ax \| awk` (pgrep -P unreliable) | `pgrep -P` |
| File mtime | `stat -f '%m'` | `stat -c '%Y'` (needs shim) |
| Python 3 | Usually available | Usually available |

## Known Limitations

- **Post-`/clear` without prompts**: If no prompts are visible and history has no match, JSONL cannot be located. Falls back to terminal detection.
- **Shared project dir**: Multiple panes on the same project are resolved independently via history index — no "latest JSONL" guessing.
- **Linux stat**: Currently macOS-only `stat -f '%m'`. Needs `stat -c '%Y'` for Linux.
- **Stale timeout**: 300s is a heuristic. A crash < 300s ago briefly shows "running".

## Config Options

```bash
set -g @aiscope-key          'a'
set -g @aiscope-popup-size   '80%'
set -g @aiscope-providers    'claude aider'
set -g @aiscope-show-idle    'on'
```

All options are read lazily — changes take effect on next `prefix+A`.
