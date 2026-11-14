<#
.SYNOPSIS
    Render the Akash SDL with Ubuntu 22.04 LTS, SSH server, and bootstrap script injected.

.DESCRIPTION
    Produces a YAML string. The container runs Ubuntu 22.04 LTS with:
    - OpenSSH server listening on port 22
    - User 'akash' with passwordless sudo + pubkey & password auth
    - Root access enabled with pubkey & password auth
    - Cloud CLIs (gcloud, aws, az, oci), Python 3, Node.js, and AI agent tools
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PublicKey,
    [Parameter(Mandatory)][string]$Password,
    [string]$BootstrapPath = (Join-Path $PSScriptRoot 'bootstrap.sh'),
    [double]$Cpu = 4.0,
    [string]$Memory = '16Gi',
    [string]$Storage = '250Gi',
    [int]$PriceUact = 20000
)

$ErrorActionPreference = 'Stop'

# Allow running standalone: ensure output directories exist.
$StateDir = Join-Path $PSScriptRoot 'state'
if (-not (Test-Path $StateDir)) {
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
}

if (-not (Test-Path $BootstrapPath)) {
    throw "Bootstrap script not found: $BootstrapPath"
}

# Base64 the bootstrap so it survives YAML/env quoting entirely.
$bootstrapRaw = [System.IO.File]::ReadAllText($BootstrapPath)
$bootstrapB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($bootstrapRaw))

$pub = $PublicKey.Trim()

# Inline boot script that initializes SSH and spawns bootstrap in background
$initScript = "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openssh-server sudo curl ca-certificates && " + `
              "mkdir -p /run/sshd /home/akash/.ssh /root/.ssh /etc/sudoers.d /etc/ssh/sshd_config.d && " + `
              "(id -u akash >/dev/null 2>&1 || useradd -m -s /bin/bash -u 1000 akash) && " + `
              "echo 'akash ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/akash && chmod 0440 /etc/sudoers.d/akash && " + `
              "echo 'akash:$Password' | chpasswd && echo 'root:$Password' | chpasswd && " + `
              "echo '$pub' > /home/akash/.ssh/authorized_keys && echo '$pub' > /root/.ssh/authorized_keys && " + `
              "chown -R akash:akash /home/akash && chmod 700 /home/akash/.ssh /root/.ssh && " + `
              "chmod 600 /home/akash/.ssh/authorized_keys /root/.ssh/authorized_keys && " + `
              "printf 'PermitRootLogin yes\nPasswordAuthentication yes\nPubkeyAuthentication yes\n' > /etc/ssh/sshd_config.d/akash.conf && " + `
              "sed -i 's/#\\?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config && " + `
              "sed -i 's/#\\?PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config && " + `
              "(echo '$bootstrapB64' | base64 -d | bash > /var/log/bootstrap.log 2>&1 &) ; " + `
              "exec /usr/sbin/sshd -D"

$sdl = @"
version: "2.0"

services:
  vm:
    image: ubuntu:22.04
    command:
      - /bin/bash
      - -c
      - "$initScript"
    env:
      - "USER_NAME=akash"
      - "TZ=UTC"
    expose:
      - port: 22
        as: 22
        to:
          - global: true

profiles:
  compute:
    vm:
      resources:
        cpu:
          units: $Cpu
        memory:
          size: $Memory
        storage:
          size: $Storage
  placement:
    dcloud:
      pricing:
        vm:
          denom: uact
          amount: $PriceUact

deployment:
  vm:
    dcloud:
      profile: vm
      count: 1
"@

return $sdl
