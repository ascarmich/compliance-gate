# compliance-gate evidence schema + checks

## What the gate does

`compliance-gate.sh` is a Claude Code `PreToolUse` hook matched to `Bash`. It
fires on every Bash tool call but short-circuits (exit 0) on anything that is
not an actual `git push` (tokenized match, not substring). On `git push`, it
reads an evidence JSON file and passes or blocks the push.

The gate does NOT perform any audit itself. It reads a file you wrote BEFORE
the push, treating that file as proof that the correct steps ran. Freshness +
head-SHA binding prevent stale evidence from unlocking the gate.

## Evidence JSON schema

Default path: `/tmp/compliance-gate-evidence.json` (override with
`COMPLIANCE_EVIDENCE_PATH`).

```json
{
  "head":       "<SHA>",           // required. Full or abbrev SHA of current repo HEAD.
  "critical":   0,                 // required. Count of open Critical findings.
  "high":       0,                 // required. Count of open High findings.
  "smoke_test": "18/18 passed",    // optional. Exact string match if configured.
  "tsc":        "clean"            // optional. Exact "clean" if configured.
}
```

- `head` is compared prefix-wise against `git rev-parse HEAD` in the repo
  being pushed. Short SHAs work.
- `critical` and `high` must be ≤ configured max (default 0 / 0).
- `smoke_test` and `tsc` are checked only if the corresponding config env var
  is set (see below).
- Any other fields are ignored — you can log extras for audit trail.

## Config env vars (set in settings.json hook block)

| Variable                       | Default                                    | Effect |
|--------------------------------|--------------------------------------------|--------|
| `COMPLIANCE_EVIDENCE_PATH`     | `/tmp/compliance-gate-evidence.json`       | Where the gate reads evidence. |
| `COMPLIANCE_REPO_PATH`         | inferred (`cd <path>` → `$CLAUDE_PROJECT_DIR` → `$PWD`) | Which repo to `rev-parse HEAD` on. |
| `COMPLIANCE_MAX_AGE_SECONDS`   | `3600`                                     | Evidence older than this = block. |
| `COMPLIANCE_SMOKE_EXPECTED`    | `""` (skip)                                | Exact string `evidence.smoke_test` must equal. Empty = no check. |
| `COMPLIANCE_TSC_REQUIRED`      | `0` (skip)                                 | `1` = require `evidence.tsc == "clean"`. |
| `COMPLIANCE_MAX_CRITICAL`      | `0`                                        | Max allowed open Critical findings. |
| `COMPLIANCE_MAX_HIGH`          | `0`                                        | Max allowed open High findings. |

Per-instance tuning is the main point: three APEX instances can share the
script but configure different `SMOKE_EXPECTED` values without editing code.

## What each pattern catches

1. **`IS_PUSH` tokenization**: distinguishes `git push` as a command from
   `git push` as a string literal inside another command (e.g. inside a
   `sqlite3` statement or `grep` pattern). Tokenizes via `shlex`. Prevents
   spurious blocks on unrelated Bash calls.

2. **Missing evidence**: first-line gate. Evidence file must exist.

3. **Stale evidence (age)**: if the evidence file is older than
   `COMPLIANCE_MAX_AGE_SECONDS`, block. Catches the case where you ran the
   audit hours ago and drifted. `stat -f` on macOS/BSD, `stat -c` on Linux —
   the script tries both.

4. **Head mismatch**: evidence was bound to a SHA; HEAD has moved since.
   Prefix-match in both directions so short vs. full SHAs work.

5. **Open findings**: `critical` / `high` counts > max. Audit isn't clean;
   push blocked until issues are addressed or recorded as accepted.

6. **Smoke test (optional)**: exact match on `smoke_test` field. Use when
   your repo has a pass/fail string (e.g. "18/18 passed"). Leave
   `SMOKE_EXPECTED` empty to skip.

7. **Tsc clean (optional)**: exact `"clean"` on the `tsc` field. Set
   `COMPLIANCE_TSC_REQUIRED=1` to enforce. Leave unset for non-TS repos.

## Exit codes

- `0` — pass. Push proceeds.
- `2` — block. Reason printed to stderr. Push stops.

The gate prints `stderr` for blocks (Claude Code surfaces this to the user)
and `stdout` for passes (shown as info in the hook chain).

## What the gate does NOT do

- Does not run audits. You (or your agent) must run `tsc`, smoke tests, and
  the compliance-auditor, then write evidence JSON.
- Does not re-run on amended commits unless evidence is rewritten; that's
  by design — evidence is bound to the SHA it attests to.
- Does not touch the network, other repos, or any file outside
  `$COMPLIANCE_EVIDENCE_PATH`.

## How agents should write evidence

After a successful audit run (tsc clean, smoke test passed, compliance-auditor
reported 0 Critical + 0 High):

```bash
cat > /tmp/compliance-gate-evidence.json <<EOF
{
  "head": "$(git rev-parse HEAD)",
  "critical": 0,
  "high": 0,
  "smoke_test": "18/18 passed",
  "tsc": "clean"
}
EOF
```

Then `git push` runs the hook; hook reads the file; file matches HEAD; push
passes. If the agent later commits more changes, the head moves, evidence
is stale, push blocks until re-audit + rewrite.
