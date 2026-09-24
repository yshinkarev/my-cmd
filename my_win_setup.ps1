# Run this script in PowerShell after signing in to Windows.
# Step 1: remove Microsoft OneDrive without deleting synced files.
# Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

$ErrorActionPreference = 'Stop'

function Remove-OneDrive {
    $uninstallKeys = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $installed = @(Get-ItemProperty -Path $uninstallKeys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -eq 'Microsoft OneDrive' })

    if ($installed.Count -eq 0) {
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

Remove-OneDrive

# Step 2: mark currently connected physical networks as private.
# Windows remembers this per network; new networks are not changed by this step.
function Set-PrivatePhysicalNetworks {
    $isAdministrator = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
    if (-not $isAdministrator) {
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

Set-PrivatePhysicalNetworks
