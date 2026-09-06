<#
.SYNOPSIS
  Installs multi-provider Claude Code profiles backed by a local OmniRoute gateway.
.DESCRIPTION
  Idempotent. Safe to re-run after editing profiles.json - that is how you customize.
.PARAMETER ApiKey
  Your OmniRoute API key. Omit to be prompted.
.PARAMETER SkipSmokeTest
  Skip the end-to-end test of each profile.
.PARAMETER ListModels
  Print every model your account exposes, grouped by provider, then exit.
  Use this to fill in profiles.json.
.PARAMETER TestModels
  Send a real one-token request to every model named in profiles.json and
  report which actually work. Routers advertise models their upstream accounts
  cannot serve; this is the only way to find those.
.PARAMETER DryRun
  Validate profiles.json against your account and report what would be built,
  without creating combos, writing profiles, or touching your PowerShell profile.
  Use this to check the package after editing it.
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\install.ps1
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\install.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [string] $ApiKey,
    [switch] $SkipSmokeTest,
    [switch] $DryRun,
    [switch] $ListModels,
    [switch] $TestModels
)

$ErrorActionPreference = 'Stop'
$Root   = Split-Path -Parent $MyInvocation.MyCommand.Path
$Marker = 'omniroute-profiles'

function Say  ($m) { Write-Host $m }
function Step ($m) { Write-Host "`n== $m" -ForegroundColor Cyan }
function Ok   ($m) { Write-Host "   [ok] $m" -ForegroundColor Green }
function Warn ($m) { Write-Host "   [!]  $m" -ForegroundColor Yellow }
function Die  ($m) { Write-Host "`n[X] $m" -ForegroundColor Red; exit 1 }

function Write-Utf8NoBom($Path, $Text) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

Say ""
Say "  Claude Code multi-provider profiles"
Say "  -----------------------------------"
Say "  Installs a local model router and adds one Claude Code command per profile."
Say ""

# ---------------------------------------------------------------- config
Step "Reading profiles.json"
$cfgPath = Join-Path $Root 'profiles.json'
if (-not (Test-Path $cfgPath)) { Die "profiles.json not found next to this script." }
try { $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json } catch { Die "profiles.json is not valid JSON: $_" }
$port = $cfg.gateway.port
$base = "http://localhost:$port"
Ok "$($cfg.profiles.Count) profiles, $($cfg.combos.Count) combos, gateway port $port"

# ---------------------------------------------------------------- claude
Step "Checking Claude Code"
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Die "Claude Code is not on PATH. Install it first: https://claude.com/claude-code"
}
Ok "claude found"

# ---------------------------------------------------------------- node
Step "Checking Node.js (needed to run the router)"
if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    Warn "Node.js is not installed."
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        $a = Read-Host "   Install Node.js LTS now via winget? [y/N]"
        if ($a -match '^(y|yes)$') {
            winget install --id OpenJS.NodeJS.LTS -e --accept-source-agreements --accept-package-agreements
            $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                        [Environment]::GetEnvironmentVariable('Path','User')
        }
    }
    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
        Die "Node.js required. Install the LTS build from https://nodejs.org , reopen PowerShell, re-run this script."
    }
}
Ok "npm found"

# ---------------------------------------------------------------- omniroute
Step "Installing the OmniRoute router"
if (Get-Command omniroute -ErrorAction SilentlyContinue) {
    Ok "already installed"
} else {
    Say "   npm install -g omniroute   (a few minutes)"
    npm install -g omniroute --silent
    if (-not (Get-Command omniroute -ErrorAction SilentlyContinue)) { Die "omniroute install failed." }
    Ok "installed"
}

