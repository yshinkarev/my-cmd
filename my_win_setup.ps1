# Run this script in PowerShell after signing in to Windows.
# Step 1: remove Microsoft OneDrive without deleting synced files.
# Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

param([switch]$ConfigureNetworks)

$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    return ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
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

# Step 2: choose an existing English keyboard as the default when multiple layouts exist.
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

# Step 3: center taskbar icons and keep windows separate.
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

# Step 4: download and install the latest LibreOffice with an English (US) interface.
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

# Step 5: download and install the latest Firefox in English (US).
function Install-Firefox {
    if (Test-ProgramInstalled -DisplayNamePattern '^Mozilla Firefox') {
        Write-Host 'Firefox is already installed. Skipping.'
        return
    }

    $downloadUrl = 'https://download.mozilla.org/?product=firefox-latest-ssl&os=win64&lang=en-US'
    Install-DownloadedProgram -Name 'Firefox' -DownloadUrl $downloadUrl -InstallerKind Exe
}

# Step 6: mark currently connected physical networks as private.
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

if ($ConfigureNetworks) {
    Set-PrivatePhysicalNetworks
    return
}

if (Test-IsAdministrator) {
    throw 'Run this script from a regular PowerShell window. Only the network step will request administrator rights.'
}

Remove-OneDrive
Set-DefaultEnglishInputMethod
Set-TaskbarPreferences
Install-LibreOffice
Install-Firefox

$publicPhysicalNetworks = @(Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' } |
    ForEach-Object { Get-NetConnectionProfile -InterfaceIndex $_.ifIndex -ErrorAction SilentlyContinue } |
    Where-Object { $_.NetworkCategory -eq 'Public' })

if ($publicPhysicalNetworks.Count -eq 0) {
    Write-Host 'No connected public physical networks. Skipping.'
    return
}

Write-Host 'Requesting administrator rights to configure network profiles...'
$powerShell = (Get-Process -Id $PID).Path
$process = Start-Process -FilePath $powerShell -Verb RunAs -Wait -PassThru -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-ConfigureNetworks'
)
if ($process.ExitCode -ne 0) {
    throw "Network configuration failed (exit code: $($process.ExitCode))."
}
