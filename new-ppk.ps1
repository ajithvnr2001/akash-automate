<#
.SYNOPSIS
    Convert an unencrypted OpenSSH private key to a PuTTY .ppk (version 2).

.DESCRIPTION
    The Windows puttygen.exe build launches its GUI for every argument
    combination and cannot be scripted reliably, and driving that GUI with
    synthetic keystrokes is unsafe (it types into whatever window happens to
    have focus). This writes the PPK directly instead.

    Supported key types, matching what PuTTY 0.75 understands:
      - ssh-rsa        (mpint d, p, q, iqmp)
      - ssh-ed25519    (uint32 length prefix 32, then the 32-byte seed)

    The private blob has NO checkint. That 4-byte field belongs to the OpenSSH
    inner key format, not to the PPK. A bare 32-byte seed also loads, but PuTTY
    0.75 will not authenticate with it; the uint32 length prefix is required.

    PPK v2 layout (PuTTY sshpubk.c):
      PuTTY-User-Key-File-2: <alg>
      Encryption: none
      Comment: <comment>
      Public-Lines: n / <base64 of the public blob>
      Private-Lines: n / <base64 of the private blob>
      Private-MAC: hex HMAC-SHA1

    The MAC key is SHA1("putty-private-key-file-mac-key") and the MAC input is
    the algorithm, encryption, comment, public blob and private blob each
    length-prefixed (the two blobs include their trailing newline).

.PARAMETER OpenSshKeyPath
    Path to an unencrypted OpenSSH private key.

.PARAMETER OutputPath
    Where to write the .ppk.

.PARAMETER Comment
    Comment line for the PPK. Defaults to the one in the OpenSSH key.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OpenSshKeyPath,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$Comment
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $OpenSshKeyPath)) { throw "Key not found: $OpenSshKeyPath" }

# ---------------------------------------------------------------- helpers
function Read-U32BE([byte[]]$buf, [ref]$pos) {
    $v = ([uint32]$buf[$pos.Value] -shl 24) -bor ([uint32]$buf[$pos.Value + 1] -shl 16) -bor
         ([uint32]$buf[$pos.Value + 2] -shl 8) -bor ([uint32]$buf[$pos.Value + 3])
    $pos.Value += 4
    return $v
}
function Read-Str([byte[]]$buf, [ref]$pos) {
    $n = Read-U32BE $buf $pos
    if ($n -gt 200000) { throw "Implausible length $n - key parse failed" }
    $out = New-Object byte[] $n
    [Array]::Copy($buf, $pos.Value, $out, 0, $n)
    $pos.Value += $n
    return ,$out
}
function Write-U32BE([System.Collections.Generic.List[byte]]$list, [uint32]$v) {
    $t = [System.BitConverter]::GetBytes($v)
    [Array]::Reverse($t)
    $list.AddRange([byte[]]$t)
}

# ---------------------------------------------------------------- parse OpenSSH key
$raw = ([System.IO.File]::ReadAllText($OpenSshKeyPath)) -replace "`r`n", "`n"
if ($raw -match 'BEGIN .*ENCRYPTED') { throw 'Encrypted private keys are not supported' }
if ($raw -notmatch 'BEGIN OPENSSH PRIVATE KEY') { throw 'Not an openssh-key-v1 private key' }

$b64 = (($raw -split "`n") | Where-Object { $_ -notmatch '^-----' }) -join ''
$blob = [Convert]::FromBase64String($b64)

$magic = [System.Text.Encoding]::ASCII.GetString($blob, 0, 14)
if ($magic -ne 'openssh-key-v1') { throw "Bad magic: $magic" }

$p = 15
$cipher = [System.Text.Encoding]::ASCII.GetString((Read-Str $blob ([ref]$p)))
if ($cipher -ne 'none') { throw "Key is encrypted ($cipher); decrypt it first" }
$null = Read-Str $blob ([ref]$p)            # kdf
$null = Read-Str $blob ([ref]$p)            # kdf options
$nKeys = Read-U32BE $blob ([ref]$p)
if ($nKeys -ne 1) { throw "Expected 1 key, found $nKeys" }
$pubBlob = Read-Str $blob ([ref]$p)
$inner = Read-Str $blob ([ref]$p)

$ip = 0
$check1 = Read-U32BE $inner ([ref]$ip)
$check2 = Read-U32BE $inner ([ref]$ip)
if ($check1 -ne $check2) { throw 'checkint mismatch - corrupt key' }
$algName = [System.Text.Encoding]::ASCII.GetString((Read-Str $inner ([ref]$ip)))

# ---------------------------------------------------------------- build private blob
$priv = New-Object System.Collections.Generic.List[byte]

