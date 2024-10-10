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
    v1.0.1

.AUTHOR
    Dallas Elliott

.LASTUPDATED
    2024-10-10

.NOTES
    Requires administrative privileges to execute.
    Designed to run on Windows systems with DISM and SFC tools available.
    Ensure the script is run in an elevated PowerShell session.
#>

# Define parameters that the script can accept
[CmdletBinding()]
param(
    [switch]$Debug,        # Switch parameter to enable or disable debug mode for more verbose logging
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
    if ($Debug) { Write-Output "`n====================== DEBUG INFO ======================" }
    if ($Debug) { Write-Output "Attempt number: $attempt" }

    # Run DISM ScanHealth to check the health of the system image
    Write-Output "Running DISM to perform ScanHealth..."
    if ($Debug) { Write-Output "[DEBUG] Executing: DISM /Online /Cleanup-Image /ScanHealth" }
    Start-Process -FilePath 'DISM' -ArgumentList '/Online', '/Cleanup-Image', '/ScanHealth' -Wait -NoNewWindow -PassThru
    $scanHealthExitCode = $LASTEXITCODE

    # Output the exit code from ScanHealth if debug mode is enabled
    if ($Debug) { Write-Output "[DEBUG] ScanHealth Exit Code: $scanHealthExitCode" }

    # If ScanHealth found issues (exit code not equal to 0), run RestoreHealth to attempt repairs
    if ($scanHealthExitCode -eq 87) {
        Write-Output "Invalid command line argument detected during ScanHealth. Please verify DISM parameters."
        if ($Debug) { Write-Output "[DEBUG] Exiting with code 87 due to invalid DISM argument." }
        exit 87
    } elseif ($scanHealthExitCode -eq 0) {
        Write-Output "No component store corruption detected during ScanHealth."
        if ($Debug) { Write-Output "[DEBUG] ScanHealth completed successfully with no errors." }
    } else {
        Write-Output "Errors detected during ScanHealth (Exit Code: $scanHealthExitCode). Running DISM RestoreHealth..."
        if ($Debug) { Write-Output "[DEBUG] Executing: DISM /Online /Cleanup-Image /RestoreHealth" }
        Start-Process -FilePath 'DISM' -ArgumentList '/Online', '/Cleanup-Image', '/RestoreHealth' -Wait -NoNewWindow -PassThru
        $restoreHealthExitCode = $LASTEXITCODE
        # Output the exit code from RestoreHealth if debug mode is enabled
        if ($Debug) { Write-Output "[DEBUG] RestoreHealth Exit Code: $restoreHealthExitCode" }

        if ($restoreHealthExitCode -ne 0) {
            Write-Output "RestoreHealth failed with exit code: $restoreHealthExitCode."
            if ($Debug) { Write-Output "[DEBUG] Exiting with code $restoreHealthExitCode due to RestoreHealth failure." }
            exit $restoreHealthExitCode
        }
    }

    # Run DISM CheckHealth to verify the integrity of the system image after repairs
    Write-Output "Running DISM to perform CheckHealth..."
    if ($Debug) { Write-Output "[DEBUG] Executing: DISM /Online /Cleanup-Image /CheckHealth" }
    Start-Process -FilePath 'DISM' -ArgumentList '/Online', '/Cleanup-Image', '/CheckHealth' -Wait -NoNewWindow -PassThru
    $checkHealthExitCode = $LASTEXITCODE

    # Output the exit code from CheckHealth if debug mode is enabled
    if ($Debug) { Write-Output "[DEBUG] CheckHealth Exit Code: $checkHealthExitCode" }

    # If CheckHealth found issues (exit code not equal to 0), run RestoreHealth again to attempt repairs
    if ($checkHealthExitCode -eq 0) {
        Write-Output "No component store corruption detected during CheckHealth."
        if ($Debug) { Write-Output "[DEBUG] CheckHealth completed successfully with no errors." }
    } elseif ($checkHealthExitCode -eq 87) {
        Write-Output "Invalid command line argument detected during CheckHealth. Please verify DISM parameters."
        if ($Debug) { Write-Output "[DEBUG] Exiting with code 87 due to invalid DISM argument." }
        exit 87
    } else {
        Write-Output "Errors detected during CheckHealth (Exit Code: $checkHealthExitCode). Running DISM RestoreHealth..."
        if ($Debug) { Write-Output "[DEBUG] Executing: DISM /Online /Cleanup-Image /RestoreHealth" }
        Start-Process -FilePath 'DISM' -ArgumentList '/Online', '/Cleanup-Image', '/RestoreHealth' -Wait -NoNewWindow -PassThru
        $restoreHealthExitCode = $LASTEXITCODE
        # Output the exit code from RestoreHealth if debug mode is enabled
        if ($Debug) { Write-Output "[DEBUG] RestoreHealth Exit Code: $restoreHealthExitCode" }

        if ($restoreHealthExitCode -ne 0) {
            Write-Output "RestoreHealth failed with exit code: $restoreHealthExitCode."
            if ($Debug) { Write-Output "[DEBUG] Exiting with code $restoreHealthExitCode due to RestoreHealth failure." }
            exit $restoreHealthExitCode
        }
    }

    # Run SFC to check and repair system files
    Write-Output "Running SFC to check and repair system files..."
    if ($Debug) { Write-Output "[DEBUG] Executing: sfc /scannow" }
    Start-Process -FilePath 'sfc' -ArgumentList '/scannow' -Wait -NoNewWindow -PassThru
    $sfcScanExitCode = $LASTEXITCODE

    # Output the exit code from SFC if debug mode is enabled
    if ($Debug) { Write-Output "[DEBUG] SFC Scan Exit Code: $sfcScanExitCode" }

    # If SFC found issues (exit code not equal to 0), increment attempt counter and repeat the process once
    if ($sfcScanExitCode -ne 0) {
        Write-Output "Errors found during SFC scan (Exit Code: $sfcScanExitCode), repeating the process once..."
        if ($Debug) { Write-Output "[DEBUG] Incrementing attempt counter and retrying. Attempt: $($attempt + 1)" }
        $attempt++
    } else {
        if ($Debug) { Write-Output "[DEBUG] SFC scan completed successfully with no errors." }
        break
    }
}

# Output completion message
if ($sfcScanExitCode -eq 0) {
    Write-Output "System checks completed successfully. No more errors found."
    if ($Debug) { Write-Output "[DEBUG] System checks finished without any errors." }
} else {
    Write-Output "System checks completed with errors that could not be fully resolved. Please review the logs for more details."
    if ($Debug) { Write-Output "[DEBUG] System checks finished with unresolved errors. Final Exit Code: $sfcScanExitCode" }
}

# Output final attempt count if debug mode is enabled
if ($Debug) { Write-Output "`n====================== DEBUG INFO ======================" }
if ($Debug) { Write-Output "Script completed with attempt count: $attempt" }

# Pause to allow the user to see the results before closing the terminal
Read-Host -Prompt "Press Enter to exit"
