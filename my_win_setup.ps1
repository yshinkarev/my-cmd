# Run this script in PowerShell after signing in to Windows.
# Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
# Completed steps are stored in <script-name>.state.json for this Windows installation and user.
# Use -RerunSteps system-restore,22 (step IDs or current numbers) to repeat selected steps.

param([switch]$ConfigureNetworks, [switch]$ConfigureSystemTemp, [switch]$ConfigureUploadFolder, [switch]$ConfigurePower, [switch]$ConfigurePersonalization, [switch]$ConfigureSystemRestore, [switch]$ConfigureCrashRecovery, [switch]$ConfigureGamesFolder, [switch]$ConfigureSearchPolicy, [switch]$ConfigureRemoteAssistance, [switch]$ConfigureVirtualMemory, [switch]$ConfigureWorkgroup, [ValidatePattern('^S-1-(\d+-)+\d+$')][string]$TargetUserSid, [string]$ErrorLog, [string[]]$RerunSteps = @(), [Alias('h')][switch]$Help)

$ErrorActionPreference = 'Stop'

function Write-Step {
    param([int]$Number, [string]$Description)

    if ($Number -gt 1) {
        Write-Host ''
    }
    Write-Host "Step ${Number}: $Description"
}

function Show-SetupHelp {
    param([array]$Steps)

    $scriptName = [IO.Path]::GetFileName($PSCommandPath)
    $stateName = [IO.Path]::GetFileNameWithoutExtension($PSCommandPath) + '.state.json'
    Write-Output @"
Windows setup script

Usage (from a regular, non-administrator PowerShell window):
  .\$scriptName
  .\$scriptName -Help
  .\$scriptName -h
  .\$scriptName -RerunSteps system-restore
  .\$scriptName -RerunSteps taskbar,power
  .\$scriptName -RerunSteps 22,24
  .\$scriptName -RerunSteps 22,steam,24

Options:
  -Help, -h       Show this help without changing settings or the state file.
  -RerunSteps     Repeat step IDs or numbers, even if already completed.
                 IDs and numbers can be mixed; numbers refer to the list below.
                 Other pending steps also run in their normal order.

State:
  $stateName is saved next to the script after each successful step.
  Completed steps are skipped without requesting administrator rights.
  Records apply to the current Windows installation and user.
  Delete the state file to clear all completion records.
  Manual changes to Windows settings are not detected for completed steps.
  The TEMP step still initializes environment variables for the current process.
  Existing Upload folders and lock-screen PNG files retain their own skip rules,
  including when -RerunSteps is used.

Steps (number, ID, description):
"@
    for ($index = 0; $index -lt $Steps.Count; $index++) {
        Write-Output ('  {0,2}. {1,-21} {2}' -f ($index + 1), $Steps[$index].Id, $Steps[$index].Description)
    }
    Write-Output ''
    Write-Output 'Configure* and ErrorLog parameters are internal helper options.'
}

function Resolve-RerunStepIds {
    param([array]$Steps, [string[]]$Selection = @())

    $resolved = @()
    foreach ($entry in $Selection) {
        # Also accept a quoted comma-separated list, including from powershell.exe -File.
        foreach ($part in ($entry -split ',')) {
            $value = $part.Trim()
            $number = 0
            if ($value -match '^[0-9]+$') {
                if (-not [int]::TryParse($value, [ref]$number) -or $number -lt 1 -or $number -gt $Steps.Count) {
                    throw "Invalid step number '$value'. Use a number from 1 to $($Steps.Count); see -Help."
                }
                $id = $Steps[$number - 1].Id
            }
            else {
                $match = $Steps | Where-Object { $_.Id -eq $value } | Select-Object -First 1
                if (-not $match) { throw "Unknown step '$value'. Use a step ID or number from 1 to $($Steps.Count); see -Help." }
                $id = $match.Id
            }
            if ($id -notin $resolved) { $resolved += $id }
        }
    }
    return $resolved
}

function Open-SetupLock {
    param([string]$StatePath)

    # Keep the file after closing: deleting a lock file can race with another opener.
    # The open handle, not the file's presence, owns the lock; crashes release it too.
    try {
        return [IO.File]::Open("$StatePath.lock", [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    }
    catch [IO.IOException] {
        throw "Could not acquire setup lock '$StatePath.lock'. Another setup instance may be running. Details: $($_.Exception.Message)"
    }
}

function Initialize-RegistryKey {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -ErrorAction Stop)) {
        New-Item -Path $Path -ErrorAction Stop | Out-Null
    }
}

function Get-SetupContext {
    $machineGuid = Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop
    $installDate = Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name InstallDate -ErrorAction Stop
    $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    return "$machineGuid/$installDate/$userSid"
}

function Read-SetupState {
    param([string]$Path, [string]$Context)

    $state = @{ SchemaVersion = 1; Context = $Context; Steps = @{} }
    if (-not (Test-Path -LiteralPath $Path)) { return $state }

    try {
        $saved = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($saved.SchemaVersion -ne 1 -or $saved.Steps -isnot [pscustomobject] -or
            [string]::IsNullOrWhiteSpace($saved.Context)) {
            throw 'Unsupported or invalid state format.'
        }
        if ($saved.Context -ne $Context) {
            Write-Host 'The state file belongs to another Windows installation or user. Starting with no completed steps.'
            return $state
        }
        foreach ($property in $saved.Steps.PSObject.Properties) {
            if ($property.Value.Status -ne 'Completed' -or $property.Value.Revision -isnot [ValueType] -or
                $property.Value.Revision -lt 1 -or [string]::IsNullOrWhiteSpace($property.Value.CompletedUtc)) {
                throw "Invalid completion record: $($property.Name)."
            }
            $state.Steps[$property.Name] = @{
                Status = 'Completed'
                Revision = $property.Value.Revision
                CompletedUtc = $property.Value.CompletedUtc
            }
        }
    }
    catch {
        # Do not silently repeat completed system changes when a state file is damaged.
        throw "Could not read setup state '$Path': $($_.Exception.Message). Rename or repair this file before retrying."
    }
    return $state
}

function Save-SetupState {
    param([string]$Path, [hashtable]$State)

    $temporaryPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $json = ConvertTo-Json -InputObject $State -Depth 8
        [IO.File]::WriteAllText($temporaryPath, $json, [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($Path)) {
            [IO.File]::Replace($temporaryPath, $Path, [System.Management.Automation.Language.NullString]::Value)
        }
        else {
            [IO.File]::Move($temporaryPath, $Path)
        }
    }
    finally {
        if ([IO.File]::Exists($temporaryPath)) { [IO.File]::Delete($temporaryPath) }
    }
}

function Test-SetupStepComplete {
    param([hashtable]$State, [string]$Id, [int]$Revision = 1)

    return $State.Steps.ContainsKey($Id) -and
        $State.Steps[$Id].Status -eq 'Completed' -and $State.Steps[$Id].Revision -eq $Revision
}

function Invoke-SetupStep {
    param(
        [int]$Number,
        [string]$Id,
        [string]$Description,
        [scriptblock]$Action,
        [hashtable]$State,
        [string]$StatePath,
        [int]$Revision = 1,
        [scriptblock]$OnSkip,
        [switch]$Rerun
    )

    $ErrorActionPreference = 'Stop'
    Write-Step -Number $Number -Description $Description
    if (-not $Rerun -and (Test-SetupStepComplete -State $State -Id $Id -Revision $Revision)) {
        Write-Host "Already completed ($Id). Skipping."
        if ($OnSkip) { & $OnSkip }
        return
    }

    # Invalidate an old completion before retrying, so a failed retry remains pending.
    if ($State.Steps.ContainsKey($Id)) {
        $State.Steps.Remove($Id)
        Save-SetupState -Path $StatePath -State $State
    }
    & $Action
    $State.Steps[$Id] = @{
        Status = 'Completed'
        Revision = $Revision
        CompletedUtc = [DateTime]::UtcNow.ToString('o')
    }
    try {
        Save-SetupState -Path $StatePath -State $State
    }
    catch {
        $State.Steps.Remove($Id)
        throw
    }
}

function Test-IsAdministrator {
    return ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Invoke-ElevatedStep {
    param(
        [string]$SwitchName,
        [string]$StepName,
        [ValidatePattern('^S-1-(\d+-)+\d+$')][string]$TargetUserSid
    )

    $errorLog = Join-Path $env:TEMP ("my_win_setup-$([guid]::NewGuid().ToString('N')).log")
    $powerShell = (Get-Process -Id $PID).Path

    try {
        $arguments = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
            "-$SwitchName", '-ErrorLog', "`"$errorLog`""
        )
        if ($TargetUserSid) { $arguments += @('-TargetUserSid', $TargetUserSid) }
        $process = Start-Process -FilePath $powerShell -Verb RunAs -Wait -PassThru -WindowStyle Hidden -ArgumentList $arguments
        if ($process.ExitCode -ne 0) {
            $details = if (Test-Path -LiteralPath $errorLog) {
                Get-Content -LiteralPath $errorLog -Raw
            }
            else {
                'The elevated process did not return an error message.'
            }
            throw "$StepName failed (exit code: $($process.ExitCode)).`n$details"
        }
    }
    finally {
        if (Test-Path -LiteralPath $errorLog) {
            Remove-Item -LiteralPath $errorLog -Force
        }
    }
}

function Test-ProgramInstalled {
    param([string]$DisplayNamePattern, [string]$ExcludeVersionPattern, [scriptblock]$AdditionalCheck)

    $uninstallKeys = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $installed = Get-ItemProperty -Path $uninstallKeys -ErrorAction SilentlyContinue |
        Where-Object {
            $_.DisplayName -match $DisplayNamePattern -and
            (-not $ExcludeVersionPattern -or "$($_.DisplayName) $($_.DisplayVersion)" -notmatch $ExcludeVersionPattern) -and
            (-not $AdditionalCheck -or (& $AdditionalCheck $_))
        } |
        Select-Object -First 1
    return [bool]$installed
}

