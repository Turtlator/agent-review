[CmdletBinding()]
param(
    [ValidateSet('Both', 'Codex', 'Claude')]
    [string]$Agent = 'Both',

    [string]$Workspace,

    [switch]$WhatIfOnly
)

$ErrorActionPreference = 'Stop'

function Convert-ToPortablePath {
    param([Parameter(Mandatory=$true)] [string]$Path)
    return $Path.Replace('\\', '/').Replace('\', '/')
}

if (-not $Workspace) {
    if ($env:AGENT_REVIEW_WORKSPACE) {
        $Workspace = $env:AGENT_REVIEW_WORKSPACE
    } else {
        $Workspace = Join-Path $HOME '.agent-review'
    }
}

if (-not (Test-Path $Workspace)) {
    if ($WhatIfOnly) {
        Write-Host "Would create workspace at $Workspace"
    } else {
        New-Item -ItemType Directory -Path $Workspace -Force | Out-Null
    }
}
if (Test-Path $Workspace) {
    $Workspace = (Resolve-Path $Workspace).Path
}

foreach ($sub in @('reviews', 'archive')) {
    $subPath = Join-Path $Workspace $sub
    if (-not (Test-Path $subPath)) {
        if ($WhatIfOnly) {
            Write-Host "Would create $subPath"
        } else {
            New-Item -ItemType Directory -Path $subPath -Force | Out-Null
        }
    }
}

$skillsRoot = Split-Path -Parent $PSCommandPath
$toolRoot = Split-Path -Parent $skillsRoot
$codexSource = Join-Path $skillsRoot (Join-Path 'codex' 'agent-review')
$claudeSource = Join-Path $skillsRoot (Join-Path 'claude' 'agent-review')
$codexDest = Join-Path $HOME (Join-Path '.codex' (Join-Path 'skills' 'agent-review'))
$claudeDest = Join-Path $HOME (Join-Path '.claude' (Join-Path 'skills' 'agent-review'))

$tokens = @{
    '{{AGENT_REVIEW_WORKSPACE}}' = Convert-ToPortablePath $Workspace
    '{{AGENT_REVIEW_TOOL_ROOT}}' = Convert-ToPortablePath $toolRoot
    '{{PROTOCOL_PATH}}' = Convert-ToPortablePath (Join-Path $skillsRoot (Join-Path 'common' 'agent-review-protocol.md'))
    '{{NEW_REVIEW_PS1}}' = Convert-ToPortablePath (Join-Path $skillsRoot (Join-Path 'scripts' 'New-AgentReview.ps1'))
    '{{NEW_REVIEW_SH}}' = Convert-ToPortablePath (Join-Path $skillsRoot (Join-Path 'scripts' 'new-agent-review.sh'))
    '{{NEW_PR_REVIEW_PS1}}' = Convert-ToPortablePath (Join-Path $skillsRoot (Join-Path 'scripts' 'New-PrReview.ps1'))
    '{{NEW_PR_REVIEW_SH}}' = Convert-ToPortablePath (Join-Path $skillsRoot (Join-Path 'scripts' 'new-pr-review.sh'))
    '{{INSTALL_PS1}}' = Convert-ToPortablePath (Join-Path $skillsRoot 'Install-GlobalSkills.ps1')
    '{{INSTALL_SH}}' = Convert-ToPortablePath (Join-Path $skillsRoot 'install-global-skills.sh')
}

function Expand-Template {
    param([Parameter(Mandatory=$true)] [string]$Text)
    foreach ($key in $tokens.Keys) {
        $Text = $Text.Replace($key, $tokens[$key])
    }
    return $Text
}

function Install-Skill {
    param(
        [Parameter(Mandatory=$true)] [string]$Source,
        [Parameter(Mandatory=$true)] [string]$Destination,
        [Parameter(Mandatory=$true)] [string]$Name
    )

    $sourceSkill = Join-Path $Source 'SKILL.md'
    if (-not (Test-Path $sourceSkill)) {
        throw "Missing source SKILL.md for $Name at $Source"
    }

    if ($WhatIfOnly) {
        Write-Host "Would install $Name skill to $Destination"
        return
    }

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $content = Get-Content -Path $sourceSkill -Raw
    Set-Content -Path (Join-Path $Destination 'SKILL.md') -Value (Expand-Template $content) -Encoding UTF8
    Write-Host "Installed $Name skill to $Destination"
}

if ($Agent -eq 'Both' -or $Agent -eq 'Codex') {
    Install-Skill -Source $codexSource -Destination $codexDest -Name 'Codex'
}

if ($Agent -eq 'Both' -or $Agent -eq 'Claude') {
    Install-Skill -Source $claudeSource -Destination $claudeDest -Name 'Claude Code'
}

Write-Host ''
Write-Host "Workspace: $Workspace"
Write-Host 'Shared protocol source:'
Write-Host "  $($tokens['{{PROTOCOL_PATH}}'])"
Write-Host ''
Write-Host 'Restart Codex or Claude Code if a running session does not discover the refreshed skill.'
