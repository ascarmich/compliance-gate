# Installing compliance-gate in APEX (3 instances + harness)

APEX runs 3 worker instances and 1 harness, each with its own `package.json`
and its own `.claude/` directory. The hook script is identical across all
four; the per-instance tuning happens in each `settings.json` via env vars.

## One-time artifact placement

In each of the 4 `.claude/` dirs (3 APEX instances + harness):

```bash
mkdir -p .claude/hooks
cp /path/to/cos/tools/compliance-gate/compliance-gate.sh .claude/hooks/
chmod +x .claude/hooks/compliance-gate.sh
```

If APEX already has a `.claude/hooks/compliance-gate.sh`, back it up first —
this script will overwrite.

## Wire into settings.json

Add a `PreToolUse` matcher-block for `Bash` in each instance's `settings.json`.
If a `PreToolUse` block already exists, append this hook entry; do NOT replace
existing hooks.

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/compliance-gate.sh\"",
            "statusMessage": "Checking compliance gate..."
          }
        ]
      }
    ]
  }
}
```

## Per-instance tuning

Each APEX instance can configure the gate differently by setting env vars
**inside the command string** (bash-level exports, not a separate block):

### Example: APEX instance A (TS + smoke test)
```json
{
  "type": "command",
  "command": "COMPLIANCE_SMOKE_EXPECTED='12/12 passed' COMPLIANCE_TSC_REQUIRED=1 bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/compliance-gate.sh\""
}
```

### Example: APEX instance B (no smoke test, TS only)
```json
{
  "type": "command",
  "command": "COMPLIANCE_TSC_REQUIRED=1 bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/compliance-gate.sh\""
}
```

### Example: APEX harness (no TS, smoke test only)
```json
{
  "type": "command",
  "command": "COMPLIANCE_SMOKE_EXPECTED='All harness checks passed' bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/compliance-gate.sh\""
}
```

### Example: shared evidence path across instances
If you want the 3 instances to write to per-instance evidence files instead of
sharing `/tmp/compliance-gate-evidence.json`:
```json
{
  "command": "COMPLIANCE_EVIDENCE_PATH='/tmp/compliance-gate-evidence-apex-a.json' bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/compliance-gate.sh\""
}
```

Each instance uses its own path. Recommended if the 3 instances could push
concurrently.

See `evidence-schema.md` for the full env-var reference.

## Agent-side workflow

Agents running inside APEX must write the evidence JSON themselves before any
`git push`. Suggested flow:

1. Agent finishes implementation, commits.
2. Agent runs `npx tsc --noEmit` (if TS), captures pass/fail.
3. Agent runs the instance's smoke test, captures exact output string.
4. Agent spawns `compliance-auditor` subagent on the diff; captures
   `critical` + `high` counts.
5. Agent writes evidence:
   ```bash
   cat > "$COMPLIANCE_EVIDENCE_PATH" <<EOF
   { "head": "$(git rev-parse HEAD)", "critical": 0, "high": 0,
     "smoke_test": "12/12 passed", "tsc": "clean" }
   EOF
   ```
6. Agent runs `git push`. Hook reads evidence, matches HEAD, passes push.

If any step fails, evidence is not written (or is written with failing
counts) and push is blocked.

## Validation after install

Quickly verify the hook fires in each instance:

```bash
# In the instance's repo:
rm -f /tmp/compliance-gate-evidence.json
git push origin main  # should be BLOCKED with a readable stderr message
```

Then write a valid evidence file for HEAD and retry; push should pass.

## Upgrading

The script is version-free (no metadata tag). To upgrade across all 4
instances, replace the file in each `.claude/hooks/` dir. No settings.json
change required unless a new env var is introduced.

## Known gotchas

- `COMPLIANCE_REPO_PATH` is inferred from `cd <path>` in the Bash command
  string OR `$CLAUDE_PROJECT_DIR`. If your push commands don't use `cd` and
  `CLAUDE_PROJECT_DIR` isn't set, override with an explicit env var.
- `python3` must be available on PATH (used for JSON parse + shlex tokenize).
- Evidence files in `/tmp` disappear on macOS reboot. Fine for the daily
  workflow; don't treat them as a persistent audit log.
- The gate cannot distinguish `git push --dry-run` from a real push. If you
  rely on `--dry-run` for diagnostics, either expect it to be blocked or add
  an exception in the tokenizer (not currently implemented).
