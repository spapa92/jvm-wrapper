#Requires -Version 5.1
<#
.SYNOPSIS
    jvmw - JDK Version Manager for Windows
    Like nvm but for Java. Terminal-ready and agent-friendly.

.DESCRIPTION
    Manages multiple JDK installations on Windows.
    Supports agent usage via structured JSON output and exit codes.
    Downloads from Adoptium (Eclipse Temurin) API.

.EXAMPLE
    jvmw list
    jvmw install 21
    jvmw use 21
    jvmw current
    jvmw available
    jvmw --json list

.NOTES
    Version: 1.0.0
    Author: jvmw
    Requires: PowerShell 5.1+, Internet access for downloads
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = "help",

    [Parameter(Position = 1)]
    [string]$Version = "",

    [switch]$Json,       # Machine-readable JSON output
    [switch]$Silent,     # No decorative output
    [switch]$Force,      # Skip confirmation prompts
    [switch]$LTS,        # Filter LTS versions only
    [switch]$Global      # Apply globally (all users) vs session-only
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------
#  CONFIGURATION
# ---------------------------------------------
$script:Config = @{
    BaseDir      = "$env:USERPROFILE\.jvmw"
    JdksDir      = "$env:USERPROFILE\.jvmw\jdks"
    ConfigFile   = "$env:USERPROFILE\.jvmw\config.json"
    LogFile      = "$env:USERPROFILE\.jvmw\jvmw.log"
    AdoptiumApi  = "https://api.adoptium.net/v3"
    JvmLinkDir   = "$env:USERPROFILE\.jvmw\current"  # symlink target
    Version      = "1.0.0"
    Arch         = if ([Environment]::Is64BitOperatingSystem) { "x64" } else { "x86" }
    OS           = "windows"
    ImageType    = "jdk"
    JvmImpl      = "hotspot"
    Vendor       = "eclipse"
}

# ---------------------------------------------
#  UTILS: Output
# ---------------------------------------------
function Write-Info    { if (-not $Silent) { Write-Host "  $args" -ForegroundColor Cyan } }
function Write-Ok      { if (-not $Silent) { Write-Host "  [OK] $args" -ForegroundColor Green } }
function Write-Warn    { if (-not $Silent) { Write-Host "  [WARN] $args" -ForegroundColor Yellow } }
function Write-Err     { Write-Host "  [ERR] $args" -ForegroundColor Red }
function Write-Header  { if (-not $Silent) { Write-Host "`n  $args" -ForegroundColor White } }

function Out-Result {
    param($Data, [int]$ExitCode = 0, [string]$Message = "")
    if ($Json) {
        $obj = @{
            success    = ($ExitCode -eq 0)
            exitCode   = $ExitCode
            message    = $Message
            data       = $Data
            timestamp  = (Get-Date -Format "o")
        }
        Write-Output ($obj | ConvertTo-Json -Depth 10)
    }
    exit $ExitCode
}

function Write-Log {
    param([string]$Level, [string]$Msg)
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Msg"
    Add-Content -Path $script:Config.LogFile -Value $line -ErrorAction SilentlyContinue
}

# ---------------------------------------------
#  INIT
# ---------------------------------------------
function Initialize-Dirs {
    foreach ($dir in @($script:Config.BaseDir, $script:Config.JdksDir)) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }
    if (-not (Test-Path $script:Config.ConfigFile)) {
        @{ current = $null; installed = @{} } | ConvertTo-Json | Set-Content $script:Config.ConfigFile
    }
}

function Get-JvmwConfig {
    if (Test-Path $script:Config.ConfigFile) {
        Get-Content $script:Config.ConfigFile -Raw | ConvertFrom-Json
    } else {
        [PSCustomObject]@{ current = $null; installed = @{} }
    }
}

function Save-JvmwConfig {
    param($Cfg)
    $Cfg | ConvertTo-Json -Depth 5 | Set-Content $script:Config.ConfigFile
}

