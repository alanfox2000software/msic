<# : batch portion
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex (${%~f0} | out-string)"
exit /b
: end batch / begin powershell #>

$scriptver = '26.09.2026'
$ProgressPreference = 'SilentlyContinue'
$host.ui.RawUI.WindowTitle = 'WebView2 Runtime Portable ' + $scriptver

#:: ==============================================================
#::  EDIT THESE LINES ONLY
#:: ==============================================================
$arch       = "x64"          # x64 / x86 / arm64
$ptpath     = "C:\WebView2"  # extraction path
$dlpath     = "$env:TEMP"    # cab download folder
$verFolder  = $true          # $true = extract to version folder, $false = extract to root

# Registry pv Value Options:
#   "auto"           = use the downloaded version (e.g., "152.0.4191.62")
#   "skip"           = do not modify pv registry value
#   "1.0.0.0"        = set custom version (replace with desired version)
$registryPvMode = "auto"

# Policy BrowserExecutableFolder Options:
#   "auto"           = set policy to finalPath (respects $verFolder setting)
#   "skip"           = do not modify policy
#   "clear"          = remove policy if set
#   "C:\CustomPath"  = set policy to custom path
$policyMode = "skip"

# System Environment Variable WEBVIEW2_BROWSER_EXECUTABLE_FOLDER Options:
#   "auto"           = set environment variable to finalPath (respects $verFolder setting)
#   "skip"           = do not modify environment variable
#   "clear"          = remove environment variable if set
#   "C:\CustomPath"  = set env var to custom path
$envVarMode = "auto"

# Folder Permissions Options:
#   "auto"           = apply default WebView2 ACL (Windows 10 only)
#                      grants (OI)(CI)(RX) to:
#                        S-1-15-2-2  (ALL RESTRICTED APP PACKAGES)
#                        S-1-15-2-1  (ALL APPLICATION PACKAGES)
#                      NOTE: auto mode will SKIP on Windows 11+
#                            and SKIP on below Windows 10
#   "skip"           = do not modify permissions
#   "custom"         = use $permissionsCustom list below
#                      (no Windows version restriction)
$permissionsMode = "auto"

# Custom ACL entries - only used when $permissionsMode = "custom"
# Format: @{ Sid = "S-1-x-x-x"; Rights = "(OI)(CI)(RX)" }
# Common SIDs:
#   S-1-15-2-1   = ALL APPLICATION PACKAGES
#   S-1-15-2-2   = ALL RESTRICTED APPLICATION PACKAGES
#   S-1-1-0      = Everyone
#   S-1-5-32-545 = Users
#   S-1-5-32-544 = Administrators
#   S-1-5-18     = SYSTEM
$permissionsCustom = @(
    @{ Sid = "S-1-15-2-2"; Rights = "(OI)(CI)(RX)" },
    @{ Sid = "S-1-15-2-1"; Rights = "(OI)(CI)(RX)" }
)

# File Filter Options:
#   $fileFilter = $null  = extract ALL files
#
#   Or specify a list of relative paths / patterns to extract.
#   Supports wildcards (* and ?) in filename part only.
#   Folder paths are relative to the runtime root.
#
#   Examples:
#     "msedgewebview2.exe"            = root file
#     "Locales\en-US.pak"             = specific locale
#     "Locales\*.pak"                 = all locale files
#     "*.dll"                         = all DLLs in root
#     "d3dcompiler_47.dll"            = specific DLL
#
$fileFilter = @(
    "*.manifest",
    "concrt140.dll",
    "EdgeWebView.dat",
    "ffmpeg.dll",
    "icudtl.dat",
    "msedge.dll",
    "msedge.dll.sig",
    "msedge_100_percent.pak",
    "msedge_elf.dll",
    "msedgewebview2.exe",
    "msedgewebview2.exe.sig",
    "msvcp140.dll",
    "msvcp140_codecvt_ids.dll",
    "resources.pak",
    "v8_context_snapshot.bin",
    "vccorlib140.dll",
    "vcruntime140.dll",
    "vcruntime140_1.dll",
    "vk_swiftshader.dll",
    "vk_swiftshader_icd.json",
    "vulkan-1.dll",
    "webview2_integration.dll",
#     "EBWebView\arm64\EmbeddedBrowserWebView.dll",
    "EBWebView\x64\EmbeddedBrowserWebView.dll",
    "EBWebView\x86\EmbeddedBrowserWebView.dll",
    "Locales\en-US.pak"
)
#:: ==============================================================

