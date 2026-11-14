<#
.SYNOPSIS
    Push API keys / environment variables into a running Akash box.

.DESCRIPTION
    The box has no root, no systemd and no docker. Secrets can only be given to
    it as files under /config (the one directory that persists across restarts).

    This writes /config/.agent-env, a plain shell fragment of
    `export NAME=value` lines, mode 600. It is sourced automatically by
    /config/.profile so every interactive SSH login already has the variables,
    and by /config/bin/agent-env.

    Existing variables are merged, not replaced: calling this repeatedly with
    different names keeps all of them, and calling it again with the same name
    overwrites that one.

    Values may contain spaces, quotes, $, backticks and backslashes. They are
    transferred base64-encoded and quoted as single-quoted shell strings.

.PARAMETER FromState
    Read host, port and key path from state\<Dseq>.json.

.PARAMETER Dseq
    Deployment sequence number (used with -FromState).

.PARAMETER HostName
    Box host, e.g. provider.h6i-dedicated.eu-se-1.digitalfrontier.so

.PARAMETER Port
    Forwarded SSH port.

.PARAMETER KeyPath
    OpenSSH private key.

.PARAMETER Vars
    Hashtable of NAME = value pairs to set.

.PARAMETER Remove
    Names to delete from the environment file.

.EXAMPLE
    .\set-api-keys.ps1 -FromState -Dseq 1794653723788 -Vars @{
        DEEPSEEK_API_KEY = 'sk-...'
        OPENAI_API_KEY   = 'sk-...'
    }

.EXAMPLE
    .\set-api-keys.ps1 -FromState -Dseq 1794653723788 -Remove DEEPSEEK_API_KEY

.EXAMPLE
    # Explicit host, if you no longer have the state file
    .\set-api-keys.ps1 -HostName provider.example.com -Port 30209 `
        -KeyPath .\keys\akash_vm_ed25519 -Vars @{ ANTHROPIC_API_KEY = 'sk-ant-...' }
#>
[CmdletBinding(DefaultParameterSetName = 'Explicit')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Explicit')]
    [string]$HostName,

    [Parameter(Mandatory, ParameterSetName = 'Explicit')]
    [int]$Port,

    [Parameter(ParameterSetName = 'Explicit')]
    [string]$KeyPath = (Join-Path $PSScriptRoot 'keys\akash_vm_ed25519'),

    [Parameter(Mandatory, ParameterSetName = 'State')]
    [switch]$FromState,

    [Parameter(Mandatory, ParameterSetName = 'State')]
    [string]$Dseq,

    [hashtable]$Vars = @{},

    [string[]]$Remove = @()
)

$ErrorActionPreference = 'Stop'

if (-not $Vars.Count -and -not $Remove.Count) {
    throw 'Nothing to do: pass -Vars, -Remove, or both.'
}

if ($FromState) {
    $statePath = Join-Path $PSScriptRoot "state\$Dseq.json"
    if (-not (Test-Path $statePath)) { throw "No state file: $statePath" }
    $state    = Get-Content $statePath -Raw | ConvertFrom-Json
    $HostName = $state.host
    $Port     = $state.port
    $KeyPath  = $state.keyPath
}

if (-not (Test-Path $KeyPath)) { throw "Key not found: $KeyPath" }

foreach ($name in @($Vars.Keys) + $Remove) {
    if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
        throw "Invalid variable name '$name' (must match [A-Za-z_][A-Za-z0-9_]*)"
    }
}

# ---------------------------------------------------------------- payload
# One base64 line per value keeps every character safe through shell quoting.
# Format: NAME<TAB>base64(value)
$payloadLines = foreach ($name in $Vars.Keys) {
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]$Vars[$name]))
    "$name`t$b64"
}
$payloadB64 = ''
if ($payloadLines) {
    $payloadB64 = [Convert]::ToBase64String(
        [System.Text.Encoding]::UTF8.GetBytes((($payloadLines -join "`n") + "`n")))
}
$removeList = ($Remove -join ' ')

# ---------------------------------------------------------------- remote script
# Kept deliberately simple: plain shell, no nested quoting, base64 for data.
$remote = @'
set -e
mkdir -p /config
ENVF=/config/.agent-env
TMP=/config/.agent-env.tmp

