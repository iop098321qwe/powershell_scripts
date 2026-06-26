<#
.SYNOPSIS
Start a target Windows service when it is found stopped.

.DESCRIPTION
Set `$serviceName` to the exact Windows service name that should be started
when it is in the `Stopped` state. This script is designed to be run by a
Windows Scheduled Task using an account that can query and start the service.

How to use this script:
1. Update `$serviceName` below to the exact service name you want to restart.
2. Save the script in a stable path such as `C:\Scripts`.
3. Test it manually from an elevated PowerShell session before scheduling it.
4. Create a Scheduled Task to run it on the interval that makes sense for the
   service.

How to find the target service name:
- Open `services.msc`, open the service's Properties window, and copy the
  value shown as `Service name`.
- Or use PowerShell commands such as `Get-Service -Name *partial-name*` or
  `Get-Service -DisplayName *partial-name*` to locate the service.
- The PowerShell service name can differ from the display name shown in the
  Services console.

How to create a Scheduled Task:
1. Open Task Scheduler and choose `Create Task`.
2. On `General`, choose an account that has permission to start the service.
   Enable `Run whether user is logged on or not` and `Run with highest
   privileges` if your environment requires it.
3. On `Triggers`, create the schedule you want, such as every 5 minutes.
4. On `Actions`, choose `Start a program`.
   Program/script: `powershell.exe`
   Add arguments: `-NoProfile -ExecutionPolicy Bypass -File
   "C:\Scripts\scheduled_task_service_restarter.ps1"`
5. Save the task, then use `Run` in Task Scheduler to test it.

Manual test example:
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File
"C:\Scripts\scheduled_task_service_restarter.ps1"`

.NOTES
If the service is already running, the script exits without changing it.
Update `$serviceName` if the service instance or tenant suffix changes.
#>

# Set this to the exact Windows service name, not the display name.
$serviceName = 'CaselleWebService$aleutianseastborough'

$service = Get-Service -Name $serviceName -ErrorAction Stop
if ($service.Status -eq 'Stopped') {
    Start-Service -Name $serviceName -ErrorAction Stop
}
