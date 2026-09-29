[CmdletBinding()]
param(
    [string]$VaultPath = "$env:USERPROFILE\OneDrive\Desktop\data\myObsidian",
    [string]$OpenClawHome = "$env:USERPROFILE\.openclaw",
    [string]$TaskName = "TurboMeta OpenClaw Obsidian Sync"
)

$ErrorActionPreference = "Stop"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Exporter = Join-Path $ScriptRoot "Export-OpenClawConversations.py"
$SyncScript = Join-Path $ScriptRoot "Invoke-OpenClawObsidianSync.ps1"

if (-not (Test-Path -LiteralPath $OpenClawHome)) { throw "OpenClaw home not found: $OpenClawHome" }
if (-not (Test-Path -LiteralPath (Join-Path $VaultPath ".git"))) { throw "Obsidian Git repository not found: $VaultPath" }

$remote = (& git -C $VaultPath remote get-url origin 2>$null).Trim()
if (-not $remote) { throw "Obsidian repository has no origin remote." }

Write-Host "OpenClaw home : $OpenClawHome"
Write-Host "Obsidian vault : $VaultPath"
Write-Host "Git remote     : $remote"
Write-Warning "Conversation originals may contain private information. Continue only if this remote repository is private."

$previewJson = & python $Exporter --openclaw-home $OpenClawHome --vault $VaultPath --dry-run
if ($LASTEXITCODE -ne 0) { throw "Dry-run export failed." }
$preview = $previewJson | ConvertFrom-Json
Write-Host "Gateway sessions found: $($preview.sessions)"
Write-Host "Notes to create/update : $($preview.changedCount)"

$approval = Read-Host "Create the initial notes and local Git commit? Type YES"
if ($approval -cne "YES") {
    Write-Host "Installation cancelled without writing conversation notes."
    exit 0
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SyncScript -VaultPath $VaultPath -OpenClawHome $OpenClawHome -NoPush
if ($LASTEXITCODE -ne 0) { throw "Initial local sync failed." }

$pushApproval = Read-Host "Push the initial conversation commit to the private remote? Type PUSH"
if ($pushApproval -ceq "PUSH") {
    & git -C $VaultPath fetch --prune
    if ($LASTEXITCODE -ne 0) { throw "Fetch failed; local commit remains available." }
    & git -C $VaultPath push
    if ($LASTEXITCODE -ne 0) { throw "Push failed; local commit remains available." }
} else {
    Write-Warning "Initial commit was not pushed. Review and push it before enabling automation."
    exit 0
}

$escapedSync = $SyncScript.Replace('"', '`"')
$escapedVault = $VaultPath.Replace('"', '`"')
$escapedHome = $OpenClawHome.Replace('"', '`"')
$arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$escapedSync`" -VaultPath `"$escapedVault`" -OpenClawHome `"$escapedHome`""
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arguments
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) `
    -RepetitionInterval (New-TimeSpan -Minutes 5) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Description "Export OpenClaw Gateway conversations to private myObsidian and push changes safely." -Force | Out-Null

Write-Host "Installed scheduled task '$TaskName' with a 5-minute interval."
