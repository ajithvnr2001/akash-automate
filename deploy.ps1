<#
.SYNOPSIS
    Provision an Akash container with agent tooling, end to end.

.DESCRIPTION
    1. Generates an SSH keypair (and optionally a PuTTY .ppk)
    2. Renders the SDL with the pubkey + bootstrap script baked in
    3. Creates the deployment, polls bids, accepts the cheapest
    4. Waits for readiness, prints connection details
    5. Writes everything to state\

.PARAMETER KeepDeployment
    Do not fail if a deployment is already active. By default the script
    refuses, because escrow means only one deployment can be funded.

.PARAMETER AllowAllProviders
    Do not skip the providers known to fail port forwarding.

.EXAMPLE
    # 1. Simple deploy using saved key:
    .\deploy.ps1

    # 2. One-click deploy using a specific Akash API key:
    .\deploy.ps1 -AkashApiKey "ac.sk.production...."

    # 3. One-click deploy injecting different AI/Cloud APIs:
    .\deploy.ps1 -ApiKeys @{
        ANTHROPIC_API_KEY = "sk-ant-..."
        OPENAI_API_KEY    = "sk-proj-..."
        DEEPSEEK_API_KEY  = "sk-..."
        GEMINI_API_KEY    = "AIzaSy..."
    }

    # 4. One-click deploy auto-loading all APIs from a .env file:
    .\deploy.ps1 -EnvFile ".\.env"
#>
[CmdletBinding()]
param(
    [string]$AkashApiKey,
    [string]$Account,
    [hashtable]$ApiKeys = @{},
    [string]$EnvFile,
    [double]$Cpu = 4.0,
    [string]$Memory = '16Gi',
    [string]$Storage = '250Gi',
    [int]$RuntimeLimitHours = 24,
    [string]$Name = 'akash-agent-box',
    [switch]$AllowAllProviders,
    [switch]$KeepDeployment,
    [switch]$SkipPpk
)

$ErrorActionPreference = 'Stop'
$API = 'https://console-api.akash.network'

# Providers that served healthy containers without forwarding the SSH port,
# or that repeatedly refuse to accept manifests (502 on every lease attempt).
$DenyList = @(
    'akash1s3hq36mpas4nmkqasn7fgwhs9968cgl3u5esnw'  # provider.froggy-servers.com - never forwards port
    'akash1sevd2ymtty3dpq9ycxgkhuzzk4fe6mchqdwd4e'  # provider.jjozzietech.com.au - never forwards port
    'akash1dudfnsqwfecytfqxwvnfc7eqc5ca429zfkhwyd'  # 502 on every manifest delivery
)

# ------------------------------------------------------------------ helpers
$StateDir = Join-Path $PSScriptRoot 'state'
$LogDir   = Join-Path $PSScriptRoot 'logs'
$KeyDir   = Join-Path $PSScriptRoot 'keys'
foreach ($d in @($StateDir, $LogDir, $KeyDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    $color = switch ($Level) { 'ERROR' { 'Red' } 'WARN' { 'Yellow' } 'OK' { 'Green' } default { 'Gray' } }
    Write-Host $line -ForegroundColor $color
    Add-Content -Path (Join-Path $LogDir 'deploy.log') -Value $line
}

function Get-ApiKey {
    if ($AkashApiKey) {
        return $AkashApiKey.Trim()
    }
    if ($Account) {
        $acctFile = Join-Path $StateDir "api-key-$Account.txt"
        if (Test-Path $acctFile) {
            return (Get-Content $acctFile -Raw).Trim()
        }
        throw "Account API key file not found: $acctFile"
    }
    if ($env:AKASH_API_KEY) {
        return $env:AKASH_API_KEY.Trim()
    }
    # Persisted fallback so a fresh shell does not have to re-export it.
    $keyFile = Join-Path $StateDir 'api-key.txt'
    if (Test-Path $keyFile) {
        return (Get-Content $keyFile -Raw).Trim()
    }
    throw 'No Akash API key found. Pass -AkashApiKey "ac.sk...", -Account <name>, set $env:AKASH_API_KEY, or save to state\api-key.txt'
}

function Invoke-AkashApi {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Method = 'GET',
        $Body = $null
    )
    $params = @{
        Uri         = "$API$Path"
        Method      = $Method
        Headers     = @{ 'x-api-key' = (Get-ApiKey) }
        ContentType = 'application/json'
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body) {
        $params.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 12 }
    }
    try {
        return Invoke-RestMethod @params
    }
    catch {
        $detail = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $raw = $_.ErrorDetails.Message
            try {
                $err = $raw | ConvertFrom-Json
                $detail = "{0} (code={1})" -f $err.message, $err.code
            } catch {
                # Non-JSON body (e.g. plain "error code: 502"): keep it verbatim.
                $detail = "$detail | body: $($raw -replace '\s+', ' ')".Trim()
            }
        }
        throw "API $Method $Path failed: $detail"
    }
}

