#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Migrates rippled → xrpld on Windows.

.DESCRIPTION
    Detects how rippled was installed (MSI / Chocolatey / Scoop / plain binary),
    locates the config file, detects how the process is managed (Windows Service /
    Task Scheduler / manual), updates cron-equivalent Task Scheduler entries and
    monitoring tool configs, then installs xrpld and starts it.

.PARAMETER Yes
    Non-interactive: accept all prompts with defaults.

.PARAMETER ConfigDir
    Override the directory to search for rippled.cfg.

.EXAMPLE
    # Interactive
    .\migrate_to_xrpld.ps1

    # Fully automated
    .\migrate_to_xrpld.ps1 -Yes
#>

[CmdletBinding()]
param(
    [switch]$Yes,
    [string]$ConfigDir = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Colour helpers ─────────────────────────────────────────────────────────────
function Write-Info    { param([string]$Msg) Write-Host "[INFO]  $Msg" -ForegroundColor Cyan }
function Write-Warn    { param([string]$Msg) Write-Host "[WARN]  $Msg" -ForegroundColor Yellow }
function Write-Success { param([string]$Msg) Write-Host "[OK]    $Msg" -ForegroundColor Green }
function Write-Err     { param([string]$Msg) Write-Host "[ERROR] $Msg" -ForegroundColor Red }
function Write-Header  { param([string]$Msg) Write-Host "`n══ $Msg ══" -ForegroundColor Cyan }
function Fail          { param([string]$Msg) Write-Err $Msg; exit 1 }

function Ask-YesNo {
    param([string]$Question, [bool]$DefaultYes = $true)
    if ($Yes) { return $DefaultYes }
    $hint = if ($DefaultYes) { "[Y/n]" } else { "[y/N]" }
    $answer = Read-Host "? $Question $hint"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $DefaultYes }
    return $answer -match '^[Yy]'
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 1 — OS & environment check
# ─────────────────────────────────────────────────────────────────────────────
Write-Header "Environment check"

$OSVersion = [System.Environment]::OSVersion.VersionString
Write-Info "OS : $OSVersion"

# Check PowerShell version
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Fail "PowerShell 5.0 or later is required. Current: $($PSVersionTable.PSVersion)"
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 2 — Detect rippled installation
# ─────────────────────────────────────────────────────────────────────────────
Write-Header "Detecting rippled installation"

$InstallMethod = ""   # msi | chocolatey | scoop | binary | not_found
$RippledBin    = ""
$RippledVersion = ""

function Get-RippledVersion {
    param([string]$BinPath)
    try {
        $out = & $BinPath --version 2>&1 | Select-Object -First 1
        return $out
    } catch { return "unknown" }
}

function Detect-Installation {
    # ── Chocolatey ──────────────────────────────────────────────────────────
    if (Get-Command choco -ErrorAction SilentlyContinue) {
        $chocoList = choco list --local-only 2>$null | Select-String 'rippled'
        if ($chocoList) {
            $script:InstallMethod = "chocolatey"
            $script:RippledBin = (Get-Command rippled -ErrorAction SilentlyContinue)?.Source
            Write-Info "Found rippled via Chocolatey"
            return
        }
    }

    # ── Scoop ────────────────────────────────────────────────────────────────
    if (Get-Command scoop -ErrorAction SilentlyContinue) {
        $scoopList = scoop list 2>$null | Select-String 'rippled'
        if ($scoopList) {
            $script:InstallMethod = "scoop"
            $script:RippledBin = (Get-Command rippled -ErrorAction SilentlyContinue)?.Source
            Write-Info "Found rippled via Scoop"
            return
        }
    }

    # ── MSI (Programs & Features / WMI) ─────────────────────────────────────
    $msiEntry = Get-WmiObject -Class Win32_Product -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'rippled' } | Select-Object -First 1
    if (-not $msiEntry) {
        # Faster registry check
        $regPaths = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
        )
        foreach ($rp in $regPaths) {
            $found = Get-ItemProperty $rp -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -match 'rippled' } | Select-Object -First 1
            if ($found) { $msiEntry = $found; break }
        }
    }
    if ($msiEntry) {
        $script:InstallMethod = "msi"
        # Try to find the binary from the install location
        $installLoc = $msiEntry.InstallLocation ?? $msiEntry.InstallSource ?? ""
        $candidate = Join-Path $installLoc "rippled.exe"
        if (Test-Path $candidate) { $script:RippledBin = $candidate }
        Write-Info "Found rippled as MSI install"
        if (-not $script:RippledBin) {
            $script:RippledBin = (Get-Command rippled -ErrorAction SilentlyContinue)?.Source
        }
        return
    }

    # ── Plain binary (PATH / common locations) ───────────────────────────────
    $binaryCmd = Get-Command rippled -ErrorAction SilentlyContinue
    if ($binaryCmd) {
        $script:InstallMethod = "binary"
        $script:RippledBin = $binaryCmd.Source
        Write-Info "Found rippled as standalone binary: $($script:RippledBin)"
        return
    }

    $commonPaths = @(
        "C:\Program Files\Ripple\rippled\rippled.exe",
        "C:\Program Files (x86)\Ripple\rippled\rippled.exe",
        "C:\rippled\rippled.exe",
        "$env:LOCALAPPDATA\rippled\rippled.exe"
    )
    foreach ($p in $commonPaths) {
        if (Test-Path $p) {
            $script:InstallMethod = "binary"
            $script:RippledBin = $p
            Write-Info "Found rippled binary at: $p"
            return
        }
    }

    $script:InstallMethod = "not_found"
}

