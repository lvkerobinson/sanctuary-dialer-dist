<#
  Update-Dialer.ps1  --  keeps a rep's local dialer folder on the latest build.

  Runs SILENTLY on a schedule (installed by Install-DialerUpdater.ps1). It checks a
  hosted manifest.json for the latest version; if newer than what's installed locally,
  it downloads the new build and mirrors it into the local extension folder. The rep
  then picks it up by clicking "Reload" on the extension card (chrome://extensions) or
  simply restarting Chrome -- unpacked extensions reload from disk on restart.

  It NEVER needs admin, NEVER touches OneDrive, and is fail-safe: if the host is
  unreachable it just does nothing and tries again next run.

  ------------------------------------------------------------------------------------
  CONFIG -- set $BaseUrl to where you publish the build (see rollout/README.md).
  The host must serve two files at stable URLs:
     $BaseUrl/manifest.json       (the dist/ manifest -- the cheap "what version?" probe)
     $BaseUrl/dialer-latest.zip   (a zip of the dist/ folder -- the actual build)
  If the URL is gated by your backend key, put it in $AuthToken (sent as a Bearer header).
  ------------------------------------------------------------------------------------
#>

$BaseUrl   = 'https://raw.githubusercontent.com/lvkerobinson/sanctuary-dialer-dist/main'
$AuthToken = ''                                          # not needed: the repo is public, code-only

# SANCTUARY-DIALER-UPDATER  (self-update sentinel -- do not remove; validated before swap)
# Bump $RolloutVersion whenever THIS script changes. Deployed updaters compare it to the
# published rollout-version.txt and refresh themselves -- so the owner never has to touch a
# rep's PC again; reps only ever click Reload in Chrome.
$RolloutVersion = 2

# ---- Fixed local layout (LOCALAPPDATA is user-writable and NOT OneDrive-synced) ----
$Root    = Join-Path $env:LOCALAPPDATA 'SanctuaryMetalsDialer'
$Current = Join-Path $Root 'current'        # the folder Chrome has loaded as "unpacked"
$LogFile = Join-Path $Root 'update.log'

# Windows PowerShell 5.1 often defaults to old TLS, which GitHub (and most HTTPS hosts)
# reject -- the download then fails silently and the extension folder has no manifest.json.
# Force TLS 1.2 so the fetch works on every machine.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

function Write-Log($msg) {
  try {
    $line = ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg)
    Add-Content -Path $LogFile -Value $line -Encoding utf8
  } catch {}
}

function Get-RemoteText($url) {
  $headers = @{}
  if ($AuthToken) { $headers['Authorization'] = "Bearer $AuthToken" }
  # Cache-bust the probe so a CDN can't hand us a stale version number.
  $sep = $(if ($url -match '\?') { '&' } else { '?' })
  $bust = $url + $sep + '_=' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  return (Invoke-WebRequest -Uri $bust -Headers $headers -UseBasicParsing -TimeoutSec 30).Content
}

