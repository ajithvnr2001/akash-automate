<#
.SYNOPSIS
    Show active Akash deployments with endpoints and cost.

.EXAMPLE
    $env:AKASH_API_KEY = "ac.sk.production...."
    .\status.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$API = 'https://console-api.akash.network'

# Fall back to the saved key so a fresh shell does not have to re-export it.
$keyFile = Join-Path $PSScriptRoot 'state\api-key.txt'
if (-not $env:AKASH_API_KEY -and (Test-Path $keyFile)) {
    $env:AKASH_API_KEY = (Get-Content $keyFile -Raw).Trim()
}

if (-not $env:AKASH_API_KEY) { throw 'AKASH_API_KEY is not set.' }
$headers = @{ 'x-api-key' = $env:AKASH_API_KEY }

$bal = (Invoke-RestMethod -Uri "$API/v1/balances" -Headers $headers).data

$active = (Invoke-RestMethod -Uri "$API/v1/deployments?state=active&limit=100" -Headers $headers).data.deployments
Write-Host ("Balance: {0:N0} uact available, {1:N0} in escrow ({2} active deployment(s))" -f $bal.balance, $bal.deployments, @($active).Count) -ForegroundColor Cyan
if ($active.Count -eq 0) {
    Write-Host 'No active deployments.' -ForegroundColor Yellow
    return
}

foreach ($d in $active) {
    $id = $d.deployment.id.dseq
    $detail = Invoke-RestMethod -Uri "$API/v1/deployments/$id" -Headers $headers
    $lease = $detail.data.leases[0]

    $price = if ($lease) { [double]$lease.price.amount } else { 0 }
    $perDay = if ($price) { [math]::Round($price * 11520 / 1e6, 2) } else { 0 }

    $endpoint = 'n/a'
    $healthy = 'unknown'
    if ($lease -and $lease.status) {
        $fp = $lease.status.forwarded_ports.vm
        if ($fp -and $fp.Count -gt 0) { $endpoint = "$($fp[0].host):$($fp[0].externalPort)" }
        $svc = $lease.status.services.vm
        if ($svc) { $healthy = "$($svc.available)/$($svc.total)" }
    }

    Write-Host ''
    Write-Host "  $id  $($d.name)" -ForegroundColor Green
    Write-Host "    provider : $($lease.id.provider)"
    Write-Host "    endpoint : $endpoint"
    Write-Host "    healthy  : $healthy"
    Write-Host ("    price    : {0:N2} uact/block (~`${1}/day)" -f $price, $perDay)
    if ($endpoint -ne 'n/a') {
        $parts = $endpoint.Split(':')
        Write-Host "    connect  : ssh -i `"$PSScriptRoot\keys\akash_vm_ed25519`" -p $($parts[1]) root@$($parts[0])" -ForegroundColor Cyan
    }
}
