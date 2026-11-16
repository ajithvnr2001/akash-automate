<#
.SYNOPSIS
    Show active Akash deployments with endpoints and cost.

.EXAMPLE
    $env:AKASH_API_KEY = "ac.sk.production...."
    .\status.ps1
#>
[CmdletBinding()]
param(
    [string]$AkashApiKey,
    [string]$Account
)

$ErrorActionPreference = 'Stop'
$API = 'https://console-api.akash.network'

$apiKey = $null
if ($AkashApiKey) {
    $apiKey = $AkashApiKey.Trim()
} elseif ($Account) {
    $acctFile = Join-Path $PSScriptRoot "state\api-key-$Account.txt"
    if (Test-Path $acctFile) { $apiKey = (Get-Content $acctFile -Raw).Trim() }
    else { throw "Account API key file not found: $acctFile" }
} elseif ($env:AKASH_API_KEY) {
    $apiKey = $env:AKASH_API_KEY.Trim()
} else {
    $keyFile = Join-Path $PSScriptRoot 'state\api-key.txt'
    if (Test-Path $keyFile) { $apiKey = (Get-Content $keyFile -Raw).Trim() }
}

if (-not $apiKey) { throw 'No Akash API key found. Pass -AkashApiKey "ac.sk...", -Account <name>, or set $env:AKASH_API_KEY' }
$headers = @{ 'x-api-key' = $apiKey }

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
