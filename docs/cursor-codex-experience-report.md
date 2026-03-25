# Cursor 调用 Codex 实战经验报告

> 本文档基于 Autofish SaaS 项目的实际开发过程，总结了使用 agents_tree 工具链（Cursor + Codex CLI）协作开发中遇到的问题、解决方案和最佳实践。

---

## 一、项目背景

Autofish 是一个基于 FastAPI + Vue 3 的 SaaS 平台，用于闲鱼商品的自动化管理与发布。在开发过程中，我们采用了 `agents_tree` 工具链进行 AI 协作开发：

- **Cursor** 作为父编排器（Parent Orchestrator），负责整体任务规划、代码审查和最终集成
- **Codex CLI** 作为子代理（Subagent），负责执行具体的编码任务

项目涉及的任务包括：

- 项目结构重组（从单体 Flask 迁移到 FastAPI + Vue 前后端分离架构）
- Vue 3 前端脚手架搭建（Vite + Element Plus + Pinia）
- SQLAlchemy ORM 数据模型定义与迁移
- JWT 认证系统实现
- 统一账号中心设计与开发
- 闲鱼适配器迁移（从直接调用改为适配器模式）
- 前端页面开发（商品管理、数据分析、账号管理等）

整个开发过程中，我们编排了 **12+ 个 Codex 任务**，分 **3 个批次** 执行，覆盖后端 API、前端页面和集成测试等多个层面。

---

## 二、遇到的问题及解决方案

### 问题 1：Codex API 503 熔断

**现象**：Codex CLI 执行过程中突然中断，错误信息显示 "所有供应商已熔断，无可用渠道"（HTTP 503 Service Unavailable）。

**影响**：
- 任务执行到一半被强制中断
- `summary.md` 输出为空文件
- 已完成的部分代码修改丢失（未被 diff.patch 捕获）

**根因分析**：Codex API 后端的供应商负载均衡策略触发了熔断保护，通常发生在高并发时段或连续大量请求之后。

**解决方案**：
1. **立即降级**：当 Codex 不可用时，Cursor 自身继续执行剩余任务，不阻塞整体进度
2. **重试策略**：在 PS1 脚本中增加自动重试逻辑（指数退避）
3. **任务拆分**：将大任务拆分为更小的子任务，减少单次 API 调用的持续时间

**建议**：
- 在 `codex-subagent.ps1` 中增加 `-MaxRetries` 参数，默认 3 次重试
- 在 orchestrator 层面实现任务级别的重试，而非 API 调用级别
- 监控 API 可用性，在熔断期间自动暂停任务队列

---

### 问题 2：codex_exit_code 始终为 null

**现象**：`result.json` 中的 `codex_exit_code` 字段始终为 `null`，无论 Codex 任务成功还是失败。

```json
{
  "codex_exit_code": null,
  "status": "failed",
  "summary": "..."
}
```

**影响**：
- Cursor 父代理无法准确判断子任务的执行状态
- 所有任务都被标记为 "failed"，即使实际上已成功完成
- 需要人工检查 `summary.md` 和 `diff.patch` 来判断真实结果

**根因分析**：PowerShell 脚本中使用 `Start-Process` 启动 Codex CLI，但获取进程退出码的方式存在问题。`Start-Process` 返回的 `Process` 对象在进程结束后，其 `ExitCode` 属性可能不可访问（取决于 `-Wait` 参数和 `-PassThru` 参数的组合方式）。

**解决方案**（待实施）：
```powershell
# 修改前（有问题）
$process = Start-Process -FilePath "codex" -ArgumentList $args -PassThru
$process.WaitForExit()
$exitCode = $process.ExitCode  # 可能为 null

# 修改后（推荐）
$process = Start-Process -FilePath "codex" -ArgumentList $args -PassThru -Wait
$exitCode = $process.ExitCode  # 现在能正确获取

# 或者使用 & 运算符直接执行
& codex exec @args
$exitCode = $LASTEXITCODE  # PowerShell 内置变量
```

**状态**：已知问题，暂未修复。当前通过检查 `summary.md` 是否非空来间接判断成功/失败。

---

### 问题 3：UTF-8 编码问题