# ---------------------------------------------------------------- server
Step "Starting the router"
# Any HTTP reply means it is listening - an unauthenticated probe returns 401,
# which is still proof of life. Only a transport failure means "not running".
function Test-Gateway {
    try   { Invoke-WebRequest "$base/v1/models" -TimeoutSec 5 -UseBasicParsing | Out-Null; return $true }
    catch { return ($null -ne $_.Exception.Response) }
}
if (Test-Gateway) {
    Ok "already running on $base"
} else {
    # npm installs `omniroute` as a .ps1/.cmd shim, not an .exe - Start-Process
    # cannot launch the .ps1 directly, so go through cmd.exe which picks the .cmd.
    Start-Process -FilePath $env:ComSpec -ArgumentList '/c', 'omniroute serve' -WindowStyle Hidden
    Say "   waiting for it to come up..."
    for ($i = 0; $i -lt 40 -and -not (Test-Gateway); $i++) { Start-Sleep -Milliseconds 1500 }
    if (-not (Test-Gateway)) {
        Die "Router did not come up on $base. Run 'omniroute serve' in another window, watch for an error, then re-run."
    }
    Ok "running on $base"
}

# ---------------------------------------------------------------- accounts
Step "Provider accounts and API key"
Say ""
Say "   In the dashboard, do two things:"
Say "     1. Add providers   (sign in to each one you want; the free ones need nothing)"
Say "     2. Create an API key and copy it"
Say ""
Say "   Dashboard: $base/dashboard"
Say ""
if (-not $ApiKey) {
    try { Start-Process "$base/dashboard" } catch { }
    $ApiKey = Read-Host "   Paste your OmniRoute API key"
}
if (-not $ApiKey) { Die "No API key supplied." }

$hdr = @{ Authorization = "Bearer $ApiKey" }
try   { $models = (Invoke-RestMethod "$base/v1/models" -Headers $hdr -TimeoutSec 20).data }
catch { Die "That key was rejected. Create one at $base/dashboard and re-run." }
$available = @{}
foreach ($m in $models) { $available[$m.id] = $true }
Ok "key accepted - $($available.Count) models visible"

# ---------------------------------------------------------------- list
if ($ListModels) {
    Step "Models your account exposes"
    $models | Group-Object { ($_.id -split '/')[0] } | Sort-Object Name | ForEach-Object {
        Say ""
        Say "  $($_.Name)  ($($_.Count))"
        $_.Group | Sort-Object id | ForEach-Object { Say "     $($_.id)" }
    }
    Say ""
    Say "  Put the ones you want into profiles.json, then run -TestModels."
    Say ""
    exit 0
}

