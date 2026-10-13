<# : batch portion
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex (${%~f0} | out-string)"
exit /b
: end batch / begin powershell #>

$scriptver = '13.10.2026'
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
    $minorVer   = [int]$os.Version.Split('.')[1]
    $caption    = $os.Caption

    # Windows version detection by build number
    # Windows 10 builds : 10240 (1507) - 19045 (22H2)
    # Windows 11 builds : 22000+
    # Windows 8.1       : 9600
    # Windows 8         : 9200
    # Windows 7         : 7601

    $isWin10 = ($majorVer -eq 10 -and $buildNum -ge 10240 -and $buildNum -le 19045)
    $isWin11 = ($majorVer -eq 10 -and $buildNum -ge 22000)
    $isWin81 = ($majorVer -eq 6 -and $minorVer -eq 3)
    $isWin8  = ($majorVer -eq 6 -and $minorVer -eq 2)
    $isWin7  = ($majorVer -eq 6 -and $minorVer -eq 1)
    $isBelowWin10 = ($majorVer -lt 10) -or ($majorVer -eq 10 -and $buildNum -lt 10240)

    return @{
        Caption      = $caption
        BuildNumber  = $buildNum
        MajorVersion = $majorVer
        MinorVersion = $minorVer
        IsWin10      = $isWin10
        IsWin11      = $isWin11
        IsWin81      = $isWin81
        IsWin8       = $isWin8
        IsWin7       = $isWin7
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
               elseif ($winVer.IsWin81)      { "Windows 8.1" }
               elseif ($winVer.IsWin8)       { "Windows 8" }
               elseif ($winVer.IsWin7)       { "Windows 7" }
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
    # Fetch WebView2 versions from Microsoft API
    # ---------------------------------------------------------------
    Write-Section "Fetching WebView2 Download Info"
    Write-Status "Status" "Contacting Microsoft API..." "Yellow"

    # For Windows 8.1 and below, use fixed version from GitHub
    if ($winVer.IsWin81 -or $winVer.IsWin8 -or $winVer.IsWin7) {
        Write-Status "Detected OS" "$winVerLabel - Using legacy version 109.0.1518.78" "Yellow"
        
        $ver = "109.0.1518.78"
        $cabUrl = "https://github.com/westinyang/WebView2RuntimeArchive/releases/download/109.0.1518.78/Microsoft.WebView2.FixedVersionRuntime.109.0.1518.78.$arch.cab"
        
        Write-Status "Legacy Version" $ver "Yellow"
        Write-Status "Source" "GitHub Archive" "DarkGray"
    } else {
        # Modern Windows - fetch from Microsoft API
        try {
            $json = Invoke-WebRequest -Uri "https://developer.microsoft.com/microsoft-edge/api/webview2" -UseBasicParsing | ConvertFrom-Json
            
            if ($json.Count -eq 0) {
                Write-Status "Error" "No versions found in API response" "Red"
                pause
                exit 1
            }

            # Get latest version
            $latestVersion = $json[0]
            $ver = $latestVersion.version
            Write-Status "Latest Version" $ver "Green"

            # Find the correct architecture URL
            $cabUrl = $null
            foreach ($build in $latestVersion.builds) {
                if ($build.architecture -eq $arch) {
                    $cabUrl = $build.url
                    break
                }
            }

            if (-not $cabUrl) {
                Write-Status "Error" "No download URL found for $arch architecture" "Red"
                pause
                exit 1
            }
        } catch {
            Write-Status "Error" "Failed to fetch API: $($_.Exception.Message)" "Red"
            pause
            exit 1
        }
    }

    Write-Status "Download URL" $cabUrl "DarkGray"

    # ---------------------------------------------------------------
    # Download
    # ---------------------------------------------------------------
    Write-Section "Downloading"
    if (-not (Test-Path $dlpath)) { New-Item $dlpath -ItemType Directory -Force | Out-Null }

    $cab = Join-Path $dlpath "Microsoft.WebView2.FixedVersionRuntime.$ver.$arch.cab"
    Write-Status "File" ([IO.Path]::GetFileName($cab)) "Yellow"

    try {
        Invoke-WebRequest -Uri $cabUrl -OutFile $cab -ErrorAction Stop
        Write-Status "Download" "Completed" "Green"
        Write-Status "Size" ("{0:N2} MB" -f ((Get-Item $cab).Length / 1MB)) "Cyan"
    } catch {
        Write-Status "Error" "Download failed: $($_.Exception.Message)" "Red"
        pause
        exit 1
    }

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
    # Create Remove.bat in the installation folder
    # ---------------------------------------------------------------
    Write-Section "Creating Removal Script"

    $removeBatContent = @'
<# : batch portion
@echo off
setlocal enabledelayedexpansion
set "SCRIPT_PATH=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex ([System.IO.File]::ReadAllText('%~f0'))" %*
exit /b
: end batch / begin powershell #>

$scriptver = '13.10.2026'
$ProgressPreference = 'SilentlyContinue'
$host.ui.RawUI.WindowTitle = 'WebView2 Runtime Removal ' + $scriptver

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

# Check for Admin privileges
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Requesting Administrator privileges..." -ForegroundColor Yellow
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"iex ([System.IO.File]::ReadAllText('$($MyInvocation.MyCommand.Path)'))`"" -Verb RunAs
    exit
}