function Write-Status {
    param(
        [string]$Label,
        [string]$Value,
        [string]$Color = "Cyan"
    )
    Write-Host ("{0,-22}: " -f $Label) -NoNewline -ForegroundColor Gray
    Write-Host $Value -ForegroundColor $Color
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "--- $Title ---" -ForegroundColor DarkGray
}

function Get-WindowsVersionInfo {
    $os         = Get-CimInstance -ClassName Win32_OperatingSystem
    $buildNum   = [int]$os.BuildNumber
    $majorVer   = [int]$os.Version.Split('.')[0]
    $caption    = $os.Caption

    # Windows version detection by build number
    # Windows 10 builds : 10240 (1507) - 19045 (22H2)
    # Windows 11 builds : 22000+
    # Windows 8.1       : 9600
    # Windows 7         : 7601

    $isWin10 = ($majorVer -eq 10 -and $buildNum -ge 10240 -and $buildNum -le 19045)
    $isWin11 = ($majorVer -eq 10 -and $buildNum -ge 22000)
    $isBelowWin10 = ($majorVer -lt 10) -or ($majorVer -eq 10 -and $buildNum -lt 10240)

    return @{
        Caption      = $caption
        BuildNumber  = $buildNum
        MajorVersion = $majorVer
        IsWin10      = $isWin10
        IsWin11      = $isWin11
        IsBelowWin10 = $isBelowWin10
    }
}

function Set-FolderPermissions {
    param(
        [string]$Path,
        [string]$Mode,
        [array]$CustomEntries
    )

    Write-Section "Folder Permissions"

    if ($Mode -eq "skip") {
        Write-Status "Permissions" "Skipped - not modified" "Yellow"
        return
    }

    if (-not (Test-Path $Path)) {
        Write-Status "Permissions" "Path not found: $Path" "Red"
        return
    }

    # ---------------------------------------------------------------
    # Windows version check for "auto" mode only
    # ---------------------------------------------------------------
    if ($Mode.ToLower() -eq "auto") {
        $winVer = Get-WindowsVersionInfo

        Write-Status "Detected OS" "$($winVer.Caption) (Build $($winVer.BuildNumber))" "Cyan"

        if ($winVer.IsBelowWin10) {
            Write-Status "Permissions" "Skipped - below Windows 10 not supported (Build $($winVer.BuildNumber))" "Yellow"
            return
        }

        if ($winVer.IsWin11) {
            Write-Status "Permissions" "Skipped - Windows 11+ does not require this ACL (Build $($winVer.BuildNumber))" "Yellow"
            return
        }

        if (-not $winVer.IsWin10) {
            Write-Status "Permissions" "Skipped - unrecognized Windows version (Build $($winVer.BuildNumber))" "Yellow"
            return
        }

        Write-Status "OS Check" "Windows 10 confirmed - applying permissions" "Green"
    }

    # ---------------------------------------------------------------
    # Build ACL entries list
    # ---------------------------------------------------------------
    $entries = switch ($Mode.ToLower()) {
        "auto" {
            @(
                @{ Sid = "S-1-15-2-2"; Rights = "(OI)(CI)(RX)" },
                @{ Sid = "S-1-15-2-1"; Rights = "(OI)(CI)(RX)" }
            )
        }
        "custom" {
            $CustomEntries
        }
        default {
            Write-Status "Permissions" "Unknown mode '$Mode' - skipped" "Yellow"
            return
        }
    }

    if (-not $entries -or $entries.Count -eq 0) {
        Write-Status "Permissions" "No entries defined - skipped" "Yellow"
        return
    }

    $allOk = $true

    foreach ($entry in $entries) {
        $sid    = $entry.Sid
        $rights = $entry.Rights

        # Resolve SID to friendly name for display
        $sidName = try {
            $sidObj = New-Object System.Security.Principal.SecurityIdentifier($sid)
            $sidObj.Translate([System.Security.Principal.NTAccount]).Value
        } catch {
            $sid
        }

        try {
            Write-Status "  Applying" "$rights -> $sidName ($sid)" "Yellow"

            $result = & icacls.exe $Path /grant "*${sid}:${rights}" 2>&1

            if ($LASTEXITCODE -eq 0) {
                Write-Status "  Applied" "$sidName" "Green"
            } else {
                Write-Status "  Failed" "$sidName - $result" "Red"
                $allOk = $false
            }
        } catch {
            Write-Status "  Error" "$sidName - $($_.Exception.Message)" "Red"
            $allOk = $false
        }
    }

    if ($allOk) {
        Write-Status "Permissions" "All entries applied successfully" "Green"
    } else {
        Write-Status "Permissions" "Some entries failed - check above" "Yellow"
    }
}