# ---------------------------------------------
#  COMMAND: help
# ---------------------------------------------
function Invoke-Help {
    if ($Json) {
        Out-Result @{
            commands = @(
                @{ name="list";      args="";           description="List locally installed JDKs" }
                @{ name="available"; args="[--lts]";    description="List JDK versions available for download" }
                @{ name="install";   args="<version>";  description="Download and install a JDK version" }
                @{ name="use";       args="<version>";  description="Switch active JDK (current session + persistent)" }
                @{ name="current";   args="";           description="Show currently active JDK" }
                @{ name="remove";    args="<version>";  description="Uninstall a JDK version" }
                @{ name="path";      args="<version>";  description="Print the home path of a JDK version" }
                @{ name="env";       args="<version>";  description="Print env-var export commands for a version" }
                @{ name="which";     args="";           description="Show java binary path in use" }
                @{ name="doctor";    args="";           description="Diagnose PATH and JAVA_HOME setup" }
            )
            flags = @(
                @{ flag="--json";    description="Output machine-readable JSON (for agents)" }
                @{ flag="--silent";  description="Suppress decorative output" }
                @{ flag="--force";   description="Skip confirmation prompts" }
                @{ flag="--lts";     description="Filter LTS-only versions" }
                @{ flag="--global";  description="Modify system PATH (requires elevation)" }
            )
        } 0 "jvmw $($script:Config.Version) - JDK Version Manager for Windows"
        return
    }

    Write-Host @"

  +-------------------------------------------------+
  |   jvmw $($script:Config.Version)  -  JDK Version Manager for Windows    |
  +-------------------------------------------------+

  COMMANDS
    list                  List installed JDKs
    available [--lts]     List downloadable JDK versions
    install <version>     Install a JDK (e.g. jvmw install 21)
    use <version>         Switch active JDK
    current               Show active JDK
    remove <version>      Uninstall a JDK
    path <version>        Print JAVA_HOME path
    env <version>         Print env-var commands (for scripts)
    which                 Show java binary in use
    doctor                Diagnose your Java environment

  FLAGS
    --json                JSON output (agent-friendly)
    --silent              No decorative text
    --force               Skip confirmations
    --lts                 LTS versions only
    --global              Modify system PATH (needs elevation)

  EXAMPLES
    jvmw install 21
    jvmw use 17
    jvmw --json list
    jvmw --json current
    jvmw --json available --lts

"@ -ForegroundColor Gray
}

# ---------------------------------------------
#  COMMAND: list
# ---------------------------------------------
function Invoke-List {
    $cfg = Get-JvmwConfig
    $jdksDir = $script:Config.JdksDir

    $installed = @()
    if (Test-Path $jdksDir) {
        Get-ChildItem $jdksDir -Directory | ForEach-Object {
            $vDir = $_.FullName
            $vName = $_.Name
            $javaExe = Join-Path $vDir "bin\java.exe"
            $active = ($cfg.current -eq $vName)
            $hasJava = Test-Path $javaExe

            $javaVersion = $null
            if ($hasJava) {
                try {
                    $javaVersion = (& $javaExe -version 2>&1 | Select-Object -First 1).ToString()
                } catch { }
            }

            $installed += @{
                name       = $vName
                path       = $vDir
                active     = $active
                javaExe    = $hasJava
                version    = $javaVersion
            }
        }
    }

    if ($Json) {
        Out-Result $installed 0 "$($installed.Count) JDK(s) installed"
        return
    }

    if ($installed.Count -eq 0) {
        Write-Warn "No JDKs installed. Run: jvmw install <version>"
        return
    }

    Write-Header "Installed JDKs:"
    Write-Host ""
    foreach ($jdk in $installed) {
        $marker = if ($jdk.active) { "->" } else { " " }
        $color  = if ($jdk.active) { "Green" } else { "Gray" }
        $ver    = if ($jdk.version) { "  ($($jdk.version))" } else { "" }
        Write-Host "  $marker  $($jdk.name)$ver" -ForegroundColor $color
    }
    Write-Host ""
}

# ---------------------------------------------
#  COMMAND: available
# ---------------------------------------------
function Invoke-Available {
    Write-Info "Fetching available JDK versions from Adoptium..."

    $url = "$($script:Config.AdoptiumApi)/info/available_releases"
    try {
        $resp = Invoke-RestMethod -Uri $url -UseBasicParsing
    } catch {
        $msg = "Failed to reach Adoptium API: $_"
        if ($Json) { Out-Result $null 1 $msg; return }
        Write-Err $msg; return
    }

    $releases = @()
    foreach ($major in $resp.available_releases) {
        $isLTS = $resp.available_lts_releases -contains $major
        if ($LTS -and -not $isLTS) { continue }
        $releases += @{
            major   = $major
            lts     = $isLTS
            label   = "JDK $major$(if($isLTS){' (LTS)'})"
        }
    }

    if ($Json) {
        Out-Result $releases 0 "$($releases.Count) versions available"
        return
    }

    Write-Header "Available JDK versions (Adoptium Temurin):"
    Write-Host ""
    foreach ($r in ($releases | Sort-Object { $_.major })) {
        $ltsTag = if ($r.lts) { "  [LTS]" } else { "" }
        $color  = if ($r.lts) { "White" } else { "Gray" }
        Write-Host "    $($r.major)$ltsTag" -ForegroundColor $color
    }
    Write-Host ""
    Write-Info "Install with: jvmw install <major>"
}