# ------------------------------------------------------------------ preflight
Write-Log 'Preflight checks'

$null = Get-ApiKey

$active = (Invoke-AkashApi -Path '/v1/deployments?state=active&limit=100').data.deployments
if ($active.Count -gt 0 -and -not $KeepDeployment) {
    $ids = ($active | ForEach-Object { $_.deployment.id.dseq }) -join ', '
    throw "Already have $($active.Count) active deployment(s): $ids. Run .\destroy.ps1 first, or pass -KeepDeployment."
}

$bal = (Invoke-AkashApi -Path '/v1/balances').data
Write-Log ("Balance {0:N0} uact, escrow {1:N0}, total {2:N0}" -f $bal.balance, $bal.deployments, $bal.total)

if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
    throw 'ssh-keygen not found. Install the Windows OpenSSH Client feature.'
}

# ------------------------------------------------------------------ keypair
$KeyName = 'akash_vm_ed25519'
$KeyPath = Join-Path $KeyDir $KeyName
$PubPath = "$KeyPath.pub"

if (Test-Path $KeyPath) {
    Write-Log "Reusing existing key $KeyName"
} else {
    Write-Log "Generating SSH keypair $KeyName"
    # No passphrase: unattended use. The key is a throwaway for a throwaway box.
    $null = & ssh-keygen -t ed25519 -f $KeyPath -N '""' -C 'akash-automate' 2>&1
    if (-not (Test-Path $KeyPath)) { throw "ssh-keygen failed to create $KeyPath" }
    Write-Log 'Keypair created' 'OK'
}

$pubKey = (Get-Content $PubPath -Raw).Trim()
if (-not $pubKey.StartsWith('ssh-ed25519')) {
    throw "Unexpected public key format in $PubPath"
}

# ------------------------------------------------------------------ password
$chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
$rand = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$bytes = New-Object byte[] 32
$rand.GetBytes($bytes)
$password = -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
Write-Log 'Generated 32-char SSH password (not shown; written to state\)'