Detect-Installation

if ($InstallMethod -eq "not_found") {
    Fail "rippled not found on this system. Nothing to migrate."
}

if ($RippledBin -and (Test-Path $RippledBin)) {
    $RippledVersion = Get-RippledVersion -BinPath $RippledBin
    Write-Info "Version  : $RippledVersion"
}

Write-Info "Install  : $InstallMethod"
Write-Info "Binary   : $($RippledBin ?? '(not resolved)')"

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 3 — Detect config file
# ─────────────────────────────────────────────────────────────────────────────
Write-Header "Detecting config file"

$ConfigFile = ""
$ConfigDirectory = ""

function Detect-Config {
    $candidates = @()

    if ($ConfigDir -ne "") {
        $candidates = @(
            (Join-Path $ConfigDir "rippled.cfg"),
            (Join-Path $ConfigDir "xrpld.cfg")
        )
    } else {
        $candidates = @(
            "C:\Program Files\Ripple\rippled\rippled.cfg",
            "C:\Program Files (x86)\Ripple\rippled\rippled.cfg",
            "C:\ProgramData\Ripple\rippled\rippled.cfg",
            "C:\ProgramData\xrpld\rippled.cfg",
            "$env:APPDATA\Ripple\rippled.cfg",
            "$env:LOCALAPPDATA\rippled\rippled.cfg",
            "C:\rippled\rippled.cfg"
        )

        # Derive from binary location
        if ($script:RippledBin) {
            $binDir = Split-Path $script:RippledBin
            $candidates += Join-Path $binDir "rippled.cfg"
            $candidates += Join-Path (Split-Path $binDir) "etc\rippled.cfg"
        }
    }

    foreach ($c in $candidates) {
        if (Test-Path $c) {
            $script:ConfigFile = $c
            $script:ConfigDirectory = Split-Path $c
            break
        }
    }

    # Check running process arguments
    if (-not $script:ConfigFile) {
        $proc = Get-Process -Name rippled -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($proc) {
            try {
                $wmiProc = Get-WmiObject Win32_Process -Filter "ProcessId=$($proc.Id)" -ErrorAction SilentlyContinue
                if ($wmiProc -and $wmiProc.CommandLine -match '--conf\s+"?([^"]+\.cfg)"?') {
                    $cfgFromProc = $Matches[1].Trim()
                    if (Test-Path $cfgFromProc) {
                        $script:ConfigFile = $cfgFromProc
                        $script:ConfigDirectory = Split-Path $cfgFromProc
                    }
                }
            } catch {}
        }
    }

    if ($script:ConfigFile) {
        Write-Info "Config   : $($script:ConfigFile)"
    } else {
        Write-Warn "No rippled.cfg found. Continuing — config step will be skipped."
    }
}

