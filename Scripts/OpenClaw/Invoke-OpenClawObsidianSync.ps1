[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$VaultPath,
    [string]$OpenClawHome = "$env:USERPROFILE\.openclaw",
    [switch]$NoPush
)

$ErrorActionPreference = "Stop"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Exporter = Join-Path $ScriptRoot "Export-OpenClawConversations.py"
$LockPath = Join-Path $VaultPath ".openclaw-sync.lock"

if (-not (Test-Path -LiteralPath (Join-Path $VaultPath ".git"))) {
    throw "VaultPath is not a Git repository: $VaultPath"
}
if (Test-Path -LiteralPath $LockPath) {
    $age = (Get-Date) - (Get-Item -LiteralPath $LockPath).LastWriteTime
    if ($age.TotalMinutes -lt 30) {
        Write-Host "OpenClaw sync is already running."
        exit 0
    }
    Remove-Item -LiteralPath $LockPath -Force
}

Set-Content -LiteralPath $LockPath -Value $PID -Encoding ASCII
try {
    $statusBefore = & git -C $VaultPath status --porcelain
    if ($LASTEXITCODE -ne 0) { throw "Unable to inspect Obsidian Git repository." }
    $unrelated = @($statusBefore | Where-Object {
        $_ -and $_ -notmatch 'Inbox/OpenClaw/' -and $_ -notmatch '\.openclaw-sync-manifest\.json'
    })
    if ($unrelated.Count -gt 0) {
        throw "Obsidian repository has unrelated changes. Commit or stash them before automatic sync."
    }

    $exportJson = & python $Exporter --openclaw-home $OpenClawHome --vault $VaultPath
    if ($LASTEXITCODE -ne 0) { throw "OpenClaw conversation export failed." }
    $exportResult = $exportJson | ConvertFrom-Json

    if ($exportResult.changedCount -eq 0) {
        Write-Host "OpenClaw conversations are already up to date."
        exit 0
    }

    & git -C $VaultPath add -- "Inbox/OpenClaw" ".openclaw-sync-manifest.json"
    if ($LASTEXITCODE -ne 0) { throw "Unable to stage OpenClaw conversation notes." }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm"
    & git -C $VaultPath commit -m "docs(openclaw): sync gateway conversations $timestamp"
    if ($LASTEXITCODE -ne 0) { throw "Unable to commit OpenClaw conversation notes." }

    if (-not $NoPush) {
        & git -C $VaultPath fetch --prune
        if ($LASTEXITCODE -ne 0) { throw "Fetch failed; the local conversation commit was preserved." }

        $branch = (& git -C $VaultPath branch --show-current).Trim()
        $upstream = (& git -C $VaultPath rev-parse --abbrev-ref --symbolic-full-name "@{u}" 2>$null).Trim()
        if (-not $upstream) { throw "No upstream is configured; the local conversation commit was preserved." }

        $aheadBehind = (& git -C $VaultPath rev-list --left-right --count "$upstream...HEAD").Trim() -split '\s+'
        $behind = [int]$aheadBehind[0]
        if ($behind -gt 0) {
            throw "Remote contains new commits. Automatic force/rebase is disabled; local conversation commit was preserved."
        }

        & git -C $VaultPath push
        if ($LASTEXITCODE -ne 0) { throw "Push failed; the local conversation commit was preserved." }
    }

    Write-Host "Synced $($exportResult.changedCount) OpenClaw conversation note(s)."
}
finally {
    Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
}