# ------------------------------------------------------------------ SDL
Write-Log 'Rendering SDL'
$sdl = & (Join-Path $PSScriptRoot 'render-sdl.ps1') `
    -PublicKey $pubKey `
    -Password $password `
    -Cpu $Cpu -Memory $Memory -Storage $Storage

$sdlPath = Join-Path $StateDir 'rendered.sdl.yaml'
[System.IO.File]::WriteAllText($sdlPath, $sdl)
Write-Log "SDL written to $sdlPath"

# ------------------------------------------------------------------ create
Write-Log 'Creating deployment'
$createBody = @{
    data = @{
        sdl               = [string]$sdl
        name              = $Name
        runtimeLimitHours = $RuntimeLimitHours
    }
}
$created = Invoke-AkashApi -Path '/v1/deployments' -Method POST -Body $createBody
$dseq = $created.data.dseq
Write-Log "Deployment created: dseq=$dseq" 'OK'

# ------------------------------------------------------------------ bids
Write-Log 'Waiting for bids (up to 2 min)'
$bids = $null
for ($i = 1; $i -le 24; $i++) {
    $bids = Invoke-AkashApi -Path "/v1/bids?dseq=$dseq"
    $open = @($bids.data | Where-Object { $_.bid.state -eq 'open' })
    if ($open.Count -gt 0) { break }
    Start-Sleep -Seconds 5
}

$open = @($bids.data | Where-Object { $_.bid.state -eq 'open' })
if ($open.Count -eq 0) {
    Write-Log "No bids received. Closing $dseq." 'ERROR'
    Invoke-AkashApi -Path "/v1/deployments/$dseq" -Method DELETE | Out-Null
    throw 'No provider bid on this SDL. Resources may be too large or price too low.'
}
Write-Log "$($open.Count) open bid(s)"

if (-not $AllowAllProviders) {
    $filtered = @($open | Where-Object { $DenyList -notcontains $_.bid.id.provider })
    if ($filtered.Count -gt 0) {
        $skipped = $open.Count - $filtered.Count
        if ($skipped -gt 0) { Write-Log "Skipped $skipped bid(s) from known-bad providers" 'WARN' }
        $open = $filtered
    } else {
        Write-Log 'All bids are from known-bad providers; using them anyway' 'WARN'
    }
}

$sorted = @($open | Sort-Object { [double]$_.bid.price.amount })

# ------------------------------------------------------------------ lease
# Try bids cheapest-first. A provider can accept the lease but fail to take the
# manifest (502 manifest_not_delivered), in which case no workload starts. Move
# to the next bid rather than aborting the whole run.
$leaseOk = $false
$chosen = $null
$attempts = 0
foreach ($candidate in $sorted) {
    $attempts++
    $provider = $candidate.bid.id.provider
    $price = [double]$candidate.bid.price.amount
    $perDay = [math]::Round($price * 11520 / 1e6, 2)
    Write-Log ("Bid {0}/{1}: {2} @ {3:N2} uact/block (~`${4}/day)" -f $attempts, $sorted.Count, $provider, $price, $perDay)

    $leaseBody = @{
        leases = @(@{
            dseq     = [string]$candidate.bid.id.dseq
            gseq     = [int]$candidate.bid.id.gseq
            oseq     = [int]$candidate.bid.id.oseq
            provider = [string]$provider
        })
    }

    try {
        $lease = Invoke-AkashApi -Path '/v1/leases' -Method POST -Body $leaseBody
        Write-Log "Lease active" 'OK'
        $leaseOk = $true
        $chosen = $candidate
        break
    }
    catch {
        Write-Log "Lease attempt failed: $($_.Exception.Message)" 'WARN'

        # The lease may exist even though the manifest was refused. Check, and
        # if a lease exists without a status, the manifest never landed - close
        # the deployment and retry with a fresh one is not possible (escrow), so
        # this deployment is considered dead for this provider.
        Start-Sleep -Seconds 4
        try {
            $check = Invoke-AkashApi -Path "/v1/deployments/$dseq"
            $hasLease = ($check.data.leases.Count -gt 0)
        } catch {
            $hasLease = $false
        }

        if ($hasLease) {
            Write-Log 'Lease exists but manifest not delivered; retrying once' 'WARN'
            try {
                $lease = Invoke-AkashApi -Path '/v1/leases' -Method POST -Body $leaseBody
                Write-Log 'Manifest delivered on retry' 'OK'
                $leaseOk = $true
                $chosen = $candidate
                break
            }
            catch {
                Write-Log 'Provider refused the manifest again' 'ERROR'
                # Once a lease exists for this dseq, another bid cannot be taken.
                Write-Log 'A lease is bound to this deployment; closing it and stopping.' 'ERROR'
                Invoke-AkashApi -Path "/v1/deployments/$dseq" -Method DELETE | Out-Null
                throw "Provider $provider accepted the lease but rejected the manifest. Deployment closed. Re-run to get a different provider."
            }
        }
        else {
            Write-Log 'No lease created; trying next bid' 'WARN'
        }
    }
}

if (-not $leaseOk) {
    Invoke-AkashApi -Path "/v1/deployments/$dseq" -Method DELETE | Out-Null
    throw 'No bid could be leased successfully. Deployment closed.'
}

