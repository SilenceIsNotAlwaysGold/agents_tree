# Cursor + Codex CLI 实际使用经验报告

> 本文档基于使用 `agents_tree` 工具链开发 Autofish SaaS 项目的真实经历，总结遇到的问题、解决方案、改进措施和最佳实践。

---

## 一、项目背景

`agents_tree` 被用于开发一个名为 **Autofish** 的 FastAPI + Vue 3 SaaS 平台（闲鱼商品自动化管理与发布）。开发模式如下：

- **Cursor**（父级 AI Agent）负责整体任务规划、代码审查和最终集成
- **Codex CLI**（子级 Agent）通过 `codex exec` 非交互式执行具体编码任务
- 共执行了 **12+ 个 Codex 任务**，分 **3 个批次**并行执行

任务覆盖范围包括：项目结构重组（Flask → FastAPI + Vue 前后端分离）、SQLAlchemy ORM 数据模型、JWT 认证系统、统一账号中心、闲鱼适配器迁移、前端页面开发和集成测试等。

---

## 二、遇到的问题与解决方案

### 问题 1：subprocess 双重超时冲突

**现象**：`codex_orchestrator.py` 中的 Python `subprocess.run` 有自己的 `timeout` 参数，同时 PS1 脚本也有 `-Timeout` 参数。

**后果**：Python 层在 120s 后杀死了进程，但 Codex 实际上已经完成了任务，PS1 脚本还在做后处理（收集 git diff、生成 result.json 等）。

**时序图**：

```
Python orchestrator ──────────────────── timeout! kill ──┐
  └─ PS1 脚本 ──────────────────────────────────────────│─── 被杀死
       └─ Codex CLI ───── 完成 ─── 后处理中... ────────┘
```

**解决方案**：移除 `codex_orchestrator.py` 中的 `subprocess.run` timeout 参数，将超时控制完全委托给 PS1 脚本的 `-Timeout` 参数。PS1 脚本的超时只控制 Codex CLI 本身，后处理步骤不受超时限制。

```python
# 修改前（有问题）
result = subprocess.run(cmd, timeout=timeout_seconds, ...)

# 修改后
result = subprocess.run(cmd, ...)  # 超时由 PS1 脚本管理
```

**状态**：✅ 已修复并提交。

---

### 问题 2：UTF-8 编码损坏（BOM 问题）

**现象**：`summary.md` 中出现乱码，如 `—` 变成 `鈥?`，中文字符部分丢失或变成问号。

**原因**：
1. Windows PowerShell 的 `Set-Content -Encoding UTF8` 默认写入**带 BOM（Byte Order Mark）**的 UTF-8
2. `Get-Content` 对不带 BOM 的 UTF-8 文件（如 Codex `--output-last-message` 产生的文件）可能误解码为系统默认编码（如 GBK / Windows-1252）
3. 编码在读取和写入之间不一致，导致内容损坏

**解决方案**：修改 `codex-subagent.ps1`，使用 .NET 方法处理所有文件读写，显式指定无 BOM UTF-8 编码：

```powershell
# 读取文件（兼容有 BOM 和无 BOM）
$content = [System.IO.File]::ReadAllText($filePath, [System.Text.Encoding]::UTF8)

# 写入文件（无 BOM）
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($filePath, $content, $utf8NoBom)
```

`[System.Text.UTF8Encoding]::new($false)` 中的 `$false` 参数表示不写入 BOM。对 `prompt.md`、`summary.md` 和 `result.json` 统一使用此方式处理。

**状态**：✅ 已修复并提交。

---

### 问题 3：codex_exit_code 始终为 null

**现象**：`result.json` 中 `codex_exit_code` 字段始终为 `null`，即使 Codex 成功完成。

```json
{
  "codex_exit_code": null,
  "status": "failed",
  "summary": "..."
}
```

**原因**：PS1 脚本中使用 `Start-Process -Wait:$false` 配合手动超时管理时，`$process.ExitCode` 在进程完成前可能无法正确获取。

**影响**：导致 status 被报告为 `"failed"`，即使代码实际上已成功生成。Cursor 父代理无法准确判断子任务的执行状态，需要人工检查 `summary.md` 和 `diff.patch` 来判断真实结果。

**当前应对**：通过检查实际生成的文件和 `summary.md` 是否非空来间接判断任务是否成功。

**推荐修复**：

```powershell
# 方案 A：使用 -Wait 确保退出码可获取
$process = Start-Process -FilePath "codex" -ArgumentList $args -PassThru -Wait
$exitCode = $process.ExitCode

# 方案 B：使用 & 运算符直接执行
& codex exec @args
$exitCode = $LASTEXITCODE
```

**状态**：⚠️ 已知问题，待修复。

---

### 问题 4：API 503 熔断（所有供应商已熔断）

**现象**：Codex CLI 连接到代理 API 时报 `503 Service Unavailable: 所有供应商已熔断，无可用渠道`。