# ---------------------------------------------
#  COMMAND: install
# ---------------------------------------------
function Invoke-Install {
    param([string]$Ver)
    if (-not $Ver) {
        $msg = "Usage: jvmw install <version>  (e.g. jvmw install 21)"
        if ($Json) { Out-Result $null 1 $msg; return }
        Write-Err $msg; return
    }

    # Normalize: strip non-digits prefix
    $major = $Ver -replace '[^\d]', '' | Select-Object -First 1
    if (-not $major) {
        $msg = "Invalid version: '$Ver'"
        if ($Json) { Out-Result $null 1 $msg; return }
        Write-Err $msg; return
    }

    $targetDir = Join-Path $script:Config.JdksDir "jdk-$major"
    if (Test-Path $targetDir) {
        $msg = "JDK $major already installed at: $targetDir"
        if ($Json) { Out-Result @{ path=$targetDir; version="jdk-$major" } 0 $msg; return }
        Write-Warn $msg
        return
    }

    # Fetch release metadata
    $apiUrl = "$($script:Config.AdoptiumApi)/assets/latest/$major/$($script:Config.JvmImpl)?architecture=$($script:Config.Arch)&image_type=$($script:Config.ImageType)&jvm_impl=$($script:Config.JvmImpl)&os=$($script:Config.OS)&vendor=$($script:Config.Vendor)"
    Write-Info "Fetching JDK $major metadata..."

    try {
        $assets = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing
    } catch {
        $msg = "Failed to fetch JDK $major metadata: $_"
        if ($Json) { Out-Result $null 1 $msg; return }
        Write-Err $msg; return
    }

    if (-not $assets -or $assets.Count -eq 0) {
        $msg = "No JDK $major found for $($script:Config.OS)/$($script:Config.Arch)"
        if ($Json) { Out-Result $null 1 $msg; return }
        Write-Err $msg; return
    }

    $asset = $assets[0]
    $dlUrl  = $asset.binary.package.link
    $dlSize = [math]::Round($asset.binary.package.size / 1MB, 1)
    $dlName = $asset.binary.package.name
    $releaseVersion = $asset.version.semver

    Write-Info "Found: $releaseVersion  ($dlSize MB)"

    if (-not $Force -and -not $Json) {
        $confirm = Read-Host "  Download and install? [Y/n]"
        if ($confirm -match '^[Nn]') {
            Write-Warn "Aborted."
            return
        }
    }

    $tmpZip = Join-Path $env:TEMP $dlName
    Write-Info "Downloading $dlName..."
    Write-Log "INFO" "Downloading JDK $major from $dlUrl"

    try {
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($dlUrl, $tmpZip)
    } catch {
        $msg = "Download failed: $_"
        if ($Json) { Out-Result $null 1 $msg; return }
        Write-Err $msg; return
    }

    Write-Info "Extracting..."
    $tmpExtract = Join-Path $env:TEMP "jvmw-extract-$major"
    if (Test-Path $tmpExtract) { Remove-Item $tmpExtract -Recurse -Force }

    try {
        Expand-Archive -Path $tmpZip -DestinationPath $tmpExtract -Force
    } catch {
        $msg = "Extraction failed: $_"
        if ($Json) { Out-Result $null 1 $msg; return }
        Write-Err $msg; return
    }

    # Find the root JDK folder inside the zip (e.g. jdk-21.0.3+9)
    $extracted = Get-ChildItem $tmpExtract -Directory | Select-Object -First 1
    if (-not $extracted) {
        $msg = "Could not find extracted JDK folder"
        if ($Json) { Out-Result $null 1 $msg; return }
        Write-Err $msg; return
    }

    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    Copy-Item -Path "$($extracted.FullName)\*" -Destination $targetDir -Recurse -Force

    # Cleanup
    Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue
    Remove-Item $tmpExtract -Recurse -Force -ErrorAction SilentlyContinue

    Write-Log "INFO" "Installed JDK $major to $targetDir"

    # Update config
    $cfg = Get-JvmwConfig
    if (-not $cfg.PSObject.Properties['installed']) {
        $cfg | Add-Member -MemberType NoteProperty -Name installed -Value @{}
    }
    $cfg.installed | Add-Member -MemberType NoteProperty -Name "jdk-$major" -Value @{
        path    = $targetDir
        version = $releaseVersion
        major   = [int]$major
        lts     = ($asset.version.major -in @(8, 11, 17, 21, 25))
    } -Force

    Save-JvmwConfig $cfg

    $result = @{ path = $targetDir; version = $releaseVersion; major = [int]$major }
    if ($Json) {
        Out-Result $result 0 "JDK $major installed successfully"
        return
    }
    Write-Ok "JDK $major installed: $targetDir"
    Write-Info "Activate with: jvmw use $major"
}

