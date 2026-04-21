#!/bin/bash
# compliance-gate.sh — PreToolUse Bash gate. Blocks `git push` unless a recent,
# matching compliance-audit evidence file shows a clean audit + clean build.
#
# Portable. Drop into any repo's .claude/hooks/. Configure via env vars set in
# the hook block of settings.json.
#
# Config (all env-driven with sensible defaults):
#   COMPLIANCE_EVIDENCE_PATH     (default: /tmp/compliance-gate-evidence.json)
#   COMPLIANCE_REPO_PATH         (default: inferred from `cd <path>` in the
#                                 command, else $CLAUDE_PROJECT_DIR, else PWD)
#   COMPLIANCE_MAX_AGE_SECONDS   (default: 3600)
#   COMPLIANCE_SMOKE_EXPECTED    (default: "" — skip smoke-test check if empty)
#                                 Set to exact string like "18/18 passed" to
#                                 require that value.
#   COMPLIANCE_TSC_REQUIRED      (default: 0 — skip tsc check if 0)
#                                 Set to 1 to require evidence.tsc == "clean".
#   COMPLIANCE_MAX_CRITICAL      (default: 0)
#   COMPLIANCE_MAX_HIGH          (default: 0)
#
# Evidence JSON schema (see evidence-schema.md for full doc):
#   {
#     "head": "<current HEAD SHA, full or short prefix>",
#     "critical": <int>,     // compliance-auditor Critical findings still open
#     "high": <int>,         // compliance-auditor High findings still open
#     "smoke_test": "18/18 passed",   // optional, required only if configured
#     "tsc": "clean"                  // optional, required only if configured
#   }
#
# Exit codes:
#   0 = pass (gate open)
#   2 = block (gate closed, stderr explains why)
#
# stdin: Claude Code hook JSON payload (tool_input.command is the Bash command).

set -eu

# ─── Read config with defaults ───────────────────────────────────────────────
EVIDENCE="${COMPLIANCE_EVIDENCE_PATH:-/tmp/compliance-gate-evidence.json}"
MAX_AGE="${COMPLIANCE_MAX_AGE_SECONDS:-3600}"
SMOKE_EXPECTED="${COMPLIANCE_SMOKE_EXPECTED:-}"
TSC_REQUIRED="${COMPLIANCE_TSC_REQUIRED:-0}"
MAX_CRITICAL="${COMPLIANCE_MAX_CRITICAL:-0}"
MAX_HIGH="${COMPLIANCE_MAX_HIGH:-0}"