$provider = $chosen.bid.id.provider
$price = [double]$chosen.bid.price.amount
$perDay = [math]::Round($price * 11520 / 1e6, 2)

# ------------------------------------------------------------------ ready
Write-Log 'Waiting for service readiness (up to 5 min)'
$endpoint = $null
$ready = $false
for ($i = 1; $i -le 50; $i++) {
    $dep = Invoke-AkashApi -Path "/v1/deployments/$dseq"
    $leaseObj = $dep.data.leases[0]
    $svc = $leaseObj.status.services.vm
    if ($svc -and $svc.available -ge 1) {
        $fp = $leaseObj.status.forwarded_ports.vm
        if ($fp -and $fp.Count -gt 0) {
            $endpoint = $fp[0]
            $ready = $true
            Write-Log ("Service available after ~{0}s" -f ($i * 6)) 'OK'
            break
        }
    }
    Start-Sleep -Seconds 6
}

if (-not $ready) {
    Write-Log 'Service did not become ready with a forwarded port.' 'ERROR'
    Write-Log "Deployment $dseq left running so you can inspect: .\status.ps1" 'WARN'
    throw 'Readiness timeout.'
}

# ------------------------------------------------------------------ port check
Write-Log 'Verifying the SSH port is reachable from here'
$reachable = $false
for ($i = 1; $i -le 6; $i++) {
    $reachable = Test-NetConnection -ComputerName $endpoint.host -Port $endpoint.externalPort `
        -InformationLevel Quiet -WarningAction SilentlyContinue
    if ($reachable) { break }
    Start-Sleep -Seconds 10
}
if ($reachable) {
    Write-Log 'Port 22 forwarded and reachable' 'OK'
} else {
    Write-Log 'Port NOT reachable. Deployment is up but the provider is not forwarding.' 'WARN'
    Write-Log 'Run .\destroy.ps1 and re-deploy to get a different provider.' 'WARN'
}

# ------------------------------------------------------------------ ppk
# The Windows puttygen.exe launches a GUI for every argument combination and
# cannot be scripted (verified: -O/-o/--version all just open a window and
# hang, leaving stray processes). Write the PPK v2 directly instead.
$ppkPath = $null
$copyPath = $null
if (-not $SkipPpk) {
    $ppkPath = Join-Path $KeyDir "$dseq.ppk"
    try {
        $null = & (Join-Path $PSScriptRoot 'new-ppk.ps1') `
            -OpenSshKeyPath $KeyPath -OutputPath $ppkPath
        if (Test-Path $ppkPath) {
            $size = (Get-Item $ppkPath).Length
            Write-Log "PPK written: $ppkPath ($size bytes)" 'OK'
        } else {
            Write-Log 'PPK generation produced no file' 'WARN'
            $ppkPath = $null
        }
    } catch {
        Write-Log "PPK generation failed: $($_.Exception.Message)" 'WARN'
        $ppkPath = $null
    }

    # Always copy the OpenSSH private key alongside the PPK so PuTTY users can
    # import either one.
    $copyPath = Join-Path $KeyDir "$dseq.openssh"
    Copy-Item -Path $KeyPath -Destination $copyPath -Force
    Write-Log "OpenSSH key copied to $copyPath"
}

