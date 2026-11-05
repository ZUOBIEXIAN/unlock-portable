# Run with Windows PowerShell 5.1. Fixtures are synthetic; no user documents,
# enterprise keys, original plaintext, Node.js or encryption driver are needed.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'bin\unlock-core.ps1') -Library
$NoProgress = $true
$root = Join-Path ([IO.Path]::GetTempPath()) ('unlock-compat-' + [guid]::NewGuid().ToString('N'))
$inputs = Join-Path $root 'inputs'
$outputs = Join-Path $root 'outputs'
[IO.Directory]::CreateDirectory($inputs) | Out-Null
[IO.Directory]::CreateDirectory($outputs) | Out-Null

function Invoke-ReferenceRC4([byte[]]$Key, [byte[]]$Data) {
    $state = New-Object byte[] 256
    for ($i = 0; $i -lt 256; $i++) { $state[$i] = $i }
    $j = 0
    for ($i = 0; $i -lt 256; $i++) {
        $j = ($j + $state[$i] + $Key[$i % $Key.Length]) -band 255
        $t = $state[$i]; $state[$i] = $state[$j]; $state[$j] = $t
    }
    $result = New-Object byte[] $Data.Length
    $i = 0; $j = 0
    for ($n = 0; $n -lt $Data.Length; $n++) {
        $i = ($i + 1) -band 255
        $j = ($j + $state[$i]) -band 255
        $t = $state[$i]; $state[$i] = $state[$j]; $state[$j] = $t
        $result[$n] = $Data[$n] -bxor $state[($state[$i] + $state[$j]) -band 255]
    }
    return ,$result
}

function Update-TestHeaderCRC([byte[]]$Header) {
    $state = 255
    foreach ($index in @(8..11) + @(28..511)) {
        if ($index -eq 46) { continue }
        $state = $state -bxor $Header[$index]
        for ($bit = 0; $bit -lt 8; $bit++) {
            if ($state -band 1) { $state = ($state -shr 1) -bxor 0xe0 }
            else { $state = $state -shr 1 }
        }
    }
    $Header[46] = 255 - $state
}

# Independent reference construction with an explicitly public TEST value.
$parameter = [byte[]]@(0x78, 0x56, 0x34, 0x12)
$checkValue = [Text.Encoding]::ASCII.GetBytes('TESTKEY!')
$selected = [byte[]]@($checkValue[6], $checkValue[0], $checkValue[5])
$repeated = New-Object byte[] 16
for ($i = 0; $i -lt 16; $i++) { $repeated[$i] = $parameter[$i % 4] }
$stage1 = Invoke-ReferenceRC4 $selected $repeated
[Array]::Copy($selected, 0, $stage1, 0, 3)
$fileKey = Invoke-ReferenceRC4 $parameter $stage1
$stream = Invoke-ReferenceRC4 $fileKey (New-Object byte[] 512)

$payloads = @{
    'sample.bat' = [Text.Encoding]::UTF8.GetBytes("@echo off`r`necho Compatibility fixture. Do not execute.`r`n")
    'sample.html' = [Text.Encoding]::UTF8.GetBytes('<!doctype html><meta charset="utf-8"><title>Test</title><p>Chinese: 中文测试</p>')
    'sample.py' = [Text.Encoding]::UTF8.GetBytes("# UTF-8 fixture: 中文`ndef add(a, b):`n    return a + b`n")
}
$dll = Join-Path $root 'fixture.dll'
$typeName = 'Fixture_' + [guid]::NewGuid().ToString('N')
Add-Type -TypeDefinition ('public class {0} {{ public static string Message() {{ return "Compatibility fixture"; }} }}' -f $typeName) -OutputAssembly $dll -OutputType Library
$payloads['sample.dll'] = [IO.File]::ReadAllBytes($dll)

