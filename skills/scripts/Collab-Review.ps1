[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$PullRequest,

    [ValidateSet('claude', 'codex')]
    [string]$Initiator = 'claude',

    [string]$Workspace,

    [string]$Repo,

    [switch]$Unsafe
)

$ErrorActionPreference = 'Stop'

if ($Initiator -eq 'claude') { $Requested = 'codex' } else { $Requested = 'claude' }

foreach ($cli in @('claude', 'codex')) {
    if (-not (Get-Command $cli -ErrorAction SilentlyContinue)) {
        throw "'$cli' not found in PATH. Install it before using this orchestrator."
    }
}

$scriptRoot = Split-Path -Parent $PSCommandPath
$skillsRoot = Split-Path -Parent $scriptRoot
$toolRoot = Split-Path -Parent $skillsRoot

$newPrArgs = @('-PullRequest', $PullRequest)
if ($Workspace) { $newPrArgs += @('-Workspace', $Workspace) }
if ($Repo) { $newPrArgs += @('-Repo', $Repo) }

$newPrScript = Join-Path $scriptRoot 'New-PrReview.ps1'
$reviewFolder = & $newPrScript @newPrArgs | Select-Object -Last 1

if (-not (Test-Path $reviewFolder)) {
    throw "Failed to create review folder. Got: '$reviewFolder'"
}

$logDir = Join-Path $reviewFolder '.collab'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

Write-Host "Review folder: $reviewFolder"
Write-Host "Initiator:     $Initiator"
Write-Host "Requested:     $Requested"

function Invoke-AgentCli {
    param(
        [Parameter(Mandatory=$true)][string]$Agent,
        [Parameter(Mandatory=$true)][string]$Prompt,
        [Parameter(Mandatory=$true)][string]$LogPath,
        [Parameter(Mandatory=$true)][string]$Cwd,
        [Parameter(Mandatory=$true)][string]$ToolRoot,
        [Parameter(Mandatory=$true)][bool]$AllowUnsafe
    )
    Push-Location $Cwd
    try {
        if ($Agent -eq 'claude') {
            $args = @('-p')
            if ($AllowUnsafe) { $args += '--dangerously-skip-permissions' }
            $args += @('--add-dir', $ToolRoot, $Prompt)
            & claude @args *> $LogPath
        } else {
            $args = @('exec')
            if ($AllowUnsafe) {
                $args += '--dangerously-bypass-approvals-and-sandbox'
            } else {
                $args += @('--sandbox', 'workspace-write')
            }
            $args += @('--skip-git-repo-check', '-C', $Cwd, $Prompt)
            & codex @args *> $LogPath
        }
        return $LASTEXITCODE
    } finally {
        Pop-Location
    }
}

$initiatorFile = "$Initiator.md"
$requestedFile = "$Requested.md"

$phase1InitiatorPrompt = "Use the agent-review skill. Read request.md and pr.diff in the current directory. Write your independent review to $initiatorFile in the current directory. Do not read $requestedFile."
$phase1RequestedPrompt = "Use the agent-review skill. Read request.md and pr.diff in the current directory. Write your independent review to $requestedFile in the current directory. Do not read $initiatorFile."

Write-Host ''
Write-Host 'Phase 1: both agents reviewing independently (parallel)...'

$phase1Common = @{
    Cwd = $reviewFolder
    ToolRoot = $toolRoot
    AllowUnsafe = [bool]$Unsafe
}

$job1 = Start-Job -ScriptBlock {
    param($Func, $Agent, $Prompt, $Log, $Cwd, $ToolRoot, $Unsafe)
    $scriptBlock = [scriptblock]::Create($Func)
    & $scriptBlock -Agent $Agent -Prompt $Prompt -LogPath $Log -Cwd $Cwd -ToolRoot $ToolRoot -AllowUnsafe $Unsafe
} -ArgumentList ${function:Invoke-AgentCli}.ToString(), $Initiator, $phase1InitiatorPrompt, (Join-Path $logDir "phase1-$Initiator.log"), $reviewFolder, $toolRoot, [bool]$Unsafe

$job2 = Start-Job -ScriptBlock {
    param($Func, $Agent, $Prompt, $Log, $Cwd, $ToolRoot, $Unsafe)
    $scriptBlock = [scriptblock]::Create($Func)
    & $scriptBlock -Agent $Agent -Prompt $Prompt -LogPath $Log -Cwd $Cwd -ToolRoot $ToolRoot -AllowUnsafe $Unsafe
} -ArgumentList ${function:Invoke-AgentCli}.ToString(), $Requested, $phase1RequestedPrompt, (Join-Path $logDir "phase1-$Requested.log"), $reviewFolder, $toolRoot, [bool]$Unsafe

Wait-Job -Job @($job1, $job2) | Out-Null
$rc1 = (Receive-Job -Job $job1 -Keep -ErrorAction SilentlyContinue) | Select-Object -Last 1
$rc2 = (Receive-Job -Job $job2 -Keep -ErrorAction SilentlyContinue) | Select-Object -Last 1
Remove-Job -Job $job1, $job2 -Force

if ($rc1 -ne 0) {
    throw "Phase 1 ($Initiator) failed (exit $rc1). See $logDir\phase1-$Initiator.log"
}
if ($rc2 -ne 0) {
    throw "Phase 1 ($Requested) failed (exit $rc2). See $logDir\phase1-$Requested.log"
}

$phase2Prompt = "Use the agent-review skill. Read $initiatorFile in the current directory. Append a '## Cross-check (vs $Initiator)' section to $requestedFile per the protocol with four subsections: 'Agreed', 'Disagreed', 'They caught, I missed', 'I still stand by'. Only edit $requestedFile."

Write-Host "Phase 2: $Requested cross-checking $Initiator's findings..."
$rc = Invoke-AgentCli -Agent $Requested -Prompt $phase2Prompt -LogPath (Join-Path $logDir "phase2-$Requested.log") -Cwd $reviewFolder -ToolRoot $toolRoot -AllowUnsafe ([bool]$Unsafe)
if ($rc -ne 0) {
    throw "Phase 2 failed (exit $rc). See $logDir\phase2-$Requested.log"
}

$phase3Prompt = "Use the agent-review skill. Read $initiatorFile (your own independent review) and $requestedFile (their independent review plus their '## Cross-check' section about your review). Write the consolidated synthesis to synthesis.md per the protocol: Confirmed (both flagged), Disputed (one flagged, the other disagreed), Single-source (only one flagged)."

Write-Host "Phase 3: $Initiator synthesizing..."
$rc = Invoke-AgentCli -Agent $Initiator -Prompt $phase3Prompt -LogPath (Join-Path $logDir "phase3-$Initiator.log") -Cwd $reviewFolder -ToolRoot $toolRoot -AllowUnsafe ([bool]$Unsafe)
if ($rc -ne 0) {
    throw "Phase 3 failed (exit $rc). See $logDir\phase3-$Initiator.log"
}

Write-Host ''
Write-Host "Done. Review at: $reviewFolder"
Write-Host 'Files in folder:'
Get-ChildItem -Path $reviewFolder | Where-Object { -not $_.PSIsContainer } | ForEach-Object { Write-Host "  $($_.Name)" }