**原因**：API 代理（aixj.vip）的上游供应商全部触发熔断机制，通常发生在高并发时段或连续大量请求之后。

**影响**：两个并行任务同时失败，但文件已部分生成。`summary.md` 输出为空文件，已完成的部分代码修改可能丢失。

**应对策略**：
1. **立即降级**：Cursor 父级 Agent 检测到失败后，直接使用自身能力完成任务，不阻塞整体进度
2. **稍后重试**：等待熔断恢复后重试 Codex（但同一会话中 API 可能持续不可用）
3. **任务拆分**：将大任务拆分为更小的子任务，减少单次 API 调用的持续时间

**建议改进**：
- 在 PS1 脚本中增加 `-MaxRetries` 参数，实现自动重试（指数退避：30s → 60s → 120s）
- 在 orchestrator 层面实现任务级别的重试
- 监控 API 可用性，在熔断期间自动暂停任务队列

**状态**：⚠️ 已知问题，手动降级应对中。

---

### 问题 5：并行任务在同一工作区冲突

**现象**：两个任务使用 `--no-worktree` 同时在同一工作区执行，导致 `changed_files` 互相污染——任务 A 的 diff 包含了任务 B 的修改，反之亦然。

**原因**：`--no-worktree` 模式下，所有任务共享同一个 Git 工作目录。Git 的暂存区和工作树是全局状态，多个并发写入者会互相干扰。

**解决方案**：后续任务改用 worktree 隔离模式（去掉 `--no-worktree`），每个任务在独立的 git worktree 中执行。

| 场景 | 推荐模式 | 原因 |
|------|----------|------|
| 并行执行多个任务 | worktree | 避免工作区冲突 |
| 单个只读分析任务 | `--no-worktree --readonly` | 无修改，无冲突风险 |
| 单个写入任务（串行） | `--no-worktree` | 简单直接，无需合并 |

**注意**：worktree 模式下需要手动将结果文件复制回主工作区。后续可增加 `-AutoMerge` 参数自动合并。

**状态**：✅ 已改用 worktree 隔离。

---

### 问题 6：`npm create vue@latest` 在 Codex sandbox 中无法访问 npm registry

**现象**：Codex 沙箱环境中 npm 无法访问外部 registry，`npm create vue@latest` 需要下载包但网络不通。

**Codex 的自适应**：Codex 检测到无法访问 registry 后，自动改为手动创建所有文件（`package.json`、`vite.config.ts`、`src/main.ts` 等），展现了不错的自适应能力。

**教训**：对需要网络访问的任务，考虑在 Cursor 端直接执行而非委托给 Codex。不适合委托给 Codex 沙箱的操作包括：
- 网络访问（npm install、pip install、API 调用）
- 交互式命令（CLI 向导、确认提示）
- 系统服务（数据库连接、Docker 操作）

**状态**：✅ 已调整任务分配策略。

---

### 问题 7：Cursor Shell 中交互式命令阻塞

**现象**：`npm create vue@latest` 需要交互式输入（选择 TypeScript / Router / Pinia 等选项），在 Cursor 的 Shell 中会无限阻塞。

**解决方案**：终止进程，改用 Task 子代理手动创建文件结构，或使用非交互式参数调用命令。

**状态**：✅ 已绕过。

---

## 三、改进措施

### 已实施的改进

#### 1. `codex-subagent.ps1`

| 改动 | 说明 |
|------|------|
| 无 BOM UTF-8 编码 | 使用 `[System.IO.File]::WriteAllText` 配合 `UTF8Encoding($false)` 替代 `Set-Content`，避免中文乱码 |
| `-Timeout` 参数 | 新增超时参数，控制 Codex CLI 的最大执行时间 |
| `-PromptTemplate` 参数 | 支持自定义 prompt 模板 |
| 改进 diff.patch 生成 | 通过临时 `git add --intent-to-add` 将未跟踪文件纳入 diff |
| 验证命令执行 | 支持在 Codex 完成后执行验证命令，将结果写入 `result.json` |

#### 2. `codex_orchestrator.py`

| 改动 | 说明 |
|------|------|
| `--repo-root` 参数 | 支持跨仓库使用，在其他仓库中执行 Codex 任务 |
| `--context-file` 参数 | 将指定文件内容注入 Codex prompt，提供额外上下文 |
| `--timeout` 参数 | 超时设置透传给 PS1 脚本 |
| 移除 Python subprocess 超时 | 避免与 PS1 脚本超时机制冲突 |

#### 3. `codex-subagent-prompt.md`

- 添加 `## Project Context` 部分，支持 `{{PROJECT_CONTEXT}}` 占位符注入项目级别的上下文信息

#### 4. 新增 `tools/batch_runner.py`

- 支持多任务并行执行
- 拓扑排序管理任务依赖（`depends_on` 数组）
- 汇总报告输出

#### 5. 新增 `tools/batch-task.example.json`

- 批量任务定义示例，展示如何定义多个任务及其依赖关系

### 建议的后续改进

