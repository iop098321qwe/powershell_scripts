$serviceName = 'CaselleWebService$aleutianseastborough'

$service = Get-Service -Name $serviceName -ErrorAction Stop
if ($service.Status -eq 'Stopped') {
    Start-Service -Name $serviceName -ErrorAction Stop
}
