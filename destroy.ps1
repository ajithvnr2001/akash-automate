<#
.SYNOPSIS
    Close all active Akash deployments and verify the account is empty.

.DESCRIPTION
    The Console API sometimes answers success:true for a close that did not
    take effect. This script re-checks and retries until nothing is active,
    rather than trusting the first success flag.
#>
[CmdletBinding()]
param(
    [int]$MaxRounds = 5
)

$ErrorActionPreference = 'Stop'
$API = 'https://console-api.akash.network'

# Fall back to the saved key so a fresh shell does not have to re-export it.
$keyFile = Join-Path $PSScriptRoot 'state\api-key.txt'
if (-not $env:AKASH_API_KEY -and (Test-Path $keyFile)) {
    $env:AKASH_API_KEY = (Get-Content $keyFile -Raw).Trim()
}

if (-not $env:AKASH_API_KEY) { throw 'AKASH_API_KEY is not set.' }
$headers = @{ 'x-api-key' = $env:AKASH_API_KEY }

function Get-Active {
    (Invoke-RestMethod -Uri "$API/v1/deployments?state=active&limit=100" -Headers $headers).data.deployments
}

$active = @(Get-Active)
if ($active.Count -eq 0) {
    Write-Host 'No active deployments. Nothing to do.' -ForegroundColor Yellow
}
else {
    Write-Host "Closing $($active.Count) deployment(s)..." -ForegroundColor Cyan
}

for ($round = 1; $round -le $MaxRounds; $round++) {
    $active = @(Get-Active)
    if ($active.Count -eq 0) { break }

    foreach ($d in $active) {
        $id = $d.deployment.id.dseq
        try {
            $r = Invoke-RestMethod -Uri "$API/v1/deployments/$id" -Method Delete -Headers $headers
            Write-Host "  round $round : closed $id ($($d.name)) success=$($r.data.success)"
        }
        catch {
            Write-Host "  round $round : close $id failed - $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    Start-Sleep -Seconds 10
}

$final = Get-Active
if ($final.Count -gt 0) {
    $ids = ($final | ForEach-Object { $_.deployment.id.dseq }) -join ', '
    Write-Host "STILL ACTIVE after $MaxRounds rounds: $ids" -ForegroundColor Red
    Write-Host 'These may need closing from the Console UI.' -ForegroundColor Red
    exit 1
}

Write-Host 'All deployments closed.' -ForegroundColor Green
$bal = (Invoke-RestMethod -Uri "$API/v1/balances" -Headers $headers).data
Write-Host ("Balance: {0:N0} uact available, {1:N0} in escrow" -f $bal.balance, $bal.deployments) -ForegroundColor Cyan

# Clean up closed deployment keys from keys\
$keyDir = Join-Path $PSScriptRoot 'keys'
if (Test-Path $keyDir) {
    $removedKeys = Get-ChildItem -Path $keyDir -File | Where-Object { $_.Name -match '^\d+\.(ppk|openssh)$' }
    if ($removedKeys.Count -gt 0) {
        $removedKeys | Remove-Item -Force
        Write-Host "Cleaned $($removedKeys.Count) old deployment key(s) from keys\" -ForegroundColor Green
    }
}

# Clean up closed deployment state files from state\
$stateDir = Join-Path $PSScriptRoot 'state'
if (Test-Path $stateDir) {
    $removedState = Get-ChildItem -Path $stateDir -File | Where-Object { $_.Name -match '^\d+\.(json|ssh)$' }
    if ($removedState.Count -gt 0) {
        $removedState | Remove-Item -Force
        Write-Host "Cleaned $($removedState.Count) old deployment state file(s) from state\" -ForegroundColor Green
    }
}
