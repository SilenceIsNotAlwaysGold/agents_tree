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

## Timeout and Validation

- `--timeout 600` kills the Codex process after 600 seconds
- `validation_commands` are automatically executed after a successful Codex run
- Results distinguish `success`, `failed`, and `validation_failed` status

## Diff Tracking

The wrapper now captures untracked (newly created) files in `diff.patch` by temporarily staging them with `git add --intent-to-add` before diffing, then resetting.

## Components

- `tools/codex_orchestrator.py` — task generation, wrapper invocation, timeout
- `tools/batch_runner.py` — parallel batch execution with dependency resolution
- `scripts/codex-subagent.ps1` — core wrapper with process management
- `.cursor/rules/codex-delegation.mdc` — persistent delegation guidance inside Cursor
