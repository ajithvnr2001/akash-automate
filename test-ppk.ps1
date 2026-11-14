<#
.SYNOPSIS
    Verify a .ppk against the OpenSSH key it was generated from.

.DESCRIPTION
    Three independent checks:
      1. Recompute the PPK's Private-MAC the way PuTTY does.
      2. The PPK public blob must equal the OpenSSH key's public blob.
      3. The 32-byte ed25519 seed in the PPK must equal the OpenSSH seed.

    Any one of these failing means PuTTY will refuse the key.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PpkPath,
    [Parameter(Mandatory)][string]$OpenSshKeyPath
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- PPK parsing
$raw = ([System.IO.File]::ReadAllText($PpkPath)) -replace "`r`n", "`n"
$lines = $raw -split "`n"

$f = @{}
$i = 0
while ($i -lt $lines.Count) {
    $line = $lines[$i]
    if     ($line -match '^(PuTTY-User-Key-File-\d|Encryption|Comment): (.*)$') {
        $f[$Matches[1]] = $Matches[2]; $i++
    }
    elseif ($line -match '^Public-Lines:\s*(\d+)$') {
        $n = [int]$Matches[1]
        $f['Public'] = ($lines[($i+1)..($i+$n)] -join "`n")
        $i += $n + 1
    }
    elseif ($line -match '^Private-Lines:\s*(\d+)$') {
        $n = [int]$Matches[1]
        $f['Private'] = ($lines[($i+1)..($i+$n)] -join "`n")
        $i += $n + 1
    }
    elseif ($line -match '^Private-MAC:\s*([0-9a-fA-F]+)$') {
        $f['MAC'] = $Matches[1].ToLower(); $i++
    }
    else { $i++ }
}

foreach ($need in 'Public', 'Private', 'MAC') {
    if (-not $f.ContainsKey($need)) { throw "PPK is missing the $need section" }
}

$keyType = $f['PuTTY-User-Key-File-2']
"type       : $keyType"
"encryption : $($f['Encryption'])"
"comment    : $($f['Comment'])"

if ($f['Encryption'] -ne 'none') { throw 'Only unencrypted PPKs are supported here' }

# ---------------------------------------------------------------- MAC check
function New-LenPrefixed([string]$s) {
    $b = [System.Text.Encoding]::UTF8.GetBytes($s)
    $l = [BitConverter]::GetBytes([uint32]$b.Length)
    [Array]::Reverse($l)
    $out = New-Object byte[] ($l.Length + $b.Length)
    [Array]::Copy($l, 0, $out, 0, 4)
    [Array]::Copy($b, 0, $out, 4, $b.Length)
    return ,$out
}

function New-BytesPrefixed([byte[]]$b) {
    $l = [BitConverter]::GetBytes([uint32]$b.Length)
    [Array]::Reverse($l)
    $out = New-Object byte[] ($l.Length + $b.Length)
    [Array]::Copy($l, 0, $out, 0, 4)
    [Array]::Copy($b, 0, $out, 4, $b.Length)
    return ,$out
}

$macIn = @()
$macIn += New-LenPrefixed $keyType
$macIn += New-LenPrefixed $f['Encryption']
$macIn += New-LenPrefixed $f['Comment']
# PuTTY hashes the DECODED (binary) blobs, each as an SSH string. Hashing the
# base64 text is the classic mistake: the file still loads, then fails to sign.
$macIn += New-BytesPrefixed ([Convert]::FromBase64String(($f['Public'] -replace '\s', '')))
$macIn += New-BytesPrefixed ([Convert]::FromBase64String(($f['Private'] -replace '\s', '')))
$macData = [byte[]]$macIn

