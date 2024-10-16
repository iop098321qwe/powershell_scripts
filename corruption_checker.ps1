<#
.SYNOPSIS
    A PowerShell script to automate DISM and SFC operations for system health and repair.

.DESCRIPTION
    This script performs a sequence of system checks and repairs using DISM and SFC.
    It will attempt to identify and repair any issues found in the system image or system files.
    The script uses DISM (Deployment Imaging Service and Management Tool) to scan the health of the system image,
    attempt repairs if necessary, and finally run SFC (System File Checker) to ensure the integrity of system files.
    If issues are detected during the first run, the script will retry the process once to verify successful repairs.

.PARAMETER Debug
    Switch parameter to enable verbose debug output for troubleshooting purposes.
    When enabled, the script will provide additional information such as exit codes after each operation.

.PARAMETER MaxAttempts
    Parameter to specify the maximum number of retry attempts for system checks and repairs.

.VERSION
    v1.0.3

.AUTHOR
    Dallas Elliott

.LASTUPDATED
    2024-10-16

.NOTES
    Requires administrative privileges to execute.
    Designed to run on Windows systems with DISM and SFC tools available.
    Ensure the script is run in an elevated PowerShell session.
#>

# Define parameters that the script can accept
[CmdletBinding()]
param(
    [switch]$DebugMode,        # Switch parameter to enable or disable debug mode for more verbose logging
    [int]$MaxAttempts = 2  # Parameter to specify the maximum number of retry attempts
)

# Function to check if the script is running as an administrator
function Test-Administrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Check for administrative privileges
if (-not (Test-Administrator)) {
    Write-Output "This script requires administrative privileges to run. Please run it as an administrator."
    exit 1
}

# Initialize the attempt counter
$attempt = 0

# Loop to perform system checks and repairs
while ($attempt -lt $MaxAttempts) {
    # Output the current attempt number if debug mode is enabled
    if ($DebugMode) {
        Write-Output "`n====================== DEBUG INFO ======================"
        Write-Output "Attempt Number: $attempt"
        Write-Output "Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        Write-Output "----------------------------------------------------------"
    }

    # Run DISM ScanHealth to check the health of the system image
    Write-Output "Running DISM to perform ScanHealth..."
    if ($DebugMode) {
        Write-Output "[DEBUG] Executing Command: DISM /Online /Cleanup-Image /ScanHealth"
        Write-Output "[DEBUG] Start Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    }
    Start-Process -FilePath 'DISM' -ArgumentList '/Online', '/Cleanup-Image', '/ScanHealth' -Wait -NoNewWindow -PassThru
    $scanHealthExitCode = $LASTEXITCODE

    if ($DebugMode) {
        Write-Output "[DEBUG] DISM ScanHealth Exit Code: $scanHealthExitCode"
        Write-Output "[DEBUG] End Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        Write-Output "----------------------------------------------------------"
    }

    # Handle ScanHealth results
    if ($scanHealthExitCode -eq 87) {
        Write-Output "Invalid command line argument detected during ScanHealth. Please verify DISM parameters."
        if ($DebugMode) { Write-Output "[DEBUG] Exiting with code 87 due to invalid DISM argument." }
        exit 87
    } elseif ($scanHealthExitCode -eq 0) {
        Write-Output "No component store corruption detected during ScanHealth."
        if ($DebugMode) { Write-Output "[DEBUG] ScanHealth completed successfully with no errors." }
    } else {
        Write-Output "Errors detected during ScanHealth (Exit Code: $scanHealthExitCode). Running DISM RestoreHealth..."
        if ($DebugMode) {
            Write-Output "[DEBUG] Executing Command: DISM /Online /Cleanup-Image /RestoreHealth"
            Write-Output "[DEBUG] Start Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        }
        Start-Process -FilePath 'DISM' -ArgumentList '/Online', '/Cleanup-Image', '/RestoreHealth' -Wait -NoNewWindow -PassThru
        $restoreHealthExitCode = $LASTEXITCODE
        if ($DebugMode) {
            Write-Output "[DEBUG] DISM RestoreHealth Exit Code: $restoreHealthExitCode"
            Write-Output "[DEBUG] End Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            Write-Output "----------------------------------------------------------"
        }

        if ($restoreHealthExitCode -ne 0) {
            Write-Output "RestoreHealth failed with exit code: $restoreHealthExitCode."
            if ($DebugMode) { Write-Output "[DEBUG] Exiting with code $restoreHealthExitCode due to RestoreHealth failure." }
            exit $restoreHealthExitCode
        }
    }

    # Run DISM CheckHealth to verify the integrity of the system image after repairs
    Write-Output "Running DISM to perform CheckHealth..."
    if ($DebugMode) {
        Write-Output "[DEBUG] Executing Command: DISM /Online /Cleanup-Image /CheckHealth"
        Write-Output "[DEBUG] Start Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    }
    Start-Process -FilePath 'DISM' -ArgumentList '/Online', '/Cleanup-Image', '/CheckHealth' -Wait -NoNewWindow -PassThru
    $checkHealthExitCode = $LASTEXITCODE

    if ($DebugMode) {
        Write-Output "[DEBUG] DISM CheckHealth Exit Code: $checkHealthExitCode"
        Write-Output "[DEBUG] End Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        Write-Output "----------------------------------------------------------"
    }

    # Handle CheckHealth results
    if ($checkHealthExitCode -eq 0) {
        Write-Output "No component store corruption detected during CheckHealth."
        if ($DebugMode) { Write-Output "[DEBUG] CheckHealth completed successfully with no errors." }
    } elseif ($checkHealthExitCode -eq 87) {
        Write-Output "Invalid command line argument detected during CheckHealth. Please verify DISM parameters."
        if ($DebugMode) { Write-Output "[DEBUG] Exiting with code 87 due to invalid DISM argument." }
        exit 87
    } else {
        Write-Output "Errors detected during CheckHealth (Exit Code: $checkHealthExitCode). Running DISM RestoreHealth..."
        if ($DebugMode) {
            Write-Output "[DEBUG] Executing Command: DISM /Online /Cleanup-Image /RestoreHealth"
            Write-Output "[DEBUG] Start Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        }
        Start-Process -FilePath 'DISM' -ArgumentList '/Online', '/Cleanup-Image', '/RestoreHealth' -Wait -NoNewWindow -PassThru
        $restoreHealthExitCode = $LASTEXITCODE
        if ($DebugMode) {
            Write-Output "[DEBUG] DISM RestoreHealth Exit Code: $restoreHealthExitCode"
            Write-Output "[DEBUG] End Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            Write-Output "----------------------------------------------------------"
        }

        if ($restoreHealthExitCode -ne 0) {
            Write-Output "RestoreHealth failed with exit code: $restoreHealthExitCode."
            if ($DebugMode) { Write-Output "[DEBUG] Exiting with code $restoreHealthExitCode due to RestoreHealth failure." }
            exit $restoreHealthExitCode
        }
    }

    # Run SFC to check and repair system files
    Write-Output "Running SFC to check and repair system files..."
    if ($DebugMode) {
        Write-Output "[DEBUG] Executing Command: sfc /scannow"
        Write-Output "[DEBUG] Start Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    }
    Start-Process -FilePath 'sfc' -ArgumentList '/scannow' -Wait -NoNewWindow -PassThru
    $sfcScanExitCode = $LASTEXITCODE

    if ($DebugMode) {
        Write-Output "[DEBUG] SFC Scan Exit Code: $sfcScanExitCode"
        Write-Output "[DEBUG]

