#Requires -Version 5.1

<#
.SYNOPSIS
Describe the script's primary outcome.

.DESCRIPTION
Describe the work performed, prerequisites, side effects, and output.
State required Windows components, modules, and permissions when applicable.

.PARAMETER TargetName
Identify the target to process. Replace this example parameter as needed.

.EXAMPLE
powershell.exe -NoProfile -File ".\example_script.ps1" -TargetName 'Example'

Describe the outcome of this example after implementing the script.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$TargetName
)

$ErrorActionPreference = 'Stop'

# Replace this guard with the task-specific implementation before use.
throw 'Template only: implement the script before running it.'