function Set-SystemTemp {
    if (-not (Test-IsAdministrator)) {
        throw 'Configuring system temporary files requires administrator rights.'
    }

    $tempDirectory = 'C:\TEMP'
    New-Item -ItemType Directory -Path $tempDirectory -Force | Out-Null

    # The machine-wide temporary directory must be writable by regular users.
    & icacls.exe $tempDirectory /grant:r '*S-1-5-32-545:(OI)(CI)M' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not set permissions on $tempDirectory."
    }

    foreach ($name in @('TEMP', 'TMP', 'TMPDIR')) {
        [Environment]::SetEnvironmentVariable($name, $tempDirectory, 'Machine')
    }
    Write-Host "Configured system temporary variables to $tempDirectory."
}

function Set-ProcessTemporaryDirectory {
    foreach ($name in @('TEMP', 'TMP', 'TMPDIR')) {
        [Environment]::SetEnvironmentVariable($name, 'C:\TEMP', 'Process')
    }
}

function Set-TemporaryDirectory {
    $tempDirectory = 'C:\TEMP'
    $names = @('TEMP', 'TMP', 'TMPDIR')
    $needsSystemSetup = -not (Test-Path -LiteralPath $tempDirectory -PathType Container)
    $needsUserSetup = $false
    $needsProcessSetup = $false

    foreach ($name in $names) {
        if ([Environment]::GetEnvironmentVariable($name, 'Machine') -ne $tempDirectory) {
            $needsSystemSetup = $true
        }
        if ([Environment]::GetEnvironmentVariable($name, 'User') -ne $tempDirectory) {
            $needsUserSetup = $true
        }
        if ([Environment]::GetEnvironmentVariable($name, 'Process') -ne $tempDirectory) {
            $needsProcessSetup = $true
        }
    }

    if (-not ($needsSystemSetup -or $needsUserSetup -or $needsProcessSetup)) {
        Write-Host 'C:\TEMP is already configured for system, user and current session. Skipping.'
        return
    }

    if ($needsSystemSetup) {
        Write-Host 'Requesting administrator rights to configure C:\TEMP...'
        Invoke-ElevatedStep -SwitchName 'ConfigureSystemTemp' -StepName 'Temporary directory configuration'
    }

    foreach ($name in $names) {
        [Environment]::SetEnvironmentVariable($name, $tempDirectory, 'User')
        [Environment]::SetEnvironmentVariable($name, $tempDirectory, 'Process')
    }
    Write-Host "Using $tempDirectory for temporary files."
}

function Set-DefaultEnglishInputMethod {
    $languageList = Get-WinUserLanguageList
    $inputMethods = @( $languageList | ForEach-Object { $_.InputMethodTips } |
        Where-Object { $_ } | Select-Object -Unique )

    if ($inputMethods.Count -lt 2) {
        Write-Host 'Only one keyboard layout is configured. Skipping.'
        return
    }

    $englishInputTip = $inputMethods | Where-Object {
        $_ -match '^[0-9A-F]{4}:(?:00000409|00000809)$'
    } | Select-Object -First 1

    if (-not $englishInputTip) {
        $englishInputTip = $languageList | Where-Object { $_.LanguageTag -match '^en(-|$)' } |
            ForEach-Object { $_.InputMethodTips } | Select-Object -First 1
    }

    if (-not $englishInputTip) {
        Write-Host 'No English keyboard layout is configured. Skipping.'
        return
    }

    $current = Get-WinDefaultInputMethodOverride
    if ($current -and $current.InputMethodTip -eq $englishInputTip) {
        Write-Host 'English is already the default keyboard layout.'
        return
    }

    Set-WinDefaultInputMethodOverride -InputTip $englishInputTip
    Write-Host "Set English keyboard layout ($englishInputTip) as default."
}

function Set-TaskbarPreferences {
    $advancedPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $current = Get-ItemProperty -Path $advancedPath
    if ($current.TaskbarLocation -eq 0 -and $current.TaskbarAl -eq 0 -and $current.TaskbarGlomLevel -eq 2) {
        Write-Host 'Taskbar preferences are already configured.'
        return
    }

    # Native taskbar positioning requires a Windows build that exposes this option.
    # Location 0 = left edge; alignment 0 = top for a vertical taskbar.
    New-ItemProperty -Path $advancedPath -Name TaskbarLocation -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -Path $advancedPath -Name TaskbarAl -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -Path $advancedPath -Name TaskbarGlomLevel -PropertyType DWord -Value 2 -Force | Out-Null

    # Restart the shell so the new preferences take effect immediately.
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Process explorer.exe
    Write-Host 'Configured the taskbar on the left with top-aligned icons and disabled window grouping.'
}