switch ($algName) {
    'ssh-ed25519' {
        $null = Read-Str $inner ([ref]$ip)          # public key (duplicate)
        $priv64 = Read-Str $inner ([ref]$ip)        # 64 bytes: seed || public
        if ($priv64.Length -ne 64) { throw "Bad ed25519 private length: $($priv64.Length)" }
        # PuTTY's ed25519 private blob is the 32-byte seed framed as an SSH
        # string (uint32 length, then the bytes). Verified against PuTTY 0.75:
        # a bare seed loads and offers fine but never completes authentication.
        $seed = New-Object byte[] 32
        [Array]::Copy($priv64, 0, $seed, 0, 32)
        Write-U32BE $priv ([uint32]$seed.Length)
        $priv.AddRange($seed)
    }
    'ssh-rsa' {
        $null = Read-Str $inner ([ref]$ip)          # e
        $null = Read-Str $inner ([ref]$ip)          # n
        $mpD    = Read-Str $inner ([ref]$ip)
        $mpIqmp = Read-Str $inner ([ref]$ip)
        $mpP    = Read-Str $inner ([ref]$ip)
        $mpQ    = Read-Str $inner ([ref]$ip)
        # PuTTY order (sshrsa.c: rsa2_private_blob): d, p, q, iqmp - each an
        # ssh mpint, already length-prefixed by the OpenSSH reader.
        foreach ($mp in @($mpD, $mpP, $mpQ, $mpIqmp)) {
            $priv.AddRange([byte[]]$mp)
        }
    }
    default {
        throw "Unsupported key type '$algName' (supported: ssh-ed25519, ssh-rsa)"
    }
}

$privBlob = $priv.ToArray()

# The comment travels in the PPK header, not in the blob.
$keyComment = [System.Text.Encoding]::ASCII.GetString((Read-Str $inner ([ref]$ip)))
if (-not $Comment) { $Comment = $keyComment }

# ---------------------------------------------------------------- encode
function Format-B64([byte[]]$data) {
    $s = [Convert]::ToBase64String($data)
    $lines = @()
    for ($i = 0; $i -lt $s.Length; $i += 64) {
        $lines += $s.Substring($i, [Math]::Min(64, $s.Length - $i))
    }
    return ($lines -join "`n")
}

$pubB64 = Format-B64 $pubBlob
$privB64 = Format-B64 $privBlob
$pubLines = ($pubB64 -split "`n").Count
$privLines = ($privB64 -split "`n").Count

# ---------------------------------------------------------------- MAC
function Add-LenPrefixed([System.IO.MemoryStream]$ms, [byte[]]$b) {
    $l = [System.BitConverter]::GetBytes([uint32]$b.Length)
    [Array]::Reverse($l)
    $ms.Write($l, 0, 4)
    $ms.Write($b, 0, $b.Length)
}
function Add-LenPrefixedString([System.IO.MemoryStream]$ms, [string]$s) {
    Add-LenPrefixed $ms ([System.Text.Encoding]::UTF8.GetBytes($s))
}

# PuTTY hashes the *binary* blobs, each as an SSH string (uint32 length +
# bytes) - sshpubk.c: put_string(macdata, public_blob->s, public_blob->len).
# Hashing the base64 text instead produces a file PuTTY loads and offers, then
# rejects at signing time ("MAC failed"), which looks like an authentication
# hang. That was the original bug.
$ms = New-Object System.IO.MemoryStream
Add-LenPrefixedString $ms $algName
Add-LenPrefixedString $ms 'none'
Add-LenPrefixedString $ms $Comment
Add-LenPrefixed $ms $pubBlob
Add-LenPrefixed $ms $privBlob
$macData = $ms.ToArray()

$sha1 = [System.Security.Cryptography.SHA1]::Create()
$macKey = $sha1.ComputeHash([System.Text.Encoding]::ASCII.GetBytes('putty-private-key-file-mac-key'))
$hmac = New-Object System.Security.Cryptography.HMACSHA1
$hmac.Key = $macKey
$macHex = ($hmac.ComputeHash($macData) | ForEach-Object { $_.ToString('x2') }) -join ''

# ---------------------------------------------------------------- write
$ppk = @"
PuTTY-User-Key-File-2: $algName
Encryption: none
Comment: $Comment
Public-Lines: $pubLines
$pubB64
Private-Lines: $privLines
$privB64
Private-MAC: $macHex
"@

# PuTTY's own writer ends the file with a newline; match it.
$ppk = ($ppk -replace "`r`n", "`n").TrimEnd("`n") + "`n"
[System.IO.File]::WriteAllText($OutputPath, $ppk)
return $OutputPath