function Stop-WebView2Processes {
    Write-Section "Closing WebView2 Processes"

    $procName = "msedgewebview2"

    # ---------------------------------------------------------------
    # Step 1: Find all msedgewebview2 processes
    # ---------------------------------------------------------------
    $webviewProcs = Get-Process -Name $procName -ErrorAction SilentlyContinue

    if (-not $webviewProcs -or $webviewProcs.Count -eq 0) {
        Write-Status "Processes" "None running" "Green"
        return
    }

    Write-Status "Found" "$($webviewProcs.Count) msedgewebview2 process(es)" "Yellow"

    # ---------------------------------------------------------------
    # Step 2: Extract --webview-exe-name= from command line args
    #         using WMI to get full command line of each process
    # ---------------------------------------------------------------
    Write-Section "Scanning WebView2 Command Line Arguments"

    $ownerExeNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($p in $webviewProcs) {
        try {
            $wmi = Get-WmiObject Win32_Process -Filter "ProcessId = $($p.Id)" -ErrorAction SilentlyContinue
            if (-not $wmi) { continue }

            $cmdline = $wmi.CommandLine
            if (-not $cmdline) { continue }

            # Match --webview-exe-name=something.exe
            $m = [regex]::Match($cmdline, '--webview-exe-name=([^\s"]+\.exe)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($m.Success) {
                $exeName = $m.Groups[1].Value.Trim()
                $ownerExeNames.Add($exeName) | Out-Null
                Write-Status "  Found arg" "PID $($p.Id) -> --webview-exe-name=$exeName" "Yellow"
            }
        } catch {
            Write-Status "  Warning" "Could not read PID $($p.Id) cmdline: $($_.Exception.Message)" "DarkGray"
        }
    }

    # ---------------------------------------------------------------
    # Step 3: Find and kill owner processes by exe name
    # ---------------------------------------------------------------
    if ($ownerExeNames.Count -gt 0) {
        Write-Section "Closing Owner Processes"
        Write-Status "Unique owners" ($ownerExeNames -join ", ") "Yellow"

        foreach ($exeName in $ownerExeNames) {
            $baseName   = [IO.Path]::GetFileNameWithoutExtension($exeName)
            $ownerProcs = Get-Process -Name $baseName -ErrorAction SilentlyContinue

            if (-not $ownerProcs -or $ownerProcs.Count -eq 0) {
                Write-Status "  Not found" "$exeName - already closed" "DarkGray"
                continue
            }

            Write-Status "  Found" "$($ownerProcs.Count) x $exeName process(es)" "Yellow"

            foreach ($op in $ownerProcs) {
                try {
                    Write-Status "  Closing" "PID $($op.Id) ($exeName)" "Yellow"
                    $op.CloseMainWindow() | Out-Null
                } catch { }
            }

            $waited = 0
            while ($waited -lt 5) {
                Start-Sleep -Seconds 1
                $waited++
                $still = Get-Process -Name $baseName -ErrorAction SilentlyContinue
                if (-not $still -or $still.Count -eq 0) { break }
            }

            $still = Get-Process -Name $baseName -ErrorAction SilentlyContinue
            if ($still -and $still.Count -gt 0) {
                foreach ($op in $still) {
                    try {
                        $op | Stop-Process -Force -ErrorAction SilentlyContinue
                        Write-Status "  Force killed" "PID $($op.Id) ($exeName)" "Red"
                    } catch {
                        Write-Status "  Kill failed" "PID $($op.Id) ($exeName) - $($_.Exception.Message)" "Red"
                    }
                }
                Start-Sleep -Seconds 1
            }

            $remaining = Get-Process -Name $baseName -ErrorAction SilentlyContinue
            if ($remaining -and $remaining.Count -gt 0) {
                Write-Status "  Warning" "$($remaining.Count) x $exeName could not be stopped" "Red"
            } else {
                Write-Status "  Done" "All $exeName stopped" "Green"
            }
        }
    } else {
        Write-Status "Owner processes" "No --webview-exe-name found in any process" "DarkGray"
    }

    # ---------------------------------------------------------------
    # Step 4: Now kill all msedgewebview2 processes
    # ---------------------------------------------------------------
    Write-Section "Closing msedgewebview2 Processes"

    $webviewProcs = Get-Process -Name $procName -ErrorAction SilentlyContinue
    if (-not $webviewProcs -or $webviewProcs.Count -eq 0) {
        Write-Status "Processes" "None running" "Green"
        return
    }

    Write-Status "Closing" "$($webviewProcs.Count) process(es)" "Yellow"

    foreach ($p in $webviewProcs) {
        try {
            Write-Status "  Closing" "PID $($p.Id)" "Yellow"
            $p.CloseMainWindow() | Out-Null
        } catch { }
    }

    $waited = 0
    while ($waited -lt 5) {
        Start-Sleep -Seconds 1
        $waited++
        $still = Get-Process -Name $procName -ErrorAction SilentlyContinue
        if (-not $still -or $still.Count -eq 0) {
            Write-Status "Processes" "All closed gracefully" "Green"
            return
        }
    }

    $still = Get-Process -Name $procName -ErrorAction SilentlyContinue
    if ($still -and $still.Count -gt 0) {
        Write-Status "Force Kill" "$($still.Count) process(es) still running" "Yellow"
        foreach ($p in $still) {
            try {
                $p | Stop-Process -Force -ErrorAction SilentlyContinue
                Write-Status "  Killed" "PID $($p.Id)" "Red"
            } catch {
                Write-Status "  Kill failed" "PID $($p.Id) - $($_.Exception.Message)" "Red"
            }
        }
        Start-Sleep -Seconds 1
    }

    $remaining = Get-Process -Name $procName -ErrorAction SilentlyContinue
    if ($remaining -and $remaining.Count -gt 0) {
        Write-Status "Warning" "$($remaining.Count) process(es) could not be stopped" "Red"
    } else {
        Write-Status "Processes" "All msedgewebview2 stopped" "Green"
    }
}

