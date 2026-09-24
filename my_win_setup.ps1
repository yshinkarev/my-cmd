# Run this script in PowerShell after signing in to Windows.
# Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

param([switch]$ConfigureNetworks, [switch]$ConfigureSystemTemp, [switch]$ConfigureUploadShare, [string]$ErrorLog)

$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    return ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Invoke-ElevatedStep {
    param(
        [string]$SwitchName,
        [string]$StepName
    )

    $errorLog = Join-Path $env:TEMP ("my_win_setup-$([guid]::NewGuid().ToString('N')).log")
    $powerShell = (Get-Process -Id $PID).Path

    try {
        $process = Start-Process -FilePath $powerShell -Verb RunAs -Wait -PassThru -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
            "-$SwitchName", '-ErrorLog', "`"$errorLog`""
        )
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
    param([string]$DisplayNamePattern)

    $uninstallKeys = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $installed = Get-ItemProperty -Path $uninstallKeys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match $DisplayNamePattern } |
        Select-Object -First 1
    return [bool]$installed
}

function Install-DownloadedProgram {
    param(
        [string]$Name,
        [string]$DownloadUrl,
        [ValidateSet('Exe', 'Msi')][string]$InstallerKind,
        [string[]]$InstallerArguments,
        [int[]]$SuccessExitCodes = @(0)
    )

    $extension = if ($InstallerKind -eq 'Msi') { '.msi' } else { '.exe' }
    $installerPath = Join-Path $env:TEMP ("${Name}Setup-$([guid]::NewGuid().ToString('N'))$extension")

    try {
        Write-Host "Downloading $Name..."
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $installerPath -UseBasicParsing

        $startOptions = @{
            FilePath = $installerPath
            Wait = $true
            PassThru = $true
        }
        if ($InstallerKind -eq 'Msi') {
            Write-Host "Requesting administrator rights to install $Name..."
            $startOptions.FilePath = 'msiexec.exe'
            $startOptions.ArgumentList = @('/i', "`"$installerPath`"") + $InstallerArguments
            $startOptions.Verb = 'RunAs'
        }
        else {
            if ($InstallerArguments) {
                $startOptions.ArgumentList = $InstallerArguments
            }
            Write-Host "Installing $Name..."
        }

        $installer = Start-Process @startOptions
        if ($installer.ExitCode -notin $SuccessExitCodes) {
            throw "$Name installation failed (exit code: $($installer.ExitCode))."
        }
        Write-Host "$Name installed."
    }
    finally {
        if (Test-Path -LiteralPath $installerPath) {
            Remove-Item -LiteralPath $installerPath -Force
            Write-Host "$Name installer removed."
        }
    }
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
    if ($current.TaskbarAl -eq 1 -and $current.TaskbarGlomLevel -eq 2) {
        Write-Host 'Taskbar preferences are already configured.'
        return
    }

    New-ItemProperty -Path $advancedPath -Name TaskbarAl -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -Path $advancedPath -Name TaskbarGlomLevel -PropertyType DWord -Value 2 -Force | Out-Null

    # Restart the shell so the new preferences take effect immediately.
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Process explorer.exe
    Write-Host 'Centered taskbar icons and disabled window grouping.'
}