function Initialize-ApplicationWindowNative {
    if ('WinSetup.ApplicationWindowNative' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace WinSetup {
    public static class ApplicationWindowNative {
        private delegate bool EnumWindowProc(IntPtr window, IntPtr data);
        [DllImport("user32.dll")]
        private static extern bool EnumWindows(EnumWindowProc callback, IntPtr data);
        [DllImport("user32.dll")]
        private static extern bool EnumChildWindows(IntPtr parent, EnumWindowProc callback, IntPtr data);
        [DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
        public static bool HasWindow(int[] processIds) {
            var ids = new HashSet<int>(processIds);
            bool found = false;
            EnumWindowProc matches = delegate(IntPtr window, IntPtr data) {
                uint id;
                GetWindowThreadProcessId(window, out id);
                if (ids.Contains((int)id)) found = true;
                return !found;
            };
            EnumWindows(delegate(IntPtr window, IntPtr data) {
                if (!IsWindowVisible(window)) return true;
                matches(window, data);
                // Older packaged apps can be hosted inside ApplicationFrameHost windows.
                if (!found) EnumChildWindows(window, matches, IntPtr.Zero);
                return !found;
            }, IntPtr.Zero);
            return found;
        }
    }
}
'@
}

function Test-ApplicationWindowOpen {
    param([string]$ProcessName)

    Initialize-ApplicationWindowNative
    $processIds = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
        Where-Object SessionId -eq (Get-Process -Id $PID).SessionId |
        Select-Object -ExpandProperty Id)
    if ($processIds.Count -eq 0) { return $false }
    return [WinSetup.ApplicationWindowNative]::HasWindow([int[]]$processIds)
}

function Wait-ApplicationWindowClosed {
    param([string]$ProcessName)

    # Wait for the window, not process exit: Store can keep running in the background.
    # A minimized window still counts as open. Allow brief window recreation.
    $closedSamples = 0
    while ($closedSamples -lt 3) {
        if (Test-ApplicationWindowOpen -ProcessName $ProcessName) { $closedSamples = 0 }
        else { $closedSamples++ }
        Start-Sleep -Seconds 1
    }
}

function Update-MicrosoftStoreApplications {
    Initialize-ApplicationWindowNative
    Write-Host 'Opening Microsoft Store updates. Keep its window open until updates finish.'
    # https://learn.microsoft.com/en-us/windows/apps/develop/launch/launch-store-app
    Start-Process 'ms-windows-store://downloadsandupdates' -ErrorAction Stop
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    while (-not (Test-ApplicationWindowOpen -ProcessName 'WinStore.App')) {
        if ([DateTime]::UtcNow -ge $deadline) {
            throw 'Microsoft Store window was not detected within 60 seconds. The step remains pending; retry with the Store window open.'
        }
        Start-Sleep -Milliseconds 500
    }

    $storeCommand = Get-Command store.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $updated = $false
    if ($storeCommand) {
        try {
            Write-Host 'Running Store updates. Respond to any prompts in this console.'
            & $storeCommand.Source updates --apply
            if ($LASTEXITCODE -ne 0) { throw "Store CLI exited with code $LASTEXITCODE." }
            $updated = $true
        }
        catch {
            Write-Warning "Automatic Store update did not finish successfully: $($_.Exception.Message)"
        }
    }
    if (-not $updated) {
        Write-Host 'Update apps manually in Microsoft Store: check for updates, then choose Update all.'
        # Reopen if the CLI or a Store self-update closed the original window.
        Start-Process 'ms-windows-store://downloadsandupdates' -ErrorAction Stop
        $deadline = [DateTime]::UtcNow.AddSeconds(60)
        while (-not (Test-ApplicationWindowOpen -ProcessName 'WinStore.App')) {
            if ([DateTime]::UtcNow -ge $deadline) { throw 'Microsoft Store window could not be reopened.' }
            Start-Sleep -Milliseconds 500
        }
    }
    Write-Host 'Wait for all updates to finish, then close Microsoft Store to continue setup.'
    Write-Host 'Closing the window completes this step; manual update results are not verified.'
    Wait-ApplicationWindowClosed -ProcessName 'WinStore.App'
    Write-Host 'Microsoft Store window closed.'
}

function Configure-HomeWorkgroup {
    $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    if ($computer.PartOfDomain) { throw 'This computer belongs to a domain. Changing domain membership is not supported by this workgroup step.' }
    if ($computer.Workgroup -eq 'HOME') {
        Write-Host 'Workgroup is already HOME. Skipping.'
        return
    }
    Invoke-ElevatedStep -SwitchName 'ConfigureWorkgroup' -StepName 'HOME workgroup configuration'
    Write-Host 'Workgroup set to HOME. Restart Windows yourself after setup to apply the change.'
}

function Set-HomeWorkgroup {
    $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    if ($computer.PartOfDomain) { throw 'This computer belongs to a domain. Changing domain membership is not supported by this workgroup step.' }
    if ($computer.Workgroup -eq 'HOME') { return }
    if (-not (Test-IsAdministrator)) { throw 'Changing the workgroup requires administrator rights.' }
    # FJoinOptions = 0 joins a workgroup. A successful return can precede reboot.
    $result = Invoke-CimMethod -InputObject $computer -MethodName JoinDomainOrWorkgroup -Arguments @{ Name = 'HOME'; FJoinOptions = [uint32]0 } -ErrorAction Stop
    if ($null -eq $result.ReturnValue -or $result.ReturnValue -ne 0) {
        throw "Could not set workgroup HOME (Windows error: $($result.ReturnValue))."
    }
}

function Set-RecycleBinSize {
    param([ValidateRange(1, 2147483647)][int]$SizeMB = 1024)

    # Explorer stores capacity in MB separately for each volume and current user.
    $basePath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\BitBucket\Volume'
    $volumes = @(Get-CimInstance -ClassName Win32_Volume -Filter 'DriveType = 3' -ErrorAction Stop |
        Where-Object { $_.DriveLetter -match '^[A-Za-z]:$' })
    if ($volumes.Count -eq 0) { throw 'No local volumes with drive letters were found for Recycle Bin configuration.' }

    foreach ($volume in $volumes) {
        $volumeId = [regex]::Match($volume.DeviceID, '\{[0-9a-fA-F-]{36}\}')
        if (-not $volumeId.Success) { throw "Cannot identify the volume for $($volume.DriveLetter)." }
        $path = Join-Path $basePath $volumeId.Value
        if (-not (Test-Path -LiteralPath $path -ErrorAction Stop)) {
            New-Item -Path $path -Force -ErrorAction Stop | Out-Null
        }
        $current = Get-ItemProperty -LiteralPath $path -ErrorAction Stop
        $desired = @{ MaxCapacity = $SizeMB; NukeOnDelete = 0 }
        $changed = $false
        foreach ($name in $desired.Keys) {
            if ($null -ne $current.$name -and $current.$name -eq $desired[$name]) { continue }
            New-ItemProperty -LiteralPath $path -Name $name -PropertyType DWord -Value $desired[$name] -Force -ErrorAction Stop | Out-Null
            $changed = $true
        }
        $saved = Get-ItemProperty -LiteralPath $path -ErrorAction Stop
        if ($saved.MaxCapacity -ne $SizeMB -or $null -eq $saved.NukeOnDelete -or $saved.NukeOnDelete -ne 0) {
            throw "Could not verify Recycle Bin settings for $($volume.DriveLetter)."
        }
        if ($changed) { Write-Host "Recycle Bin on $($volume.DriveLetter): maximum size set to $SizeMB MB." }
        else { Write-Host "Recycle Bin on $($volume.DriveLetter) is already configured for $SizeMB MB. Skipping." }
    }
    Write-Host 'Recycle Bin settings saved for the current user. Restart Windows yourself after setup to refresh Explorer.'
}

function Get-VirtualMemoryState {
    $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $pageFiles = @(Get-CimInstance -ClassName Win32_PageFileSetting -ErrorAction Stop)
    $pagePath = "$env:SystemDrive\pagefile.sys"
    $pageFileMatches = $computer.AutomaticManagedPagefile -eq $false -and
        $pageFiles.Count -eq 1 -and $pageFiles[0].Name -eq $pagePath -and
        $pageFiles[0].InitialSize -eq 6144 -and $pageFiles[0].MaximumSize -eq 6144
    $power = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -ErrorAction Stop
    return @{
        Computer = $computer
        PageFiles = $pageFiles
        PagePath = $pagePath
        PageFileMatches = $pageFileMatches
        HibernationDisabled = ($null -ne $power.HibernateEnabled -and $power.HibernateEnabled -eq 0)
    }
}

function Configure-VirtualMemory {
    $state = Get-VirtualMemoryState
    if ($state.PageFileMatches -and $state.HibernationDisabled) {
        Write-Host 'A fixed 6144 MB page file and disabled hibernation are already configured. Skipping.'
        return
    }
    Invoke-ElevatedStep -SwitchName 'ConfigureVirtualMemory' -StepName 'Page file and hibernation configuration'
    Write-Host 'Configured a single 6144 MB page file on the system drive and disabled hibernation.'
    Write-Host 'Restart Windows yourself after setup to apply the page file size.'
    Write-Host 'Fast Startup and hybrid sleep are also unavailable when hibernation is disabled.'
}

function Set-VirtualMemory {
    if (-not (Test-IsAdministrator)) {
        throw 'Administrator rights are required to configure the page file and hibernation.'
    }
    $state = Get-VirtualMemoryState
    if (-not $state.HibernationDisabled) {
        & powercfg.exe /hibernate off
        if ($LASTEXITCODE -ne 0) { throw "Disabling hibernation failed (exit code: $LASTEXITCODE)." }
    }
    if (-not $state.PageFileMatches) {
        # Win32_PageFileSetting describes the next boot, unlike Win32_PageFileUsage.
        # https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-pagefilesetting
        if ($state.Computer.AutomaticManagedPagefile) {
            Set-CimInstance -InputObject $state.Computer -Property @{ AutomaticManagedPagefile = $false } -ErrorAction Stop | Out-Null
        }
        # Re-read because disabling automatic management can change the stored settings.
        $pageFiles = @(Get-CimInstance -ClassName Win32_PageFileSetting -ErrorAction Stop)
        $target = $pageFiles | Where-Object Name -eq $state.PagePath | Select-Object -First 1
        $sizes = @{ InitialSize = [uint32]6144; MaximumSize = [uint32]6144 }
        if ($target) {
            if ($target.InitialSize -ne 6144 -or $target.MaximumSize -ne 6144) {
                Set-CimInstance -InputObject $target -Property $sizes -ErrorAction Stop | Out-Null
            }
        }
        else {
            New-CimInstance -ClassName Win32_PageFileSetting -Property @{
                Name = $state.PagePath; InitialSize = [uint32]6144; MaximumSize = [uint32]6144
            } -ErrorAction Stop | Out-Null
        }
        # Keep the total configured page file size at 6 GB; never delete pagefile.sys directly.
        foreach ($pageFile in $pageFiles) {
            if ($pageFile.Name -ne $state.PagePath) {
                Remove-CimInstance -InputObject $pageFile -ErrorAction Stop
            }
        }
    }
    $actual = Get-VirtualMemoryState
    if (-not ($actual.PageFileMatches -and $actual.HibernationDisabled)) {
        throw 'Page file or hibernation settings did not pass verification.'
    }
}

function Get-RemoteAssistanceSettings {
    # Local System Properties switch plus policies for both invitation and offered assistance.
    # https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-remoteassistance
    @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance'; Name = 'fAllowToGetHelp' }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'; Name = 'fAllowToGetHelp' }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'; Name = 'fAllowUnsolicited' }
}

function Test-RemoteAssistanceDisabled {
    foreach ($setting in (Get-RemoteAssistanceSettings)) {
        if (-not (Test-Path -LiteralPath $setting.Path -ErrorAction Stop)) { return $false }
        $current = Get-ItemProperty -LiteralPath $setting.Path -ErrorAction Stop
        if ($null -eq $current.($setting.Name) -or $current.($setting.Name) -ne 0) { return $false }
    }
    return $true
}

function Configure-RemoteAssistance {
    if (Test-RemoteAssistanceDisabled) {
        Write-Host 'Windows Remote Assistance is already disabled. Skipping.'
        return
    }
    Invoke-ElevatedStep -SwitchName 'ConfigureRemoteAssistance' -StepName 'Remote Assistance configuration'
}

function Set-RemoteAssistanceDisabled {
    if (Test-RemoteAssistanceDisabled) { return }
    if (-not (Test-IsAdministrator)) {
        throw 'Administrator rights are required to disable Windows Remote Assistance.'
    }
    foreach ($setting in (Get-RemoteAssistanceSettings)) {
        if (-not (Test-Path -LiteralPath $setting.Path -ErrorAction Stop)) {
            New-Item -Path $setting.Path -Force -ErrorAction Stop | Out-Null
        }
        $current = Get-ItemProperty -LiteralPath $setting.Path -ErrorAction Stop
        if ($null -ne $current.($setting.Name) -and $current.($setting.Name) -eq 0) { continue }
        New-ItemProperty -LiteralPath $setting.Path -Name $setting.Name -PropertyType DWord -Value 0 -Force -ErrorAction Stop | Out-Null
    }
    if (-not (Test-RemoteAssistanceDisabled)) {
        throw 'Remote Assistance settings did not pass verification.'
    }
    Write-Host 'Windows Remote Assistance is disabled for invitations and offered assistance.'
}

function Set-SearchPolicy {
    param([Parameter(Mandatory)][ValidatePattern('^S-1-(\d+-)+\d+$')][string]$UserSid)

    # Explicit SID preserves the original user even when UAC uses another admin account.
    $userRoot = "Registry::HKEY_USERS\$UserSid"
    if (-not (Test-Path -LiteralPath $userRoot -ErrorAction Stop)) {
        throw "The original user's registry hive is not loaded: $UserSid."
    }
    $path = "$userRoot\Software\Policies\Microsoft\Windows\Explorer"
    if (-not (Test-Path -LiteralPath $path -ErrorAction Stop)) {
        New-Item -Path $path -Force -ErrorAction Stop | Out-Null
    }
    $current = Get-ItemProperty -LiteralPath $path -ErrorAction Stop
    if ($current.DisableSearchBoxSuggestions -eq 1) { return }
    # Also disables recent-query suggestions in File Explorer; indexing is unaffected.
    New-ItemProperty -LiteralPath $path -Name DisableSearchBoxSuggestions -PropertyType DWord -Value 1 -Force -ErrorAction Stop | Out-Null
    if ((Get-ItemPropertyValue -LiteralPath $path -Name DisableSearchBoxSuggestions -ErrorAction Stop) -ne 1) {
        throw 'The web search policy could not be saved.'
    }
}

