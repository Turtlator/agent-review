[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9-]*$')]
    [string]$Slug,

    [string]$Repo = (Get-Location).Path,

    [string]$Workspace,

    [switch]$Force
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

$date = Get-Date -Format 'yyyy-MM-dd'
$folderName = "$date-$($Slug.ToLowerInvariant())"
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

$files = @{
    'review-request.md' = 'request.md'
    'resolution.md' = 'resolution.md'
    'synthesis.md' = 'synthesis.md'
}

foreach ($entry in $files.GetEnumerator()) {
    $source = Join-Path $templateRoot $entry.Key
    $dest = Join-Path $reviewFolder $entry.Value
    if (-not (Test-Path $source)) {
        throw "Missing template: $source"
    }
    if (-not (Test-Path $dest) -or $Force) {
        Copy-Item -Path $source -Destination $dest -Force
    }
}

$requestPath = Join-Path $reviewFolder 'request.md'
$content = Get-Content -Path $requestPath -Raw
$content = $content.Replace('Repo: <absolute path to repo>', "Repo: $Repo")
$content = $content.Replace('Created: <YYYY-MM-DD>', "Created: $date")
Set-Content -Path $requestPath -Value $content -Encoding UTF8

Write-Host $reviewFolder