function Set-UploadShare {
    if (-not (Test-IsAdministrator)) {
        throw 'Sharing C:\Upload requires administrator rights.'
    }

    $sharePath = 'C:\Upload'
    if (Test-Path -LiteralPath $sharePath -PathType Container) {
        Write-Host 'C:\Upload already exists. Skipping the entire share step.'
        return
    }
    $existingShare = Get-SmbShare -Name 'Upload' -ErrorAction SilentlyContinue
    if ($existingShare) {
        $existingPath = [IO.Path]::GetFullPath($existingShare.Path).TrimEnd('\')
        $uploadPath = [IO.Path]::GetFullPath($sharePath).TrimEnd('\')
        if ($existingPath -ine $uploadPath) {
            throw "The SMB share 'Upload' already points to '$($existingShare.Path)'. Resolve this share before setting up C:\Upload."
        }
        if (@(Get-SmbSession).Count -ne 0) {
            throw "The stale Upload share has active SMB sessions. Close them and retry."
        }

        Remove-SmbShare -Name 'Upload' -Force -Confirm:$false
        Write-Host 'Removed the stale Upload share before creating the folder.'
    }

    New-Item -ItemType Directory -Path $sharePath | Out-Null
    & icacls.exe $sharePath /grant:r '*S-1-1-0:(OI)(CI)M' '*S-1-5-7:(OI)(CI)M' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not set permissions on $sharePath."
    }

    $everyone = ([Security.Principal.SecurityIdentifier] 'S-1-1-0').Translate([Security.Principal.NTAccount]).Value
    $anonymous = ([Security.Principal.SecurityIdentifier] 'S-1-5-7').Translate([Security.Principal.NTAccount]).Value
    New-SmbShare -Name 'Upload' -Path $sharePath -ChangeAccess @($everyone, $anonymous) | Out-Null

    # Allow null sessions only for this share; keep any existing exceptions.
    $serverParameters = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters'
    $nullSessionShares = @((Get-ItemProperty -Path $serverParameters -Name NullSessionShares -ErrorAction SilentlyContinue).NullSessionShares |
        Where-Object { $_ })
    if ('Upload' -notin $nullSessionShares) {
        New-ItemProperty -Path $serverParameters -Name NullSessionShares -PropertyType MultiString `
            -Value ([string[]]($nullSessionShares + 'Upload')) -Force | Out-Null
    }

    $server = Get-SmbServerConfiguration
    $serverOptions = @{ AutoShareWorkstation = $false; Force = $true }
    if ($server.RequireSecuritySignature) {
        $serverOptions.RequireSecuritySignature = $false
    }
    Set-SmbServerConfiguration @serverOptions | Out-Null

    # Removing a share disconnects clients, so leave existing sessions for the next restart.
    if (@(Get-SmbSession).Count -eq 0) {
        Get-SmbShare -Special $true |
            Where-Object { $_.Name -match '^(?:[A-Z]\$|ADMIN\$)$' } |
            ForEach-Object { Remove-SmbShare -Name $_.Name -Force -Confirm:$false }
    }
    else {
        Write-Host 'Administrative disk shares will close after the next restart (active SMB sessions exist).'
    }

    if (-not (Get-NetFirewallRule -Name 'my-cmd-upload-smb' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name 'my-cmd-upload-smb' -DisplayName 'Upload SMB (private local subnet)' `
            -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -Profile Private `
            -RemoteAddress LocalSubnet | Out-Null
    }
    Write-Host "Shared C:\Upload as \\$env:COMPUTERNAME\Upload for anonymous read and write."
}

function Configure-UploadShare {
    if (Test-Path -LiteralPath 'C:\Upload' -PathType Container) {
        Write-Host 'C:\Upload already exists. Skipping the entire share step.'
        return
    }

    Write-Host 'Requesting administrator rights to share C:\Upload...'
    Invoke-ElevatedStep -SwitchName 'ConfigureUploadShare' -StepName 'Upload share configuration'
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

function Install-LibreOffice {
    if (Test-ProgramInstalled -DisplayNamePattern '^LibreOffice(?:\s+\d|$)') {
        Write-Host 'LibreOffice is already installed. Skipping.'
        return
    }

    $downloadPage = Invoke-WebRequest -Uri 'https://www.libreoffice.org/download/' -UseBasicParsing
    $downloadUrl = $downloadPage.Links |
        Where-Object {
            $_.href -match '^https://download\.documentfoundation\.org/libreoffice/stable/\d+(?:\.\d)+/win/x86_64/LibreOffice_[^/]+_Win_x86-64\.msi$'
        } | Select-Object -First 1 -ExpandProperty href

    if (-not $downloadUrl) {
        throw 'Could not find the current LibreOffice Windows x64 installer on the official download page.'
    }

    Install-DownloadedProgram -Name 'LibreOffice' -DownloadUrl $downloadUrl -InstallerKind Msi -InstallerArguments @('UI_LANGS=en_US', '/qf', '/norestart') -SuccessExitCodes @(0, 3010)
}

function Install-Firefox {
    if (Test-ProgramInstalled -DisplayNamePattern '^Mozilla Firefox') {
        Write-Host 'Firefox is already installed. Skipping.'
        return
    }

    $downloadUrl = 'https://download.mozilla.org/?product=firefox-latest-ssl&os=win64&lang=en-US'
    Install-DownloadedProgram -Name 'Firefox' -DownloadUrl $downloadUrl -InstallerKind Exe
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

if ($ConfigureSystemTemp -or $ConfigureUploadShare -or $ConfigureNetworks) {
    try {
        if ($ConfigureSystemTemp) { Set-SystemTemp }
        elseif ($ConfigureUploadShare) { Set-UploadShare }
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

Write-Host 'Step 1: use C:\TEMP for Windows and user temporary files.'
Set-TemporaryDirectory
Write-Host 'Step 2: choose an existing English keyboard as the default when multiple layouts exist.'
Set-DefaultEnglishInputMethod
Write-Host 'Step 3: center taskbar icons and keep windows separate.'
Set-TaskbarPreferences
Write-Host 'Step 4: share C:\Upload for guest read and write on private networks.'
Configure-UploadShare
Write-Host 'Step 5: remove Microsoft OneDrive without deleting synced files.'
Remove-OneDrive
Write-Host 'Step 6: download and install the latest LibreOffice with an English (US) interface.'
Install-LibreOffice
Write-Host 'Step 7: download and install the latest Firefox in English (US).'
Install-Firefox

Write-Host 'Step 8: mark currently connected physical networks as private.'
$publicPhysicalNetworks = @(Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' } |
    ForEach-Object { Get-NetConnectionProfile -InterfaceIndex $_.ifIndex -ErrorAction SilentlyContinue } |
    Where-Object { $_.NetworkCategory -eq 'Public' })

if ($publicPhysicalNetworks.Count -eq 0) {
    Write-Host 'No connected public physical networks. Skipping.'
    return
}

Write-Host 'Requesting administrator rights to configure network profiles...'
Invoke-ElevatedStep -SwitchName 'ConfigureNetworks' -StepName 'Network configuration'
