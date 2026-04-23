#!/usr/bin/env bash
# Rule-based tests for session name resolution.
set -euo pipefail

PASS=0 FAIL=0
_assert() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf '  \033[32m✓\033[0m %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf '  \033[31m✗\033[0m %s\n    expected: [%s]\n    actual:   [%s]\n' "$label" "$expected" "$actual"
    FAIL=$((FAIL + 1))
  fi
}

# ── Inline the N-record builder ──
_build_n_records() {
  python3 -c "
import json,sys
seen={}
for line in sys.stdin:
    line=line.strip()
    if not line: continue
    try: d=json.loads(line)
    except: continue
    disp=d.get('display','')
    sid=d.get('sessionId','')
    if not disp or not sid: continue
    if not disp.startswith('/') and ' ' in disp.strip() and sid not in seen:
        seen[sid]=disp[:300]
for sid,disp in seen.items():
    print(sid+'\t'+disp)
"
}

_get_name() { echo "$1" | grep "^$2	" | cut -f2; }

# ── Inline the prompt extractor ──
_extract_prompts() {
  awk '
    /^❯ [^\/]/ { if (buf) print buf; sub(/^❯ /, "", $0); buf=$0; next }
    /^❯ /      { if (buf) print buf; buf=""; next }
    /^[╭╰│►▸✓✗●○┌└├─╌⎿⏺✻⚠]/ || /^  / || /^[[:space:]]*$/ || /^[A-Z][a-z]+ [0-9]/ {
      if (buf) print buf; buf=""; next
    }
    buf { gsub(/^[[:space:]]+/,"",$0); buf=buf " " $0 }
    END { if (buf) print buf }
  ' | grep -v '^\s*$'
}

# ═══════════════════════════════════════════
echo "N-record rules"
# ═══════════════════════════════════════════

idx=$(cat <<'EOF'
{"display":"/clear","sessionId":"s1","project":"/p"}
{"display":"/model","sessionId":"s1","project":"/p"}
{"display":"hello","sessionId":"s1","project":"/p"}
{"display":"two words","sessionId":"s1","project":"/p"}
{"display":"three word phrase","sessionId":"s1","project":"/p"}
{"display":"two words","sessionId":"s2","project":"/p"}
{"display":"/clear","sessionId":"s2","project":"/p"}
EOF
)
result=$(echo "$idx" | _build_n_records)

_assert "slash+single-word skipped, first multi-word wins" \
  "two words" "$(_get_name "$result" s1)"
_assert "each session gets independent name" \
  "two words" "$(_get_name "$result" s2)"

# Session with only slashes and single words → no record
result2=$(echo '{"display":"/clear","sessionId":"s3","project":"/p"}
{"display":"ok","sessionId":"s3","project":"/p"}' | _build_n_records)
_assert "all-slash-or-single-word → no name" \
  "" "$(_get_name "$result2" s3 || true)"

# Different sessionIds from /clear boundary
result3=$(echo '{"display":"old task","sessionId":"old","project":"/p"}
{"display":"/clear","sessionId":"old","project":"/p"}
{"display":"new task","sessionId":"new","project":"/p"}' | _build_n_records)
_assert "/clear boundary: old session named" "old task" "$(_get_name "$result3" old)"
_assert "/clear boundary: new session named" "new task" "$(_get_name "$result3" new)"

# ═══════════════════════════════════════════
echo ""
echo "Prompt extraction rules"
# ═══════════════════════════════════════════

# Rule: slash prompts excluded
r=$(printf '❯ /cmd\n❯ real prompt here\n' | _extract_prompts)
_assert "slash prompts excluded" "real prompt here" "$r"

# Rule: wrapped lines joined with space
r=$(printf '❯ aaa bbb ccc\nddd eee\n\n' | _extract_prompts)
_assert "continuation joined" "aaa bbb ccc ddd eee" "$r"

# Rule: indented lines (claude output) break continuation
r=$(printf '❯ prompt\n  output line\n❯ next\n' | _extract_prompts)
_assert "indent breaks continuation" "$(printf 'prompt\nnext')" "$r"

# Rule: ⎿ ⏺ break continuation
r=$(printf '❯ prompt\n⎿ result\n⏺ response\n' | _extract_prompts)
_assert "output markers break continuation" "prompt" "$r"

# Rule: blank line breaks continuation
r=$(printf '❯ first\n\n❯ second\n' | _extract_prompts)
_assert "blank line breaks" "$(printf 'first\nsecond')" "$r"

# Rule: empty input → empty output
r=$(printf '' | _extract_prompts || true)
_assert "empty → empty" "" "$r"

# Rule: only /clear visible → empty prompts
r=$(printf '❯ /clear\n  ⎿  (no content)\n\n' | _extract_prompts || true)
_assert "/clear only → empty" "" "$r"

# ═══════════════════════════════════════════
echo ""
total=$((PASS + FAIL))
if ((FAIL == 0)); then
  printf '\033[32mAll %d tests passed.\033[0m\n' "$total"
else
  printf '\033[31m%d/%d tests failed.\033[0m\n' "$FAIL" "$total"
  exit 1
fi
