# Implementation Notes

## Goal

The repository models a parent-child agent system:

- `Cursor` or another primary agent acts as the coordinator
- `Codex CLI` acts as a bounded worker for a single delegated task

The worker contract is intentionally file-based. That makes the system easy to inspect, easy to debug, and independent of private editor APIs.

## Task Contract

The delegated task is a JSON file with these core fields:

- `task_id`
- `repo_root`
- `goal`
- `scope`
- `constraints`
- `validation_commands`
- `base_branch`
- `output_dir`

The wrapper reads that file, expands a prompt template, and feeds the prompt to `codex exec` over standard input.

## Execution Modes

### Read-only

Used for codebase analysis, triage, and summarization.

- enables `--sandbox read-only`
- avoids file edits
- still produces a `summary.md` and a `result.json`

### Writable

Used for bounded implementation tasks.

- defaults to writable sandboxing
- optionally creates a dedicated `git worktree`
- emits a `diff.patch` and dirty-state snapshots for inspection

## Why A Wrapper Script Exists

The wrapper script is doing more than just shelling out to `codex`:

- validates the task spec
- resolves paths relative to the repository root
- optionally creates a dedicated worktree
- builds a stable delegated prompt
- launches `Codex CLI` non-interactively
- stores machine-readable and human-readable artifacts
- computes delta-aware changed-file reporting

That last point matters in real repos because a parent repo can already be dirty before a delegated run starts.

## Dirty State Tracking

The script records:

- `preexisting_changed_files`
- `all_changed_files`
- `changed_files`

`changed_files` is intended to represent only files that changed because of the delegated task, not files that were already dirty before the task began.

To avoid noise, the script filters out common runtime and scratch paths such as:

- `.tmp/`
- `.worktrees/`
- `.venv*`
- `.pytest_cache/`
- `__pycache__/`

## Important Windows Caveats

This repository targets Windows PowerShell because that was the original environment for the prototype.

Two practical issues showed up during implementation:

1. `Codex CLI` and PowerShell output handling can be finicky when native command stderr is treated as a terminating error. The wrapper avoids relying on the `codex.ps1` launcher and calls the CLI entrypoint through `node`.
2. `git worktree` on Windows can interact poorly with sandboxed subprocess ownership checks, especially around `safe.directory`. Read-only or same-worktree runs are therefore useful fallback modes.

## Result File Shape

The wrapper writes a `result.json` with:

- high-level status
- Codex exit code
- read-only vs writable mode
- worktree metadata
- changed file sets
- artifact paths

That gives the parent agent enough structure to:

- decide whether the delegated task succeeded
- read the final summary
- review the patch
- chain another delegated task

## Cross-Repository Usage

The tools support targeting external repositories:

```powershell
python tools/codex_orchestrator.py \
  --repo-root "c:/Users/me/project/my-app" \
  --goal "Refactor the auth module" \
  --scope "src/auth.py" \
  --context-file "docs/architecture.md" \
  --no-worktree
```

The `--context-file` flag injects project documentation into the prompt so Codex has relevant background.

## Batch Execution

`tools/batch_runner.py` runs multiple tasks with dependency management and parallelism:

```powershell
python tools/batch_runner.py --batch-file tasks/my-batch.json --max-parallel 4
```

The batch file declares tasks with `depends_on` arrays. The runner resolves the topological order and runs independent tasks in parallel.

## Timeout, Retry, and Validation

- `--timeout 600` kills the Codex process after 600 seconds
- `--max-retries 3` retries on transient errors (503, 429, rate limits) with exponential backoff (30s → 60s → 120s → 300s cap)
- Retry logic only triggers on detectable transient errors in stderr; permanent failures exit immediately
- `validation_commands` are automatically executed after a successful Codex run
- Results distinguish `success`, `failed`, `validation_failed`, `timeout`, `dep_failed`, and `skipped` status

## Diff Tracking

The wrapper now captures untracked (newly created) files in `diff.patch` by temporarily staging them with `git add --intent-to-add` before diffing, then resetting.

## Dependency-Aware Batch Execution

The batch runner now validates `depends_on` references at startup — if a task refers to a non-existent `task_id`, execution aborts with a clear error before any work is done.

When a task fails, all downstream dependents are automatically skipped with status `dep_failed`, regardless of whether `--stop-on-failure` is set. This prevents wasted API calls on tasks that cannot succeed.

## Exit Code Reliability

The wrapper uses `Start-Process -Wait -PassThru` for the no-timeout path to ensure `$process.ExitCode` is always populated. For the timeout path, an extra `$process.WaitForExit()` call after `WaitForExit(ms)` returns `$true` ensures the handle is fully closed and `ExitCode` is readable. A final null-guard treats any still-null exit code as failure.

## UTF-8 Without BOM

All file writes in the wrapper use `[System.IO.File]::WriteAllText` with `UTF8Encoding($false)`. This includes `prompt.md`, `summary.md`, `result.json`, `git-status-before.txt`, `git-status.txt`, and `diff.patch`. The PowerShell `Set-Content -Encoding UTF8` cmdlet is avoided entirely because it emits a BOM on Windows PowerShell 5.x.

## Components

- `tools/codex_orchestrator.py` — task generation, wrapper invocation, retry pass-through
- `tools/batch_runner.py` — parallel batch execution with dependency validation and failure propagation
- `scripts/codex-subagent.ps1` — core wrapper with process management, retry loop, UTF-8 handling
- `.cursor/rules/codex-delegation.mdc` — persistent delegation guidance inside Cursor