Write-Host ""
Write-Host "========================================" -ForegroundColor DarkCyan
Write-Host "  WebView2 Runtime Removal" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor DarkCyan
Write-Host ""

# Get script path from batch environment variable
$scriptPath = $env:SCRIPT_PATH.TrimEnd('\')
$removeDir  = $scriptPath

# ================================================================
# Initial Confirmation Dialog
# ================================================================

Write-Host "========================================" -ForegroundColor DarkYellow
Write-Host "  CONFIRM REMOVAL" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor DarkYellow
Write-Host ""
Write-Host "This will completely remove WebView2 Runtime from:" -ForegroundColor Yellow
Write-Host "  $removeDir" -ForegroundColor Cyan
Write-Host ""
Write-Host "The following will be deleted:" -ForegroundColor Yellow
Write-Host "  - Portable folder" -ForegroundColor Gray
Write-Host "  - Registry entries (pv, location)" -ForegroundColor Gray
Write-Host "  - Group Policy settings" -ForegroundColor Gray
Write-Host "  - Environment variables" -ForegroundColor Gray
Write-Host ""
Write-Host ""
Write-Host "Options:" -ForegroundColor Gray
Write-Host "  [Y] Yes  - Continue with removal" -ForegroundColor Green
Write-Host "  [N] No   - Cancel and exit" -ForegroundColor Red
Write-Host ""

$confirmChoice = $null
while ($confirmChoice -ne 'Y' -and $confirmChoice -ne 'N') {
    $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    $confirmChoice = $key.Character.ToString().ToUpper()
    
    if ($confirmChoice -eq 'Y') {
        Write-Host "Y" -ForegroundColor Green
        Write-Host ""
        break
    } elseif ($confirmChoice -eq 'N') {
        Write-Host "N" -ForegroundColor Red
        Write-Host ""
        Write-Status "Status" "Removal canceled by user" "Yellow"
        Write-Host ""
        exit 0
    }
}

Write-Status "Portable Folder" $removeDir "Yellow"
Write-Status "Status" "Preparing removal script..." "Yellow"
Write-Host ""

try {
    # Generate unique temp file name
    $guid = [guid]::NewGuid().ToString().Substring(0, 8)
    $tempPsScript = Join-Path $env:TEMP "wv2_removal_$guid.ps1"
    $tempBatScript = Join-Path $env:TEMP "wv2_removal_$guid.bat"

    # Create comprehensive PowerShell cleanup script
    $psCleanupCode = @"
`$removeDir = '$removeDir'
`$ProgressPreference = 'SilentlyContinue'

function Write-Status {
    param(
        [string]`$Label,
        [string]`$Value,
        [string]`$Color = "Cyan"
    )
    Write-Host ("{0,-22}: " -f `$Label) -NoNewline -ForegroundColor Gray
    Write-Host `$Value -ForegroundColor `$Color
}

function Write-Section {
    param([string]`$Title)
    Write-Host ""
    Write-Host "--- `$Title ---" -ForegroundColor DarkGray
}

`$host.ui.RawUI.WindowTitle = 'WebView2 Cleanup' 

Write-Host ""
Write-Host "========================================" -ForegroundColor DarkRed
Write-Host "  WebView2 Runtime Cleanup" -ForegroundColor Red
Write-Host "========================================" -ForegroundColor DarkRed
Write-Host ""
Write-Status "Portable Folder" `$removeDir "Yellow"
Write-Status "Status" "Running deferred cleanup..." "Yellow"
Write-Host ""

try {

    # ================================================================
    # Phase 1: Close all processes
    # ================================================================

    Write-Section "Closing WebView2 Processes"

    `$procName = "msedgewebview2"
    `$webviewProcs = Get-Process -Name `$procName -ErrorAction SilentlyContinue

    if (-not `$webviewProcs -or `$webviewProcs.Count -eq 0) {
        Write-Status "Processes" "None running" "Green"
    } else {
        Write-Status "Found" "`$(`$webviewProcs.Count) msedgewebview2 process(es)" "Yellow"

        `$ownerExeNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        foreach (`$p in `$webviewProcs) {
            try {
                `$wmi = Get-WmiObject Win32_Process -Filter "ProcessId = `$(`$p.Id)" -ErrorAction SilentlyContinue
                if (-not `$wmi) { continue }
                `$cmdline = `$wmi.CommandLine
                if (-not `$cmdline) { continue }
                `$m = [regex]::Match(`$cmdline, '--webview-exe-name=([^\s"]+\.exe)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                if (`$m.Success) {
                    `$exeName = `$m.Groups[1].Value.Trim()
                    `$ownerExeNames.Add(`$exeName) | Out-Null
                    Write-Status "  Found arg" "PID `$(`$p.Id) -> `$exeName" "Yellow"
                }
            } catch { }
        }

        if (`$ownerExeNames.Count -gt 0) {
            Write-Section "Closing Owner Processes"
            foreach (`$exeName in `$ownerExeNames) {
                `$baseName   = [IO.Path]::GetFileNameWithoutExtension(`$exeName)
                `$ownerProcs = Get-Process -Name `$baseName -ErrorAction SilentlyContinue
                if (`$ownerProcs -and `$ownerProcs.Count -gt 0) {
                    Write-Status "  Closing" "`$exeName (`$(`$ownerProcs.Count) process(es))" "Yellow"
                    foreach (`$op in `$ownerProcs) { try { `$op.CloseMainWindow() | Out-Null } catch { } }
                    `$waited = 0
                    while (`$waited -lt 5) {
                        Start-Sleep -Seconds 1
                        `$waited++
                        `$still = Get-Process -Name `$baseName -ErrorAction SilentlyContinue
                        if (-not `$still -or `$still.Count -eq 0) { break }
                    }
                    `$still = Get-Process -Name `$baseName -ErrorAction SilentlyContinue
                    if (`$still -and `$still.Count -gt 0) {
                        foreach (`$op in `$still) {
                            try { `$op | Stop-Process -Force -ErrorAction SilentlyContinue
                                Write-Status "  Force killed" "PID `$(`$op.Id)" "Red"
                            } catch { }
                        }
                    }
                }
            }
        }

        Write-Section "Closing msedgewebview2 Processes"
        `$webviewProcs = Get-Process -Name `$procName -ErrorAction SilentlyContinue
        if (`$webviewProcs -and `$webviewProcs.Count -gt 0) {
            Write-Status "Closing" "`$(`$webviewProcs.Count) process(es)" "Yellow"
            foreach (`$p in `$webviewProcs) { try { `$p.CloseMainWindow() | Out-Null } catch { } }
            `$waited = 0
            while (`$waited -lt 5) {
                Start-Sleep -Seconds 1
                `$waited++
                `$still = Get-Process -Name `$procName -ErrorAction SilentlyContinue
                if (-not `$still -or `$still.Count -eq 0) { break }
            }
            `$still = Get-Process -Name `$procName -ErrorAction SilentlyContinue
            if (`$still -and `$still.Count -gt 0) {
                foreach (`$p in `$still) {
                    try { `$p | Stop-Process -Force -ErrorAction SilentlyContinue
                        Write-Status "  Force killed" "PID `$(`$p.Id)" "Red"
                    } catch { }
                }
            }
            Write-Status "Processes" "Closed" "Green"
        }
    }

    # ================================================================
    # Phase 2: Close Explorer windows
    # ================================================================

    Write-Section "Closing Explorer Windows"
    
    try {
        `$shell = New-Object -ComObject Shell.Application -ErrorAction SilentlyContinue
        if (`$shell) {
            `$folder = [uri]`$removeDir
            `$windowsClosed = 0
            
            Write-Status "Target Path"  `$removeDir  "Yellow"
            
            foreach (`$w in `$shell.Windows()) {
                try {
                    if (`$w.LocationURL -ieq `$folder.AbsoluteUri) {
                        Write-Status "  Closing" "Explorer window: `$(`$w.LocationName)" "Yellow"
                        `$w.Quit()
                        `$windowsClosed++
                    } else {
                        `$wFolder = [uri]`$w.LocationURL
                        if (`$wFolder.LocalPath -like "`$removeDir*") {
                            Write-Status "  Closing" "Explorer window: `$(`$w.LocationName)" "Yellow"
                            `$w.Quit()
                            `$windowsClosed++
                        }
                    }
                } catch {
                }
            }
            
            if (`$windowsClosed -gt 0) {
                Write-Status "Windows Closed" "`$windowsClosed Explorer window(s)" "Green"
                Start-Sleep -Seconds 1
            } else {
                Write-Status "Explorer Windows" "None showing target path" "Green"
            }
        } else {
            Write-Status "Shell.Application" "Could not create COM object" "Yellow"
        }
    } catch {
        Write-Status "Explorer Windows" "Warning: `$(`$_.Exception.Message)" "Yellow"
    }

    # ================================================================
    # Phase 3: Remove Registry entries
    # ================================================================

    Write-Section "Registry - pv Value"
    `$regPath = if ([Environment]::Is64BitOperatingSystem) {
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"
    } else {
        "HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"
    }

    try {
        `$pvExists = Get-ItemProperty -Path `$regPath -Name "pv" -ErrorAction SilentlyContinue
        if (`$pvExists) {
            Remove-ItemProperty -Path `$regPath -Name "pv" -Force -ErrorAction Stop
            Write-Status "Registry pv" "Deleted" "Green"
        } else {
            Write-Status "Registry pv" "Not found - skipped" "Yellow"
        }
    } catch {
        Write-Status "Registry pv" "Error: `$(`$_.Exception.Message)" "Red"
    }

    Write-Section "Registry - location Value"
    try {
        `$locExists = Get-ItemProperty -Path `$regPath -Name "location" -ErrorAction SilentlyContinue
        if (`$locExists) {
            Remove-ItemProperty -Path `$regPath -Name "location" -Force -ErrorAction Stop
            Write-Status "Registry location" "Deleted" "Green"
        } else {
            Write-Status "Registry location" "Not found - skipped" "Yellow"
        }
    } catch {
        Write-Status "Registry location" "Error: `$(`$_.Exception.Message)" "Red"
    }

    # ================================================================
    # Phase 4: Remove Group Policy
    # ================================================================

    Write-Section "Group Policy - BrowserExecutableFolder"
    `$policyFilePath  = "`$env:SystemRoot\System32\GroupPolicy\Machine\registry.pol"
    `$policyKey       = "Software\Policies\Microsoft\Edge\WebView2\BrowserExecutableFolder"
    `$policyValueName = "*"

    try {
        if (Get-Module -ListAvailable PolicyFileEditor -ErrorAction SilentlyContinue) {
            Import-Module PolicyFileEditor -ErrorAction SilentlyContinue
            if (Get-Module PolicyFileEditor) {
                `$existing = Get-PolicyFileEntry -Path `$policyFilePath -Key `$policyKey -ValueName `$policyValueName -ErrorAction SilentlyContinue
                if (`$existing) {
                    Remove-PolicyFileEntry -Path `$policyFilePath -Key `$policyKey -ValueName `$policyValueName -ErrorAction SilentlyContinue
                    Write-Status "Policy" "Deleted" "Green"
                    Write-Status "GPUpdate" "Running..." "Yellow"
                    Start-Process gpupdate.exe -ArgumentList "/force" -NoNewWindow -Wait
                    Write-Status "GPUpdate" "Done" "Green"
                } else {
                    Write-Status "Policy" "Not found - skipped" "Yellow"
                }
            } else {
                Write-Status "Policy" "PolicyFileEditor module load failed - skipped" "Yellow"
            }
        } else {
            Write-Status "Policy" "PolicyFileEditor module not available - skipped" "Yellow"
        }
    } catch {
        Write-Status "Policy" "Error: `$(`$_.Exception.Message)" "Yellow"
    }

    # ================================================================
    # Phase 5: Remove Environment Variable
    # ================================================================

    Write-Section "System Environment Variable"
    `$varName = "WEBVIEW2_BROWSER_EXECUTABLE_FOLDER"
    try {
        `$current = [System.Environment]::GetEnvironmentVariable(`$varName, [System.EnvironmentVariableTarget]::Machine)
        if (`$current) {
            [System.Environment]::SetEnvironmentVariable(`$varName, `$null, [System.EnvironmentVariableTarget]::Machine)
            Write-Status "Environment Variable" "Deleted (was: `$current)" "Green"
        } else {
            Write-Status "Environment Variable" "Not found - skipped" "Yellow"
        }
    } catch {
        Write-Status "Environment Variable" "Error: `$(`$_.Exception.Message)" "Red"
    }

    # ================================================================
    # Phase 6: Delete folder
    # ================================================================

    Write-Section "File Removal"
    Write-Status "Target Folder" `$removeDir "Yellow"
    Write-Status "Status" "Waiting for all locks to release..." "Yellow"

    `$maxRetries = 8
    `$attempt = 0
    `$folderDeleted = `$false

    while (`$attempt -lt `$maxRetries) {
        `$attempt++
        try {
            if (Test-Path `$removeDir) {
                Remove-Item `$removeDir -Recurse -Force -ErrorAction Stop
                Write-Status "Folder Deleted" `$removeDir "Green"
                `$folderDeleted = `$true
                break
            } else {
                Write-Status "Folder" "Already deleted" "Green"
                `$folderDeleted = `$true
                break
            }
        } catch {
            if (`$attempt -lt `$maxRetries) {
                `$remaining = `$maxRetries - `$attempt
                Write-Status "Attempt `$attempt" "Failed - retrying in 3 seconds (`$remaining remaining)..." "Yellow"
                Start-Sleep -Seconds 3
            } else {
                Write-Status "Error" "Could not delete after `$maxRetries attempts" "Red"
                Write-Status "Details" "`$(`$_.Exception.Message)" "Yellow"
                Write-Status "Manual Action" "Please manually delete: `$removeDir" "Yellow"
            }
        }
    }

    Write-Host ""
    Write-Host "========================================" -ForegroundColor DarkGreen
    Write-Host "  REMOVAL COMPLETE" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor DarkGreen
    Write-Host ""
    Write-Status "WebView2 Processes" "Stopped" "Green"
    Write-Status "Explorer Windows" "Closed" "Green"
    Write-Status "Registry pv" "Removed" "Green"
    Write-Status "Registry location" "Removed" "Green"
    Write-Status "Group Policy" "Removed" "Green"
    Write-Status "Environment Variable" "Removed" "Green"
    if (`$folderDeleted) {
        Write-Status "Portable Folder" "Deleted" "Green"
    } else {
        Write-Status "Portable Folder" "Failed - see above" "Red"
    }
    Write-Host "========================================" -ForegroundColor DarkGreen
    Write-Host ""

} catch {
    Write-Host ""
    Write-Status "FATAL ERROR" `$_.Exception.Message "Red"
    Write-Host `$_.ScriptStackTrace -ForegroundColor DarkRed
    Write-Host ""
}

Write-Host ""
Write-Host "Press any key to close this window and complete cleanup..." -ForegroundColor Yellow
`$null = `$Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

# Self-delete this script
Start-Sleep -Seconds 2
Remove-Item `$PSCommandPath -Force -ErrorAction SilentlyContinue

# Delete the batch wrapper
Remove-Item '$tempBatScript' -Force -ErrorAction SilentlyContinue
"@

    # Create batch wrapper script
    $batCleanupCode = @"
@echo off
setlocal enabledelayedexpansion

REM Change to TEMP directory as working directory
cd /d "%TEMP%"

REM Wait for current PowerShell process to exit
timeout /t 3 /nobreak >nul 2>&1

REM Run the PowerShell cleanup script in a new process
powershell -NoProfile -ExecutionPolicy Bypass -File "$tempPsScript"

REM Pause to show results
pause

REM Clean up self
del /q "%~f0" >nul 2>&1
"@

    try {
        # Write PowerShell cleanup script
        [System.IO.File]::WriteAllText($tempPsScript, $psCleanupCode, [System.Text.Encoding]::UTF8)
        Write-Status "Cleanup Script" "Created successfully" "Green"

        # Write batch cleanup script
        [System.IO.File]::WriteAllText($tempBatScript, $batCleanupCode, [System.Text.Encoding]::ASCII)
        Write-Status "Batch Wrapper" "Created successfully" "Green"

        Write-Host ""
        Write-Host "========================================" -ForegroundColor DarkYellow
        Write-Host "  TRANSFER TO CLEANUP" -ForegroundColor Yellow
        Write-Host "========================================" -ForegroundColor DarkYellow
        Write-Host ""
        Write-Status "Next Step" "Launching deferred cleanup process..." "Yellow"
        Write-Host ""
        Write-Host "This window will close. Full removal will continue in new window." -ForegroundColor Cyan
        Write-Host ""

        Start-Sleep -Seconds 2

        # Launch batch cleanup script and exit current script
        Start-Process -FilePath $tempBatScript

        Start-Sleep -Seconds 1
        exit 0

    } catch {
        Write-Status "Error" "Could not create cleanup scripts: $($_.Exception.Message)" "Red"
        Write-Status "Manual Action Required" "Please manually delete: $removeDir" "Yellow"
        Write-Host ""
        pause
    }

}
catch {
    Write-Host ""
    Write-Status "FATAL ERROR" $_.Exception.Message "Red"
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    Write-Host ""
    pause
}
'@

    $removeBatPath = Join-Path $ptpath "Remove.bat"
    
    try {
        Set-Content -Path $removeBatPath -Value $removeBatContent -Force
        Write-Status "Remove.bat" "Created in $ptpath" "Green"
    } catch {
        Write-Status "Remove.bat" "Error creating: $($_.Exception.Message)" "Yellow"
    }
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