# ---------------------------------------------
#  COMMAND: use
# ---------------------------------------------
function Invoke-Use {
    param([string]$Ver)
    if (-not $Ver) {
        $msg = "Usage: jvmw use <version>"
        if ($Json) { Out-Result $null 1 $msg; return }
        Write-Err $msg; return
    }

    $major = $Ver -replace '[^\d]', ''
    $jdkName = "jdk-$major"
    $jdkPath = Join-Path $script:Config.JdksDir $jdkName
    $binPath  = Join-Path $jdkPath "bin"
    $javaExe  = Join-Path $binPath "java.exe"

    if (-not (Test-Path $javaExe)) {
        $msg = "JDK $major not installed. Run: jvmw install $major"
        if ($Json) { Out-Result $null 1 $msg; return }
        Write-Err $msg; return
    }

    # Set JAVA_HOME and update PATH in current process
    [System.Environment]::SetEnvironmentVariable("JAVA_HOME", $jdkPath, "Process")

    $currentPath = $env:PATH
    # Remove old jvmw jdk paths
    $pathParts = $currentPath -split ';' | Where-Object {
        $_ -notmatch [regex]::Escape($script:Config.JdksDir)
    }
    $newPath = ($binPath + ";" + ($pathParts -join ";"))
    [System.Environment]::SetEnvironmentVariable("PATH", $newPath, "Process")
    $env:PATH = $newPath
    $env:JAVA_HOME = $jdkPath

    # Persist to user env
    try {
        $scope = if ($Global) { "Machine" } else { "User" }
        [System.Environment]::SetEnvironmentVariable("JAVA_HOME", $jdkPath, $scope)

        $persistedPath = [System.Environment]::GetEnvironmentVariable("PATH", $scope)
        $persistedParts = $persistedPath -split ';' | Where-Object {
            $_ -notmatch [regex]::Escape($script:Config.JdksDir)
        }
        $newPersistedPath = ($binPath + ";" + ($persistedParts -join ";"))
        [System.Environment]::SetEnvironmentVariable("PATH", $newPersistedPath, $scope)
    } catch {
        Write-Warn "Could not persist to $scope environment: $_ (process env still set)"
    }

    # Save in config
    $cfg = Get-JvmwConfig
    $cfg.current = $jdkName
    Save-JvmwConfig $cfg

    Write-Log "INFO" "Switched to JDK $major ($jdkPath)"

    $result = @{
        active    = $jdkName
        javaHome  = $jdkPath
        bin       = $binPath
        scope     = if ($Global) { "machine" } else { "user" }
    }

    if ($Json) {
        Out-Result $result 0 "Switched to JDK $major"
        return
    }

    Write-Ok "Using JDK $major"
    Write-Info "JAVA_HOME = $jdkPath"
    Write-Info "PATH updated (current session + user env)"

    # Verify
    try {
        $v = (& $javaExe -version 2>&1 | Select-Object -First 1).ToString()
        Write-Info "java: $v"
    } catch { }
}