# ---------------------------------------------------------------- test
# A router's catalog lists what its providers advertise, not what your account
# can actually serve. The only reliable check is to call each model once.
if ($TestModels) {
    Step "Testing every model named in profiles.json"
    $seen = @{}
    $dead = @()
    foreach ($c in $cfg.combos) {
        foreach ($m in $c.models) {
            if ($seen.ContainsKey($m)) { continue }
            $seen[$m] = $true
            $body = @{ model = $m; max_tokens = 8
                       messages = @(@{ role = 'user'; content = 'Say OK' }) } | ConvertTo-Json -Depth 6
            try {
                $r = Invoke-RestMethod "$base/v1/messages" -Method Post -Headers $hdr `
                        -ContentType 'application/json' -Body $body -TimeoutSec 120
                if ($r.content) { Ok "$m" } else { Warn "$m - empty reply"; $dead += $m }
            } catch {
                $msg = $_.ErrorDetails.Message
                if (-not $msg) { $msg = $_.Exception.Message }
                Warn "$m - $($msg -replace '\s+',' ' -replace '^(.{80}).*$','$1')"
                $dead += $m
            }
        }
    }
    Say ""
    if ($dead.Count -eq 0) {
        Ok "all $($seen.Count) models work"
    } else {
        Warn "$($dead.Count) of $($seen.Count) models are unusable - remove them from profiles.json:"
        $dead | ForEach-Object { Say "     $_" }
    }
    Say ""
    exit 0
}

# ---------------------------------------------------------------- combos
Step "Creating routing combos"
$env:OMNIROUTE_API_KEY = $ApiKey
$existing = @()
try { $existing = (Invoke-RestMethod "$base/v1/combos" -Headers $hdr -TimeoutSec 20).data.name } catch { }
$goodCombos = @{}

foreach ($c in $cfg.combos) {
    $have    = @($c.models | Where-Object { $available.ContainsKey($_) })
    $missing = @($c.models | Where-Object { -not $available.ContainsKey($_) })
    if ($have.Count -eq 0) {
        Warn "$($c.name): skipped - you have none of its models"
        continue
    }
    if ($missing.Count -gt 0) { Warn "$($c.name): dropping unavailable - $($missing -join ', ')" }
    if ($DryRun) {
        $goodCombos[$c.name] = $true
        Ok "would create $($c.name) [$($c.strategy)] - $($have.Count) models"
        continue
    }
    if ($existing -contains $c.name) { & omniroute combo delete $c.name --yes 2>&1 | Out-Null }
    $out = & omniroute combo create $c.name --strategy $c.strategy --models ($have -join ',') 2>&1
    if ($LASTEXITCODE -eq 0) {
        $goodCombos[$c.name] = $true
        Ok "$($c.name) [$($c.strategy)] - $($have.Count) models"
    } else {
        Warn "$($c.name): create failed - $out"
    }
}
if ($goodCombos.Count -eq 0) { Die "No combos could be created. Add at least one provider at $base/dashboard." }

# ---------------------------------------------------------------- profiles
Step "Writing Claude Code profiles"
$installed = @()
foreach ($p in $cfg.profiles) {
    $need = @($p.slots.opus, $p.slots.sonnet, $p.slots.haiku) | Sort-Object -Unique
    $bad  = @($need | Where-Object { -not $goodCombos.ContainsKey($_) })
    if ($bad.Count -gt 0) { Warn "$($p.command): skipped - needs combo(s) $($bad -join ', ')"; continue }

    $dir = Join-Path $HOME $p.dir
    if ($DryRun) {
        $installed += $p
        Ok "would write $($p.command)  ->  ~\$($p.dir)  [opus=$($p.slots.opus) sonnet=$($p.slots.sonnet) haiku=$($p.slots.haiku)]"
        continue
    }
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $settings = [ordered]@{
        env = [ordered]@{
            ANTHROPIC_BASE_URL                       = $base
            ANTHROPIC_AUTH_TOKEN                     = $ApiKey
            ANTHROPIC_DEFAULT_OPUS_MODEL             = $p.slots.opus
            ANTHROPIC_DEFAULT_SONNET_MODEL           = $p.slots.sonnet
            ANTHROPIC_DEFAULT_HAIKU_MODEL            = $p.slots.haiku
            ANTHROPIC_DEFAULT_FABLE_MODEL            = $p.slots.opus
            ANTHROPIC_MODEL                          = $p.slots.opus
            CLAUDE_CODE_MAX_CONTEXT_TOKENS           = "$($cfg.gateway.contextTokens)"
        }
        model = $p.slots.opus
    }
    Write-Utf8NoBom (Join-Path $dir 'settings.json') ($settings | ConvertTo-Json -Depth 10)

    # Never clobber an existing .claude.json - it holds that profile's history.
    $cj = Join-Path $dir '.claude.json'
    if (-not (Test-Path $cj)) {
        Write-Utf8NoBom $cj (([ordered]@{ hasCompletedOnboarding = $true }) | ConvertTo-Json)
    }

    if ($p.delegation) {
        # CLAUDE.md is the file people tailor to their own data rules, so never
        # clobber an edited one. Delete it to take a fresh copy of the template.
        $src = Join-Path $Root 'templates\CLAUDE.md'
        $dst = Join-Path $dir 'CLAUDE.md'
        if (-not (Test-Path $dst)) {
            Copy-Item $src $dst -Force
        } elseif ((Get-Content $dst -Raw) -ne (Get-Content $src -Raw)) {
            Warn "$($p.command): kept your edited CLAUDE.md (delete it to take the template version)"
        }
        $ad = Join-Path $dir 'agents'
        if (-not (Test-Path $ad)) { New-Item -ItemType Directory -Path $ad -Force | Out-Null }
        Copy-Item (Join-Path $Root 'templates\agents\*.md') $ad -Force
    }
    $installed += $p
    Ok "$($p.command)  ->  ~\$($p.dir)"
}
if ($installed.Count -eq 0) { Die "No profiles could be installed." }

# ---------------------------------------------------------------- launchers
if ($DryRun) {
    Step "Dry run complete - nothing was changed"
    Say ""
    Say "   Would install: $(($installed | ForEach-Object { $_.command }) -join ', ')"
    Say "   Into:          $($PROFILE.CurrentUserCurrentHost)"
    Say ""
    Say "   Re-run without -DryRun to apply."
    Say ""
    exit 0
}

Step "Adding commands to your PowerShell profile"
$L = New-Object System.Collections.Generic.List[string]
$L.Add("# >>> $Marker >>>  (managed block - edit profiles.json and re-run install.ps1)")
$L.Add('$script:OmniVars = @(')
$L.Add("    'CLAUDE_CONFIG_DIR','ANTHROPIC_BASE_URL','ANTHROPIC_AUTH_TOKEN',")
$L.Add("    'ANTHROPIC_MODEL','ANTHROPIC_DEFAULT_OPUS_MODEL','ANTHROPIC_DEFAULT_FABLE_MODEL',")
$L.Add("    'ANTHROPIC_DEFAULT_SONNET_MODEL','ANTHROPIC_DEFAULT_HAIKU_MODEL',")
$L.Add("    'CLAUDE_CODE_MAX_CONTEXT_TOKENS')")
$L.Add('function Clear-OmniProfile { foreach ($n in $script:OmniVars) { Remove-Item "Env:\$n" -ErrorAction SilentlyContinue } }')
$L.Add('function Get-OmniProfile {')
$L.Add('    if (-not $env:CLAUDE_CONFIG_DIR) { return "no profile active" }')
$L.Add('    [pscustomobject]@{')
$L.Add('        ConfigDir = $env:CLAUDE_CONFIG_DIR')
$L.Add('        Opus      = $env:ANTHROPIC_DEFAULT_OPUS_MODEL')
$L.Add('        Sonnet    = $env:ANTHROPIC_DEFAULT_SONNET_MODEL')
$L.Add('        Haiku     = $env:ANTHROPIC_DEFAULT_HAIKU_MODEL')
$L.Add('    }')
$L.Add('}')
$L.Add('# The router does not autostart on Windows, so bring it up on demand.')
$L.Add('# Any HTTP reply (incl. 401) proves it is listening; only a transport error means down.')
$L.Add('function Test-OmniGateway {')
$L.Add('    param([string]$Url)')
$L.Add('    try { Invoke-WebRequest "$Url/v1/models" -TimeoutSec 3 -UseBasicParsing | Out-Null; return $true }')
$L.Add('    catch { return ($null -ne $_.Exception.Response) }')
$L.Add('}')
$L.Add('function Start-OmniGateway {')
$L.Add('    param([string]$Url)')
$L.Add('    if (Test-OmniGateway $Url) { return $true }')
$L.Add('    Write-Host "  starting the model router..." -ForegroundColor DarkGray')
$L.Add('    Start-Process -FilePath $env:ComSpec -ArgumentList "/c","omniroute serve" -WindowStyle Hidden')
$L.Add('    for ($i = 0; $i -lt 30; $i++) {')
$L.Add('        Start-Sleep -Milliseconds 1000')
$L.Add('        if (Test-OmniGateway $Url) { return $true }')
$L.Add('    }')
$L.Add('    return $false')
$L.Add('}')
$L.Add('function Invoke-OmniClaude {')
$L.Add('    param([Parameter(Mandatory)][string]$Dir,[string[]]$Extra,[string[]]$Passthru)')
$L.Add('    Clear-OmniProfile   # entry-clear: a killed run can never leak into another profile')
$L.Add('    $path = Join-Path $HOME $Dir')
$L.Add('    $file = Join-Path $path "settings.json"')
$L.Add('    if (-not (Test-Path $file)) { Write-Error "Missing $file"; return }')
$L.Add('    $env:CLAUDE_CONFIG_DIR = $path')
$L.Add('    (Get-Content $file -Raw | ConvertFrom-Json).env.PSObject.Properties |')
$L.Add('        ForEach-Object { Set-Item "Env:\$($_.Name)" $_.Value }')
$L.Add('    if (-not (Start-OmniGateway $env:ANTHROPIC_BASE_URL)) {')
$L.Add('        Clear-OmniProfile')
$L.Add('        Write-Error "The model router is not responding. Run ''omniroute serve'' in another window to see why."')
$L.Add('        return')
$L.Add('    }')
$L.Add('    try { & claude @Extra @Passthru } finally { Clear-OmniProfile }')
$L.Add('}')
foreach ($p in $installed) {
    if ($p.extraArgs.Count -gt 0) { $extra = " -Extra @('" + ($p.extraArgs -join "','") + "')" } else { $extra = "" }
    $L.Add("# $($p.summary)")
    $L.Add("function $($p.command) { Invoke-OmniClaude -Dir '$($p.dir)'$extra -Passthru `$args }")
}
$L.Add("# <<< $Marker <<<")
$block = ($L -join "`r`n")

   # CurrentUserCurrentHost is what a bare `. $PROFILE` reloads - keep them the same
   # file, or the commands would land somewhere the documented reload never reads.
$profilePath = $PROFILE.CurrentUserCurrentHost
if (-not (Test-Path $profilePath)) { New-Item -ItemType File -Path $profilePath -Force | Out-Null }
$cur = Get-Content $profilePath -Raw
if ($null -eq $cur) { $cur = '' }
$pattern = "(?ms)^# >>> $Marker >>>.*?^# <<< $Marker <<<\r?\n?"
if ($cur -match $pattern) {
    $new = [regex]::Replace($cur, $pattern, '')
    Ok "replaced the existing managed block"
} else {
    $new = $cur
    Ok "added a new managed block"
}
Write-Utf8NoBom $profilePath ($new.TrimEnd() + "`r`n`r`n" + $block + "`r`n")
Ok "profile: $profilePath"

# ---------------------------------------------------------------- verify
if (-not $SkipSmokeTest) {
    Step "Testing each profile end to end"
    . $profilePath
    # Claude Code prints a harmless [claude-code:unrecognized_model] note to stderr
    # because a combo name is not in its model catalog. Under 'Stop', PowerShell 5.1
    # would turn that into a terminating error, so relax it and filter the line out.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    foreach ($p in $installed) {
        $out = Invoke-OmniClaude -Dir $p.dir -Passthru @('-p', 'Reply with exactly: OK') 2>&1 |
               ForEach-Object { "$_" }
        $clean = @($out | Where-Object { $_ -notmatch '^\[claude-code:' -and $_.Trim() -ne '' })
        if ($clean -match 'OK') {
            Ok "$($p.command) works"
        } else {
            Warn "$($p.command) - unexpected reply: $($clean -join ' | ')"
        }
    }
    $ErrorActionPreference = $prevEap
}

Step "Done"
Say ""
Say "   Reload your shell, then use:"
Say ""
foreach ($p in $installed) { Say ("     {0,-16} {1}" -f $p.command, $p.summary) }
Say ""
Say "     . `$PROFILE"
Say ""
Say "   Customize: edit profiles.json, re-run this script."
Say "   Remove:    .\uninstall.ps1"
Say ""
