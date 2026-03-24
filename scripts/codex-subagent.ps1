param(
    [Parameter(Mandatory = $true)]
    [string]$TaskFile,

    [string]$CodexCommand = "codex",

    [string]$Model,

    [string]$PromptTemplate,

    [int]$Timeout = 0,

    [switch]$NoWorktree,

    [switch]$Readonly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "[codex-subagent] $Message"
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Resolve-OptionalPath {
    param(
        [string]$BasePath,
        [string]$Candidate
    )

    if ([string]::IsNullOrWhiteSpace($Candidate)) {
        return $null
    }

    if ([System.IO.Path]::IsPathRooted($Candidate)) {
        return [System.IO.Path]::GetFullPath($Candidate)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $Candidate))
}

function Format-BulletList {
    param(
        [object[]]$Items,
        [string]$Fallback
    )

    $cleanItems = @(
        $Items | ForEach-Object {
            $text = "$_".Trim()
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $text
            }
        }
    )

    if ($null -eq $cleanItems -or $cleanItems.Count -eq 0) {
        return "- $Fallback"
    }

    return (($cleanItems | ForEach-Object { "- $_" }) -join "`n")
}

function New-SafeTaskId {
    param([string]$Value)

    $safe = ($Value.ToLowerInvariant() -replace "[^a-z0-9._-]+", "-").Trim("-")
    if ([string]::IsNullOrWhiteSpace($safe)) {
        $safe = "codex-task"
    }
    return $safe
}