# ---------------------------------------------
#  COMMAND: current
# ---------------------------------------------
function Invoke-Current {
    $cfg = Get-JvmwConfig
    $current = $cfg.current

    if (-not $current) {
        $msg = "No JDK active. Run: jvmw use <version>"
        if ($Json) { Out-Result $null 1 $msg; return }
        Write-Warn $msg; return
    }

    $jdkPath = Join-Path $script:Config.JdksDir $current
    $javaExe = Join-Path $jdkPath "bin\java.exe"
    $javaVersion = $null

    if (Test-Path $javaExe) {
        try { $javaVersion = (& $javaExe -version 2>&1 | Select-Object -First 1).ToString() } catch { }
    }

    # Also check env JAVA_HOME for session-level info
    $sessionHome = $env:JAVA_HOME

    $result = @{
        name        = $current
        path        = $jdkPath
        javaHome    = $jdkPath
        sessionHome = $sessionHome
        javaVersion = $javaVersion
        major       = [int]($current -replace 'jdk-', '')
    }

    if ($Json) {
        Out-Result $result 0 "Current JDK: $current"
        return
    }

    Write-Header "Active JDK:"
    Write-Host "  -> $current" -ForegroundColor Green
    Write-Host "    JAVA_HOME : $jdkPath" -ForegroundColor Gray
    if ($javaVersion) {
        Write-Host "    Version   : $javaVersion" -ForegroundColor Gray
    }
    Write-Host ""
}

# ---------------------------------------------
#  COMMAND: path
# ---------------------------------------------
function Invoke-Path {
    param([string]$Ver)
    if (-not $Ver) {
        $msg = "Usage: jvmw path <version>"
        if ($Json) { Out-Result $null 1 $msg; return }
        Write-Err $msg; return
    }
    $major   = $Ver -replace '[^\d]', ''
    $jdkPath = Join-Path $script:Config.JdksDir "jdk-$major"
    if (-not (Test-Path $jdkPath)) {
        $msg = "JDK $major not installed"
        if ($Json) { Out-Result $null 1 $msg; return }
        Write-Err $msg; return
    }
    if ($Json) {
        Out-Result @{ path=$jdkPath; bin=(Join-Path $jdkPath "bin") } 0 "JDK $major path"
        return
    }
    Write-Output $jdkPath
}

# ---------------------------------------------
#  COMMAND: env
# ---------------------------------------------
function Invoke-Env {
    param([string]$Ver)
    if (-not $Ver) {
        $msg = "Usage: jvmw env <version>"
        if ($Json) { Out-Result $null 1 $msg; return }
        Write-Err $msg; return
    }
    $major   = $Ver -replace '[^\d]', ''
    $jdkPath = Join-Path $script:Config.JdksDir "jdk-$major"
    $binPath = Join-Path $jdkPath "bin"
    if (-not (Test-Path $jdkPath)) {
        $msg = "JDK $major not installed"
        if ($Json) { Out-Result $null 1 $msg; return }
        Write-Err $msg; return
    }

    $cmds = @(
        "`$env:JAVA_HOME = '$jdkPath'"
        "`$env:PATH = '$binPath;' + `$env:PATH"
    )

    if ($Json) {
        Out-Result @{
            javaHome  = $jdkPath
            bin       = $binPath
            commands  = $cmds
        } 0 "Env for JDK $major"
        return
    }

    foreach ($c in $cmds) { Write-Output $c }
}

# ---------------------------------------------
#  COMMAND: which
# ---------------------------------------------
function Invoke-Which {
    $java = Get-Command java -ErrorAction SilentlyContinue
    if (-not $java) {
        $msg = "java not found in PATH"
        if ($Json) { Out-Result $null 1 $msg; return }
        Write-Warn $msg; return
    }

    $javaHome = $env:JAVA_HOME
    $javaPath = $java.Source
    $result = @{
        javaPath = $javaPath
        javaHome = $javaHome
        inPath   = $true
    }

    if ($Json) {
        Out-Result $result 0 "java found: $javaPath"
        return
    }
    Write-Output $javaPath
}

# ---------------------------------------------
#  COMMAND: remove
# ---------------------------------------------
function Invoke-Remove {
    param([string]$Ver)
    if (-not $Ver) {
        $msg = "Usage: jvmw remove <version>"
        if ($Json) { Out-Result $null 1 $msg; return }
        Write-Err $msg; return
    }
    $major   = $Ver -replace '[^\d]', ''
    $jdkName = "jdk-$major"
    $jdkPath = Join-Path $script:Config.JdksDir $jdkName

    if (-not (Test-Path $jdkPath)) {
        $msg = "JDK $major not installed"
        if ($Json) { Out-Result $null 1 $msg; return }
        Write-Err $msg; return
    }

    if (-not $Force -and -not $Json) {
        $confirm = Read-Host "  Remove JDK $major at '$jdkPath'? [y/N]"
        if ($confirm -notmatch '^[Yy]') {
            Write-Warn "Aborted."; return
        }
    }

    Remove-Item $jdkPath -Recurse -Force
    Write-Log "INFO" "Removed JDK $major"

    $cfg = Get-JvmwConfig
    if ($cfg.current -eq $jdkName) { $cfg.current = $null }
    # Remove from installed hashtable if present
    if ($cfg.installed.PSObject.Properties[$jdkName]) {
        $cfg.installed.PSObject.Properties.Remove($jdkName)
    }
    Save-JvmwConfig $cfg

    if ($Json) {
        Out-Result @{ removed=$jdkName } 0 "JDK $major removed"
        return
    }
    Write-Ok "JDK $major removed"
}

