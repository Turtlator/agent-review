[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$PullRequest,

    [string]$Repo,

    [string]$Workspace,

    [string]$Slug,

    [switch]$Force,

    [switch]$NoDiff
)

$ErrorActionPreference = 'Stop'

if (-not $Workspace) {
    if ($env:AGENT_REVIEW_WORKSPACE) {
        $Workspace = $env:AGENT_REVIEW_WORKSPACE
    } else {
        $Workspace = Join-Path $HOME '.agent-review'
    }
}

if (-not (Test-Path $Workspace)) {
    New-Item -ItemType Directory -Path $Workspace -Force | Out-Null
}
$Workspace = (Resolve-Path $Workspace).Path

$scriptRoot = Split-Path -Parent $PSCommandPath
$skillsRoot = Split-Path -Parent $scriptRoot
$toolRoot = Split-Path -Parent $skillsRoot

$ghCmd = Get-Command gh -ErrorAction SilentlyContinue
if (-not $ghCmd) {
    throw "GitHub CLI 'gh' not found in PATH. Install from https://cli.github.com/ and run 'gh auth login'."
}

if ($Repo) {
    if (-not (Test-Path $Repo)) {
        throw "Repo path does not exist: $Repo"
    }
    $Repo = (Resolve-Path $Repo).Path
}

function Invoke-Gh {
    param([Parameter(Mandatory=$true)][string[]]$GhArgs)
    if ($Repo) {
        Push-Location $Repo
        try {
            $out = & gh @GhArgs
            $code = $LASTEXITCODE
        } finally {
            Pop-Location
        }
    } else {
        $out = & gh @GhArgs
        $code = $LASTEXITCODE
    }
    return [pscustomobject]@{ Output = $out; ExitCode = $code }
}

$fields = 'number,title,body,headRefName,baseRefName,url,author,state,isDraft,files,additions,deletions,headRepositoryOwner,headRepository,baseRepository'
$viewResult = Invoke-Gh -GhArgs @('pr', 'view', $PullRequest, '--json', $fields)
if ($viewResult.ExitCode -ne 0) {
    throw "Failed to fetch PR via 'gh pr view $PullRequest'. Confirm the PR reference is valid and you are authenticated ('gh auth status')."
}

$prJsonText = ($viewResult.Output -join "`n")
$pr = $prJsonText | ConvertFrom-Json

if (-not $Slug) {
    $titleSlug = ($pr.title -replace '[^a-zA-Z0-9]+', '-').Trim('-').ToLowerInvariant()
    if ($titleSlug.Length -gt 40) {
        $titleSlug = $titleSlug.Substring(0, 40).TrimEnd('-')
    }
    if ([string]::IsNullOrWhiteSpace($titleSlug)) {
        $Slug = "pr-$($pr.number)"
    } else {
        $Slug = "pr-$($pr.number)-$titleSlug"
    }
}

if ($Slug -notmatch '^[a-zA-Z0-9][a-zA-Z0-9-]*$') {
    throw "Computed slug is invalid: '$Slug'. Pass -Slug to override."
}

$date = Get-Date -Format 'yyyy-MM-dd'
$folderName = "$date-$Slug"
$reviewsDir = Join-Path $Workspace 'reviews'
$reviewFolder = Join-Path $reviewsDir $folderName
$templateRoot = Join-Path $toolRoot 'templates'

if (-not (Test-Path $reviewsDir)) {
    New-Item -ItemType Directory -Path $reviewsDir -Force | Out-Null
}

if ((Test-Path $reviewFolder) -and -not $Force) {
    throw "Review folder already exists: $reviewFolder. Use -Force to reuse it."
}

New-Item -ItemType Directory -Path $reviewFolder -Force | Out-Null

foreach ($name in @('resolution.md', 'synthesis.md')) {
    $src = Join-Path $templateRoot $name
    $dst = Join-Path $reviewFolder $name
    if (-not (Test-Path $src)) {
        throw "Missing template: $src"
    }
    if (-not (Test-Path $dst) -or $Force) {
        Copy-Item -Path $src -Destination $dst -Force
    }
}