function Get-GitStatusLines {
    param([string]$WorkspacePath)

    $statusCommand = 'git -C "{0}" status --short --untracked-files=all 2>nul' -f $WorkspacePath
    $statusLines = @(cmd.exe /d /c $statusCommand)
    if ($LASTEXITCODE -ne 0) {
        return @()
    }

    return @(
        $statusLines | ForEach-Object { "$_".TrimEnd() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Should-IncludeChangedPath {
    param([string]$RelativePath)

    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        return $false
    }

    $normalized = $RelativePath.Replace("\", "/")
    $excludedPrefixes = @(
        ".tmp/",
        ".venv/",
        ".venv.",
        ".venv.broken/",
        ".pytest_cache/",
        ".worktrees/",
        "__pycache__/"
    )

    foreach ($prefix in $excludedPrefixes) {
        if ($normalized.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
    }

    if ($normalized.StartsWith("pytest-cache-files-", [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    return $true
}

function Get-RelativePathsFromStatusLines {
    param([string[]]$StatusLines)

    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($line in $StatusLines) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.Length -lt 4) {
            continue
        }

        $pathText = $line.Substring(3).Trim()
        if ($pathText -match " -> ") {
            $pathText = ($pathText -split " -> ")[-1].Trim()
        }

        if ((Should-IncludeChangedPath -RelativePath $pathText) -and -not $paths.Contains($pathText)) {
            $paths.Add($pathText)
        }
    }

    return @($paths.ToArray())
}

function Get-FileFingerprint {
    param(
        [string]$WorkspacePath,
        [string]$RelativePath
    )

    $fullPath = Join-Path $WorkspacePath $RelativePath
    if (-not (Test-Path -LiteralPath $fullPath)) {
        return "[missing]"
    }

    $item = Get-Item -LiteralPath $fullPath
    if ($item.PSIsContainer) {
        return "[directory]"
    }

    return (Get-FileHash -Algorithm SHA256 -LiteralPath $fullPath).Hash
}

function Get-FingerprintMap {
    param(
        [string]$WorkspacePath,
        [string[]]$RelativePaths
    )

    $map = @{}
    foreach ($relativePath in $RelativePaths) {
        $map[$relativePath] = Get-FileFingerprint -WorkspacePath $WorkspacePath -RelativePath $relativePath
    }
    return $map
}

function Compare-ChangedFiles {
    param(
        [string[]]$BaselinePaths,
        [hashtable]$BaselineFingerprints,
        [string[]]$CurrentPaths,
        [hashtable]$CurrentFingerprints
    )

    $allPaths = New-Object System.Collections.Generic.List[string]
    foreach ($path in @($BaselinePaths) + @($CurrentPaths)) {
        if (-not [string]::IsNullOrWhiteSpace($path) -and -not $allPaths.Contains($path)) {
            $allPaths.Add($path)
        }
    }

    $deltaPaths = New-Object System.Collections.Generic.List[string]
    foreach ($path in $allPaths) {
        $baselineExists = $BaselineFingerprints.ContainsKey($path)
        $currentExists = $CurrentFingerprints.ContainsKey($path)

        if (-not $baselineExists -and $currentExists) {
            $deltaPaths.Add($path)
            continue
        }

        if ($baselineExists -and -not $currentExists) {
            continue
        }

        if ($baselineExists -and $currentExists -and $BaselineFingerprints[$path] -ne $CurrentFingerprints[$path]) {
            $deltaPaths.Add($path)
        }
    }

    return @($deltaPaths.ToArray())
}

$resolvedTaskFile = (Resolve-Path -LiteralPath $TaskFile).Path
$task = Get-Content -LiteralPath $resolvedTaskFile -Raw | ConvertFrom-Json

$repoRootCandidate = if ($task.PSObject.Properties.Name -contains "repo_root") {
    Resolve-OptionalPath -BasePath (Split-Path -Parent $resolvedTaskFile) -Candidate $task.repo_root
} else {
    [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
}

if (-not $repoRootCandidate) {
    throw "Task file must provide repo_root, or the script must live under the target repository."
}

$repoRoot = (Resolve-Path -LiteralPath $repoRootCandidate).Path
$gitRoot = (git -C $repoRoot rev-parse --show-toplevel).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "Repository root '$repoRoot' is not inside a git repository."
}
$repoRoot = $gitRoot

if (-not (Get-Command $CodexCommand -ErrorAction SilentlyContinue)) {
    throw "Codex CLI command '$CodexCommand' was not found. Install it first, e.g. 'npm install -g @openai/codex'."
}

$nodeCommand = Get-Command "node" -ErrorAction SilentlyContinue
if (-not $nodeCommand) {
    throw "Node.js was not found on PATH."
}

$globalModulesRoot = (npm root -g).Trim()
$codexEntry = Join-Path $globalModulesRoot "@openai\codex\bin\codex.js"
if (-not (Test-Path -LiteralPath $codexEntry)) {
    throw "Codex CLI entry script was not found at '$codexEntry'."
}

if (-not ($task.PSObject.Properties.Name -contains "goal") -or [string]::IsNullOrWhiteSpace($task.goal)) {
    throw "Task file must include a non-empty 'goal'."
}

$taskIdSource = if ($task.PSObject.Properties.Name -contains "task_id" -and -not [string]::IsNullOrWhiteSpace($task.task_id)) {
    $task.task_id
} else {
    $task.goal
}
$taskId = New-SafeTaskId -Value $taskIdSource

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$scopeItems = @($task.scope)
$constraintItems = @($task.constraints)
$validationItems = @($task.validation_commands)
$baseRef = if ($task.PSObject.Properties.Name -contains "base_branch" -and -not [string]::IsNullOrWhiteSpace($task.base_branch)) {
    $task.base_branch
} else {
    "HEAD"
}

$outputDirCandidate = if ($task.PSObject.Properties.Name -contains "output_dir" -and -not [string]::IsNullOrWhiteSpace($task.output_dir)) {
    $task.output_dir
} else {
    ".tmp/codex/results/$taskId"
}
$outputDir = Resolve-OptionalPath -BasePath $repoRoot -Candidate $outputDirCandidate
Ensure-Directory -Path $outputDir

$templatePath = $null
if (-not [string]::IsNullOrWhiteSpace($PromptTemplate)) {
    $templatePath = if ([System.IO.Path]::IsPathRooted($PromptTemplate)) {
        $PromptTemplate
    } else {
        [System.IO.Path]::GetFullPath((Join-Path $repoRoot $PromptTemplate))
    }
} elseif ($task.PSObject.Properties.Name -contains "prompt_template" -and -not [string]::IsNullOrWhiteSpace($task.prompt_template)) {
    $templatePath = Resolve-OptionalPath -BasePath (Split-Path -Parent $resolvedTaskFile) -Candidate $task.prompt_template
}

if (-not $templatePath -or -not (Test-Path -LiteralPath $templatePath)) {
    $fallback = Join-Path $repoRoot "tools\codex-subagent-prompt.md"
    if (Test-Path -LiteralPath $fallback) {
        $templatePath = $fallback
    } else {
        $scriptDir = Split-Path -Parent $PSScriptRoot
        $fallback2 = Join-Path $scriptDir "tools\codex-subagent-prompt.md"
        if (Test-Path -LiteralPath $fallback2) {
            $templatePath = $fallback2
        } else {
            throw "Prompt template not found. Provide -PromptTemplate or place codex-subagent-prompt.md in tools/."
        }
    }
}

$workspacePath = $repoRoot
$worktreePath = $null
$branchName = $null
$worktreeCreated = $false

if (-not $NoWorktree) {
    $worktreesRoot = Join-Path $repoRoot ".worktrees"
    Ensure-Directory -Path $worktreesRoot

    $worktreeSlug = "$taskId-$timestamp"
    $branchName = "codex/$worktreeSlug"
    $worktreePath = Join-Path $worktreesRoot $worktreeSlug

    Write-Step "Creating isolated worktree at $worktreePath"
    git -C $repoRoot worktree add -b $branchName $worktreePath $baseRef | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create git worktree for task '$taskId'."
    }

    $workspacePath = $worktreePath
    $worktreeCreated = $true
}

$scopeText = Format-BulletList -Items $scopeItems -Fallback "No explicit file scope was provided. Stay tightly focused on the stated goal."
$constraintText = Format-BulletList -Items $constraintItems -Fallback "Do not refactor unrelated files or change dependency versions unless the task explicitly requires it."
$validationText = Format-BulletList -Items $validationItems -Fallback "No validation commands were provided. If you modify code, run the narrowest relevant verification you can."

$contextText = ""
if ($task.PSObject.Properties.Name -contains "context_files") {
    $contextParts = @()
    foreach ($ctxFile in @($task.context_files)) {
        $ctxPath = Resolve-OptionalPath -BasePath $repoRoot -Candidate $ctxFile
        if ($ctxPath -and (Test-Path -LiteralPath $ctxPath)) {
            $ctxContent = Get-Content -LiteralPath $ctxPath -Raw
            $contextParts += "### $ctxFile`n`n$ctxContent"
        }
    }
    if ($contextParts.Count -gt 0) {
        $contextText = ($contextParts -join "`n`n---`n`n")
    }
}

$template = Get-Content -LiteralPath $templatePath -Raw
$prompt = $template.
    Replace("{{TASK_ID}}", $taskId).
    Replace("{{GOAL}}", $task.goal.Trim()).
    Replace("{{WORKSPACE_PATH}}", $workspacePath).
    Replace("{{SCOPE}}", $scopeText).
    Replace("{{CONSTRAINTS}}", $constraintText).
    Replace("{{VALIDATION_COMMANDS}}", $validationText).
    Replace("{{PROJECT_CONTEXT}}", $contextText)

$promptPath = Join-Path $outputDir "prompt.md"
$summaryPath = Join-Path $outputDir "summary.md"
$stdoutPath = Join-Path $outputDir "codex.stdout.log"
$stderrPath = Join-Path $outputDir "codex.stderr.log"
$resultPath = Join-Path $outputDir "result.json"
$patchPath = Join-Path $outputDir "diff.patch"
$statusPath = Join-Path $outputDir "git-status.txt"
$baselineStatusPath = Join-Path $outputDir "git-status-before.txt"
$startedAt = (Get-Date).ToString("o")

Set-Content -LiteralPath $promptPath -Value $prompt -Encoding UTF8

$baselineStatusLines = Get-GitStatusLines -WorkspacePath $workspacePath
$baselinePaths = Get-RelativePathsFromStatusLines -StatusLines $baselineStatusLines
$baselineFingerprints = Get-FingerprintMap -WorkspacePath $workspacePath -RelativePaths $baselinePaths
Set-Content -LiteralPath $baselineStatusPath -Value (($baselineStatusLines | ForEach-Object { "$_" }) -join [Environment]::NewLine) -Encoding UTF8

$sandboxMode = if ($Readonly) { "read-only" } else { "workspace-write" }
$codexArgs = @("exec", "--cd", $workspacePath)

if ($Readonly) {
    $codexArgs += @("--sandbox", "read-only")
} else {
    $codexArgs += @("--full-auto")
}

if (-not [string]::IsNullOrWhiteSpace($Model)) {
    $codexArgs += @("--model", $Model)
}
$codexArgs += @("--output-last-message", $summaryPath, "-")

Write-Step "Running Codex in $sandboxMode mode"
$startProcessArgs = @{
    NoNewWindow = $true
    Wait = $false
    PassThru = $true
    FilePath = $nodeCommand.Source
    ArgumentList = @($codexEntry) + $codexArgs
    RedirectStandardInput = $promptPath
    RedirectStandardOutput = $stdoutPath
    RedirectStandardError = $stderrPath
}
$process = Start-Process @startProcessArgs

if ($Timeout -gt 0) {
    $completed = $process.WaitForExit($Timeout * 1000)
    if (-not $completed) {
        Write-Step "ERROR: Codex timed out after ${Timeout}s, killing process"
        $process.Kill()
        $process.WaitForExit(5000)
        $codexExitCode = 124
    } else {
        $codexExitCode = $process.ExitCode
    }
} else {
    $process.WaitForExit()
    $codexExitCode = $process.ExitCode
}

$finishedAt = (Get-Date).ToString("o")
$stdoutText = if (Test-Path -LiteralPath $stdoutPath) {
    "$((Get-Content -LiteralPath $stdoutPath -Raw))".Trim()
} else {
    ""
}

$summaryText = if (Test-Path -LiteralPath $summaryPath) {
    "$((Get-Content -LiteralPath $summaryPath -Raw))".Trim()
} elseif ([string]::IsNullOrWhiteSpace($stdoutText)) {
    "_Codex returned no final message. Check codex.stderr.log for details._"
} else {
    $stdoutText
}
Set-Content -LiteralPath $summaryPath -Value $summaryText -Encoding UTF8

$gitStatus = Get-GitStatusLines -WorkspacePath $workspacePath
$currentPaths = Get-RelativePathsFromStatusLines -StatusLines $gitStatus
$currentFingerprints = Get-FingerprintMap -WorkspacePath $workspacePath -RelativePaths $currentPaths
$changedFiles = Compare-ChangedFiles -BaselinePaths $baselinePaths -BaselineFingerprints $baselineFingerprints -CurrentPaths $currentPaths -CurrentFingerprints $currentFingerprints
$addUntrackedCommand = 'git -C "{0}" add --intent-to-add --all 2>nul' -f $workspacePath
cmd.exe /d /c $addUntrackedCommand | Out-Null
$patchCommand = 'git -C "{0}" diff --binary 2>nul' -f $workspacePath
$patchText = @(cmd.exe /d /c $patchCommand)
$resetCommand = 'git -C "{0}" reset 2>nul' -f $workspacePath
cmd.exe /d /c $resetCommand | Out-Null

Set-Content -LiteralPath $statusPath -Value (($gitStatus | ForEach-Object { "$_" }) -join [Environment]::NewLine) -Encoding UTF8
Set-Content -LiteralPath $patchPath -Value (($patchText | ForEach-Object { "$_" }) -join [Environment]::NewLine) -Encoding UTF8

$validationResults = @()
if ($codexExitCode -eq 0 -and -not $Readonly) {
    $rawValidation = @($task.validation_commands)
    $validationCmds = @($rawValidation | ForEach-Object { "$_".Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    foreach ($cmd in $validationCmds) {
        Write-Step "Running validation: $cmd"
        $valOutput = cmd.exe /d /c "cd /d `"$workspacePath`" && $cmd 2>&1"
        $valExit = $LASTEXITCODE
        $validationResults += [ordered]@{
            command = $cmd
            exit_code = $valExit
            passed = ($valExit -eq 0)
        }
        if ($valExit -ne 0) {
            Write-Step "WARN: validation failed: $cmd (exit $valExit)"
        }
    }
}

$allValidationsPassed = ($validationResults.Count -eq 0) -or ($validationResults | Where-Object { -not $_.passed }).Count -eq 0
$overallStatus = if ($codexExitCode -ne 0) {
    "failed"
} elseif (-not $allValidationsPassed) {
    "validation_failed"
} else {
    "success"
}

$result = [ordered]@{
    task_id = $taskId
    goal = $task.goal.Trim()
    status = $overallStatus
    codex_exit_code = $codexExitCode
    readonly = [bool]$Readonly
    used_worktree = -not $NoWorktree
    branch = $branchName
    repo_root = $repoRoot
    workspace_path = $workspacePath
    worktree_path = $worktreePath
    started_at = $startedAt
    finished_at = $finishedAt
    preexisting_changed_files = $baselinePaths
    all_changed_files = $currentPaths
    changed_files = $changedFiles
    validation = $validationResults
    output = [ordered]@{
        prompt = $promptPath
        summary = $summaryPath
        stdout_log = $stdoutPath
        stderr_log = $stderrPath
        git_status_before = $baselineStatusPath
        git_status = $statusPath
        diff_patch = $patchPath
    }
}

$result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resultPath -Encoding UTF8

Write-Step "Summary: $summaryPath"
Write-Step "Result JSON: $resultPath"
Write-Step "Patch: $patchPath"
if ($worktreeCreated) {
    Write-Step "Worktree kept at $worktreePath for review."
}

exit $codexExitCode