**现象**：`summary.md` 中的中文内容显示为乱码。例如：
- 破折号 "—" 变成 "鈥?"
- 中文字符部分丢失或变成问号

**根因分析**：
1. PowerShell 的 `Set-Content -Encoding UTF8` 默认写入 **带 BOM（Byte Order Mark）** 的 UTF-8 格式
2. `Get-Content` 在读取 **不带 BOM** 的 UTF-8 文件时，可能使用系统默认编码（如 GBK / Windows-1252）进行解码
3. Codex CLI 输出的是标准 UTF-8（无 BOM），但 PowerShell 写入文件时添加了 BOM，导致编码混乱

**解决方案**：改用 .NET Framework 原生方法操作文件，显式指定无 BOM 的 UTF-8 编码：

```powershell
# 读取文件（兼容有 BOM 和无 BOM）
$content = [System.IO.File]::ReadAllText($filePath, [System.Text.Encoding]::UTF8)

# 写入文件（无 BOM）
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($filePath, $content, $utf8NoBom)
```

**关键要点**：
- `[System.Text.UTF8Encoding]::new($false)` 中的 `$false` 参数表示不写入 BOM
- 避免使用 PowerShell 的 `Set-Content` / `Out-File` 处理需要精确控制编码的场景
- 在脚本开头统一设置 `$OutputEncoding = [System.Text.Encoding]::UTF8`

**状态**：已修复并提交。

---

### 问题 4：双重超时冲突

**现象**：Codex 任务明明已经完成，但 PS1 脚本的后处理阶段（收集 diff、生成 result.json）被 Python orchestrator 的 `subprocess.run(timeout=...)` 提前杀死。

**时序图**：
```
Python orchestrator ──────────────────── timeout! kill ──┐
  └─ PS1 脚本 ──────────────────────────────────────────│─── 被杀死
       └─ Codex CLI ───── 完成 ─── 后处理中... ────────┘
```

**根因分析**：
- Python 的 `codex_orchestrator.py` 在 `subprocess.run()` 中设置了 `timeout` 参数
- PS1 脚本自身也有 `-Timeout` 参数控制 Codex CLI 的执行时间
- 当 Codex 在接近 Python 超时阈值时完成任务，PS1 脚本进入后处理阶段（收集 git diff、生成 summary 等），此时 Python 层的超时触发，直接终止整个 PS1 进程
- 后果：Codex 的输出已产生，但 `result.json` 和 `diff.patch` 未生成

**解决方案**：移除 Python 层的超时控制，将超时管理完全委托给 PS1 脚本：

```python
# 修改前
result = subprocess.run(cmd, timeout=timeout_seconds, ...)

# 修改后
result = subprocess.run(cmd, ...)  # 不设 timeout，由 PS1 脚本管理
```

PS1 脚本的 `-Timeout` 参数只控制 Codex CLI 本身的执行时间，后处理步骤不受超时限制。

**状态**：已修复并提交。

---

### 问题 5：并行任务无隔离导致冲突

**现象**：两个使用 `--no-worktree` 参数的 Codex 任务同时执行时，两者都在同一个工作区目录中修改文件。`changed_files` 列表互相污染——任务 A 的 diff 包含了任务 B 的修改，反之亦然。

**影响**：
- 无法准确归因哪些修改属于哪个任务
- `diff.patch` 可能包含冲突的修改
- 合并结果不可预测

**根因分析**：`--no-worktree` 模式下，所有任务共享同一个 Git 工作目录。Git 的暂存区（staging area）和工作树（working tree）是全局状态，多个并发写入者会互相干扰。

**解决方案**：
1. **并行任务必须使用 worktree**：每个任务在独立的 Git worktree 中执行，天然隔离
2. **串行执行无隔离任务**：如果确实需要 `--no-worktree`，则在 orchestrator 中串行执行
3. **Orchestrator 默认策略**：`batch_runner.py` 默认使用 worktree 模式

```python
# batch_runner.py 中的安全检查
if parallel and any(task.get("no_worktree") for task in tasks):
    raise ValueError("并行任务不允许使用 --no-worktree，请使用 worktree 隔离")
```