function Configure-SearchPolicy {
    $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    try {
        Set-SearchPolicy -UserSid $userSid
    }
    catch [System.UnauthorizedAccessException] {
        Invoke-ElevatedStep -SwitchName 'ConfigureSearchPolicy' -StepName 'Search policy configuration' -TargetUserSid $userSid
    }
    catch [System.Security.SecurityException] {
        Invoke-ElevatedStep -SwitchName 'ConfigureSearchPolicy' -StepName 'Search policy configuration' -TargetUserSid $userSid
    }
}

function Set-SearchPreferences {
    Configure-SearchPolicy
    $searchPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings'
    $settings = @(
        @{ Path = $searchPath; Name = 'IsMSACloudSearchEnabled'; Value = 0 }
        @{ Path = $searchPath; Name = 'IsAADCloudSearchEnabled'; Value = 0 }
        @{ Path = $searchPath; Name = 'IsDynamicSearchBoxEnabled'; Value = 0 }
    )
    $changed = $false
    foreach ($setting in $settings) {
        if (-not (Test-Path -LiteralPath $setting.Path)) {
            New-Item -Path $setting.Path -Force -ErrorAction Stop | Out-Null
        }
        $current = Get-ItemProperty -LiteralPath $setting.Path -ErrorAction Stop
        if ($null -ne $current.($setting.Name) -and $current.($setting.Name) -eq $setting.Value) {
            continue
        }
        New-ItemProperty -LiteralPath $setting.Path -Name $setting.Name -PropertyType DWord -Value $setting.Value -Force -ErrorAction Stop | Out-Null
        $actual = Get-ItemPropertyValue -LiteralPath $setting.Path -Name $setting.Name -ErrorAction Stop
        if ($actual -ne $setting.Value) {
            throw "Search setting could not be saved: $($setting.Name)."
        }
        $changed = $true
    }
    if ($changed) {
        Write-Host 'Saved preferences to disable web suggestions, personal/work cloud results and search highlights.'
    }
    else {
        Write-Host 'Search preferences are already configured.'
    }
    # Registry read-back verifies persistence, not the behavior of a running Search UI.
    Write-Host 'Restart Windows yourself after setup to apply search preferences. Web suppression can depend on the Windows build.'
    Write-Host 'Local apps, settings and files remain searchable. File indexing is unchanged.'
}

function Set-ExplorerPreferences {
    $explorerPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'
    # https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-gppref/3c837e92-016e-4148-86e5-b4f0381a757f
    $settings = @(
        @{ Path = "$explorerPath\Advanced"; Name = 'HideFileExt'; Value = 0 }
        @{ Path = "$explorerPath\Advanced"; Name = 'Hidden'; Value = 1 }
        @{ Path = "$explorerPath\CabinetState"; Name = 'FullPath'; Value = 1 }
    )
    $changed = $false
    foreach ($setting in $settings) {
        if (-not (Test-Path -LiteralPath $setting.Path)) {
            New-Item -Path $setting.Path -Force -ErrorAction Stop | Out-Null
        }
        $current = Get-ItemProperty -LiteralPath $setting.Path -ErrorAction Stop
        if ($null -ne $current.($setting.Name) -and $current.($setting.Name) -eq $setting.Value) {
            continue
        }
        New-ItemProperty -LiteralPath $setting.Path -Name $setting.Name -PropertyType DWord -Value $setting.Value -Force -ErrorAction Stop | Out-Null
        $actual = Get-ItemPropertyValue -LiteralPath $setting.Path -Name $setting.Name -ErrorAction Stop
        if ($actual -ne $setting.Value) {
            throw "Could not configure Explorer setting '$($setting.Name)'."
        }
        $changed = $true
    }
    if (-not $changed) {
        Write-Host 'Explorer preferences are already configured. Skipping.'
        return
    }
    Write-Host 'Configured Explorer to show file extensions, hidden files and folders, and the full path in the title bar.'
    Write-Host 'Restarting Explorer to apply preferences. Open Explorer windows may close.'
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Process explorer.exe
}

function New-UploadFolder {
    $uploadPath = 'C:\Upload'
    if (Test-Path -LiteralPath $uploadPath -PathType Container) {
        Write-Host 'C:\Upload already exists.'
        return
    }

    New-Item -ItemType Directory -Path $uploadPath -ErrorAction Stop | Out-Null
    Write-Host 'Created C:\Upload.'
}

function Configure-UploadFolder {
    $uploadPath = 'C:\Upload'
    if (Test-Path -LiteralPath $uploadPath -PathType Container) {
        Write-Host 'C:\Upload already exists. Skipping folder creation and properties.'
        return
    }

    try {
        New-UploadFolder
    }
    catch [System.UnauthorizedAccessException] {
        Write-Host 'Requesting administrator rights to create C:\Upload...'
        Invoke-ElevatedStep -SwitchName 'ConfigureUploadFolder' -StepName 'Upload folder creation'
    }

    # Open properties in the signed-in user's shell, outside the elevated process.
    try {
        $shell = New-Object -ComObject Shell.Application
        $parent = $shell.Namespace('C:\')
        $folder = $parent.ParseName('Upload')
        if ($null -eq $folder) {
            throw 'C:\Upload could not be found in Windows Explorer.'
        }
        $folder.InvokeVerb('properties')
        Write-Host 'Requested properties for C:\Upload. Configure sharing there if needed.'
    }
    catch {
        Write-Warning "Could not open folder properties: $($_.Exception.Message). Open C:\Upload in Explorer and press Alt+Enter."
    }
}

function Get-PowerSettingValues {
    param([string]$Subgroup, [string]$Setting)

    $output = & powercfg.exe /qh SCHEME_CURRENT $Subgroup $Setting 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Could not read power setting $Setting (exit code: $LASTEXITCODE)."
    }

    # The last two hexadecimal indices in the query are the AC and DC values.
    $indices = @([regex]::Matches(($output -join "`n"), '0x[0-9A-Fa-f]{8}') |
        ForEach-Object { $_.Value })
    if ($indices.Count -lt 2) {
        throw "Could not parse power setting $Setting."
    }
    return @([Convert]::ToInt32($indices[-2], 16), [Convert]::ToInt32($indices[-1], 16))
}

function Set-PowerPreferences {
    if (-not (Test-IsAdministrator)) {
        throw 'Changing power settings requires administrator rights.'
    }

    # Powercfg timeout values are in seconds; lid action 0 means Do nothing.
    $settings = @(
        @{ Subgroup = 'SUB_BUTTONS'; Name = 'LIDACTION'; AcValue = 0; DcValue = 0 }
        @{ Subgroup = 'SUB_VIDEO'; Name = 'VIDEOIDLE'; AcValue = 1800; DcValue = 900 }
        @{ Subgroup = 'SUB_SLEEP'; Name = 'STANDBYIDLE'; AcValue = 7200; DcValue = 1800 }
        @{ Subgroup = 'SUB_SLEEP'; Name = 'HIBERNATEIDLE'; AcValue = 0; DcValue = 0 }
    )
    foreach ($setting in $settings) {
        & powercfg.exe /setacvalueindex SCHEME_CURRENT $setting.Subgroup $setting.Name $setting.AcValue
        if ($LASTEXITCODE -ne 0) {
            throw "Could not set AC power setting $($setting.Name) (exit code: $LASTEXITCODE)."
        }
        & powercfg.exe /setdcvalueindex SCHEME_CURRENT $setting.Subgroup $setting.Name $setting.DcValue
        if ($LASTEXITCODE -ne 0) {
            throw "Could not set battery power setting $($setting.Name) (exit code: $LASTEXITCODE)."
        }
    }
    & powercfg.exe /setactive SCHEME_CURRENT
    if ($LASTEXITCODE -ne 0) {
        throw "Could not activate the updated power plan (exit code: $LASTEXITCODE)."
    }
    Write-Host 'Configured lid action, display, sleep and hibernate timeouts for AC and battery.'
}

function Configure-PowerPreferences {
    try {
        $lid = Get-PowerSettingValues -Subgroup 'SUB_BUTTONS' -Setting 'LIDACTION'
        $display = Get-PowerSettingValues -Subgroup 'SUB_VIDEO' -Setting 'VIDEOIDLE'
        $sleep = Get-PowerSettingValues -Subgroup 'SUB_SLEEP' -Setting 'STANDBYIDLE'
        $hibernate = Get-PowerSettingValues -Subgroup 'SUB_SLEEP' -Setting 'HIBERNATEIDLE'
        if ($lid[0] -eq 0 -and $lid[1] -eq 0 -and
            $display[0] -eq 1800 -and $display[1] -eq 900 -and
            $sleep[0] -eq 7200 -and $sleep[1] -eq 1800 -and
            $hibernate[0] -eq 0 -and $hibernate[1] -eq 0) {
            Write-Host 'Power preferences are already configured. Skipping.'
            return
        }
        Write-Host "Current power settings (AC/battery): lid $($lid -join '/'), display $($display -join '/'), sleep $($sleep -join '/'), hibernate $($hibernate -join '/')."
    }
    catch {
        Write-Host "Could not verify existing power preferences: $($_.Exception.Message)"
    }

    Write-Host 'Requesting administrator rights to configure power preferences...'
    Invoke-ElevatedStep -SwitchName 'ConfigurePower' -StepName 'Power configuration'
}