# ─── Parse hook payload → command string ─────────────────────────────────────
INPUT=$(cat)
COMMAND=$(python3 -c 'import json, sys
try:
    d = json.loads(sys.stdin.read())
    print(d.get("tool_input", {}).get("command", ""))
except Exception:
    print("")' <<<"$INPUT")

# ─── Short-circuit: only fire on actual `git push` ───────────────────────────
# Tokenize to avoid matching substrings in string literals (e.g. sqlite
# statements or grep patterns containing "git push").
IS_PUSH=$(python3 -c 'import shlex, sys
cmd = sys.argv[1]
try:
    tokens = shlex.split(cmd, posix=True)
except Exception:
    print("0"); sys.exit(0)
for i in range(len(tokens) - 1):
    if tokens[i] == "git" and tokens[i+1] == "push":
        print("1"); sys.exit(0)
print("0")' "$COMMAND")

if [ "$IS_PUSH" != "1" ]; then
  exit 0
fi

# ─── Determine repo path ──────────────────────────────────────────────────────
REPO_PATH="${COMPLIANCE_REPO_PATH:-}"
if [ -z "$REPO_PATH" ]; then
  # Look for "cd <path>" segment in the piped command
  REPO_PATH=$(python3 -c 'import re, sys
cmd = sys.argv[1]
m = re.search(r"cd\s+([^\s&;]+)", cmd)
print(m.group(1) if m else "")' "$COMMAND")
fi
if [ -z "$REPO_PATH" ]; then
  REPO_PATH="${CLAUDE_PROJECT_DIR:-$PWD}"
fi
# Expand ~ safely
REPO_PATH="${REPO_PATH/#\~/$HOME}"

CURRENT_HEAD=$(git -C "$REPO_PATH" rev-parse HEAD 2>/dev/null || echo "")

# ─── Evidence exists? ────────────────────────────────────────────────────────
if [ ! -f "$EVIDENCE" ]; then
  echo "BLOCK: No compliance evidence at $EVIDENCE. Before pushing:" >&2
  echo "  1. cd $REPO_PATH && npx tsc --noEmit" >&2
  [ -n "$SMOKE_EXPECTED" ] && echo "  2. Run your smoke test; confirm output matches '$SMOKE_EXPECTED'" >&2
  echo "  3. Spawn compliance-auditor on the staged diff" >&2
  echo "  4. Write evidence JSON to $EVIDENCE with head=$CURRENT_HEAD, critical=0, high=0" >&2
  exit 2
fi

# ─── Evidence fresh? ─────────────────────────────────────────────────────────
# stat -f on macOS/BSD; stat -c on Linux. Try both.
if stat -f %m "$EVIDENCE" >/dev/null 2>&1; then
  EVIDENCE_MTIME=$(stat -f %m "$EVIDENCE")
else
  EVIDENCE_MTIME=$(stat -c %Y "$EVIDENCE")
fi
AGE=$(( $(date +%s) - EVIDENCE_MTIME ))
if [ "$AGE" -gt "$MAX_AGE" ]; then
  echo "BLOCK: Compliance evidence is $AGE seconds old (limit $MAX_AGE). Re-run audit against HEAD $CURRENT_HEAD." >&2
  exit 2
fi

# ─── Head matches? ───────────────────────────────────────────────────────────
EVIDENCE_HEAD=$(python3 -c "import json; d=json.load(open('$EVIDENCE')); print(d.get('head',''))")
if [ -n "$CURRENT_HEAD" ] && [ -n "$EVIDENCE_HEAD" ]; then
  case "$CURRENT_HEAD" in
    "$EVIDENCE_HEAD"*) ;;
    *)
      case "$EVIDENCE_HEAD" in
        "$CURRENT_HEAD"*) ;;
        *)
          echo "BLOCK: Evidence head ($EVIDENCE_HEAD) does not match current HEAD ($CURRENT_HEAD). Re-audit the new commits." >&2
          exit 2
          ;;
      esac
      ;;
  esac
fi

# ─── Findings gates ──────────────────────────────────────────────────────────
CRITICAL=$(python3 -c "import json; d=json.load(open('$EVIDENCE')); print(d.get('critical',0))")
HIGH=$(python3 -c "import json; d=json.load(open('$EVIDENCE')); print(d.get('high',0))")

if [ "$CRITICAL" -gt "$MAX_CRITICAL" ]; then
  echo "BLOCK: Evidence shows $CRITICAL Critical findings (limit $MAX_CRITICAL)." >&2
  exit 2
fi
if [ "$HIGH" -gt "$MAX_HIGH" ]; then
  echo "BLOCK: Evidence shows $HIGH High findings (limit $MAX_HIGH)." >&2
  exit 2
fi

# ─── Optional smoke-test check ───────────────────────────────────────────────
if [ -n "$SMOKE_EXPECTED" ]; then
  SMOKE=$(python3 -c "import json; d=json.load(open('$EVIDENCE')); print(d.get('smoke_test',''))")
  if [ "$SMOKE" != "$SMOKE_EXPECTED" ]; then
    echo "BLOCK: Evidence smoke_test is '$SMOKE', expected '$SMOKE_EXPECTED'." >&2
    exit 2
  fi
fi

# ─── Optional tsc check ──────────────────────────────────────────────────────
if [ "$TSC_REQUIRED" = "1" ]; then
  TSC=$(python3 -c "import json; d=json.load(open('$EVIDENCE')); print(d.get('tsc',''))")
  if [ "$TSC" != "clean" ]; then
    echo "BLOCK: Evidence tsc is '$TSC', expected 'clean'." >&2
    exit 2
  fi
fi

# ─── Pass ────────────────────────────────────────────────────────────────────
echo "Compliance gate passed: repo=$REPO_PATH head=$CURRENT_HEAD age=${AGE}s critical=$CRITICAL high=$HIGH"