# ---------------------------------------------
#  COMMAND: doctor
# ---------------------------------------------
function Invoke-Doctor {
    $checks = @()

    # Check 1: JAVA_HOME
    $javaHome = $env:JAVA_HOME
    $checks += @{
        check  = "JAVA_HOME set"
        ok     = ($null -ne $javaHome -and $javaHome -ne "")
        detail = if ($javaHome) { $javaHome } else { "Not set" }
    }

    # Check 2: java in PATH
    $java = Get-Command java -ErrorAction SilentlyContinue
    $checks += @{
        check  = "java in PATH"
        ok     = ($null -ne $java)
        detail = if ($java) { $java.Source } else { "Not found" }
    }

    # Check 3: JAVA_HOME matches PATH java
    $homeMatch = $false
    if ($java -and $javaHome) {
        $homeMatch = $java.Source.StartsWith($javaHome)
    }
    $checks += @{
        check  = "JAVA_HOME matches active java"
        ok     = $homeMatch
        detail = if ($homeMatch) { "Consistent" } else { "Mismatch detected" }
    }

    # Check 4: jvmw installed JDKs
    $jdksDir = $script:Config.JdksDir
    $installedCount = 0
    if (Test-Path $jdksDir) {
        $installedCount = (Get-ChildItem $jdksDir -Directory).Count
    }
    $checks += @{
        check  = "jvmw JDKs directory"
        ok     = ($installedCount -gt 0)
        detail = "$installedCount JDK(s) installed in $jdksDir"
    }

    # Check 5: jvmw config
    $cfg = Get-JvmwConfig
    $checks += @{
        check  = "jvmw config active JDK"
        ok     = ($null -ne $cfg.current -and $cfg.current -ne "")
        detail = if ($cfg.current) { $cfg.current } else { "None selected" }
    }

    $allOk = ($checks | Where-Object { -not $_.ok }).Count -eq 0

    if ($Json) {
        Out-Result @{
            healthy = $allOk
            checks  = $checks
        } (if ($allOk) { 0 } else { 1 }) (if ($allOk) { "All checks passed" } else { "Some checks failed" })
        return
    }

    Write-Header "jvmw doctor"
    Write-Host ""
    foreach ($c in $checks) {
        $icon  = if ($c.ok) { "[OK]" } else { "[ERR]" }
        $color = if ($c.ok) { "Green" } else { "Red" }
        Write-Host "  $icon  $($c.check)" -ForegroundColor $color
        Write-Host "       $($c.detail)" -ForegroundColor Gray
    }
    Write-Host ""
    if ($allOk) { Write-Ok "All checks passed" } else { Write-Warn "Some issues detected" }
}

# ---------------------------------------------
#  ENTRYPOINT
# ---------------------------------------------
Initialize-Dirs

switch ($Command.ToLower()) {
    "help"      { Invoke-Help }
    "--help"    { Invoke-Help }
    "-h"        { Invoke-Help }
    "list"      { Invoke-List }
    "ls"        { Invoke-List }
    "available" { Invoke-Available }
    "avail"     { Invoke-Available }
    "install"   { Invoke-Install -Ver $Version }
    "i"         { Invoke-Install -Ver $Version }
    "use"       { Invoke-Use    -Ver $Version }
    "switch"    { Invoke-Use    -Ver $Version }
    "current"   { Invoke-Current }
    "path"      { Invoke-Path   -Ver $Version }
    "env"       { Invoke-Env    -Ver $Version }
    "which"     { Invoke-Which }
    "remove"    { Invoke-Remove -Ver $Version }
    "rm"        { Invoke-Remove -Ver $Version }
    "uninstall" { Invoke-Remove -Ver $Version }
    "doctor"    { Invoke-Doctor }
    "diag"      { Invoke-Doctor }
    default {
        $msg = "Unknown command: '$Command'. Run: jvmw help"
        if ($Json) { Out-Result $null 127 $msg; return }
        Write-Err $msg
        Invoke-Help
        exit 127
    }
}