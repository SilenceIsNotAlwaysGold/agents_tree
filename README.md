# agents_tree

`agents_tree` is a minimal reference implementation for using `Cursor` as a parent orchestrator and `Codex CLI` as a delegated subagent.

The core idea is simple:

- the parent agent defines the task, scope, and constraints
- a wrapper script converts that task into a stable `codex exec` invocation
- Codex runs in either read-only mode or a writable isolated worktree
- the run emits durable artifacts such as `summary.md`, `result.json`, and `diff.patch`

This repository packages the implementation logic and the helper files required to reproduce that flow.

## Repository Layout

- `scripts/codex-subagent.ps1`: PowerShell wrapper that launches `Codex CLI`
- `tools/codex-subagent-prompt.md`: prompt template for delegated runs
- `tools/codex-task.example.json`: task spec example
- `docs/implementation.md`: architecture, execution flow, and practical notes

## Workflow

```mermaid
flowchart LR
    Parent[ParentAgent] --> TaskJson[TaskSpecJson]
    TaskJson --> Wrapper[PowerShellWrapper]
    Wrapper -->|optional| Worktree[GitWorktree]
    Wrapper --> Codex[CodexExec]
    Codex --> Summary[summary.md]
    Codex --> Result[result.json]
    Codex --> Patch[diff.patch]
    Summary --> Parent
    Result --> Parent
    Patch --> Parent
```

## Requirements

- Windows PowerShell
- `git`
- `node` and `npm`
- `Codex CLI`

Install Codex CLI:

```powershell
npm install -g @openai/codex
codex login
```

Codex CLI supports non-interactive execution via `codex exec`, which is what this repository uses for automation. See the upstream project and official docs for the base CLI behavior: [openai/codex](https://github.com/openai/codex) and the OpenAI docs for [non-interactive mode](https://developers.openai.com/codex/noninteractive) and the [CLI reference](https://developers.openai.com/codex/cli/reference).

## Quick Start

Run a task in writable mode:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\codex-subagent.ps1 `
  -TaskFile .\tools\codex-task.example.json
```

Run a task in read-only mode:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\codex-subagent.ps1 `
  -TaskFile .\tools\codex-task.example.json `
  -Readonly
```

Run directly in the current repository instead of an isolated worktree:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\codex-subagent.ps1 `
  -TaskFile .\tools\codex-task.example.json `
  -NoWorktree
```

## What The Script Produces

Each task writes output under its configured `output_dir`:

- `prompt.md`
- `summary.md`
- `codex.stdout.log`
- `codex.stderr.log`
- `git-status-before.txt`
- `git-status.txt`
- `diff.patch`
- `result.json`

The wrapper captures both the baseline dirty state and the post-run dirty state so the parent agent can distinguish:

- files that were already dirty before the run
- files that are dirty after the run
- files that changed because of the delegated task

## Notes

- The implementation is intentionally minimal and favors scriptability over deep editor integration.
- On Windows, worktree and sandbox behavior can surface edge cases around `git safe.directory` and PowerShell policy constraints. Those trade-offs are documented in `docs/implementation.md`.