function Resolve-FilteredFiles {
    param(
        [string]$SourceRoot,
        [string[]]$Filter
    )

    $results = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($entry in $Filter) {
        $entry = $entry.TrimStart('\').TrimStart('/')

        $dirPart  = [IO.Path]::GetDirectoryName($entry)
        $filePart = [IO.Path]::GetFileName($entry)

        $searchRoot = if ($dirPart) {
            Join-Path $SourceRoot $dirPart
        } else {
            $SourceRoot
        }

        if (-not (Test-Path $searchRoot)) {
            Write-Status "Warning" "Path not found: $searchRoot" "Yellow"
            continue
        }

        $found = Get-ChildItem -Path $searchRoot -Filter $filePart -File -ErrorAction SilentlyContinue

        foreach ($f in $found) {
            $rel = $f.FullName.Substring($SourceRoot.Length).TrimStart('\')
            $results.Add(@{ Src = $f.FullName; Rel = $rel })
        }
    }

    return $results
}

function Copy-FilteredFiles {
    param(
        [string]$SourceRoot,
        [string]$DestRoot,
        [string[]]$Filter
    )

    if (-not $Filter) {
        Get-ChildItem $SourceRoot | Move-Item -Destination $DestRoot -Force
        return @{ Copied = "ALL"; Count = (Get-ChildItem $DestRoot -Recurse -File).Count }
    }

    $files = Resolve-FilteredFiles -SourceRoot $SourceRoot -Filter $Filter

    if ($files.Count -eq 0) {
        Write-Status "Warning" "No files matched the filter" "Yellow"
        return @{ Copied = "FILTERED"; Count = 0 }
    }

    $count = 0
    foreach ($f in $files) {
        $dest    = Join-Path $DestRoot $f.Rel
        $destDir = [IO.Path]::GetDirectoryName($dest)
        if (-not (Test-Path $destDir)) {
            New-Item $destDir -ItemType Directory -Force | Out-Null
        }
        Copy-Item $f.Src -Destination $dest -Force
        Write-Status "  Copied" $f.Rel "DarkGray"
        $count++
    }

    return @{ Copied = "FILTERED"; Count = $count }
}

function Set-EnvVar {
    param(
        [string]$Mode,
        [string]$TargetPath
    )

    $varName = "WEBVIEW2_BROWSER_EXECUTABLE_FOLDER"
    $current = [System.Environment]::GetEnvironmentVariable($varName, [System.EnvironmentVariableTarget]::Machine)

    Write-Section "System Environment Variable"

    if ($Mode -eq "skip") {
        Write-Status "Environment Variable" "Skipped - not modified" "Yellow"
        return
    }

    try {
        switch -Regex ($Mode.ToLower()) {
            "^auto$" {
                [System.Environment]::SetEnvironmentVariable($varName, $TargetPath, [System.EnvironmentVariableTarget]::Machine)
                Write-Status "Environment Variable Set" $TargetPath "Green"
                Write-Status "Previous Value" $(if ($current) { $current } else { "(not set)" }) "DarkGray"
            }
            "^clear$" {
                if ($current) {
                    [System.Environment]::SetEnvironmentVariable($varName, $null, [System.EnvironmentVariableTarget]::Machine)
                    Write-Status "Environment Variable" "Cleared (was: $current)" "Green"
                } else {
                    Write-Status "Environment Variable" "Nothing to clear (not set)" "Yellow"
                }
            }
            default {
                if (Test-Path $Mode) {
                    [System.Environment]::SetEnvironmentVariable($varName, $Mode, [System.EnvironmentVariableTarget]::Machine)
                    Write-Status "Environment Variable Set" $Mode "Green"
                    Write-Status "Previous Value" $(if ($current) { $current } else { "(not set)" }) "DarkGray"
                } else {
                    Write-Status "Environment Variable" "Warning: Path '$Mode' not found - skipped" "Yellow"
                }
            }
        }
    } catch {
        Write-Status "Environment Variable Error" $_.Exception.Message "Red"
    }
}

function Set-WebView2Policy {
    param(
        [string]$Mode,
        [string]$TargetPath
    )

    $policyFilePath  = "$env:SystemRoot\System32\GroupPolicy\Machine\registry.pol"
    $policyKey       = "Software\Policies\Microsoft\Edge\WebView2\BrowserExecutableFolder"
    $policyValueName = "*"

    Write-Section "Group Policy BrowserExecutableFolder"

    if ($Mode -eq "skip") {
        Write-Status "Policy" "Skipped - not modified" "Yellow"
        return
    }

    if (-not (Get-Module -ListAvailable PolicyFileEditor -ErrorAction SilentlyContinue)) {
        try {
            Write-Status "PolicyFileEditor" "Installing module..." "Yellow"
            Install-Module PolicyFileEditor -Force -Scope AllUsers -ErrorAction Stop
            Write-Status "PolicyFileEditor" "Installed" "Green"
        } catch {
            Write-Status "PolicyFileEditor" "Install failed - policy skipped" "Yellow"
            return
        }
    }

    Import-Module PolicyFileEditor -ErrorAction SilentlyContinue

    if (-not (Get-Module PolicyFileEditor)) {
        Write-Status "PolicyFileEditor" "Failed to load - policy skipped" "Yellow"
        return
    }

    try {
        switch -Regex ($Mode.ToLower()) {
            "^auto$" {
                $existing = Get-PolicyFileEntry -Path $policyFilePath -Key $policyKey -ValueName $policyValueName -ErrorAction SilentlyContinue
                Set-PolicyFileEntry -Path $policyFilePath -Key $policyKey -ValueName $policyValueName -Data $TargetPath -Type String
                Write-Status "Policy Set" $TargetPath "Green"
                Write-Status "Previous Value" $(if ($existing) { $existing.Data } else { "(not set)" }) "DarkGray"
                Write-Status "GPUpdate" "Running..." "Yellow"
                Start-Process gpupdate.exe -ArgumentList "/force" -NoNewWindow -Wait
                Write-Status "GPUpdate" "Done" "Green"
            }
            "^clear$" {
                $existing = Get-PolicyFileEntry -Path $policyFilePath -Key $policyKey -ValueName $policyValueName -ErrorAction SilentlyContinue
                if ($existing) {
                    Remove-PolicyFileEntry -Path $policyFilePath -Key $policyKey -ValueName $policyValueName -ErrorAction SilentlyContinue
                    Write-Status "Policy" "Cleared (was: $($existing.Data))" "Green"
                    Write-Status "GPUpdate" "Running..." "Yellow"
                    Start-Process gpupdate.exe -ArgumentList "/force" -NoNewWindow -Wait
                    Write-Status "GPUpdate" "Done" "Green"
                } else {
                    Write-Status "Policy" "Nothing to clear (not set)" "Yellow"
                }
            }
            default {
                if (Test-Path $Mode) {
                    $existing = Get-PolicyFileEntry -Path $policyFilePath -Key $policyKey -ValueName $policyValueName -ErrorAction SilentlyContinue
                    Set-PolicyFileEntry -Path $policyFilePath -Key $policyKey -ValueName $policyValueName -Data $Mode -Type String
                    Write-Status "Policy Set" $Mode "Green"
                    Write-Status "Previous Value" $(if ($existing) { $existing.Data } else { "(not set)" }) "DarkGray"
                    Write-Status "GPUpdate" "Running..." "Yellow"
                    Start-Process gpupdate.exe -ArgumentList "/force" -NoNewWindow -Wait
                    Write-Status "GPUpdate" "Done" "Green"
                } else {
                    Write-Status "Policy" "Warning: Path '$Mode' not found - skipped" "Yellow"
                }
            }
        }
    } catch {
        Write-Status "Policy Error" $_.Exception.Message "Red"
    }
}

function Set-RegistryPvValue {
    param(
        [string]$Mode,
        [string]$DownloadedVersion
    )

    Write-Section "Registry pv Value"

    $regPath = if ([Environment]::Is64BitOperatingSystem) {
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"
    } else {
        "HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"
    }

    if ($Mode -eq "skip") {
        Write-Status "Registry pv" "Skipped - not modified" "Yellow"
        return $null
    }

    try {
        if (-not (Test-Path $regPath)) {
            New-Item $regPath -Force | Out-Null
            Write-Status "Registry Key" "Created" "Green"
        }

        $pvValue = switch -Regex ($Mode.ToLower()) {
            "^auto$" {
                $DownloadedVersion
            }
            default {
                # Custom version value
                if ($Mode -match '^\d+\.\d+\.\d+\.\d+$') {
                    $Mode
                } else {
                    Write-Status "Registry pv" "Invalid version format '$Mode' - must be X.X.X.X - skipped" "Yellow"
                    return $null
                }
            }
        }

        $existing = (Get-ItemProperty -Path $regPath -Name "pv" -ErrorAction SilentlyContinue).pv
        New-ItemProperty -Path $regPath -Name "pv" -Value $pvValue -PropertyType String -Force | Out-Null
        Write-Status "Registry pv" $pvValue "Green"
        Write-Status "Previous Value" $(if ($existing) { $existing } else { "(not set)" }) "DarkGray"
        Write-Status "Registry Path" $regPath "DarkGray"

        return $pvValue
    } catch {
        Write-Status "Registry Error" $_.Exception.Message "Red"
        return $null
    }
}

function Set-RegistryLocationValue {
    param(
        [string]$Path
    )

    Write-Section "Registry Location Value"

    $regPath = if ([Environment]::Is64BitOperatingSystem) {
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"
    } else {
        "HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"
    }

    try {
        if (-not (Test-Path $regPath)) {
            New-Item $regPath -Force | Out-Null
            Write-Status "Registry Key" "Created" "Green"
        }

        $existing = (Get-ItemProperty -Path $regPath -Name "location" -ErrorAction SilentlyContinue).location
        New-ItemProperty -Path $regPath -Name "location" -Value $Path -PropertyType String -Force | Out-Null
        Write-Status "Registry location" $Path "Green"
        Write-Status "Previous Value" $(if ($existing) { $existing } else { "(not set)" }) "DarkGray"
        Write-Status "Registry Path" $regPath "DarkGray"
    } catch {
        Write-Status "Registry Error" $_.Exception.Message "Red"
    }
}

# ---------------------------------------------------------------
# Elevate
# ---------------------------------------------------------------
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Requesting Administrator privileges..." -ForegroundColor Yellow
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"iex (gc '$($MyInvocation.MyCommand.Path)' -Raw)`"" -Verb RunAs
    exit
}

# ---------------------------------------------------------------
# Detect Windows version (once, reuse in header + summary)
# ---------------------------------------------------------------
$winVer = Get-WindowsVersionInfo

$winVerLabel = if     ($winVer.IsWin11)      { "Windows 11" }
               elseif ($winVer.IsWin10)      { "Windows 10" }
               elseif ($winVer.IsBelowWin10) { "Below Windows 10" }
               else                          { "Unknown"    }

# ---------------------------------------------------------------
# Header
# ---------------------------------------------------------------
Write-Host ""
Write-Host "========================================" -ForegroundColor DarkCyan
Write-Host "      WebView2 Runtime Portable         " -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor DarkCyan
Write-Host ""
Write-Status "Architecture"   $arch
Write-Status "Install path"   $ptpath
Write-Status "Version folder" $(if ($verFolder) { "Yes" } else { "No" })
Write-Status "Download path"  $dlpath
Write-Status "OS"             "$($winVer.Caption) (Build $($winVer.BuildNumber))"
Write-Status "Registry pv"    $registryPvMode
Write-Status "Policy"         $policyMode
Write-Status "Env Variable"   $envVarMode
Write-Status "Permissions"    $(
    if ($permissionsMode.ToLower() -eq "auto") {
        "auto (Windows 10 only - current: $winVerLabel)"
    } else {
        $permissionsMode
    }
)
Write-Status "File filter"    $(if ($fileFilter) { "$($fileFilter.Count) pattern(s)" } else { "ALL (no filter)" })
Write-Host ""

try {
    # ---------------------------------------------------------------
    # Fetch download page
    # ---------------------------------------------------------------
    Write-Section "Fetching WebView2 Download Info"
    Write-Status "Status" "Contacting Microsoft..." "Yellow"
    $html = (Invoke-WebRequest -Uri "https://developer.microsoft.com/en-us/microsoft-edge/webview2/#download-section" -UseBasicParsing).Content

    $pattern = 'https:\\u002F\\u002Fmsedge\.sf\.dl\.delivery\.mp\.microsoft\.com\\u002Ffilestreamingservice\\u002Ffiles\\u002F[a-z0-9\-]+\\u002FMicrosoft\.WebView2\.FixedVersionRuntime\.(\d+\.\d+\.\d+\.\d+)\.(x86|x64|arm64)\.cab'
    $matches = [regex]::Matches($html, $pattern)

    if ($matches.Count -eq 0) {
        Write-Status "Error" "No download URLs found" "Red"
        pause
        exit 1
    }

    $versions = $matches | ForEach-Object { $_.Groups[1].Value } | Sort-Object { [version]$_ } -Descending -Unique
    $ver = $versions[0]
    Write-Status "Latest Version" $ver "Green"

    $cabUrl = $null
    foreach ($m in $matches) {
        if ($m.Groups[1].Value -eq $ver -and $m.Groups[2].Value -eq $arch) {
            $cabUrl = $m.Value.Replace('\u002F', '/')
            break
        }
    }

    if (-not $cabUrl) {
        Write-Status "Error" "No URL found for $ver ($arch)" "Red"
        pause
        exit 1
    }

    Write-Status "Download URL" $cabUrl "DarkGray"

    # ---------------------------------------------------------------
    # Download
    # ---------------------------------------------------------------
    Write-Section "Downloading"
    if (-not (Test-Path $dlpath)) { New-Item $dlpath -ItemType Directory -Force | Out-Null }

    $cab = Join-Path $dlpath "Microsoft.WebView2.FixedVersionRuntime.$ver.$arch.cab"
    Write-Status "File" ([IO.Path]::GetFileName($cab)) "Yellow"

    Invoke-WebRequest -Uri $cabUrl -OutFile $cab
    Write-Status "Download" "Completed" "Green"
    Write-Status "Size" ("{0:N2} MB" -f ((Get-Item $cab).Length / 1MB)) "Cyan"

    # ---------------------------------------------------------------
    # Stop WebView2 processes before extraction
    # ---------------------------------------------------------------
    Stop-WebView2Processes

    # ---------------------------------------------------------------
    # Clean up and prepare paths
    # ---------------------------------------------------------------
    Write-Section "Cleanup and Preparation"
    
    # Determine final extraction path
    $finalPath = if ($verFolder) {
        Join-Path $ptpath $ver
    } else {
        $ptpath
    }
    
    # Clean up the entire $ptpath directory
    if (Test-Path $ptpath) {
        Write-Status "Cleanup" "Removing $ptpath" "Yellow"
        Remove-Item $ptpath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Status "Cleanup" "Complete" "Green"
    }
    
    New-Item $finalPath -ItemType Directory -Force | Out-Null
    Write-Status "Target Path" $finalPath "Cyan"

    # ---------------------------------------------------------------
    # Extract
    # ---------------------------------------------------------------
    Write-Section "Extracting"

    $temp = Join-Path $env:TEMP ([guid]::NewGuid().ToString())
    New-Item $temp -ItemType Directory -Force | Out-Null

    Write-Status "Extracting CAB" "Please wait..." "Yellow"
    & expand -F:* "`"$cab`"" "`"$temp`"" >$null 2>&1

    $src = Join-Path $temp "Microsoft.WebView2.FixedVersionRuntime.$ver.$arch"
    if (-not (Test-Path $src)) {
        Write-Status "Error" "Extraction failed - source folder not found" "Red"
        pause
        exit 1
    }

    Write-Status "CAB Extracted" $temp "Green"

    # ---------------------------------------------------------------
    # Copy files
    # ---------------------------------------------------------------
    Write-Section "Copying Files"
    $result = Copy-FilteredFiles -SourceRoot $src -DestRoot $finalPath -Filter $fileFilter

    Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
    Write-Status "Mode"        $result.Copied "Cyan"
    Write-Status "Files Count" $result.Count  "Green"
    Write-Status "Output Path" $finalPath      "Green"

    # ---------------------------------------------------------------
    # Folder Permissions (apply to final path)
    # ---------------------------------------------------------------
    Set-FolderPermissions -Path $finalPath -Mode $permissionsMode -CustomEntries $permissionsCustom

    # ---------------------------------------------------------------
    # Registry pv value (with custom option)
    # ---------------------------------------------------------------
    $registryPvSet = Set-RegistryPvValue -Mode $registryPvMode -DownloadedVersion $ver

    # ---------------------------------------------------------------
    # Registry location value
    # ---------------------------------------------------------------
    Set-RegistryLocationValue -Path $ptpath

    # ---------------------------------------------------------------
    # Determine the path to use for policy and environment variable
    # ---------------------------------------------------------------
    # KEY CHANGE: Use $finalPath instead of $ptpath to respect $verFolder setting
    $configPath = $finalPath

    # ---------------------------------------------------------------
    # Policy
    # ---------------------------------------------------------------
    Set-WebView2Policy -Mode $policyMode -TargetPath $configPath

    # ---------------------------------------------------------------
    # Environment Variable
    # ---------------------------------------------------------------
    Set-EnvVar -Mode $envVarMode -TargetPath $configPath

    # ---------------------------------------------------------------
    # Summary
    # ---------------------------------------------------------------
    Write-Host ""
    Write-Host "========================================" -ForegroundColor DarkCyan
    Write-Host "  COMPLETE                              " -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor DarkCyan

    Write-Status "Version"            "$ver ($arch)"                               "Green"
    Write-Status "OS"                 "$($winVer.Caption) (Build $($winVer.BuildNumber))" "Cyan"
    Write-Status "Base Path"          $ptpath                                       "Cyan"
    Write-Status "Final Path"         $finalPath                                    "Cyan"
    Write-Status "Files"              "$($result.Count) files ($($result.Copied))" "Cyan"
    Write-Status "Registry pv"        $(if ($registryPvSet) { $registryPvSet } else { "Skipped" }) "Cyan"
    Write-Status "Registry location"  $ptpath                                       "Cyan"

    $permLabel = switch ($permissionsMode.ToLower()) {
        "auto"   {
            if     ($winVer.IsWin10)      { "Applied (Windows 10 - ALL_APP_PACKAGES + ALL_APPLICATION_PACKAGES)" }
            elseif ($winVer.IsWin11)      { "Skipped (Windows 11+ not required)"       }
            elseif ($winVer.IsBelowWin10) { "Skipped (below Windows 10 not supported)" }
            else                          { "Skipped (unrecognized Windows version)"    }
        }
        "skip"   { "Not modified"                                           }
        "custom" { "Applied ($($permissionsCustom.Count) custom entries)"  }
        default  { "Unknown mode"                                           }
    }
    Write-Status "Permissions"  $permLabel "Cyan"

    $policyLabel = switch -Regex ($policyMode.ToLower()) {
        "^auto$"  { "Set to $configPath"     }
        "^skip$"  { "Not modified"       }
        "^clear$" { "Cleared"            }
        default   { "Set to $policyMode" }
    }
    Write-Status "Group Policy" $policyLabel "Cyan"

    $envLabel = switch -Regex ($envVarMode.ToLower()) {
        "^auto$"  { "Set to $configPath"    }
        "^skip$"  { "Not modified"      }
        "^clear$" { "Cleared"           }
        default   { "Set to $envVarMode" }
    }
    Write-Status "Environment Variable" $envLabel "Cyan"

    Write-Host "========================================" -ForegroundColor DarkCyan
}
catch {
    Write-Host ""
    Write-Status "ERROR" $_.Exception.Message "Red"
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
}

Write-Host ""
pause