| 优先级 | 改进项 | 说明 |
|--------|--------|------|
| 🔴 高 | 修复 `codex_exit_code` 为 null | 使用 `$LASTEXITCODE` 或 `-PassThru -Wait` 模式 |
| 🔴 高 | API 503 自动重试 | 指数退避（30s → 60s → 120s），减少因临时故障导致的任务失败 |
| 🟡 中 | Worktree 自动合并 | `-AutoMerge` 参数，自动 commit + merge 回主分支 |
| 🟡 中 | 实时进度反馈 | 替代当前的终端文件轮询，使用 named pipe 或 WebSocket |
| 🟢 低 | 支持 Linux / macOS | 提供 Bash 脚本或使用 PowerShell Core 跨平台 |
| 🟢 低 | 任务进度回调机制 | 当前只能轮询检查，可增加回调通知 |
| 🟢 低 | 成本追踪 | 记录每个任务的 token 消耗和 API 调用次数 |

---

## 四、最佳实践总结

### 1. 任务粒度

每个 Codex 任务应该是独立、可验证的。过大的任务（如完整项目重组）容易因 API 中断而部分失败。

- **太小**（1-2 个文件）：编排开销大于收益，不如 Cursor 直接做
- **合适**（5-15 个文件）：Codex 能充分理解上下文，且不容易超时
- **太大**（20+ 个文件）：容易超时、遇到 API 限制、上下文窗口溢出

### 2. Worktree 隔离

并行任务**必须**使用 worktree 模式，避免工作区冲突。`--no-worktree` 仅用于串行执行或只读分析。

### 3. 双重保障

Cursor 父级 Agent 应有能力在 Codex 失败时直接完成任务。关键原则：**不要让工具链的不稳定性阻塞项目进度**。Cursor 本身就是一个强大的编码代理，Codex 是加速器而非必需品。

```
正常模式：Cursor → 编排 → Codex 执行 → 结果收集
降级模式：Cursor → 直接使用 Task subagent 执行 → 结果收集
```

### 4. 验证命令

每个任务应包含验证命令，确保生成的代码可以编译/导入：

```json
{
  "goal": "实现用户认证 API",
  "validate": "cd backend && python -c 'from app.api.auth import router; print(\"OK\")'"
}
```

常用验证命令：
- Python 模块导入：`python -c 'import module; print("OK")'`
- 语法检查：`python -m py_compile file.py`
- 测试运行：`pytest tests/test_specific.py -x`
- 前端类型检查：`cd frontend && npx vue-tsc --noEmit`

### 5. 超时设置

根据任务复杂度设置合理超时——简单任务 120s，复杂任务 600s。超时过短会导致有效工作被中断，过长会浪费等待时间。

### 6. 编码一致性

Windows 环境下始终使用无 BOM UTF-8。避免使用 PowerShell 的 `Set-Content` / `Out-File` 处理需要精确控制编码的场景。

### 7. 网络依赖

避免在 Codex sandbox 中执行需要网络访问的操作。这类任务应在 Cursor 端直接执行。

### 8. 上下文传递

通过 `--context-file` 传递项目规划文档（架构设计、API 规范、数据模型定义），帮助 Codex 理解全局架构，显著提高任务完成质量。

---

## 五、实际效果统计

### 批次执行概况

| 批次 | 任务数 | Codex 完成 | Cursor 直接完成 | API 失败 |
|------|--------|-----------|----------------|---------|
| Batch 1 (P0-1, P1-3) | 2 | 1 (部分) | 1 | 2 (503) |
| Batch 2 (P0-2, P1-1, P3-1, P3-2) | 4 | 2 | 2 | 2 (503) |
| Batch 3 (后续任务) | 4+ | 2 | 2+ | - |

### 关键指标

- **Codex 平均执行时间**：5–8 分钟/任务
- **Token 消耗**：35,000–63,000 tokens/任务
- **成功率（不含 API 中断）**：~60%（部分完成也算成功）
- **混合策略总完成率**：100%（Codex 失败的任务由 Cursor 接管完成）

### 任务执行明细

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

---

## 六、总结

`agents_tree` 工具链（Cursor + Codex CLI）在 Autofish 项目的开发中验证了父子代理协作模式的可行性。尽管过程中遇到了编码问题、超时冲突、API 不稳定等挑战，但通过逐一排查和修复，工具链的可靠性和易用性得到了持续改进。

核心收获：

1. **文件协议优于 API 协议**：基于文件的 task → result 契约让调试、重放和审计都变得简单
2. **降级能力至关重要**：100% 依赖 Codex 不现实，Cursor 必须保留直接执行的能力
3. **Windows 编码问题是真实痛点**：PowerShell 的 UTF-8 BOM 行为需要开发者主动处理
4. **隔离是并行的前提**：worktree 模式虽然增加了合并成本，但消除了并行冲突
5. **任务粒度决定成功率**：5-15 个文件的任务规模是当前最佳甜蜜点