Detect-Config

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 4 — Detect startup method
# ─────────────────────────────────────────────────────────────────────────────
Write-Header "Detecting startup method"

$StartMethod   = ""   # service | taskscheduler | manual | none
$ServiceName   = "rippled"
$TaskSchedName = ""

function Detect-Startup {
    # ── Windows Service ──────────────────────────────────────────────────────
    $svc = Get-Service -Name "rippled" -ErrorAction SilentlyContinue
    if ($svc) {
        $script:StartMethod = "service"
        $script:ServiceName = "rippled"
        Write-Info "Startup  : Windows Service (rippled)"
        Write-Info "State    : $($svc.Status)"
        return
    }

    # Some installs register under a different display name
    $svcAlt = Get-WmiObject Win32_Service -ErrorAction SilentlyContinue |
        Where-Object { $_.PathName -match 'rippled' } | Select-Object -First 1
    if ($svcAlt) {
        $script:StartMethod = "service"
        $script:ServiceName = $svcAlt.Name
        Write-Info "Startup  : Windows Service ($($svcAlt.Name))"
        return
    }

    # ── Task Scheduler ───────────────────────────────────────────────────────
    $tasks = Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object { $_.TaskName -match 'rippled' -or $_.Actions.Execute -match 'rippled' }
    if ($tasks) {
        $script:StartMethod = "taskscheduler"
        $script:TaskSchedName = ($tasks | Select-Object -First 1).TaskName
        Write-Info "Startup  : Task Scheduler ($($script:TaskSchedName))"
        return
    }

    # ── Manual / bare process ────────────────────────────────────────────────
    $proc = Get-Process -Name rippled -ErrorAction SilentlyContinue
    if ($proc) {
        $script:StartMethod = "manual"
        Write-Warn "Startup  : manual (rippled is running, no service/scheduler found)"
    } else {
        $script:StartMethod = "none"
        Write-Info "Startup  : not currently managed / not running"
    }
}

Detect-Startup

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 5 — Detect Task Scheduler entries referencing rippled
# ─────────────────────────────────────────────────────────────────────────────
Write-Header "Detecting Task Scheduler entries"

$TasksWithRippled = @()

function Detect-TaskSchedulerJobs {
    $allTasks = Get-ScheduledTask -ErrorAction SilentlyContinue
    foreach ($t in $allTasks) {
        $actions = $t.Actions
        foreach ($a in $actions) {
            $exe = $a.Execute ?? ""
            $args = $a.Arguments ?? ""
            if ($exe -match 'rippled' -or $args -match 'rippled') {
                $script:TasksWithRippled += $t
                Write-Info "Task Scheduler entry referencing rippled: $($t.TaskName)"
                break
            }
        }
    }
    if ($script:TasksWithRippled.Count -eq 0) {
        Write-Info "No Task Scheduler entries referencing rippled found."
    }
}

Detect-TaskSchedulerJobs

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 6 — Detect monitoring tools referencing rippled
# ─────────────────────────────────────────────────────────────────────────────
Write-Header "Detecting monitoring tool configs"

$MonitoringFiles = @()   # list of [path, tool]