**建议**：orchestrator 默认使用 worktree，只有明确指定 `--no-worktree` 时才跳过隔离——并且此时自动切换为串行执行。

---

### 问题 6：npm create vue 交互式阻塞

**现象**：在 Codex 沙箱中执行 `npm create vue@latest` 时，命令阻塞等待用户交互输入（选择 TypeScript / Router / Pinia 等选项），导致任务超时。

**影响**：
- Codex 无法完成前端脚手架创建
- 整个任务超时失败
- 沙箱环境通常没有网络访问权限，即使不阻塞也无法下载依赖

**根因分析**：
1. Codex 的沙箱执行环境设计为安全隔离，默认不提供网络访问
2. `npm create vue@latest` 是一个交互式命令，需要 TTY 输入
3. 沙箱中没有 TTY，命令直接挂起

**解决方案**：
1. **Codex 自动降级**：Codex 检测到无法执行时，手动创建所需的文件结构（`package.json`, `vite.config.ts`, `src/main.ts` 等）
2. **在 Cursor 端直接创建**：将前端脚手架创建任务留给 Cursor 父代理，因为 Cursor 拥有完整的系统访问权限
3. **预生成模板**：准备好项目模板，Codex 只需复制和定制

**建议**：对于需要以下能力的任务，不适合委托给 Codex 沙箱：
- 网络访问（npm install, pip install, API 调用）
- 交互式命令（CLI 向导、确认提示）
- 系统服务（数据库连接、Docker 操作）

---

### 问题 7：Worktree 合并工作流

**现象**：Codex 在 worktree 中完成工作后，修改的文件留在 worktree 目录中，不会自动提交到分支或合并回主工作区。开发者需要手动处理合并。

**影响**：
- 每次任务完成后需要手动 `cp` 或 `cherry-pick` 文件
- 多个 worktree 任务完成后，合并顺序可能产生冲突
- 增加了人工操作的负担

**当前工作流**：
```powershell
# 1. Codex 在 worktree 中完成任务
# 2. 手动检查 worktree 中的修改
cd .tmp/codex-worktree-xxx
git diff

# 3. 复制文件回主工作区
cp -r backend/* ../../../backend/

# 4. 在主工作区提交
cd ../../..
git add -A
git commit -m "feat: integrate codex task output"
```

**建议改进**：在 PS1 脚本中增加自动合并选项：

```powershell
# 新增 -AutoMerge 参数
param(
    [switch]$AutoMerge
)

if ($AutoMerge) {
    # 在 worktree 中提交
    git -C $worktreePath add -A
    git -C $worktreePath commit -m "codex: $taskDescription"

    # 切回主分支并合并
    git merge $worktreeBranch --no-ff -m "merge: codex task - $taskDescription"

    # 清理 worktree
    git worktree remove $worktreePath
}
```

---

## 三、最佳实践总结

### 1. 任务粒度控制

单个 Codex 任务应该控制在 **5-15 个文件** 的修改范围内。

- **太小**（1-2 个文件）：编排开销大于收益，不如 Cursor 直接做
- **合适**（5-15 个文件）：Codex 能充分理解上下文，且不容易超时
- **太大**（20+ 个文件）：容易超时、遇到 API 限制、上下文窗口溢出

实际经验：Autofish 项目中，我们将整体开发拆分为 3 个批次，每个批次包含 3-5 个任务，每个任务处理一个功能模块。

### 2. 混合执行策略

Codex API 不稳定时（503 熔断、网络超时），Cursor 应该能够无缝接管：

```
正常模式：Cursor → 编排 → Codex 执行 → 结果收集
降级模式：Cursor → 直接使用 Task subagent 执行 → 结果收集
```

关键原则：**不要让工具链的不稳定性阻塞项目进度**。Cursor 本身就是一个强大的编码代理，Codex 是加速器而非必需品。

### 3. Worktree 优先原则

并行任务 **必须** 使用 worktree 隔离，避免脏文件互相污染。

| 场景 | 推荐模式 | 原因 |
|------|----------|------|
| 并行执行多个任务 | worktree | 避免工作区冲突 |
| 单个只读分析任务 | --no-worktree --readonly | 无修改，无冲突风险 |
| 单个写入任务（串行）| --no-worktree | 简单直接，无需合并 |
| 需要保留完整 git 历史 | worktree | 可独立提交和追溯 |