# ------------------------------------------------------------------ state
$state = [ordered]@{
    dseq         = $dseq
    name         = $Name
    host         = $endpoint.host
    port         = $endpoint.externalPort
    username     = 'root'
    password     = $password
    keyPath      = $KeyPath
    ppkPath      = $ppkPath
    opensshKey   = $(if ($copyPath) { $copyPath } else { $null })
    provider     = $chosen.bid.id.provider
    priceUact    = $price
    perDayUsd    = $perDay
    cpu          = $Cpu
    memory       = $Memory
    storage      = $Storage
    createdAt    = (Get-Date).ToString('o')
    sshCommand   = "ssh -i `"$KeyPath`" -p $($endpoint.externalPort) root@$($endpoint.host)"
}
$statePath = Join-Path $StateDir "$dseq.json"
# Set-Content -Encoding UTF8 writes a BOM under PowerShell 5.1, which breaks
# non-PowerShell readers (jq, Python json). Write UTF-8 without a BOM.
[System.IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 5),
    (New-Object System.Text.UTF8Encoding($false)))

$sshConfigPath = Join-Path $StateDir "$dseq.ssh"
$sshConfig = @"
Host akash-$dseq
    HostName $($endpoint.host)
    Port $($endpoint.externalPort)
    User root
    IdentityFile $KeyPath
    StrictHostKeyChecking no
    UserKnownHostsFile NUL
"@
[System.IO.File]::WriteAllText($sshConfigPath, $sshConfig,
    (New-Object System.Text.UTF8Encoding($false)))

# ------------------------------------------------------------------ auto-inject APIs
$envVarsToInject = @{}

# Load from default .env or specified -EnvFile
$autoEnv = if ($EnvFile) { $EnvFile } else { Join-Path $PSScriptRoot '.env' }
if (Test-Path $autoEnv) {
    Write-Log "Reading environment variables from $autoEnv"
    Get-Content $autoEnv | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith('#') -and $line -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
            $val = $Matches[2].Trim()
            if (($val.StartsWith('"') -and $val.EndsWith('"')) -or ($val.StartsWith("'") -and $val.EndsWith("'"))) {
                $val = $val.Substring(1, $val.Length - 2)
            }
            $envVarsToInject[$Matches[1]] = $val
        }
    }
}

# Add from -ApiKeys hashtable (takes precedence)
if ($ApiKeys -and $ApiKeys.Count -gt 0) {
    foreach ($k in $ApiKeys.Keys) {
        $envVarsToInject[$k] = [string]$ApiKeys[$k]
    }
}

if ($envVarsToInject.Count -gt 0) {
    Write-Log "Auto-injecting $($envVarsToInject.Count) API key(s) / environment variable(s) into box..."
    try {
        & (Join-Path $PSScriptRoot 'set-api-keys.ps1') `
            -HostName $endpoint.host `
            -Port $endpoint.externalPort `
            -KeyPath $KeyPath `
            -Vars $envVarsToInject
        Write-Log "API keys successfully loaded into /root/.agent-env and /home/akash/.agent-env" 'OK'
    } catch {
        Write-Log "Warning: Automatic API key injection encountered an issue: $($_.Exception.Message)" 'WARN'
    }
}

# ------------------------------------------------------------------ report
Write-Host ''
Write-Host '================ PROVISIONED ================' -ForegroundColor Green
Write-Host "  Deployment : $dseq"
Write-Host "  Provider   : $($chosen.bid.id.provider)"
Write-Host "  Endpoint   : $($endpoint.host):$($endpoint.externalPort)"
Write-Host "  Username   : root (full root/sudo access; user 'akash' also configured)"
Write-Host "  Spec       : $Cpu CPU / $Memory / $Storage"
Write-Host "  Cost       : $price uact/block (~`$$perDay/day)"
if ($envVarsToInject.ContainsKey('SUPABASE_URL')) {
    Write-Host "  OpenCode DB: Supabase auto-restore & auto-persist enabled ($($envVarsToInject['SUPABASE_URL']))" -ForegroundColor Cyan
}
Write-Host ''
Write-Host '  SSH key    :' -NoNewline
Write-Host " $KeyPath"
if ($ppkPath) { Write-Host '  PuTTY ppk  :' -NoNewline; Write-Host " $ppkPath" } else { Write-Host '  PuTTY ppk  : not generated' -ForegroundColor Yellow }
Write-Host '  Password   :' -NoNewline
Write-Host " stored in $statePath" -ForegroundColor Yellow
Write-Host ''
Write-Host '  Connect:' -NoNewline
Write-Host " $($state.sshCommand)"
Write-Host '=============================================' -ForegroundColor Green
Write-Host ''
Write-Host "Bootstrap installs cloud CLIs (gcloud, aws, az, oci), Python 3, Node & AI agent tools; check progress with:" -ForegroundColor Gray
Write-Host "  ssh ... 'tail -f /var/log/bootstrap.log'" -ForegroundColor Gray
