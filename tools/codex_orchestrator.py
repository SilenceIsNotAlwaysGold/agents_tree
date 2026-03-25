#!/usr/bin/env python3
"""Generate task specs and launch the Codex subagent wrapper."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Any


def slugify(value: str) -> str:
    lowered = value.strip().lower()
    safe = []
    previous_dash = False
    for char in lowered:
        if char.isalnum() or char in {".", "_", "-"}:
            safe.append(char)
            previous_dash = False
            continue
        if not previous_dash:
            safe.append("-")
            previous_dash = True
    slug = "".join(safe).strip("-")
    return slug or "codex-task"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Create a task JSON and run scripts/codex-subagent.ps1."
    )
    parser.add_argument("--goal", required=True, help="Delegated task goal")
    parser.add_argument("--task-id", help="Optional stable task identifier")
    parser.add_argument(
        "--scope",
        action="append",
        default=[],
        help="Repeatable file or directory scope entry",
    )
    parser.add_argument(
        "--constraint",
        action="append",
        default=[],
        help="Repeatable task constraint",
    )
    parser.add_argument(
        "--validate",
        action="append",
        default=[],
        help="Repeatable validation command",
    )
    parser.add_argument(
        "--base-branch",
        default="main",
        help="Base ref for worktree creation",
    )
    parser.add_argument(
        "--output-dir",
        help="Override output directory under .tmp/codex/results/",
    )
    parser.add_argument(
        "--readonly",
        action="store_true",
        help="Run the child task in read-only mode",
    )
    parser.add_argument(
        "--no-worktree",
        action="store_true",
        help="Run in the current repository instead of a fresh worktree",
    )
    parser.add_argument(
        "--model",
        help="Optional Codex model override",
    )
    parser.add_argument(
        "--codex-command",
        default="codex",
        help="Codex command name or path",
    )
    parser.add_argument(
        "--repo-root",
        help="Target repository root (defaults to the agents_tree repo root)",
    )
    parser.add_argument(
        "--prompt-template",
        help="Path to a custom prompt template (defaults to tools/codex-subagent-prompt.md)",
    )
    parser.add_argument(
        "--context-file",
        action="append",
        default=[],
        help="Repeatable path to a project context file injected into the prompt",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=0,
        help="Timeout in seconds for the Codex run (0 = no timeout)",
    )
    parser.add_argument(
        "--max-retries",
        type=int,
        default=0,
        help="Number of retries with exponential backoff on transient API errors (0 = no retry)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Write the task file and print the wrapper command without executing it",
    )
    return parser.parse_args()


def build_task(args: argparse.Namespace, repo_root: Path) -> dict[str, Any]:
    task_id = args.task_id or slugify(args.goal)
    output_dir = args.output_dir or f".tmp/codex/results/{task_id}"
    task: dict[str, Any] = {
        "task_id": task_id,
        "repo_root": str(repo_root),
        "goal": args.goal,
        "scope": args.scope,
        "constraints": args.constraint,
        "validation_commands": args.validate,
        "base_branch": args.base_branch,
        "output_dir": output_dir,
    }
    if args.context_file:
        task["context_files"] = args.context_file
    if args.prompt_template:
        task["prompt_template"] = args.prompt_template
    return task


def write_task_file(repo_root: Path, task: dict[str, Any]) -> Path:
    tasks_dir = repo_root / ".tmp" / "codex" / "tasks"
    tasks_dir.mkdir(parents=True, exist_ok=True)
    task_file = tasks_dir / f"{task['task_id']}.json"
    task_file.write_text(json.dumps(task, indent=2) + "\n", encoding="utf-8")
    return task_file


def build_wrapper_command(args: argparse.Namespace, agents_tree_root: Path, task_file: Path) -> list[str]:
    command = [
        "powershell",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(agents_tree_root / "scripts" / "codex-subagent.ps1"),
        "-TaskFile",
        str(task_file),
        "-CodexCommand",
        args.codex_command,
    ]
    if args.readonly:
        command.append("-Readonly")
    if args.no_worktree:
        command.append("-NoWorktree")
    if args.model:
        command.extend(["-Model", args.model])
    if args.prompt_template:
        command.extend(["-PromptTemplate", args.prompt_template])
    if args.timeout > 0:
        command.extend(["-Timeout", str(args.timeout)])
    if args.max_retries > 0:
        command.extend(["-MaxRetries", str(args.max_retries)])
    return command


def main() -> int:
    args = parse_args()
    agents_tree_root = Path(__file__).resolve().parents[1]
    repo_root = Path(args.repo_root).resolve() if args.repo_root else agents_tree_root
    task = build_task(args, repo_root)
    task_file = write_task_file(repo_root, task)
    command = build_wrapper_command(args, agents_tree_root, task_file)

    print(f"[orchestrator] repo_root: {repo_root}")
    print(f"[orchestrator] task file: {task_file}")
    print("[orchestrator] command:")
    print(" ".join(f'"{part}"' if " " in part else part for part in command))

    if args.dry_run:
        return 0

    result = subprocess.run(command, cwd=repo_root)

    output_dir = repo_root / task["output_dir"]
    result_file = output_dir / "result.json"
    summary_file = output_dir / "summary.md"

    if result_file.exists():
        print(f"[orchestrator] result: {result_file}")
        try:
            payload = json.loads(result_file.read_text(encoding="utf-8"))
            changed = payload.get("changed_files", [])
            print(f"[orchestrator] status: {payload.get('status')}")
            print(f"[orchestrator] changed_files: {changed}")
        except json.JSONDecodeError:
            print("[orchestrator] warning: result.json was not valid JSON", file=sys.stderr)

    if summary_file.exists():
        print(f"[orchestrator] summary: {summary_file}")

    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
