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

.PARAMETER Log
    Switch parameter to enable logging of all script output to a log file.
    When enabled, the script output will be logged to a file named "corruption_checker-YYYY-MM-DD-HH-mm.log".

.VERSION
    v1.0.8

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
    [switch]$Log,              # Switch parameter to enable logging to a file
    [int]$MaxAttempts = 2      # Parameter to specify the maximum number of retry attempts
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

# Set up logging if Log switch is enabled
$logFile = $null
if ($Log) {
    $timestamp = Get-Date -Format "yyyy-MM-dd-HH-mm"
    $logFile = "corruption_checker-$timestamp.log"
    Start-Transcript -Path $logFile -Append
}

# Function to output and log messages
function Write-Log {
    param (
        [string]$message
    )
    Write-Output $message
    if ($Log) {
        Add-Content -Path $logFile -Value $message
    }
}

# Function to execute DISM commands
function Execute-DISM {
    param (
        [string]$Arguments
    )
    if ($DebugMode) {
        Write-Log "[DEBUG] Executing Command: DISM $Arguments"
        Write-Log "[DEBUG] Start Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    }
    $output = & DISM $Arguments
    $exitCode = $LASTEXITCODE
    if ($DebugMode) {
        Write-Log "$output"
        Write-Log "[DEBUG] DISM Command Exit Code: $exitCode"
        Write-Log "[DEBUG] End Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        Write-Log "----------------------------------------------------------"
    }
    return @{ Output = $output; ExitCode = $exitCode }
}

# Initialize the attempt counter
$attempt = 0

# Loop to perform system checks and repairs
while ($attempt -lt $MaxAttempts) {
    # Output the current attempt number if debug mode is enabled
    if ($DebugMode) {
        Write-Log "`n====================== DEBUG INFO ======================"
        Write-Log "Attempt Number: $attempt"
        Write-Log "Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        Write-Log "----------------------------------------------------------"
    }

    # Run DISM ScanHealth to check the health of the system image
    Write-Log "Running DISM to perform ScanHealth..."
    $scanHealthResult = Execute-DISM '/Online /Cleanup-Image /ScanHealth'
    $scanHealthExitCode = $scanHealthResult.ExitCode

    # Handle ScanHealth results
    if ($scanHealthExitCode -eq 87) {
        Write-Log "Invalid command line argument detected during ScanHealth. Please verify DISM parameters."
        if ($DebugMode) {
            Write-Log "[DEBUG] Exiting with code 87 due to invalid DISM argument."
            Write-Log "[DEBUG] Detailed Exit Code Information: Invalid DISM parameters provided."
        }
        if ($Log) { Stop-Transcript }
        exit 87
    } elseif ($scanHealthExitCode -eq 0) {
        Write-Log "No component store corruption detected during ScanHealth."
        if ($DebugMode) {
            Write-Log "[DEBUG] ScanHealth completed successfully with no errors."
            Write-Log "[DEBUG] DISM operation completed successfully. No repairs needed."
        }
    } elseif ($scanHealthExitCode -eq 1) {
        Write-Log "Component store corruption detected during ScanHealth. Attempting to repair..."
        $restoreHealthResult = Execute-DISM '/Online /Cleanup-Image /RestoreHealth'
        $restoreHealthExitCode = $restoreHealthResult.ExitCode

        if ($restoreHealthExitCode -ne 0) {
            Write-Log "RestoreHealth failed with exit code: $restoreHealthExitCode."
            Write-Log "[ERROR] Detailed failure information: The DISM RestoreHealth command encountered an issue that could not be resolved automatically. Exit code: $restoreHealthExitCode. Possible causes may include corrupted system files that require manual intervention, insufficient permissions, or a missing source for component repair. Please review the output for more details and consider checking the DISM log file at C:\Windows\Logs\DISM\dism.log."
            Write-Log "Would you like to manually intervene to attempt resolving the issue? (y/n)"
            $userInput = Read-Host "Enter your choice"
            if ($userInput -eq 'y') {
                Write-Log "Please take appropriate manual steps to resolve the issue. After completing, press Enter to continue."
                Read-Host -Prompt "Press Enter to continue after manual intervention"
            } else {
                Write-Log "Exiting due to unresolved RestoreHealth failure."
                if ($Log) { Stop-Transcript }
                exit $restoreHealthExitCode
            }
        }
    } else {
        Write-Log "Unexpected exit code ($scanHealthExitCode) received from DISM ScanHealth."
        Write-Log "[ERROR] Detailed failure information: The DISM ScanHealth command returned an unexpected exit code: $scanHealthExitCode. Possible causes may include corrupted system files that require manual intervention, insufficient permissions, or system instability. Please review the output for more details and consider checking the DISM log file at C:\Windows\Logs\DISM\dism.log."
        Write-Log "Would you like to manually intervene to attempt resolving the issue? (y/n)"
        $userInput = Read-Host "Enter your choice"
        if ($userInput -eq 'y') {
            Write-Log "Please take appropriate manual steps to resolve the issue. After completing, press Enter to continue."
            Read-Host -Prompt "Press Enter to continue after manual intervention"
        } else {
            Write-Log "Exiting due to unexpected ScanHealth failure."
            if ($Log) { Stop-Transcript }
            exit $scanHealthExitCode
        }
    }

    # Run DISM CheckHealth to verify the integrity of the system image after repairs
    Write-Log "Running DISM to perform CheckHealth..."
    $checkHealthResult = Execute-DISM '/Online /Cleanup-Image /CheckHealth'
    $checkHealthExitCode = $checkHealthResult.ExitCode

    # Handle CheckHealth results
    if ($checkHealthExitCode -eq 0) {
        Write-Log "No component store corruption detected during CheckHealth."
        if ($DebugMode) {
            Write-Log "[DEBUG] CheckHealth completed successfully with no errors."
        }
    } elseif ($checkHealthExitCode -eq 87) {
        Write-Log "Invalid command line argument detected during CheckHealth. Please verify DISM parameters."
        if ($DebugMode) {
            Write-Log "[DEBUG] Exiting with code 87 due to invalid DISM argument."
            Write-Log "[DEBUG] Detailed Exit Code Information: Invalid DISM parameters provided."
        }
        if ($Log) { Stop-Transcript }
        exit 87
    } elseif ($checkHealthExitCode -eq 1) {
        Write-Log "Component store corruption detected during CheckHealth. Attempting to repair..."
        $restoreHealthResult = Execute-DISM '/Online /Cleanup-Image /RestoreHealth'
        $restoreHealthExitCode = $restoreHealthResult.ExitCode

        if ($restoreHealthExitCode -ne 0) {
            Write-Log "RestoreHealth failed with exit code: $restoreHealthExitCode."
            Write-Log "[ERROR] Detailed failure information: The DISM RestoreHealth command encountered an issue that could not be resolved automatically. Exit code: $restoreHealthExitCode. Possible causes may include corrupted system files that require manual intervention, insufficient permissions, or a missing source for component repair. Please review the output for more details and consider checking the DISM log file at C:\Windows\Logs\DISM\dism.log."
            Write-Log "Would you like to manually intervene to attempt resolving the issue? (y/n)"
            $userInput = Read-Host "Enter your choice"
            if ($userInput -eq 'y') {
                Write-Log "Please take appropriate manual steps to resolve the issue. After completing, press Enter to continue."
                Read-Host -Prompt "Press Enter to continue after manual intervention"
            } else {
                Write-Log "Exiting due to unresolved RestoreHealth failure."
                if ($Log) { Stop-Transcript }
                exit $restoreHealthExitCode
            }
        }
    }

    # Run SFC to check and repair system files
    Write-Log "Running SFC to check and repair system files..."
    if ($DebugMode) {
        Write-Log "[DEBUG] Executing Command: sfc /scannow"
        Write-Log "[DEBUG] Start Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    }
    $sfcScanOutput = & sfc /scannow
    $sfcScanExitCode = $LASTEXITCODE

    if ($DebugMode) {
        Write-Log "$sfcScanOutput"
        Write-Log "[DEBUG] SFC Scan Exit Code: $sfcScanExitCode"
        Write-Log "[DEBUG] End Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        Write-Log "----------------------------------------------------------"
    }

    # Handle SFC results
    if ($sfcScanExitCode -ne 0) {
        Write-Log "Errors found during SFC scan (Exit Code: $sfcScanExitCode). Repeating the process once..."
        if ($DebugMode) {
            Write-Log "[DEBUG] Incrementing attempt counter and retrying. Attempt: $($attempt + 1)"
            Write-Log "[DEBUG] Detailed Exit Code Information: SFC encountered issues that could not be automatically repaired."
        }
        $attempt++
    } else {
        if ($DebugMode) { Write-Log "[DEBUG] SFC scan completed successfully with no errors." }
        break
    }
}

# Output completion message
if ($sfcScanExitCode -eq 0) {
    Write-Log "System checks completed successfully. No more errors found."
    if ($DebugMode) { Write-Log "[DEBUG] System checks finished without any errors." }
} else {
    Write-Log "System checks completed with errors that could not be fully resolved. Please review the logs for more details."
    if ($DebugMode) { Write-Log "[DEBUG] System checks finished with unresolved errors. Final Exit Code: $sfcScanExitCode" }
}

# Stop logging if enabled
if ($Log) { Stop-Transcript }

