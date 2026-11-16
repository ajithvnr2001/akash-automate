<#
.SYNOPSIS
    Execute a local shell script on the running Akash box over SSH.

.DESCRIPTION
    Normalizes line endings, base64-encodes the script, and executes via bash as root.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$HostName,
    [Parameter(Mandatory)][int]$Port,
    [Parameter(Mandatory)][string]$ScriptPath,
    [string]$User = 'root',
    [string]$KeyPath = ''
)

$ErrorActionPreference = 'Stop'

if (-not $KeyPath) {
    $KeyPath = Join-Path $PSScriptRoot 'keys\akash_vm_ed25519'
}

if (-not (Test-Path $ScriptPath)) {
    throw "Script not found: $ScriptPath"
}
if (-not (Test-Path $KeyPath)) {
    throw "SSH key not found: $KeyPath"
}

# Read as raw text and normalise to LF so bash never sees CRLF.
$script = ([System.IO.File]::ReadAllText($ScriptPath)) -replace "`r`n", "`n" -replace "`r", "`n"
$bytes = [System.Text.Encoding]::UTF8.GetBytes($script)
$enc = [Convert]::ToBase64String($bytes)

# Avoid heredocs and quoting entirely: ship the script base64-encoded.
$oneLiner = "echo $enc | base64 -d | bash"

& ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o ConnectTimeout=25 `
    -i $KeyPath -p $Port "$User@$HostName" $oneLiner