function Detect-Monitoring {
    $searchDirs = @(
        "C:\Program Files\Datadog\Datadog Agent\etc\conf.d",
        "C:\ProgramData\Datadog\conf.d",
        "C:\Program Files\PRTG Network Monitor",
        "C:\Program Files (x86)\PRTG Network Monitor",
        "C:\ProgramData\Nagios",
        "C:\Program Files\NSClient++",
        "C:\nsclient",
        "C:\Program Files\Prometheus"
    )

    foreach ($dir in $searchDirs) {
        if (Test-Path $dir) {
            $matches_ = Get-ChildItem -Path $dir -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { (Select-String -Path $_.FullName -Pattern '\brippled\b' -Quiet -ErrorAction SilentlyContinue) }
            foreach ($f in $matches_) {
                $script:MonitoringFiles += $f.FullName
                Write-Info "Monitoring config referencing rippled: $($f.FullName)"
            }
        }
    }

    # Scheduled tasks acting as monitors / watchdogs (already detected above)
    # Only flag here if they weren't already the primary startup method
    if ($StartMethod -ne "taskscheduler") {
        foreach ($t in $TasksWithRippled) {
            Write-Info "Watchdog task referencing rippled: $($t.TaskName)"
        }
    }

    if ($MonitoringFiles.Count -eq 0) {
        Write-Info "No monitoring configs referencing rippled found."
    }
}

Detect-Monitoring

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 7 — Summary & confirmation
# ─────────────────────────────────────────────────────────────────────────────
Write-Header "Migration summary"

Write-Host ""
Write-Host "  OS              : $OSVersion"
Write-Host "  Install method  : $InstallMethod"
Write-Host "  Binary          : $($RippledBin ?? '(not resolved)')"
Write-Host "  Config file     : $($ConfigFile ?: '(not found)')"
Write-Host "  Startup method  : $StartMethod"
if ($TasksWithRippled.Count -gt 0) {
    Write-Host "  Sched tasks     : $($TasksWithRippled.Count) task(s) to update"
}
if ($MonitoringFiles.Count -gt 0) {
    Write-Host "  Monitor configs : $($MonitoringFiles.Count) file(s) to update"
}
Write-Host ""
Write-Host "  Plan:"
Write-Host "    1.  Stop rippled ($StartMethod)"
Write-Host "    2.  Uninstall old $InstallMethod package"
Write-Host "    3.  Install xrpld"
Write-Host "    4.  Migrate config (rippled.cfg → xrpld expected location)"
Write-Host "    5.  Update Task Scheduler entries ($($TasksWithRippled.Count) task(s))"
Write-Host "    6.  Update monitoring configs ($($MonitoringFiles.Count) file(s))"
Write-Host "    7.  Register and start xrpld ($StartMethod)"
Write-Host "    8.  Verify xrpld is running"
Write-Host ""

