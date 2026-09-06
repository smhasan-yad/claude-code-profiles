<#
.SYNOPSIS
  Removes what install.ps1 added.
.DESCRIPTION
  Removes the managed block from your PowerShell profile and, with -RemoveConfigs,
  the profile directories too. Leaves Node, OmniRoute and your provider logins alone.
.PARAMETER RemoveConfigs
  Also delete the ~/.claude-* directories this created, including their chat history.
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
#>
[CmdletBinding()]
param([switch] $RemoveConfigs)

$ErrorActionPreference = 'Stop'
$Root   = Split-Path -Parent $MyInvocation.MyCommand.Path
$Marker = 'omniroute-profiles'

function Say ($m) { Write-Host $m }
function Ok  ($m) { Write-Host "   [ok] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "   [!]  $m" -ForegroundColor Yellow }

Say ""
Say "  Removing omniroute-profiles"
Say ""

# --- PowerShell profile block -------------------------------------------
$profilePath = $PROFILE.CurrentUserCurrentHost
if (Test-Path $profilePath) {
    $cur = Get-Content $profilePath -Raw
    $pattern = "(?ms)^# >>> $Marker >>>.*?^# <<< $Marker <<<\r?\n?"
    if ($cur -match $pattern) {
        $new = [regex]::Replace($cur, $pattern, '').TrimEnd() + "`r`n"
        [System.IO.File]::WriteAllText($profilePath, $new, (New-Object System.Text.UTF8Encoding($false)))
        Ok "removed the managed block from $profilePath"
    } else {
        Warn "no managed block found in $profilePath"
    }
} else {
    Warn "no PowerShell profile at $profilePath"
}

# --- config dirs ---------------------------------------------------------
$cfgPath = Join-Path $Root 'profiles.json'
if (Test-Path $cfgPath) {
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    foreach ($p in $cfg.profiles) {
        $dir = Join-Path $HOME $p.dir
        if (-not (Test-Path $dir)) { continue }
        if ($RemoveConfigs) {
            Remove-Item $dir -Recurse -Force
            Ok "deleted $dir"
        } else {
            Say "   kept  $dir   (delete with: .\uninstall.ps1 -RemoveConfigs)"
        }
    }
}

Say ""
Say "  Left alone on purpose: Node.js, the OmniRoute install, your provider logins,"
Say "  your routing combos, and your original claude command."
Say ""
Say "  To go further:"
Say "    omniroute stop              stop the router"
Say "    npm uninstall -g omniroute  remove the router"
Say ""
