#!/usr/bin/env python3
"""Run multiple Codex tasks in parallel with dependency management.

Usage:
    python batch_runner.py --batch-file batch.json
    python batch_runner.py --batch-file batch.json --max-parallel 2 --dry-run

Batch file format:
{
  "defaults": {
    "repo_root": "c:/Users/clouditera/project/autofish",
    "base_branch": "main",
    "no_worktree": true,
    "context_files": ["docs/autofish-saas-roadmap.md"]
  },
  "tasks": [
    {
      "task_id": "p0-1",
      "goal": "...",
      "scope": ["app.py", "src/"],
      "depends_on": [],
      "validation_commands": ["pytest tests/ -q"]
    },
    {
      "task_id": "p1-3",
      "goal": "...",
      "depends_on": [],
    },
    {
      "task_id": "p0-2",
      "depends_on": ["p0-1"],
      ...
    }
  ]
}
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path
from typing import Any


def load_batch(batch_file: Path) -> dict[str, Any]:
    return json.loads(batch_file.read_text(encoding="utf-8"))


def merge_defaults(task: dict[str, Any], defaults: dict[str, Any]) -> dict[str, Any]:
    merged = {**defaults, **task}
    if "context_files" in defaults and "context_files" in task:
        merged["context_files"] = defaults["context_files"] + task.get("context_files", [])
    return merged


def resolve_execution_order(tasks: list[dict[str, Any]]) -> list[list[str]]:
    """Topological sort into parallel batches."""
    task_map = {t["task_id"]: t for t in tasks}
    completed: set[str] = set()
    batches: list[list[str]] = []

    remaining = set(task_map.keys())
    while remaining:
        ready = []
        for tid in remaining:
            deps = set(task_map[tid].get("depends_on", []))
            if deps.issubset(completed):
                ready.append(tid)

        if not ready:
            unresolved = remaining - completed
            raise ValueError(
                f"Circular or unsatisfied dependencies: {unresolved}. "
                f"Completed: {completed}"
            )

        batches.append(sorted(ready))
        completed.update(ready)
        remaining -= set(ready)

    return batches


def run_single_task(
    agents_tree_root: Path,
    task: dict[str, Any],
    dry_run: bool = False,
    timeout: int = 0,
) -> dict[str, Any]:
    """Run one task via codex_orchestrator.py, return result summary."""
    task_id = task["task_id"]
    repo_root = task.get("repo_root", ".")

    cmd = [
        sys.executable,
        str(agents_tree_root / "tools" / "codex_orchestrator.py"),
        "--goal", task["goal"],
        "--task-id", task_id,
        "--repo-root", str(repo_root),
        "--base-branch", task.get("base_branch", "main"),
    ]

    for scope_item in task.get("scope", []):
        cmd.extend(["--scope", scope_item])

    for constraint in task.get("constraints", []):
        cmd.extend(["--constraint", constraint])

    for validate in task.get("validation_commands", []):
        cmd.extend(["--validate", validate])

    for ctx_file in task.get("context_files", []):
        cmd.extend(["--context-file", ctx_file])

    if task.get("prompt_template"):
        cmd.extend(["--prompt-template", task["prompt_template"]])

    if task.get("no_worktree", False):
        cmd.append("--no-worktree")

    if task.get("readonly", False):
        cmd.append("--readonly")

    if task.get("model"):
        cmd.extend(["--model", task["model"]])

    if timeout > 0:
        cmd.extend(["--timeout", str(timeout)])

    if dry_run:
        cmd.append("--dry-run")

    print(f"[batch] starting: {task_id}")
    start = time.time()

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout if timeout > 0 else None,
        )
        elapsed = time.time() - start
        stdout_tail = result.stdout[-500:] if result.stdout else ""
        stderr_tail = result.stderr[-500:] if result.stderr else ""

        output_dir = Path(repo_root) / f".tmp/codex/results/{task_id}"
        result_file = output_dir / "result.json"
        task_result = None
        if result_file.exists():
            try:
                task_result = json.loads(result_file.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                pass

        status = "success" if result.returncode == 0 else "failed"
        if task_result:
            status = task_result.get("status", status)

        return {
            "task_id": task_id,
            "status": status,
            "exit_code": result.returncode,
            "elapsed_seconds": round(elapsed, 1),
            "stdout_tail": stdout_tail,
            "stderr_tail": stderr_tail,
            "result_file": str(result_file) if result_file.exists() else None,
        }

    except subprocess.TimeoutExpired:
        elapsed = time.time() - start
        return {
            "task_id": task_id,
            "status": "timeout",
            "exit_code": 124,
            "elapsed_seconds": round(elapsed, 1),
            "stdout_tail": "",
            "stderr_tail": f"Timed out after {timeout}s",
            "result_file": None,
        }
    except Exception as e:
        elapsed = time.time() - start
        return {
            "task_id": task_id,
            "status": "error",
            "exit_code": -1,
            "elapsed_seconds": round(elapsed, 1),
            "stdout_tail": "",
            "stderr_tail": str(e),
            "result_file": None,
        }


def print_batch_summary(results: list[dict[str, Any]]) -> None:
    print("\n" + "=" * 60)
    print("BATCH RESULTS")
    print("=" * 60)

    for r in results:
        icon = {
            "success": "OK",
            "failed": "FAIL",
            "validation_failed": "VFAIL",
            "timeout": "TIMEOUT",
            "error": "ERROR",
        }.get(r["status"], "?")

        print(f"  [{icon:>5}] {r['task_id']:<20} ({r['elapsed_seconds']}s)")

    succeeded = sum(1 for r in results if r["status"] == "success")
    total = len(results)
    print(f"\n  {succeeded}/{total} tasks succeeded")
    print("=" * 60)


def main() -> int:
    parser = argparse.ArgumentParser(description="Run Codex tasks in parallel batches")
    parser.add_argument("--batch-file", required=True, help="Path to batch JSON file")
    parser.add_argument("--max-parallel", type=int, default=4, help="Max concurrent tasks")
    parser.add_argument("--timeout", type=int, default=0, help="Per-task timeout in seconds")
    parser.add_argument("--dry-run", action="store_true", help="Print commands without executing")
    parser.add_argument("--stop-on-failure", action="store_true", help="Stop if any task fails")
    args = parser.parse_args()

    batch_file = Path(args.batch_file).resolve()
    batch_data = load_batch(batch_file)
    defaults = batch_data.get("defaults", {})
    tasks = [merge_defaults(t, defaults) for t in batch_data["tasks"]]

    agents_tree_root = Path(__file__).resolve().parents[1]

    batches = resolve_execution_order(tasks)
    task_map = {t["task_id"]: t for t in tasks}
    all_results: list[dict[str, Any]] = []
    failed = False

    for batch_idx, batch_task_ids in enumerate(batches):
        print(f"\n{'='*60}")
        print(f"BATCH {batch_idx + 1}/{len(batches)}: {', '.join(batch_task_ids)}")
        print(f"{'='*60}")

        if failed and args.stop_on_failure:
            print("[batch] skipping due to prior failure")
            for tid in batch_task_ids:
                all_results.append({
                    "task_id": tid, "status": "skipped", "exit_code": -1,
                    "elapsed_seconds": 0, "stdout_tail": "", "stderr_tail": "",
                    "result_file": None,
                })
            continue

        batch_tasks = [task_map[tid] for tid in batch_task_ids]
        batch_results = []

        max_workers = min(args.max_parallel, len(batch_tasks))
        with ProcessPoolExecutor(max_workers=max_workers) as executor:
            futures = {
                executor.submit(
                    run_single_task,
                    agents_tree_root,
                    task,
                    args.dry_run,
                    args.timeout,
                ): task["task_id"]
                for task in batch_tasks
            }

            for future in as_completed(futures):
                task_id = futures[future]
                try:
                    result = future.result()
                except Exception as e:
                    result = {
                        "task_id": task_id, "status": "error", "exit_code": -1,
                        "elapsed_seconds": 0, "stdout_tail": "", "stderr_tail": str(e),
                        "result_file": None,
                    }

                batch_results.append(result)
                icon = "OK" if result["status"] == "success" else "FAIL"
                print(f"[batch] [{icon}] {task_id} ({result['elapsed_seconds']}s)")

                if result["status"] != "success":
                    failed = True

        all_results.extend(batch_results)

    report_path = batch_file.parent / f"{batch_file.stem}-results.json"
    report_path.write_text(json.dumps(all_results, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"\n[batch] full report: {report_path}")

    print_batch_summary(all_results)

    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())