if (-not (Ask-YesNo "Proceed with migration?")) {
    Write-Info "Aborted by user."
    exit 0
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 8 — Stop rippled
# ─────────────────────────────────────────────────────────────────────────────
Write-Header "Stopping rippled"

function Stop-Rippled {
    switch ($StartMethod) {
        "service" {
            Write-Info "Stopping Windows service: $ServiceName"
            Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
            Set-Service  -Name $ServiceName -StartupType Disabled -ErrorAction SilentlyContinue
            Write-Success "Service stopped and disabled."
        }
        "taskscheduler" {
            Write-Info "Disabling Task Scheduler entry: $TaskSchedName"
            Disable-ScheduledTask -TaskName $TaskSchedName -ErrorAction SilentlyContinue | Out-Null
            Stop-ScheduledTask   -TaskName $TaskSchedName -ErrorAction SilentlyContinue | Out-Null
            Write-Success "Scheduled task disabled."
        }
        default {
            $proc = Get-Process -Name rippled -ErrorAction SilentlyContinue
            if ($proc) {
                Write-Warn "Sending stop signal to rippled process(es)..."
                $proc | Stop-Process -Force
                Start-Sleep -Seconds 3
                if (Get-Process -Name rippled -ErrorAction SilentlyContinue) {
                    Fail "rippled is still running. Stop it manually and re-run."
                }
                Write-Success "rippled process stopped."
            } else {
                Write-Info "rippled is not running. Proceeding."
            }
        }
    }
}

Stop-Rippled

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 9 — Uninstall rippled
# ─────────────────────────────────────────────────────────────────────────────
Write-Header "Uninstalling rippled"

function Uninstall-Rippled {
    switch ($InstallMethod) {
        "chocolatey" {
            Write-Info "choco uninstall rippled"
            choco uninstall rippled -y --skip-autouninstaller 2>&1
        }
        "scoop" {
            Write-Info "scoop uninstall rippled"
            scoop uninstall rippled 2>&1
        }
        "msi" {
            Write-Info "Removing via MSI uninstall..."
            # Locate the uninstall string
            $regPaths = @(
                "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
                "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
            )
            $entry = $null
            foreach ($rp in $regPaths) {
                $entry = Get-ItemProperty $rp -ErrorAction SilentlyContinue |
                    Where-Object { $_.DisplayName -match 'rippled' } | Select-Object -First 1
                if ($entry) { break }
            }
            if ($entry -and $entry.UninstallString) {
                $uninstCmd = $entry.UninstallString -replace '/I', '/X'
                Start-Process "msiexec.exe" -ArgumentList "$uninstCmd /qn /norestart" -Wait
                Write-Success "MSI package removed."
            } else {
                Write-Warn "Could not find MSI uninstall entry. The binary may remain at: $RippledBin"
            }
        }
        "binary" {
            if ($RippledBin -and (Test-Path $RippledBin)) {
                Write-Info "Removing binary: $RippledBin"
                Remove-Item -Path $RippledBin -Force
                Write-Success "Binary removed."
            }
        }
    }
}

Uninstall-Rippled

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 10 — Install xrpld
# ─────────────────────────────────────────────────────────────────────────────
Write-Header "Installing xrpld"

# ── Repo / download config — update these URLs when Ripple publishes xrpld ──
$XRPLD_CHOCO_PACKAGE  = $env:XRPLD_CHOCO_PACKAGE  ?? "xrpld"
$XRPLD_SCOOP_APP      = $env:XRPLD_SCOOP_APP       ?? "xrpld"
$XRPLD_MSI_URL        = $env:XRPLD_MSI_URL         ?? "https://github.com/XRPLF/rippled/releases/latest/download/xrpld-installer.msi"
$XRPLD_EXE_URL        = $env:XRPLD_EXE_URL         ?? "https://github.com/XRPLF/rippled/releases/latest/download/xrpld.exe"

function Install-Xrpld {
    switch ($InstallMethod) {

        "chocolatey" {
            Write-Info "choco install $XRPLD_CHOCO_PACKAGE"
            choco install $XRPLD_CHOCO_PACKAGE -y 2>&1
        }

        "scoop" {
            Write-Info "scoop install $XRPLD_SCOOP_APP"
            scoop install $XRPLD_SCOOP_APP 2>&1
        }

        "msi" {
            Write-Info "Downloading xrpld MSI installer from: $XRPLD_MSI_URL"
            $msiPath = "$env:TEMP\xrpld-installer.msi"
            Invoke-WebRequest -Uri $XRPLD_MSI_URL -OutFile $msiPath -UseBasicParsing
            Write-Info "Running installer..."
            Start-Process "msiexec.exe" -ArgumentList "/i `"$msiPath`" /qn /norestart" -Wait
            Remove-Item $msiPath -Force -ErrorAction SilentlyContinue
            Write-Success "xrpld MSI installed."
        }

        "binary" {
            Write-Info "Downloading xrpld binary from: $XRPLD_EXE_URL"
            $targetDir = Split-Path $RippledBin
            $targetPath = Join-Path $targetDir "xrpld.exe"
            Invoke-WebRequest -Uri $XRPLD_EXE_URL -OutFile $targetPath -UseBasicParsing
            Write-Success "xrpld binary placed at: $targetPath"
        }

        default {
            Write-Warn "No known package manager was used. Manual install required."
            Write-Host ""
            Write-Host "  Download xrpld from:"
            Write-Host "  https://github.com/XRPLF/rippled/releases"
            Write-Host ""
            if (-not (Ask-YesNo "Is xrpld already installed/placed in PATH?" $false)) {
                Fail "xrpld binary not available. Aborting."
            }
        }
    }

    # Verify
    $xrpldCmd = Get-Command xrpld -ErrorAction SilentlyContinue
    if (-not $xrpldCmd) {
        # Also check the same directory as the old binary
        $binDir = if ($RippledBin) { Split-Path $RippledBin } else { "" }
        $xrpldExe = if ($binDir) { Join-Path $binDir "xrpld.exe" } else { "" }
        if ($xrpldExe -and (Test-Path $xrpldExe)) {
            Write-Success "xrpld installed at: $xrpldExe"
        } else {
            Fail "xrpld binary not found after installation."
        }
    } else {
        Write-Success "xrpld installed: $($xrpldCmd.Source)"
    }
}

Install-Xrpld

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 11 — Config file migration
#
# The new xrpld package ships with a registered service but no config file.
# We find where xrpld expects its config and place the old rippled.cfg there.
# ─────────────────────────────────────────────────────────────────────────────
Write-Header "Config file migration"

$XrpldConfigFile = ""

function Get-XrpldExpectedConfig {
    # 1. Ask the installed service where it expects the config
    $svcObj = Get-WmiObject Win32_Service -Filter "Name='xrpld'" -ErrorAction SilentlyContinue
    if ($svcObj -and $svcObj.PathName -match '--conf\s+"?([^"]+\.cfg)"?') {
        return $Matches[1].Trim()
    }

    # 2. Check xrpld.exe --help output
    $xrpldExe = (Get-Command xrpld -ErrorAction SilentlyContinue)?.Source
    if ($xrpldExe) {
        try {
            $helpOut = & $xrpldExe --help 2>&1
            if ($helpOut -match '(C:\\[^\s"]+\.cfg)') { return $Matches[1].Trim() }
        } catch {}
    }

    # 3. Default locations
    $defaults = @(
        "C:\ProgramData\xrpld\xrpld.cfg",
        "C:\ProgramData\Ripple\xrpld\xrpld.cfg",
        "C:\Program Files\Ripple\xrpld\xrpld.cfg"
    )
    foreach ($d in $defaults) {
        $dir = Split-Path $d
        if (Test-Path $dir) { return $d }
    }

    # 4. Mirror old config directory
    if ($script:ConfigDirectory) {
        return Join-Path $script:ConfigDirectory "xrpld.cfg"
    }

    return "C:\ProgramData\xrpld\xrpld.cfg"
}

function Handle-Config {
    if (-not $ConfigFile) {
        Write-Warn "No rippled config found. xrpld will start with compiled defaults."
        Write-Warn "You may need to create a config manually."
        return
    }

    $expectedCfg    = Get-XrpldExpectedConfig
    $expectedDir    = Split-Path $expectedCfg
    $srcBase        = Split-Path $ConfigFile -Leaf
    $dstBase        = Split-Path $expectedCfg -Leaf

    Write-Info "Old rippled config : $ConfigFile"
    Write-Info "xrpld expects cfg  : $expectedCfg"
    Write-Host ""

    $targetCfg = $expectedCfg
    if ($srcBase -ne $dstBase) {
        Write-Host "  Note: new package expects '$dstBase', you currently have '$srcBase'." -ForegroundColor Yellow
        if (-not (Ask-YesNo "Rename to '$dstBase' (recommended)?")) {
            $targetCfg = Join-Path $expectedDir $srcBase
        }
    }

    # Create directory if needed
    if (-not (Test-Path $expectedDir)) {
        Write-Info "Creating config directory: $expectedDir"
        New-Item -ItemType Directory -Path $expectedDir -Force | Out-Null
    }

    if ($ConfigFile -ne $targetCfg) {
        Write-Info "Copying: $ConfigFile → $targetCfg"
        Copy-Item -Path $ConfigFile -Destination $targetCfg -Force
        # Backup original
        Rename-Item -Path $ConfigFile -NewName "$ConfigFile.bak" -ErrorAction SilentlyContinue
        Write-Info "Original backed up as $ConfigFile.bak"
    } else {
        Write-Info "Config already at correct location."
    }

    $script:XrpldConfigFile = $targetCfg
    Write-Success "Config ready at: $targetCfg"
}

Handle-Config

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 12 — Update Task Scheduler entries
# ─────────────────────────────────────────────────────────────────────────────
Write-Header "Updating Task Scheduler entries"

function Migrate-TaskSchedulerJobs {
    foreach ($task in $TasksWithRippled) {
        Write-Info "Updating task: $($task.TaskName)"

        $changed = $false
        $actions = $task.Actions

        foreach ($action in $actions) {
            $origExe  = $action.Execute  ?? ""
            $origArgs = $action.Arguments ?? ""

            $newExe  = $origExe  -replace '\brippled(\.exe)?\b', 'xrpld$1'
            $newArgs = $origArgs -replace '\brippled\b', 'xrpld' `
                                 -replace 'rippled\.cfg', 'xrpld.cfg'

            if ($newExe -ne $origExe -or $newArgs -ne $origArgs) {
                $action.Execute   = $newExe
                $action.Arguments = $newArgs
                $changed = $true
                Write-Info "  Execute : $origExe → $newExe"
                Write-Info "  Args    : $origArgs → $newArgs"
            }
        }

        if ($changed) {
            Set-ScheduledTask -TaskName $task.TaskName -Action $actions -ErrorAction SilentlyContinue | Out-Null
            Write-Success "  Task updated: $($task.TaskName)"
        }
    }
    if ($TasksWithRippled.Count -eq 0) {
        Write-Info "No Task Scheduler entries to update."
    }
}

Migrate-TaskSchedulerJobs

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 13 — Update monitoring configs
# ─────────────────────────────────────────────────────────────────────────────
Write-Header "Updating monitoring configs"

function Migrate-MonitoringConfigs {
    foreach ($f in $MonitoringFiles) {
        if (-not (Test-Path $f)) { continue }

        Write-Info "Updating: $f"
        Copy-Item -Path $f -Destination "$f.bak-rippled" -Force
        Write-Info "  Backed up as $f.bak-rippled"

        $content = Get-Content -Path $f -Raw
        $updated = $content `
            -replace '\brippled\b', 'xrpld' `
            -replace 'rippled\.cfg', 'xrpld.cfg'

        if ($updated -ne $content) {
            Set-Content -Path $f -Value $updated -NoNewline
            Write-Success "  Updated: $f"
        } else {
            Write-Info "  No changes needed in: $f"
        }
    }
    if ($MonitoringFiles.Count -eq 0) {
        Write-Info "No monitoring configs to update."
    }
}

Migrate-MonitoringConfigs

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 14 — Register and start xrpld
# ─────────────────────────────────────────────────────────────────────────────
Write-Header "Starting xrpld"

function Start-Xrpld {
    $xrpldExe = (Get-Command xrpld -ErrorAction SilentlyContinue)?.Source
    if (-not $xrpldExe) {
        # Try same dir as old binary
        if ($RippledBin) {
            $candidate = Join-Path (Split-Path $RippledBin) "xrpld.exe"
            if (Test-Path $candidate) { $xrpldExe = $candidate }
        }
    }
    if (-not $xrpldExe) { Fail "Cannot locate xrpld.exe to start." }

    $cfgArg = if ($XrpldConfigFile) { "--conf `"$XrpldConfigFile`"" } else { "" }

    switch ($StartMethod) {

        "service" {
            $existingSvc = Get-Service -Name "xrpld" -ErrorAction SilentlyContinue
            if (-not $existingSvc) {
                Write-Info "Registering xrpld Windows Service..."
                $binPathArg = if ($cfgArg) {
                    "`"$xrpldExe`" $cfgArg"
                } else {
                    "`"$xrpldExe`""
                }
                New-Service -Name "xrpld" `
                            -BinaryPathName $binPathArg `
                            -DisplayName "XRP Ledger Daemon (xrpld)" `
                            -StartupType Automatic `
                            -Description "XRP Ledger node daemon" | Out-Null
                Write-Success "Service 'xrpld' registered."
            } else {
                Write-Info "Service 'xrpld' already exists."
                # Patch the binary path if config changed
                if ($XrpldConfigFile) {
                    $binPath = "`"$xrpldExe`" $cfgArg"
                    sc.exe config xrpld binPath= $binPath | Out-Null
                    Write-Info "Service binary path updated."
                }
                Set-Service -Name "xrpld" -StartupType Automatic | Out-Null
            }
            Start-Service -Name "xrpld" -ErrorAction Stop
            Write-Success "xrpld service started."
        }

        "taskscheduler" {
            # The task was already updated in section 12.
            # Re-enable and run it.
            if ($TaskSchedName -and (Get-ScheduledTask -TaskName $TaskSchedName -ErrorAction SilentlyContinue)) {
                $newTaskName = $TaskSchedName -replace 'rippled', 'xrpld'
                Enable-ScheduledTask  -TaskName $TaskSchedName -ErrorAction SilentlyContinue | Out-Null
                Start-ScheduledTask   -TaskName $TaskSchedName -ErrorAction SilentlyContinue | Out-Null
                Write-Success "Scheduled task started: $TaskSchedName"
            } else {
                Write-Warn "Original task not found. Creating new task for xrpld..."
                $action  = New-ScheduledTaskAction -Execute $xrpldExe -Argument $cfgArg
                $trigger = New-ScheduledTaskTrigger -AtStartup
                $settings = New-ScheduledTaskSettingsSet -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
                Register-ScheduledTask -TaskName "xrpld" -Action $action `
                    -Trigger $trigger -Settings $settings `
                    -RunLevel Highest -Force | Out-Null
                Start-ScheduledTask -TaskName "xrpld"
                Write-Success "New scheduled task 'xrpld' created and started."
            }
        }

        default {
            Write-Warn "No service manager in use. Starting xrpld manually..."
            $argList = if ($cfgArg) { "--silent $cfgArg" } else { "--silent" }
            Start-Process -FilePath $xrpldExe -ArgumentList $argList -WindowStyle Hidden
            Write-Info "xrpld launched in background."
        }
    }
}