# Keep the UPDATER ITSELF current. Each run, compare the published rollout-version to the one
# baked into this script; if newer, download the new Update-Dialer.ps1 and replace this file
# in place. The scheduled task launches a stable VBS -> this script, so swapping the file's
# contents is all that's needed; the next run uses the new logic. Fully guarded + validated
# (non-trivial size, parses cleanly, carries the sentinel, and reports a strictly-higher
# version) so a bad/partial download can NEVER brick the updater -- on any doubt we keep the
# working copy. This is what lets fixes ship without ever revisiting a rep's PC.
function Invoke-SelfUpdate {
  try {
    $self = $PSCommandPath
    if (-not $self -or -not (Test-Path $self)) { return }
    $remoteRoll = (Get-RemoteText "$BaseUrl/rollout-version.txt").Trim()
    if ($remoteRoll -notmatch '^\d+$') { return }
    if ([int]$remoteRoll -le $RolloutVersion) { return }
    Write-Log "self-update: updater rollout v$RolloutVersion -> v$remoteRoll -- fetching new script"
    $headers = @{}; if ($AuthToken) { $headers['Authorization'] = "Bearer $AuthToken" }
    $bust = '?_=' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $newPs = (Invoke-WebRequest -Uri ("$BaseUrl/Update-Dialer.ps1" + $bust) -Headers $headers -UseBasicParsing -TimeoutSec 60).Content
    if (-not $newPs -or $newPs.Length -lt 800) { Write-Log "self-update: download too small -- keeping current"; return }
    $perr = $null
    [System.Management.Automation.Language.Parser]::ParseInput($newPs, [ref]$null, [ref]$perr) | Out-Null
    if ($perr -and $perr.Count) { Write-Log "self-update: new script has parse errors -- keeping current"; return }
    if ($newPs -notmatch 'SANCTUARY-DIALER-UPDATER') { Write-Log "self-update: sentinel missing -- keeping current"; return }
    if ($newPs -notmatch '\$RolloutVersion\s*=\s*(\d+)' -or [int]$Matches[1] -le $RolloutVersion) { Write-Log "self-update: new script not actually newer -- keeping current"; return }
    [System.IO.File]::WriteAllText("$self.new", $newPs, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item "$self.new" $self -Force
    Write-Log "self-update: updater refreshed to rollout v$remoteRoll (next run uses it)"
  } catch { Write-Log ("self-update: error -- " + $_.Exception.Message) }
}

try {
  if (-not (Test-Path $Root)) { New-Item -ItemType Directory -Path $Root -Force | Out-Null }
  Invoke-SelfUpdate   # keep the updater script itself current before doing the build update

  # 1) Local version (0.0.0.0 if nothing installed yet)
  $localVer = [version]'0.0.0.0'
  $localManifest = Join-Path $Current 'manifest.json'
  if (Test-Path $localManifest) {
    try { $localVer = [version]((Get-Content $localManifest -Raw | ConvertFrom-Json).version) } catch {}
  }

  # 2) Remote version
  $remoteVer = [version]((Get-RemoteText "$BaseUrl/manifest.json" | ConvertFrom-Json).version)

  if ($remoteVer -le $localVer) {
    Write-Log "up to date (local $localVer, remote $remoteVer)"
    return
  }
  Write-Log "update available: $localVer -> $remoteVer -- downloading"

  # 3) Download the build zip to a temp file
  $tmpZip = Join-Path $env:TEMP ("dialer-{0}.zip" -f $remoteVer)
  $tmpDir = Join-Path $env:TEMP ("dialer-stage-{0}" -f [guid]::NewGuid().ToString('N'))
  $headers = @{}
  if ($AuthToken) { $headers['Authorization'] = "Bearer $AuthToken" }
  Invoke-WebRequest -Uri "$BaseUrl/dialer-latest.zip" -Headers $headers -OutFile $tmpZip -UseBasicParsing -TimeoutSec 120

  # 4) Expand + validate it actually contains an extension (manifest.json present)
  if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force }
  Expand-Archive -Path $tmpZip -DestinationPath $tmpDir -Force
  # The zip may wrap files in a top folder (e.g. dist/). Find the manifest.json's folder.
  $manifestHit = Get-ChildItem -Path $tmpDir -Recurse -Filter 'manifest.json' | Select-Object -First 1
  if (-not $manifestHit) { throw "downloaded build has no manifest.json -- refusing to install" }
  $srcDir = $manifestHit.Directory.FullName

  $stagedVer = [version]((Get-Content $manifestHit.FullName -Raw | ConvertFrom-Json).version)
  if ($stagedVer -ne $remoteVer) {
    Write-Log "WARN: zip manifest version $stagedVer != advertised $remoteVer -- installing zip's actual version"
  }

  # 5) Mirror the new build into the live folder. robocopy /MIR handles files Chrome
  #    may have open and removes any files dropped from the new build. Exit codes 0-7
  #    are success; >=8 is a real failure.
  #    /XF config.local.js: the published build is CODE-ONLY (no secrets). Each rep's
  #    config.local.js was placed once at install and is theirs to keep -- exclude it so
  #    the mirror never overwrites or (in /MIR mode) deletes it.
  if (-not (Test-Path $Current)) { New-Item -ItemType Directory -Path $Current -Force | Out-Null }
  $rc = Start-Process -FilePath 'robocopy.exe' `
        -ArgumentList @("`"$srcDir`"", "`"$Current`"", '/MIR', '/XF', 'config.local.js', '/R:2', '/W:2', '/NJH', '/NJS', '/NDL', '/NFL') `
        -Wait -PassThru -WindowStyle Hidden
  if ($rc.ExitCode -ge 8) { throw "robocopy failed (exit $($rc.ExitCode))" }

  Write-Log "INSTALLED $stagedVer -- reps: click Reload on the extension, or just restart Chrome"

  # 6) Cleanup
  Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue
  Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}
catch {
  Write-Log ("ERROR: " + $_.Exception.Message)
}