### 4. 验证命令

每个任务都应带 `--validate` 参数，确保 Codex 产出的代码可正常工作：

```json
{
  "goal": "实现用户认证 API",
  "validate": "cd backend && python -c 'from app.api.auth import router; print(\"OK\")'"
}
```

常用验证命令：
- Python 模块：`python -c 'import module; print("OK")'`
- 语法检查：`python -m py_compile file.py`
- 测试运行：`pytest tests/test_specific.py -x`
- 前端构建：`cd frontend && npx vue-tsc --noEmit`

### 5. 导入路径修复

大规模重构后（如从 `src/` 迁移到 `backend/app/`），import 路径会大量失效。最高效的修复方式是编写 Python 脚本批量替换：

```python
import os
import re

replacements = {
    "from src.": "from app.",
    "from src import": "from app import",
    "import src.": "import app.",
}

for root, dirs, files in os.walk("backend/app"):
    for f in files:
        if f.endswith(".py"):
            path = os.path.join(root, f)
            content = open(path, "r", encoding="utf-8").read()
            for old, new in replacements.items():
                content = content.replace(old, new)
            open(path, "w", encoding="utf-8").write(content)
```

### 6. 测试驱动

每完成一个 batch，立即运行 `pytest` 验证：

```bash
# 快速冒烟测试
pytest backend/tests/ -x --tb=short

# 特定模块测试
pytest backend/tests/test_auth.py -v

# 导入检查
python -c "from app.main import app; print('FastAPI app loaded')"
```

快速发现 import 错误、兼容性问题和遗漏的依赖，比等所有任务做完再测试高效得多。

### 7. 上下文传递

通过 `--context-file` 传递项目规划文档，帮助 Codex 理解全局架构：

```powershell
python tools/codex_orchestrator.py `
  --goal "实现商品管理 API" `
  --context-file docs/architecture.md `
  --context-file docs/api-spec.md `
  --scope backend/app/api/ `
  --scope backend/app/models/