Start-Xrpld

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 15 — Verify xrpld
# ─────────────────────────────────────────────────────────────────────────────
Write-Header "Verifying xrpld"

function Verify-Xrpld {
    $maxWait = 30
    $waited  = 0
    Write-Info "Waiting up to ${maxWait}s for xrpld..."

    while ($waited -lt $maxWait) {
        $proc = Get-Process -Name xrpld -ErrorAction SilentlyContinue
        if ($proc) {
            Write-Success "xrpld process is running (PID: $($proc.Id))."

            if ($StartMethod -eq "service") {
                $svc = Get-Service -Name "xrpld" -ErrorAction SilentlyContinue
                if ($svc) { Write-Info "Service status: $($svc.Status)" }
            }

            # RPC sanity check
            $xrpldExe = (Get-Command xrpld -ErrorAction SilentlyContinue)?.Source
            if ($xrpldExe) {
                try {
                    $info = & $xrpldExe server_info 2>&1 | Select-String 'server_state' | Select-Object -First 1
                    if ($info) { Write-Info "server_state: $info" }
                } catch {}
            }

            return
        }
        Start-Sleep -Seconds 2
        $waited += 2
    }

    Write-Err "xrpld not detected after ${maxWait}s."
    Write-Err "Check the event log or logs:"
    Write-Err "  Get-EventLog -LogName Application -Source xrpld -Newest 20"
    exit 1
}

Verify-Xrpld

# ─────────────────────────────────────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────────────────────────────────────
Write-Header "Migration complete"

Write-Host ""
Write-Host "  rippled → xrpld migration successful!" -ForegroundColor Green
Write-Host ""
Write-Host "  Useful commands:"
if ($StartMethod -eq "service") {
    Write-Host "    Get-Service xrpld"
    Write-Host "    Get-EventLog -LogName Application -Source xrpld -Newest 20"
}
if ($StartMethod -eq "taskscheduler") {
    Write-Host "    Get-ScheduledTaskInfo -TaskName xrpld"
}
Write-Host "    xrpld server_info"
if ($XrpldConfigFile) {
    Write-Host "    Config: $XrpldConfigFile"
}
Write-Host ""