$passed = 0
foreach ($metadata in @(0x0d, 0x0f)) {
    foreach ($entry in $payloads.GetEnumerator()) {
        $header = New-Object byte[] 4096
        $header[0] = 0x89; $header[1] = 0x7d; $header[2] = 0x1c
        $header[4] = 0x49; $header[6] = $metadata
        [Array]::Copy($parameter, 0, $header, 8, 4)
        $wrapped = Invoke-ReferenceRC4 $parameter $checkValue
        [Array]::Copy($wrapped, 0, $header, 12, 8)
        Update-TestHeaderCRC $header
        $cipher = New-Object byte[] (4096 + $entry.Value.Length)
        [Array]::Copy($header, 0, $cipher, 0, 4096)
        for ($i = 0; $i -lt $entry.Value.Length; $i++) { $cipher[4096 + $i] = $entry.Value[$i] -bxor $stream[$i % 512] }
        $name = ('{0:X2}-' -f $metadata) + $entry.Key
        $source = Join-Path $inputs $name
        $destination = Join-Path $outputs $name
        [IO.File]::WriteAllBytes($source, $cipher)
        if ([UnlockPortable.EngineV2]::Inspect($source).Kind -ne 'Supported') { throw "Scan rejected: $name" }
        $result = [UnlockPortable.EngineV2]::DecryptFile($source, $destination, $null)
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $expected = [BitConverter]::ToString($sha.ComputeHash($entry.Value)).Replace('-', '') } finally { $sha.Dispose() }
        if ($result.SHA256 -ine $expected -or (Get-FileHash -LiteralPath $destination).Hash -ine $expected) { throw "Mismatch: $name" }
        $passed++
    }
}
$bad = [byte[]]$cipher.Clone(); $bad[46] = $bad[46] -bxor 1
$badPath = Join-Path $inputs 'bad-header.bin'
[IO.File]::WriteAllBytes($badPath, $bad)
if ([UnlockPortable.EngineV2]::Inspect($badPath).Kind -ne 'Invalid') { throw 'Bad CRC accepted' }
$unknown = [byte[]]$cipher.Clone(); $unknown[2] = 0x15
$unknownPath = Join-Path $inputs 'unknown-mode.bin'
[IO.File]::WriteAllBytes($unknownPath, $unknown)
if ([UnlockPortable.EngineV2]::Inspect($unknownPath).Kind -ne 'Unsupported') { throw 'Unknown mode accepted' }
[IO.File]::WriteAllText((Join-Path $inputs 'plain.txt'), 'ordinary text')
$scan = Find-UnlockFiles $inputs
if ($scan.Files.Count -ne 8 -or $scan.Invalid -ne 1 -or $scan.Unsupported -ne 1 -or $scan.Plain -ne 1) { throw 'Scanner classification mismatch' }
Write-Output "$passed / 8 extension/metadata fixtures passed; invalid/unknown/plain classifications passed."

# Extension-agnostic opaque-byte tests: these are NOT claimed to be valid
# PDF/image/video/etc documents. They prove no extension selects a different
# decoder, drops bytes, or prevents matching the encrypted header.
$extensions = @('txt','log','md','csv','json','xml','yaml','yml','ini','cfg','conf','html','htm','css','js','ts','py','bat','cmd','ps1','sh','c','cpp','h','hpp','java','cs','sql','svg','srt','pdf','doc','docx','xls','xlsx','ppt','pptx','zip','7z','rar','tar','gz','png','jpg','jpeg','gif','bmp','webp','ico','mp3','wav','mp4','avi','mkv','exe','dll','dat','bin','db','sqlite')
$opaque = New-Object byte[] 8197
(New-Object Random 7301).NextBytes($opaque)
for ($i = 0; $i -lt 256; $i++) { $opaque[$i] = $i }
$cipher = New-Object byte[] (4096 + $opaque.Length)
[Array]::Copy($header, 0, $cipher, 0, 4096)
for ($i = 0; $i -lt $opaque.Length; $i++) { $cipher[4096 + $i] = $opaque[$i] -bxor $stream[$i % 512] }
$sha = [Security.Cryptography.SHA256]::Create()
try { $expected = [BitConverter]::ToString($sha.ComputeHash($opaque)).Replace('-', '') } finally { $sha.Dispose() }
foreach ($extension in $extensions) {
    $source = Join-Path $inputs ('opaque.' + $extension)
    $destination = Join-Path $outputs ('opaque.' + $extension)
    [IO.File]::WriteAllBytes($source, $cipher)
    if ([UnlockPortable.EngineV2]::Inspect($source).Kind -ne 'Supported') { throw "Extension rejected: $extension" }
    $result = [UnlockPortable.EngineV2]::DecryptFile($source, $destination, $null)
    if ($result.SHA256 -ine $expected -or (Get-FileHash -LiteralPath $destination).Hash -ine $expected) { throw "Opaque byte mismatch: $extension" }
}
Write-Output "$($extensions.Count) / $($extensions.Count) common-extension opaque-byte tests passed."
Write-Output "All fixtures were treated as data, not executed. Test workspace: $root"