```

推荐传递的上下文文件：
- 架构设计文档
- API 规范 / OpenAPI spec
- 数据模型定义
- 编码规范和项目约定

### 8. 监控策略

使用 `block_until_ms: 0` 将 Codex 放入后台执行，通过轮询终端文件监控进度：

```
1. 启动任务（block_until_ms: 0）
2. 等待 10 秒
3. 读取终端文件，检查输出
4. 如果未完成，等待 20 秒后再检查（指数退避）
5. 检测到 exit_code 出现 → 任务完成
6. 读取 summary.md 和 result.json
```

这种异步监控模式避免了 Cursor 长时间阻塞等待，可以在 Codex 执行期间进行其他工作。

---

## 四、已完成的改动清单

### 1. `scripts/codex-subagent.ps1`

| 改动 | 说明 |
|------|------|
| UTF-8 无 BOM 编码修复 | 使用 `[System.IO.File]::WriteAllText` 替代 `Set-Content`，避免 BOM 导致的中文乱码 |
| 超时处理参数 (`-Timeout`) | 新增 `-Timeout` 参数，控制 Codex CLI 的最大执行时间（秒） |
| 未跟踪文件纳入 diff.patch | `git diff` 现在包含 `--cached` 和未暂存文件，同时收集新增的未跟踪文件 |
| 验证命令执行和结果报告 | 支持在 Codex 完成后执行验证命令，将验证结果写入 `result.json` |

### 2. `tools/codex_orchestrator.py`

| 改动 | 说明 |
|------|------|
| 跨仓库使用 (`--repo-root`) | 支持在其他仓库中执行 Codex 任务，不限于 agents_tree 本身 |
| 上下文文件注入 (`--context-file`) | 将指定文件内容注入到 Codex 的 prompt 中，提供额外上下文 |
| 超时参数透传 (`--timeout`) | 将超时设置传递给 PS1 脚本的 `-Timeout` 参数 |
| 移除 Python 层超时 | 避免与 PS1 脚本的超时机制冲突（双重超时问题） |

### 3. `tools/codex-subagent-prompt.md`

| 改动 | 说明 |
|------|------|
| 增加 Project Context 区域 | 新增 `{{PROJECT_CONTEXT}}` 占位符，用于注入项目级别的上下文信息 |

### 4. `tools/batch_runner.py`（新增）

| 功能 | 说明 |
|------|------|
| 批量并行任务执行 | 支持同时启动多个 Codex 任务，每个任务在独立 worktree 中运行 |
| 依赖管理（拓扑排序） | 任务之间可以声明依赖关系，自动按依赖顺序执行 |
| 合并结果报告 | 所有任务完成后，生成统一的汇总报告 |

### 5. `tools/batch-task.example.json`（新增）

提供了批量任务配置的示例文件，展示如何定义多个任务及其依赖关系。

### 6. `docs/implementation.md`

| 改动 | 说明 |
|------|------|
| 跨仓库使用文档 | 补充了 `--repo-root` 的使用说明和示例 |
| 批量执行文档 | 添加了 `batch_runner.py` 的使用说明 |
| 超时和验证文档 | 补充了超时配置和验证命令的最佳实践 |

---

## 五、待改进项

### 优先级高

1. **修复 codex_exit_code 为 null 的问题**
   - 使用 `$LASTEXITCODE` 或正确的 `Start-Process -PassThru -Wait` 模式
   - 影响：所有任务状态判断的准确性

2. **增加 API 503 自动重试（指数退避）**
   - 实现：在 PS1 脚本中添加 retry loop，间隔 30s / 60s / 120s
   - 影响：减少因临时 API 故障导致的任务失败

### 优先级中

3. **Worktree 自动合并选项**
   - 实现：`-AutoMerge` 参数，自动 commit + merge 回主分支
   - 影响：减少手动合并操作

4. **更好的进度反馈**
   - 当前：轮询终端文件，只能看到最终输出
   - 目标：实时流式输出，类似 `tail -f`
   - 方案：使用 named pipe 或 WebSocket 推送

### 优先级低

5. **支持 Linux / macOS**
   - 当前仅支持 PowerShell (Windows)
   - 方案：提供等效的 Bash 脚本，或使用 PowerShell Core 跨平台
   - 注意：Git worktree 和文件路径处理需要适配

6. **任务模板库**
   - 预定义常见任务模板（API 开发、前端页面、数据库迁移等）
   - 减少重复编写任务描述的工作量

7. **成本追踪**
   - 记录每个 Codex 任务消耗的 token 数和 API 调用次数
   - 帮助优化任务粒度和成本控制

---

## 附录：Autofish 项目任务执行记录

| 批次 | 任务 | 状态 | 执行方式 | 备注 |
|------|------|------|----------|------|
| Batch 1 | 项目结构重组 | ✅ 完成 | Codex worktree | 后端目录结构迁移 |
| Batch 1 | SQLAlchemy ORM 模型 | ✅ 完成 | Codex worktree | 数据模型定义 |
| Batch 1 | JWT 认证系统 | ✅ 完成 | Codex worktree | 登录/注册/Token 刷新 |
| Batch 2 | Vue 前端脚手架 | ✅ 完成 | Cursor 直接执行 | Codex 沙箱无法 npm create |
| Batch 2 | 闲鱼适配器迁移 | ✅ 完成 | Codex no-worktree | 适配器模式重构 |
| Batch 2 | 统一账号中心 | ✅ 完成 | Codex worktree | 多平台账号管理 |
| Batch 3 | 前端商品管理页面 | ✅ 完成 | Cursor 直接执行 | Element Plus 表格/表单 |
| Batch 3 | 前端数据分析页面 | ✅ 完成 | Cursor 直接执行 | ECharts 图表集成 |
| Batch 3 | API 集成测试 | ✅ 完成 | Codex worktree | pytest 测试套件 |
| - | Import 路径修复 | ✅ 完成 | Python 脚本 | 批量替换 src → app |
| - | 依赖整理 | ✅ 完成 | Cursor 直接执行 | requirements.txt 更新 |
| - | 文档编写 | ✅ 完成 | Cursor 直接执行 | API 文档和部署指南 |