# Start from what is already there.
if [ -f "$ENVF" ]; then cp "$ENVF" "$TMP"; else : > "$TMP"; fi

DROP="__REMOVE__"
for n in $DROP; do
  grep -v "^export $n=" "$TMP" > "$TMP.n" 2>/dev/null || : > "$TMP.n"
  mv -f "$TMP.n" "$TMP"
done

PAYLOAD="__PAYLOAD__"
if [ -n "$PAYLOAD" ]; then
  echo "$PAYLOAD" | base64 -d > /tmp/.envpayload
  while IFS="$(printf '\t')" read -r name b64val; do
    [ -n "$name" ] || continue
    # Drop any previous definition of this name.
    grep -v "^export $name=" "$TMP" > "$TMP.n" 2>/dev/null || : > "$TMP.n"
    mv -f "$TMP.n" "$TMP"
    # Single-quote the value: only ' itself needs escaping.
    val=$(echo "$b64val" | base64 -d)
    esc=$(printf '%s' "$val" | sed "s/'/'\\\\''/g")
    printf "export %s='%s'\n" "$name" "$esc" >> "$TMP"
  done < /tmp/.envpayload
  rm -f /tmp/.envpayload
fi

mv -f "$TMP" "$ENVF"
chmod 600 "$ENVF"
[ -d /home/akash ] && cp -f "$ENVF" /home/akash/.agent-env 2>/dev/null && chown akash:akash /home/akash/.agent-env 2>/dev/null || true

# Ensure interactive logins source it.
for p in /home/akash/.bashrc /root/.bashrc /etc/profile; do
  if [ -f "$p" ]; then
    grep -q 'agent-env' "$p" 2>/dev/null || \
      printf '[ -f /config/.agent-env ] && . /config/.agent-env\n' >> "$p"
  fi
done

echo "--- variables now set (names only) ---"
sed 's/=.*/=<set>/' "$ENVF"
echo "--- values as a fresh login shell sees them ---"
bash -lc '. /config/.agent-env; for n in __NAMES__; do eval "v=\$$n"; printf "%s: [%s]\n" "$n" "$v"; done'
'@

$remote = $remote.Replace('__PAYLOAD__', $payloadB64)
$remote = $remote.Replace('__REMOVE__', $removeList)
$remote = $remote.Replace('__NAMES__', (@($Vars.Keys) -join ' '))
$remote = $remote -replace "`r`n", "`n"

$scriptB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($remote))

Write-Host "Writing to ${HostName}:${Port} ..." -ForegroundColor Cyan

# ssh writes its host-key warning to stderr, which Windows PowerShell would
# turn into a terminating error under $ErrorActionPreference='Stop'.
# Redirect through a temp file instead of 2>&1 to keep this reliable.
$stdoutFile = [System.IO.Path]::GetTempFileName()
$stderrFile = [System.IO.Path]::GetTempFileName()
try {
    $proc = Start-Process -FilePath 'ssh' `
        -ArgumentList @(
            '-o', 'StrictHostKeyChecking=no',
            '-o', 'UserKnownHostsFile=NUL',
            '-o', 'ConnectTimeout=25',
            '-o', 'BatchMode=yes',
            '-i', $KeyPath,
            '-p', "$Port",
            "akash@$HostName",
            "echo $scriptB64 | base64 -d | sh"
        ) `
        -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $stdoutFile `
        -RedirectStandardError $stderrFile

    $out = @(Get-Content $stdoutFile -ErrorAction SilentlyContinue)
    $err = @(Get-Content $stderrFile -ErrorAction SilentlyContinue)

    $out | ForEach-Object { Write-Host $_ }
    $err | Where-Object { $_ -notmatch '^Warning: Permanently added' } | ForEach-Object { Write-Host $_ -ForegroundColor Yellow }

    if ($proc.ExitCode -ne 0) {
        Write-Host "Remote script exited $($proc.ExitCode)" -ForegroundColor Red
        exit 1
    }
}
finally {
    Remove-Item $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
}

Write-Host "Done. Values are in /config/.agent-env (mode 600) and are loaded by every new SSH login." -ForegroundColor Green
