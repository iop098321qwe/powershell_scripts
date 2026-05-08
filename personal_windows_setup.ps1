[CmdletBinding()]
param (
    [string]$Win11DebloatUri = 'https://debloat.raphi.re/',
    [string]$PackageConfigUri = 'https://raw.githubusercontent.com/iop098321qwe/powershell_scripts/main/personal_windows_setup.config'
)

$ErrorActionPreference = 'Stop'
$script:BootstrapScriptText = $MyInvocation.MyCommand.ScriptBlock.Ast.Extent.Text

function Write-Section {
    param (
        [Parameter(Mandatory)]
        [string]$Message
    )

    Write-Output ''
    Write-Output '-------------------------------------------------------------------------------------------'
    Write-Output " $Message"
    Write-Output '-------------------------------------------------------------------------------------------'
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity

    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-ElevatedBootstrap {
    param (
        [Parameter(Mandatory)]
        [string]$ScriptText
    )

    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($ScriptText))

    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-EncodedCommand',
        $encodedCommand
    )
}

function Install-Chocolatey {
    if (Get-Command choco.exe -ErrorAction SilentlyContinue) {
        Write-Output '> Chocolatey is already installed.'
        return
    }

    Write-Output '> Installing Chocolatey...'

    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072

    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))

    $chocolateyInstall = if ($env:ChocolateyInstall) { $env:ChocolateyInstall } else { Join-Path ${env:ProgramData} 'chocolatey' }
    $chocolateyBin = Join-Path $chocolateyInstall 'bin'
    if ((Test-Path $chocolateyBin) -and ($env:Path -notlike "*$chocolateyBin*")) {
        $env:Path = "$chocolateyBin;$env:Path"
    }
}

function Install-ChocolateyPackages {
    param (
        [Parameter(Mandatory)]
        [string[]]$Packages
    )

    if ($Packages.Count -eq 0) {
        Write-Output '> No Chocolatey packages were requested.'
        return
    }

    $chocoPath = (Get-Command choco.exe -ErrorAction Stop).Source

    Write-Output "> Installing Chocolatey packages: $($Packages -join ', ')..."
    & $chocoPath install @Packages -y --no-progress
}

function Get-ChocolateyPackagesFromConfig {
    param (
        [Parameter(Mandatory)]
        [string]$ConfigUri
    )

    Write-Output "> Downloading Chocolatey package config from $ConfigUri..."

    $configContent = Invoke-RestMethod -Uri $ConfigUri
    $packages = @(
        $configContent -split "`r?`n" | ForEach-Object {
            $line = $_.Trim()

            if ($line -and -not $line.StartsWith('#')) {
                $line
            }
        }
    )

    if ($packages.Count -eq 0) {
        throw "No Chocolatey packages were found in $ConfigUri."
    }

    return $packages
}

try {
    if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
        throw 'PowerShell execution is restricted by security policies. FullLanguage mode is required.'
    }

    Clear-Host
    Write-Section -Message 'Personal Windows Setup'

    if (-not (Test-IsAdministrator)) {
        Write-Output '> Restarting as Administrator...'
        Start-ElevatedBootstrap -ScriptText $script:BootstrapScriptText
        exit
    }

    Write-Section -Message 'Win11Debloat'
    Write-Output '> Launching Raphire Win11Debloat interactively...'
    & ([scriptblock]::Create((Invoke-RestMethod -Uri $Win11DebloatUri)))

    Write-Section -Message 'Chocolatey'
    Install-Chocolatey

    Write-Section -Message 'Applications'
    $ChocolateyPackages = Get-ChocolateyPackagesFromConfig -ConfigUri $PackageConfigUri
    Install-ChocolateyPackages -Packages $ChocolateyPackages

    Write-Section -Message 'Complete'
    Write-Output '> Personal Windows setup completed.'
}
catch {
    Write-Host ''
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Output ''
    Write-Output 'Press enter to exit...'
    Read-Host | Out-Null
    exit 1
}