$sha1 = [System.Security.Cryptography.SHA1]::Create()
$macKey = $sha1.ComputeHash([System.Text.Encoding]::UTF8.GetBytes('putty-private-key-file-mac-key'))
$hmac = New-Object System.Security.Cryptography.HMACSHA1
$hmac.Key = $macKey
$calcMac = (($hmac.ComputeHash($macData)) | ForEach-Object { $_.ToString('x2') }) -join ''
$macOk = $calcMac -eq $f['MAC']
"MAC        : $(if ($macOk) { 'valid' } else { "INVALID (calc $calcMac, file $($f['MAC']))" })"

# ---------------------------------------------------------------- OpenSSH parsing
$ossRaw = ([System.IO.File]::ReadAllText($OpenSshKeyPath)) -replace "`r`n", "`n"
$ossB64 = (($ossRaw -split "`n") | Where-Object { $_ -notmatch '^-----' }) -join ''
$blob = [Convert]::FromBase64String($ossB64)

$script:buf = $blob
$script:p = 0
function Read-U32 {
    $v = [uint32](($script:buf[$script:p] -shl 24) -bor ($script:buf[$script:p+1] -shl 16) -bor
                  ($script:buf[$script:p+2] -shl 8) -bor $script:buf[$script:p+3])
    $script:p += 4
    return $v
}
function Read-Str {
    $n = Read-U32
    $o = $script:p
    $script:p += $n
    $out = New-Object byte[] $n
    [Array]::Copy($script:buf, $o, $out, 0, $n)
    return ,$out
}

$magic = [System.Text.Encoding]::ASCII.GetString($blob, 0, 14)
if ($magic -ne 'openssh-key-v1') { throw "Not an openssh-key-v1 file (magic: $magic)" }

$script:p = 15
$null = Read-Str            # cipher
$null = Read-Str            # kdf
$null = Read-Str            # kdf options
$nKeys = Read-U32
if ($nKeys -ne 1) { throw "Expected 1 key, found $nKeys" }
$ossPub = Read-Str
$inner = Read-Str

$script:buf = $inner
$script:p = 0
$c1 = Read-U32
$c2 = Read-U32
if ($c1 -ne $c2) { throw 'checkint mismatch - key is encrypted or corrupt' }
$innerType = [System.Text.Encoding]::ASCII.GetString((Read-Str))
$null = Read-Str            # public again
$priv64 = Read-Str          # seed || public

if ($priv64.Length -ne 64) { throw "Unexpected ed25519 private length: $($priv64.Length)" }
$ossSeed = New-Object byte[] 32
[Array]::Copy($priv64, 0, $ossSeed, 0, 32)

# ---------------------------------------------------------------- public check
# Decode from the whitespace-stripped text; the MAC above used it verbatim.
$ppkPub = [Convert]::FromBase64String(($f['Public'] -replace '\s', ''))
$pubOk = [Convert]::ToBase64String($ppkPub) -eq [Convert]::ToBase64String($ossPub)
"public key : $(if ($pubOk) { 'matches' } else { 'DIFFERENT' })"

# ---------------------------------------------------------------- seed check
# PPK private blob for ed25519: uint32 length (=32) then the seed. No checkint.
$ppkPriv = [Convert]::FromBase64String(($f['Private'] -replace '\s', ''))
$mpLen = [uint32](($ppkPriv[0] -shl 24) -bor ($ppkPriv[1] -shl 16) -bor ($ppkPriv[2] -shl 8) -bor $ppkPriv[3])
$seedBytes = if ($ppkPriv.Length -ge (4 + $mpLen)) { @($ppkPriv[4..(3 + $mpLen)]) } else { @() }

$seedOk = ($mpLen -eq 32 -and $seedBytes.Count -eq 32)
if ($seedOk) {
    for ($k = 0; $k -lt 32; $k++) {
        if ($seedBytes[$k] -ne $ossSeed[$k]) { $seedOk = $false; break }
    }
}
"private key: $(if ($seedOk) { 'matches' } else { 'DIFFERENT' })"

if ($macOk -and $pubOk -and $seedOk) {
    "RESULT     : PASS - PPK is valid and matches the OpenSSH key"
    exit 0
}
"RESULT     : FAIL"
exit 1