$fileLines = @()
if ($pr.files) {
    foreach ($f in $pr.files) {
        $fileLines += "- $($f.path) (+$($f.additions) / -$($f.deletions))"
    }
}
if (-not $fileLines) {
    $fileLines = @('- (no files reported by gh pr view)')
}
$fileList = $fileLines -join "`n"

$repoFull = $null
if ($pr.baseRepository -and $pr.baseRepository.owner -and $pr.baseRepository.owner.login -and $pr.baseRepository.name) {
    $repoFull = "$($pr.baseRepository.owner.login)/$($pr.baseRepository.name)"
}
if (-not $repoFull -and $pr.url) {
    $m = [regex]::Match($pr.url, 'github\.com/([^/]+)/([^/]+)/pull/')
    if ($m.Success) { $repoFull = "$($m.Groups[1].Value)/$($m.Groups[2].Value)" }
}
if (-not $repoFull) { $repoFull = '(unknown)' }

$headFull = $null
if ($pr.headRepository -and $pr.headRepositoryOwner -and $pr.headRepositoryOwner.login -and $pr.headRepository.name) {
    $headFull = "$($pr.headRepositoryOwner.login)/$($pr.headRepository.name)"
}

$stateLine = $pr.state
if ($pr.isDraft) { $stateLine = "$stateLine (draft)" }

$forkNote = ''
if ($headFull -and $headFull -ne $repoFull) {
    $forkNote = "`nHead repo (fork): $headFull"
}

$repoForRequest = if ($Repo) { $Repo } else { $repoFull }

$goal = if ([string]::IsNullOrWhiteSpace($pr.body)) {
    "Review GitHub PR #$($pr.number): $($pr.title). (PR body was empty.)"
} else {
    "Review GitHub PR #$($pr.number): $($pr.title).`n`n$($pr.body)"
}

$diffNote = ''
$diffPath = Join-Path $reviewFolder 'pr.diff'
if (-not $NoDiff) {
    $diffResult = Invoke-Gh -GhArgs @('pr', 'diff', $PullRequest)
    if ($diffResult.ExitCode -ne 0) {
        Write-Warning "Failed to capture PR diff via 'gh pr diff $PullRequest'. Continuing without pr.diff."
    } else {
        $diffText = $diffResult.Output -join "`n"
        Set-Content -Path $diffPath -Value $diffText -Encoding UTF8
        $diffNote = "`nPR diff snapshot saved to ``pr.diff`` in this folder (captured at review creation time; re-run ``gh pr diff $($pr.url)`` for the latest)."
    }
}

$requestPath = Join-Path $reviewFolder 'request.md'

$content = @"
# Review: PR #$($pr.number) - $($pr.title)

Status: inbox
Repo: $repoForRequest
Branch: $($pr.headRefName)
PR: $($pr.url)
Authoring agent: Human
Reviewing agent: Any
Created: $date

## Goal

$goal

## Scope

GitHub PR: $($pr.url)
Base branch: $($pr.baseRefName)
Head branch: $($pr.headRefName)$forkNote

Changed files (+$($pr.additions) / -$($pr.deletions) across $($pr.files.Count) file(s)):

$fileList

## Context

- GitHub repo: $repoFull
- Author: $($pr.author.login)
- State: $stateLine
- Inspect the PR diff at ``pr.diff`` for the review snapshot, or run ``gh pr diff $($pr.url)`` for the latest.
- If the reviewing agent needs a local checkout, ``gh pr checkout $($pr.number)`` inside the target repo will fetch the branch.

## Questions

1. <Specific thing to check>
2. <Specific thing to challenge>

## Verification

List commands already run and their outcomes.

``````text
<command output summary>
``````

## Notes

This review folder was created from a GitHub PR by ``New-PrReview.ps1``.$diffNote
"@

Set-Content -Path $requestPath -Value $content -Encoding UTF8

Write-Host $reviewFolder
