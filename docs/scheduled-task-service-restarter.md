# Scheduled Task Service Restarter

`scheduled_task_service_restarter.ps1` checks one Windows service and starts
it only when its status is `Stopped`. It is intended to be run by Windows
Task Scheduler on a recurring interval.

## Find the Service Name

Use the exact Windows service name, not the display name.

1. Open `services.msc`.
2. Find the service you want to monitor and open its Properties window.
3. Copy the value shown as `Service name`.

You can also search from PowerShell:

```powershell
Get-Service -Name '*Caselle*'
Get-Service -DisplayName '*Caselle*'
```

Use the `Name` value returned by PowerShell in the script. For services with
tenant or instance suffixes, include the full value, such as
`CaselleWebService$aleutianseastborough`.

## Update the Script

1. Open `scheduled_task_service_restarter.ps1`.
2. Set `$serviceName` to the exact service name you found.
3. Save the script in a stable location such as
   `C:\Scripts\scheduled_task_service_restarter.ps1`.

## Test the Script Manually

Before scheduling the script, run it manually from an elevated PowerShell
session or from the same account that the task will use.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\scheduled_task_service_restarter.ps1"
```

If the service is already running, the script exits without changing it. To
confirm the restart path, stop the service first, then run the script again.

## Create a Scheduled Task in Task Scheduler

1. Open Task Scheduler and select `Create Task`.
2. On `General`, give the task a clear name and choose an account that has
   permission to start the service.
3. Enable `Run whether user is logged on or not`.
4. Enable `Run with highest privileges` if the environment requires it.
5. On `Triggers`, add the schedule you want. A common starting point is every
   5 minutes.
6. On `Actions`, choose `Start a program` and use the following values:

```text
Program/script: powershell.exe
Add arguments: -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\scheduled_task_service_restarter.ps1"
Start in: C:\Scripts
```

7. Review `Conditions` and `Settings` for anything specific to the server.
8. Save the task and provide credentials if Task Scheduler prompts for them.
9. Use `Run` from Task Scheduler to verify the task starts the service when it
   is stopped.

## Troubleshooting

1. If the task runs but the service does not start, verify that the task's
   account has permission to start that service.
2. If PowerShell cannot find the service, confirm you used the service name,
   not the display name.
3. If the script path contains spaces, keep the `-File` path wrapped in
   double quotes.
4. If execution policy blocks the script, confirm the task action includes
   `-ExecutionPolicy Bypass`, or use your organization's approved script
   signing process.