function New-BlackBackground {
    param([string]$Path)

    Add-Type -AssemblyName System.Drawing
    $bitmap = New-Object System.Drawing.Bitmap(1920, 1080)
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.Clear([System.Drawing.Color]::Black)
        }
        finally {
            $graphics.Dispose()
        }
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $bitmap.Dispose()
    }
}

function Wait-WinRTResult {
    param($Operation, [type]$ResultType)

    $asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.IsGenericMethodDefinition -and
        $_.GetGenericArguments().Count -eq 1 -and $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    } | Select-Object -First 1
    $task = $asTask.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    return $task.GetAwaiter().GetResult()
}

function Wait-WinRTAction {
    param($Operation)

    $asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and -not $_.IsGenericMethod -and
        $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.FullName -eq 'Windows.Foundation.IAsyncAction'
    } | Select-Object -First 1
    $task = $asTask.Invoke($null, @($Operation))
    [void]$task.GetAwaiter().GetResult()
}

function Initialize-PersonalizationNative {
    if ('WinSetup.PersonalizationNative' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace WinSetup {
    public static class PersonalizationNative {
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SystemParametersInfo(uint action, uint param, string value, uint flags);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetSysColors(int count, int[] elements, uint[] colors);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr SendMessageTimeout(IntPtr window, uint message, UIntPtr wParam,
            string lParam, uint flags, uint timeout, out UIntPtr result);
    }
}
'@
}

function Set-PersonalizationPreferences {
    # Windows PowerShell provides the .NET Framework WinRT bridge used below.
    # Keep this process under the current user, without elevation.
    $needsNativeBitness = [Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess
    if ($PSVersionTable.PSEdition -eq 'Core' -or $needsNativeBitness) {
        $systemDirectory = if ($needsNativeBitness) { 'Sysnative' } else { 'System32' }
        $windowsPowerShell = Join-Path $env:WINDIR "$systemDirectory\WindowsPowerShell\v1.0\powershell.exe"
        & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -ConfigurePersonalization
        if ($LASTEXITCODE -ne 0) {
            throw "Personalization failed (exit code: $LASTEXITCODE)."
        }
        return
    }

    $imagePath = Join-Path $PSScriptRoot ([IO.Path]::GetFileNameWithoutExtension($PSCommandPath) + '_bkgd.png')
    Initialize-PersonalizationNative

    $personalizePath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    Initialize-RegistryKey -Path $personalizePath
    foreach ($name in @('AppsUseLightTheme', 'SystemUsesLightTheme', 'EnableTransparency')) {
        New-ItemProperty -Path $personalizePath -Name $name -PropertyType DWord -Value 0 -Force | Out-Null
    }

    # Solid color mode, with no desktop wallpaper or pattern.
    $wallpapersPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers'
    Initialize-RegistryKey -Path $wallpapersPath
    New-ItemProperty -Path $wallpapersPath -Name BackgroundType -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -Path 'HKCU:\Control Panel\Colors' -Name Background -PropertyType String -Value '0 0 0' -Force | Out-Null
    New-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name Pattern -PropertyType String -Value '' -Force | Out-Null
    if (-not [WinSetup.PersonalizationNative]::SetSysColors(1, [int[]]@(1), [uint32[]]@(0))) {
        throw 'Could not apply the black desktop color.'
    }
    # SPI_SETDESKWALLPAPER, SPIF_UPDATEINIFILE | SPIF_SENDCHANGE.
    if (-not [WinSetup.PersonalizationNative]::SystemParametersInfo(20, 0, '', 3)) {
        throw 'Could not clear the desktop wallpaper.'
    }
    $messageResult = [UIntPtr]::Zero
    [void][WinSetup.PersonalizationNative]::SendMessageTimeout(
        [IntPtr]0xffff, 0x001A, [UIntPtr]::Zero, 'ImmersiveColorSet', 2, 1000, [ref]$messageResult)
    Write-Host 'Applied black desktop background, dark mode and disabled transparency.'
    Write-Host 'Some open applications may need to be restarted to display the new theme.'

    # The image file marks a previous creation; leave the lock screen unchanged if it exists.
    if (Test-Path -LiteralPath $imagePath) {
        Write-Host "Background image already exists. Skipping image creation and lock screen configuration: $imagePath"
        return
    }
    New-BlackBackground -Path $imagePath

    # Disable rotating Spotlight/slideshow images before setting the static image.
    $contentPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    Initialize-RegistryKey -Path $contentPath
    foreach ($name in @('RotatingLockScreenEnabled', 'RotatingLockScreenOverlayEnabled')) {
        New-ItemProperty -Path $contentPath -Name $name -PropertyType DWord -Value 0 -Force | Out-Null
    }
    $lockScreenPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lock Screen'
    Initialize-RegistryKey -Path $lockScreenPath
    New-ItemProperty -Path $lockScreenPath -Name SlideshowEnabled -PropertyType DWord -Value 0 -Force | Out-Null

    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $storageFileType = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
    $lockScreenType = [Windows.System.UserProfile.LockScreen, Windows.System.UserProfile, ContentType = WindowsRuntime]
    $imageFile = Wait-WinRTResult -Operation ($storageFileType::GetFileFromPathAsync($imagePath)) -ResultType $storageFileType
    try {
        Wait-WinRTAction -Operation ($lockScreenType::SetImageFileAsync($imageFile))
    }
    catch {
        $cause = $_.Exception.GetBaseException()
        throw "Could not set lock screen image '$imagePath': $($cause.Message) (HRESULT: $('0x{0:X8}' -f $cause.HResult)). The PNG file has been kept."
    }
    Write-Host "Applied black lock screen image: $imagePath. Clock and other lock screen UI remain visible."
}

function Get-SystemRestoreStorageState {
    $volume = Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter='$env:SystemDrive'" -ErrorAction Stop
    if (-not $volume -or $volume.Capacity -le 0) {
        throw 'Could not determine the system volume and its capacity.'
    }

    # SPP records the volumes monitored by the System Restore client.
    $clientKey = $null
    try {
        $clientKey = Get-Item -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SPP\Clients' -ErrorAction Stop
    }
    catch [System.Management.Automation.ItemNotFoundException] {
        # No registered clients means that protection has not been enabled yet.
    }
    $enabled = $false
    if ($null -ne $clientKey) {
        try {
            $protectedVolumes = @($clientKey.GetValue('{09F7EDC5-294E-4180-AF6A-FB0E6A0E9513}', $null))
            $enabled = @($protectedVolumes | Where-Object {
                $_ -match [regex]::Escape($volume.DeviceID)
            }).Count -gt 0
        }
        finally {
            $clientKey.Dispose()
        }
    }

    $storage = @(Get-CimInstance -ClassName Win32_ShadowStorage -ErrorAction Stop |
        Where-Object {
            $_.Volume.DeviceID -eq $volume.DeviceID -and $_.DiffVolume.DeviceID -eq $volume.DeviceID
        })
    # Allow only byte/MB rounding, not rounding a different percentage to 1%.
    $targetBytes = [math]::Floor([decimal]$volume.Capacity / 100)
    $quotaMatches = $storage.Count -eq 1 -and
        [math]::Abs([decimal]$storage[0].MaxSpace - $targetBytes) -le 1MB
    return [pscustomobject]@{ Enabled = $enabled; QuotaMatches = $quotaMatches }
}

function Test-CrashAutoRestartDisabled {
    $settings = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -ErrorAction Stop
    return ($null -ne $settings.AutoReboot -and $settings.AutoReboot -eq 0)
}

function New-GamesFolder {
    if (-not (Test-Path -LiteralPath 'C:\Games' -PathType Container)) {
        New-Item -ItemType Directory -Path 'C:\Games' -ErrorAction Stop | Out-Null
        Write-Host 'Created C:\Games.'
    }
}

function Open-ApplicationAndWait {
    param([string]$Uri, [string]$ProcessName, [string]$DisplayName)

    Initialize-ApplicationWindowNative
    Start-Process -FilePath $Uri -ErrorAction Stop
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    while (-not (Test-ApplicationWindowOpen -ProcessName $ProcessName)) {
        if ([DateTime]::UtcNow -ge $deadline) {
            throw "$DisplayName window was not detected within 60 seconds. The step remains pending."
        }
        Start-Sleep -Milliseconds 500
    }
    Write-Host "Close $DisplayName when finished to continue setup."
    Wait-ApplicationWindowClosed -ProcessName $ProcessName
    Write-Host "$DisplayName window closed."
}

function Configure-DefenderFolders {
    try {
        New-GamesFolder
    }
    catch [System.UnauthorizedAccessException] {
        Invoke-ElevatedStep -SwitchName 'ConfigureGamesFolder' -StepName 'Games folder creation'
    }
    Write-Host 'In Windows Security, open: Virus & threat protection > Manage settings > Exclusions > Add or remove exclusions.'
    Write-Host 'Choose Add an exclusion > Folder, then add C:\Games manually if it is not already listed.'
    if (Test-Path -LiteralPath 'C:\Soft' -PathType Container) {
        Write-Host 'Also add C:\Soft as a folder exclusion if it is not already listed.'
    }
    Write-Host 'Closing Windows Security completes this manual step. Exclusions are not changed or verified by this script.'
    Open-ApplicationAndWait -Uri 'windowsdefender://threat' -ProcessName 'SecHealthUI' -DisplayName 'Windows Security'
}

function Configure-CrashRecovery {
    if (Test-CrashAutoRestartDisabled) {
        Write-Host 'Automatic restart on system failure is already disabled. Skipping.'
        return
    }
    Invoke-ElevatedStep -SwitchName 'ConfigureCrashRecovery' -StepName 'System failure recovery configuration'
}

function Set-CrashRecovery {
    if (Test-CrashAutoRestartDisabled) { return }
    if (-not (Test-IsAdministrator)) {
        throw 'Administrator rights are required to configure system failure recovery.'
    }
    # https://learn.microsoft.com/en-us/troubleshoot/windows-client/performance/configure-system-failure-and-recovery-options
    New-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -Name AutoReboot -PropertyType DWord -Value 0 -Force -ErrorAction Stop | Out-Null
    if (-not (Test-CrashAutoRestartDisabled)) {
        throw 'Windows did not disable automatic restart on system failure.'
    }
    Write-Host 'Automatic restart on system failure is disabled.'
}

function Configure-SystemRestoreStorage {
    try {
        $state = Get-SystemRestoreStorageState
        if ($state.Enabled -and $state.QuotaMatches) {
            Write-Host "System protection on $env:SystemDrive is already enabled with a 1% storage limit. Skipping."
            return
        }
    }
    catch {
        Write-Host "Could not read System Restore settings without elevation: $($_.Exception.Message)"
        Write-Host 'Administrator rights are needed to verify the current state before making any changes.'
    }

    Invoke-ElevatedStep -SwitchName 'ConfigureSystemRestore' -StepName 'System Restore storage configuration'
}

function Set-SystemRestoreStorage {
    if (-not (Test-IsAdministrator)) {
        throw 'Configuring System Restore storage requires administrator rights.'
    }

    # Enable-ComputerRestore is provided by Windows PowerShell 5.1.
    $needsNativeBitness = [Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess
    if ($PSVersionTable.PSEdition -eq 'Core' -or $needsNativeBitness) {
        $systemDirectory = if ($needsNativeBitness) { 'Sysnative' } else { 'System32' }
        $windowsPowerShell = Join-Path $env:WINDIR "$systemDirectory\WindowsPowerShell\v1.0\powershell.exe"
        & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -ConfigureSystemRestore
        if ($LASTEXITCODE -ne 0) {
            throw "System Restore configuration failed (exit code: $LASTEXITCODE)."
        }
        return
    }

    $systemDrive = $env:SystemDrive
    $state = Get-SystemRestoreStorageState
    if ($state.Enabled -and $state.QuotaMatches) {
        Write-Host "System protection on $systemDrive is already enabled with a 1% storage limit. Skipping."
        return
    }
    if (-not $state.Enabled) {
        Enable-ComputerRestore -Drive "$systemDrive\" -ErrorAction Stop
        # Enabling protection may initialize or change the storage association.
        $state = Get-SystemRestoreStorageState
    }
    if ($state.QuotaMatches) {
        if (-not $state.Enabled) { throw 'System protection is still disabled after enabling it.' }
        Write-Host "System protection is enabled on $systemDrive; the storage limit is already 1%."
        return
    }

    # Reducing the quota can remove older restore points. Do not disable protection.
    Write-Host "Setting System Restore storage on $systemDrive to 1%. Older restore points may be removed."
    & vssadmin.exe resize shadowstorage "/for=$systemDrive" "/on=$systemDrive" '/maxsize=1%'
    if ($LASTEXITCODE -ne 0) {
        throw "Could not set System Restore storage to 1% on $systemDrive (exit code: $LASTEXITCODE)."
    }
    $state = Get-SystemRestoreStorageState
    if (-not ($state.Enabled -and $state.QuotaMatches)) {
        throw 'System Restore settings did not pass verification after configuration.'
    }
    Write-Host "System protection is enabled on $systemDrive with a 1% storage limit."
}

function Remove-OneDrive {
    if (-not (Test-ProgramInstalled -DisplayNamePattern '^Microsoft OneDrive$')) {
        Write-Host 'Microsoft OneDrive is not installed. Skipping.'
        return
    }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw 'WinGet is unavailable. Sign in to Windows, update App Installer, then retry.'
    }

    Write-Host 'Uninstalling Microsoft OneDrive...'
    & winget uninstall --id Microsoft.OneDrive --exact --accept-source-agreements

    if ($LASTEXITCODE -ne 0) {
        throw "OneDrive uninstall failed (WinGet exit code: $LASTEXITCODE)."
    }
}

function Remove-TeamsMeetingAddin {
    $uninstallKeys = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKCU:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $entries = @(Get-ItemProperty -Path $uninstallKeys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -eq 'Microsoft Teams Meeting Add-in for Microsoft Office' })
    if ($entries.Count -eq 0) {
        Write-Host 'Microsoft Teams Meeting Add-in for Microsoft Office is not installed. Skipping.'
        return
    }

    foreach ($entry in $entries) {
        # Use the registered MSI product code; do not execute arbitrary uninstall strings.
        $productCode = [guid]::Empty
        if ($entry.WindowsInstaller -ne 1 -or -not [guid]::TryParse($entry.PSChildName, [ref]$productCode)) {
            throw "Unsupported Teams Meeting Add-in installer: $($entry.PSChildName)."
        }
        $logPath = Join-Path $env:TEMP ("TeamsMeetingAddin-uninstall-$([guid]::NewGuid().ToString('N')).log")
        $options = @{
            FilePath = 'msiexec.exe'
            ArgumentList = @('/x', $productCode.ToString('B'), '/qn', '/norestart', '/L*v', "`"$logPath`"")
            Wait = $true
            PassThru = $true
            WindowStyle = 'Hidden'
        }
        # Per-user MSI installations must be removed under the signed-in user.
        if ($entry.PSPath -match '::HKEY_LOCAL_MACHINE\\') {
            $options.Verb = 'RunAs'
        }
        Write-Host 'Uninstalling Microsoft Teams Meeting Add-in for Microsoft Office...'
        $process = Start-Process @options
        if ($process.ExitCode -notin @(0, 1605, 1614, 3010)) {
            throw "Teams Meeting Add-in uninstall failed (exit code: $($process.ExitCode)). Log: $logPath"
        }
        if ($process.ExitCode -eq 3010) {
            Write-Host 'Teams Meeting Add-in removed. A Windows restart is required.'
        }
        else {
            Write-Host 'Teams Meeting Add-in is removed or already absent.'
        }
    }
}

function Remove-UnwantedPrograms {
    Remove-OneDrive

    # Remove only these exact Store packages for the signed-in user.
    $apps = @(
        @{ Name = 'Feedback Hub'; Package = 'Microsoft.WindowsFeedbackHub' }
        @{ Name = 'Microsoft Clipchamp'; Package = 'Clipchamp.Clipchamp' }
        @{ Name = 'Microsoft News'; Package = 'Microsoft.BingNews' }
        @{ Name = 'Microsoft To Do'; Package = 'Microsoft.Todos' }
        @{ Name = 'Outlook (new)'; Package = 'Microsoft.OutlookForWindows' }
        @{ Name = 'Power Automate'; Package = 'Microsoft.PowerAutomateDesktop' }
        @{ Name = 'Microsoft Solitaire & Casual Games'; Package = 'Microsoft.MicrosoftSolitaireCollection' }
        @{ Name = 'Start Experiences App'; Package = 'Microsoft.StartExperiencesApp' }
        @{ Name = 'Sticky Notes'; Package = 'Microsoft.MicrosoftStickyNotes' }
        @{ Name = 'Weather'; Package = 'Microsoft.BingWeather' }
    )
    foreach ($app in $apps) {
        $packages = @(Get-AppxPackage -Name $app.Package -ErrorAction Stop |
            Where-Object { $_.Name -eq $app.Package })
        if ($packages.Count -eq 0) {
            Write-Host "$($app.Name) is not installed. Skipping."
            continue
        }
        foreach ($package in $packages) {
            if ($package.NonRemovable) {
                throw "Windows marks $($app.Name) as non-removable: $($package.PackageFullName)."
            }
            Write-Host "Uninstalling $($app.Name)..."
            Remove-AppxPackage -Package $package.PackageFullName -ErrorAction Stop
        }
        Write-Host "$($app.Name) removed."
    }

    Remove-TeamsMeetingAddin
}

function Test-X64Executable {
    param([string]$Path)
    $reader = $null
    try {
        $reader = [IO.BinaryReader]::new([IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite'))
        if ($reader.ReadUInt16() -ne 0x5A4D) { return $false }
        $reader.BaseStream.Position = 0x3C
        $offset = $reader.ReadInt32()
        if ($offset -lt 64 -or $offset -gt $reader.BaseStream.Length - 6) { return $false }
        $reader.BaseStream.Position = $offset
        return $reader.ReadUInt32() -eq 0x4550 -and $reader.ReadUInt16() -eq 0x8664
    }
    catch { return $false }
    finally { if ($reader) { $reader.Dispose() } }
}

function Test-FirefoxPreferences {
    param($Entry)
    if ($Entry.DisplayName -notmatch '\(x64 en-US\)$' -or -not $Entry.InstallLocation) { return $false }
    if (-not (Test-X64Executable -Path (Join-Path $Entry.InstallLocation 'firefox.exe'))) { return $false }
    # A localized package does not prove the effective language of an existing profile.
    # Profile selection, language packs, policies and user.js can all override it.
    $profileRoot = Join-Path $env:APPDATA 'Mozilla\Firefox'
    if (Test-Path -LiteralPath $profileRoot) { return $false }
    if (Test-Path -LiteralPath (Join-Path $Entry.InstallLocation 'distribution\policies.json')) { return $false }
    return $true
}

function Test-LibreOfficePreferences {
    param($Entry)
    if (-not $Entry.InstallLocation) { return $false }
    if (-not (Test-X64Executable -Path (Join-Path $Entry.InstallLocation 'program\soffice.exe'))) { return $false }
    # Only an explicit user-selected UI locale is evidence; installed English resources are not.
    # https://github.com/LibreOffice/core/blob/master/officecfg/registry/schema/org/openoffice/Setup.xcs
    try {
        $bootstrap = Get-Content -LiteralPath (Join-Path $Entry.InstallLocation 'program\bootstrap.ini') -Raw -ErrorAction Stop
        if ($bootstrap -notmatch '(?m)^UserInstallation=\$SYSUSERCONFIG/LibreOffice/4\s*$') { return $false }
        $profile = Join-Path $env:APPDATA 'LibreOffice\4\user\registrymodifications.xcu'
        [xml]$config = Get-Content -LiteralPath $profile -Raw -ErrorAction Stop
        $ns = [Xml.XmlNamespaceManager]::new($config.NameTable)
        $ns.AddNamespace('oor', 'http://openoffice.org/2001/registry')
        $values = @($config.SelectNodes('//item[@oor:path="/org.openoffice.Setup/L10N"]/prop[@oor:name="ooLocale"]/value', $ns))
        return $values.Count -eq 1 -and $values[0].InnerText -eq 'en-US'
    }
    catch { return $false }
}

function Install-WinGetProgram {
    param(
        [string]$Name, [string]$PackageId, [string]$DisplayNamePattern,
        [string]$Locale, [string]$Architecture, [string]$CustomInstallerArguments,
        [switch]$SkipInstallationConfirmation, [string]$ExcludeVersionPattern,
        [scriptblock]$AdditionalCheck
    )

    if (Test-ProgramInstalled -DisplayNamePattern $DisplayNamePattern -ExcludeVersionPattern $ExcludeVersionPattern -AdditionalCheck $AdditionalCheck) {
        Write-Host "$Name is already installed. Skipping."
        return
    }
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        throw 'WinGet is unavailable. Update App Installer in Microsoft Store, then retry.'
    }
    if ($SkipInstallationConfirmation) {
        Write-Host "Downloading $Name and opening its installation wizard. Setup continues when WinGet returns; client installation may continue separately."
    }
    else {
        Write-Host "Downloading $Name and opening its installation wizard. Complete the wizard to continue setup."
    }
    # Wait for WinGet; a bootstrapper can hand work to another process and exit early.
    # --interactive preserves the installer UI.
    $wingetArguments = @('install', '--id', $PackageId, '--exact', '--source', 'winget', '--interactive', '--accept-source-agreements')
    if ($Locale) { $wingetArguments += @('--locale', $Locale) }
    if ($Architecture) { $wingetArguments += @('--architecture', $Architecture) }
    if ($CustomInstallerArguments) { $wingetArguments += @('--custom', $CustomInstallerArguments) }
    # An excluded prerelease may have a higher version than the desired stable package.
    if (($ExcludeVersionPattern -or $AdditionalCheck) -and (Test-ProgramInstalled -DisplayNamePattern $DisplayNamePattern)) {
        Write-Host "$Name is present, but its required version, architecture or language does not match or could not be confirmed. Opening the requested installer."
        $wingetArguments += '--force'
    }
    & winget.exe @wingetArguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Name installation failed or was cancelled (WinGet exit code: $LASTEXITCODE)."
    }
    if ($SkipInstallationConfirmation) {
        Write-Host "$Name installer launched successfully. Continuing without waiting for client installation or verifying its completion."
        return
    }
    if (-not (Test-ProgramInstalled -DisplayNamePattern $DisplayNamePattern -ExcludeVersionPattern $ExcludeVersionPattern)) {
        throw "$Name installation could not be confirmed. The step remains pending."
    }
    if ($AdditionalCheck -and -not (Test-ProgramInstalled -DisplayNamePattern $DisplayNamePattern -AdditionalCheck $AdditionalCheck)) {
        Write-Warning "$Name installation completed, but x64 and the active English (US) interface could not both be confirmed. Check the application's About and language settings. This step records the installation, not verified interface preferences."
    }
    Write-Host "$Name installed."
}

function Install-MSIAfterburner {
    # The stable and beta channels have distinct package IDs; use the exact stable ID.
    Install-WinGetProgram -Name 'MSI Afterburner (stable)' -PackageId 'Guru3D.Afterburner' -DisplayNamePattern '^MSI Afterburner(?:\s|$)' -ExcludeVersionPattern '(?i)(?<![a-z])(?:beta|alpha|rc|preview)(?![a-z])'
}

function Get-NvidiaAppDownloadUrl {
    $page = Invoke-WebRequest -UseBasicParsing -Uri 'https://www.nvidia.com/en-us/software/nvidia-app/' -ErrorAction Stop
    $links = @($page.Links | ForEach-Object { $_.href } | Where-Object {
        $_ -match '^https://us\.download\.nvidia\.com/nvapp/client/[0-9.]+/NVIDIA_app_v[0-9.]+\.exe$'
    } | Select-Object -Unique)
    if ($links.Count -ne 1) {
        throw 'Could not identify a unique NVIDIA App installer on the official download page.'
    }
    return $links[0]
}

function Install-SignedDownloadedProgram {
    param(
        [string]$Name, [string]$DisplayNamePattern,
        [scriptblock]$ResolveDownloadUrl, [string]$PublisherPattern
    )
    if (Test-ProgramInstalled -DisplayNamePattern $DisplayNamePattern) {
        Write-Host "$Name is already installed. Skipping."
        return
    }
    $downloadUrl = & $ResolveDownloadUrl
    $installerPath = Join-Path $env:TEMP ("setup-$([guid]::NewGuid().ToString('N')).exe")
    try {
        Write-Host "Downloading $Name from $downloadUrl"
        Invoke-WebRequest -UseBasicParsing -Uri $downloadUrl -OutFile $installerPath -ErrorAction Stop
        $signature = Get-AuthenticodeSignature -LiteralPath $installerPath -ErrorAction Stop
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch $PublisherPattern) {
            throw "$Name installer does not have a valid signature from the expected publisher."
        }
        Write-Host "Opening the $Name installation wizard. Complete the wizard to continue setup."
        # No silent switches. Wait for the installer and its child processes.
        $process = Start-Process -FilePath $installerPath -Verb RunAs -Wait -PassThru -ErrorAction Stop
        if ($process.ExitCode -notin @(0, 3010)) {
            throw "$Name installation failed or was cancelled (exit code: $($process.ExitCode))."
        }
        if (-not (Test-ProgramInstalled -DisplayNamePattern $DisplayNamePattern)) {
            throw "$Name installation could not be confirmed. The step remains pending."
        }
        if ($process.ExitCode -eq 3010) { Write-Host 'Restart Windows yourself after setup.' }
        Write-Host "$Name installed."
    }
    finally {
        if (Test-Path -LiteralPath $installerPath) {
            Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Install-NvidiaApp {
    Install-SignedDownloadedProgram -Name 'NVIDIA App' -DisplayNamePattern '^NVIDIA App(?:\s+[0-9].*)?$' -ResolveDownloadUrl { Get-NvidiaAppDownloadUrl } -PublisherPattern '(?:^|,\s*)O=NVIDIA Corporation(?:,|$)'
}

function Test-StoreAppInstalled {
    param([string]$PackageName)

    $packages = @(Get-AppxPackage -Name $PackageName -ErrorAction Stop |
        Where-Object { $_.Name -eq $PackageName -and $_.Status -eq 'Ok' })
    return $packages.Count -gt 0
}

function Install-WinGetStoreApp {
    param([string]$Name, [string]$ProductId, [string]$PackageName)

    if (Test-StoreAppInstalled -PackageName $PackageName) {
        Write-Host "$Name is already installed. Skipping."
        return
    }
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        throw 'WinGet is unavailable. Update App Installer in Microsoft Store, then retry.'
    }
    Write-Host "Downloading and installing $Name from Microsoft Store through WinGet. Respond to any agreement prompts in this console."
    # Synchronous invocation waits for the Store installation without opening its window.
    & winget.exe install --id $ProductId --exact --source msstore --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "$Name installation failed or was cancelled (WinGet exit code: $LASTEXITCODE)."
    }
    if (-not (Test-StoreAppInstalled -PackageName $PackageName)) {
        throw "$Name installation could not be confirmed for the current user. The step remains pending."
    }
    Write-Host "$Name installed."
}

function Install-LenovoVantage {
    Install-WinGetStoreApp -Name 'Lenovo Vantage' -ProductId '9WZDNCRFJ4MV' -PackageName 'E046963F.LenovoCompanion'
}

function Install-LogiOptionsPlus {
    Install-WinGetProgram -Name 'Logi Options+' -PackageId 'Logitech.OptionsPlus' -DisplayNamePattern '^Logi Options\+$'
}

function Install-Steam {
    Install-WinGetProgram -Name 'Steam' -PackageId 'Valve.Steam' -DisplayNamePattern '^Steam$'
}

function Install-BattleNet {
    Install-WinGetProgram -Name 'Battle.net' -PackageId 'Blizzard.BattleNet' -DisplayNamePattern '^Battle\.net$' -SkipInstallationConfirmation
}

function Install-LibreOffice {
    Install-WinGetProgram -Name 'LibreOffice' -PackageId 'TheDocumentFoundation.LibreOffice' -DisplayNamePattern '^LibreOffice(?:\s+\d+(?:\.\d+)*)?$' -Architecture 'x64' -CustomInstallerArguments 'UI_LANGS=en_US' -AdditionalCheck { param($entry) Test-LibreOfficePreferences -Entry $entry }
}

function Install-Firefox {
    Install-WinGetProgram -Name 'Mozilla Firefox' -PackageId 'Mozilla.Firefox' -DisplayNamePattern '^Mozilla Firefox(?:\s|$)' -Locale 'en-US' -Architecture 'x64' -AdditionalCheck { param($entry) Test-FirefoxPreferences -Entry $entry }
}

# Windows remembers this per network; new networks are not changed by this step.
function Set-PrivatePhysicalNetworks {
    if (-not (Test-IsAdministrator)) {
        throw 'Changing network profiles requires PowerShell to be run as administrator.'
    }

    $connectedAdapters = @(Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' })
    foreach ($adapter in $connectedAdapters) {
        $profile = Get-NetConnectionProfile -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue
        if ($profile -and $profile.NetworkCategory -eq 'Public') {
            Set-NetConnectionProfile -InterfaceIndex $adapter.ifIndex -NetworkCategory Private
            Write-Host "Set network '$($profile.Name)' ($($adapter.Name)) to Private."
        }
    }
}

# Stable IDs keep completion records valid when steps are reordered or renumbered.
# Increase a step's Revision when its desired behavior changes and it must run again.
$steps = @(
    @{
        Id = 'temporary-directory'; Revision = 1
        Description = 'use C:\TEMP for Windows and user temporary files.'
        Action = { Set-TemporaryDirectory }
        # Registry settings persist; process environment variables must be restored per session.
        OnSkip = { Set-ProcessTemporaryDirectory }
    }
    @{
        Id = 'english-input'; Revision = 1
        Description = 'choose an existing English keyboard as the default when multiple layouts exist.'
        Action = {
            Set-DefaultEnglishInputMethod
            Write-Host 'To adjust keyboard repeat delay, run: control keyboard'
        }
    }
    @{
        Id = 'private-networks'; Revision = 1
        Description = 'mark currently connected physical networks as private.'
        Action = {
            $publicPhysicalNetworks = @(Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' } |
                ForEach-Object { Get-NetConnectionProfile -InterfaceIndex $_.ifIndex -ErrorAction SilentlyContinue } |
                Where-Object { $_.NetworkCategory -eq 'Public' })
            if ($publicPhysicalNetworks.Count -eq 0) {
                Write-Host 'No connected public physical networks. Skipping.'
            }
            else {
                Write-Host 'Requesting administrator rights to configure network profiles...'
                Invoke-ElevatedStep -SwitchName 'ConfigureNetworks' -StepName 'Network configuration'
            }
        }
    }
    @{
        Id = 'taskbar'; Revision = 1
        Description = 'place the taskbar on the left with icons at the top and keep windows separate.'
        Action = { Set-TaskbarPreferences }
    }
    @{
        Id = 'upload-folder'; Revision = 1
        Description = 'create C:\Upload and open its folder properties.'
        Action = { Configure-UploadFolder }
    }
    @{
        Id = 'power'; Revision = 1
        Description = 'configure lid action, display, sleep and hibernate timeouts for AC and battery.'
        Action = { Configure-PowerPreferences }
    }
    @{
        Id = 'remove-apps'; Revision = 1
        Description = 'Remove unwanted preinstalled applications'
        Action = { Remove-UnwantedPrograms }
    }
    @{
        Id = 'store-updates'; Revision = 1
        Description = 'update Microsoft Store applications and wait for the Store window to close.'
        Action = { Update-MicrosoftStoreApplications }
    }
    @{
        Id = 'personalization'; Revision = 1
        Description = 'use black backgrounds, dark mode and disable transparency.'
        Action = { Set-PersonalizationPreferences }
    }
    @{
        Id = 'system-restore'; Revision = 1
        Description = 'enable system protection and limit restore point storage to 1% of the system drive.'
        Action = { Configure-SystemRestoreStorage }
    }
    @{
        Id = 'crash-recovery'; Revision = 1
        Description = 'disable automatic restart on system failure.'
        Action = { Configure-CrashRecovery }
    }
    @{
        Id = 'explorer'; Revision = 1
        Description = 'show file extensions, hidden files and folders, and the full path in Explorer title bars.'
        Action = { Set-ExplorerPreferences }
    }
    @{
        Id = 'defender-folders'; Revision = 2
        Description = 'create C:\Games and open Windows Security for manual folder exclusions; wait until its window closes.'
        Action = { Configure-DefenderFolders }
    }
    @{
        Id = 'search'; Revision = 1
        Description = 'disable web suggestions, cloud search results and search highlights.'
        Action = { Set-SearchPreferences }
    }
    @{
        Id = 'remote-assistance'; Revision = 1
        Description = 'disable Windows Remote Assistance, including invitations and offered assistance.'
        Action = { Configure-RemoteAssistance }
    }
    @{
        Id = 'virtual-memory'; Revision = 1
        Description = 'set a single fixed 6144 MB page file on the system drive and disable hibernation.'
        Action = { Configure-VirtualMemory }
    }
    @{
        Id = 'recycle-bin'; Revision = 1
        Description = 'limit the Recycle Bin to 1024 MB on each local drive for the current user.'
        Action = { Set-RecycleBinSize -SizeMB 1024 }
    }
    @{
        Id = 'workgroup'; Revision = 1
        Description = 'set the computer workgroup to HOME without restarting Windows.'
        Action = { Configure-HomeWorkgroup }
    }
    @{
        Id = 'msi-afterburner'; Revision = 3
        Description = 'download and install stable MSI Afterburner using its installation wizard.'
        Action = { Install-MSIAfterburner }
    }
    @{
        Id = 'nvidia-app'; Revision = 1
        Description = 'download NVIDIA App from NVIDIA and install it using its installation wizard.'
        Action = { Install-NvidiaApp }
    }
    @{
        Id = 'lenovo-vantage'; Revision = 1
        Description = 'download and install Lenovo Vantage from Microsoft Store through WinGet and wait for completion.'
        Action = { Install-LenovoVantage }
    }
    @{
        Id = 'logi-options-plus'; Revision = 1
        Description = 'download and install Logi Options+ through WinGet using its installation wizard.'
        Action = { Install-LogiOptionsPlus }
    }
    @{
        Id = 'steam'; Revision = 1
        Description = 'download and install Steam through WinGet using its installation wizard.'
        Action = { Install-Steam }
    }
    @{
        Id = 'battle-net'; Revision = 1
        Description = 'download and launch the Battle.net installer through WinGet; continue without confirming client installation.'
        Action = { Install-BattleNet }
    }
    @{
        Id = 'libreoffice'; Revision = 2
        Description = 'download and install the latest LibreOffice with an English (US) interface.'
        Action = { Install-LibreOffice }
    }
    @{
        Id = 'firefox'; Revision = 2
        Description = 'download and install the latest Firefox in English (US).'
        Action = { Install-Firefox }
    }
)

if ($Help) {
    Show-SetupHelp -Steps $steps
    return
}

if ($ConfigureSystemTemp -or $ConfigureUploadFolder -or $ConfigurePower -or $ConfigureNetworks -or $ConfigureSystemRestore -or $ConfigureCrashRecovery -or $ConfigureGamesFolder -or $ConfigureSearchPolicy -or $ConfigureRemoteAssistance -or $ConfigureVirtualMemory -or $ConfigureWorkgroup) {
    try {
        if ($ConfigureSystemTemp) { Set-SystemTemp }
        elseif ($ConfigureUploadFolder) { New-UploadFolder }
        elseif ($ConfigurePower) { Set-PowerPreferences }
        elseif ($ConfigureSystemRestore) { Set-SystemRestoreStorage }
        elseif ($ConfigureCrashRecovery) { Set-CrashRecovery }
        elseif ($ConfigureGamesFolder) { New-GamesFolder }
        elseif ($ConfigureRemoteAssistance) { Set-RemoteAssistanceDisabled }
        elseif ($ConfigureVirtualMemory) { Set-VirtualMemory }
        elseif ($ConfigureWorkgroup) { Set-HomeWorkgroup }
        elseif ($ConfigureSearchPolicy) {
            if (-not $TargetUserSid) { throw 'The original user SID is required for search policy configuration.' }
            Set-SearchPolicy -UserSid $TargetUserSid
        }
        else { Set-PrivatePhysicalNetworks }
        return
    }
    catch {
        if ($ErrorLog) {
            try {
                $_ | Format-List * -Force | Out-String | Set-Content -LiteralPath $ErrorLog -Encoding UTF8
            }
            catch {
                Write-Host "Could not save the elevated error: $($_.Exception.Message)"
            }
        }
        Write-Host "Elevated step failed: $($_.Exception.Message)"
        exit 1
    }
}

if (Test-IsAdministrator) {
    throw 'Run this script from a regular PowerShell window. Steps requiring administrator rights will request them.'
}

if ($ConfigurePersonalization) {
    try {
        Set-PersonalizationPreferences
    }
    catch {
        Write-Error -ErrorAction Continue "Personalization failed: $($_.Exception.Message)"
        exit 1
    }
    return
}

$rerunStepIds = @(Resolve-RerunStepIds -Steps $steps -Selection $RerunSteps)
$statePath = Join-Path $PSScriptRoot ([IO.Path]::GetFileNameWithoutExtension($PSCommandPath) + '.state.json')
$setupLock = Open-SetupLock -StatePath $statePath
try {
    $state = Read-SetupState -Path $statePath -Context (Get-SetupContext)
    # Check that state can be saved before performing system changes.
    Save-SetupState -Path $statePath -State $state
    for ($index = 0; $index -lt $steps.Count; $index++) {
        $step = $steps[$index]
        Invoke-SetupStep @step -Number ($index + 1) -State $state -StatePath $statePath -Rerun:($step.Id -in $rerunStepIds)
    }
}
finally {
    $setupLock.Dispose()
}
