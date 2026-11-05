param([switch]$Library)
$ErrorActionPreference = 'Stop'

function Read-UnlockScript([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt 2MB) { return '' }
    try { [IO.File]::ReadAllText($Path) } catch { '' }
}

function Get-UnlockCleanupPlan([string]$Prefix, [string]$Destination, [string]$Source) {
    $prefix = [IO.Path]::GetFullPath($Prefix).TrimEnd('\')
    $destination = [IO.Path]::GetFullPath($Destination).TrimEnd('\')
    $source = [IO.Path]::GetFullPath($Source).TrimEnd('\')
    $files = New-Object 'System.Collections.Generic.List[object]'
    $plan = [pscustomobject]@{Prefix=$prefix; Files=$files; Package=$null}
    if ($prefix -ieq $source -or -not (Test-Path -LiteralPath $prefix -PathType Container)) { return $plan }
    if ((Get-Item -LiteralPath $prefix -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { return $plan }
    $js = Read-UnlockScript (Join-Path $prefix 'unlock.js')
    $core = Read-UnlockScript (Join-Path $prefix 'unlock-core.ps1')
    $oursJS = $js.Contains('function findEncryptedFiles(') -and $js.Contains('async function unlockInPlace(')
    $oursPS = $core.Contains('namespace UnlockPortable') -and $core.Contains('class EngineV2')

    $packageRoot = Join-Path $prefix 'node_modules\@zlhy7\ld-decrypt-tool'
    $linked = $false
    foreach ($relative in @('node_modules','node_modules\@zlhy7','node_modules\@zlhy7\ld-decrypt-tool')) {
        $p = Join-Path $prefix $relative
        if ((Test-Path -LiteralPath $p) -and ((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { $linked = $true }
    }
    if (-not $linked -and $prefix -ine $destination) {
        $manifest = Read-UnlockScript (Join-Path $packageRoot 'package.json')
        if ($manifest) {
            try { if (($manifest | ConvertFrom-Json).name -ceq '@zlhy7/ld-decrypt-tool') { $plan.Package = '@zlhy7/ld-decrypt-tool' } } catch { }
        }
    }
    foreach ($name in @('unlock.js','unlock-core.ps1','unlock.cmd','unlock.ps1','unlock')) {
        if ($prefix -ieq $destination -and $name -ne 'unlock.js') { continue }
        $p = Join-Path $prefix $name
        $text = Read-UnlockScript $p
        $owned = ($name -eq 'unlock.js' -and $oursJS) -or ($name -eq 'unlock-core.ps1' -and $oursPS)
        if ($name -in @('unlock.cmd','unlock.ps1','unlock')) {
            $owned = ($oursJS -and $text.Contains('unlock.js')) -or ($oursPS -and $text.Contains('unlock-core.ps1')) -or
                ($plan.Package -and $text -match '@zlhy7[\\/]ld-decrypt-tool[\\/]bin[\\/]unlock\.js')
        }
        if ($owned -and $text) { $files.Add([pscustomobject]@{Path=$p; Hash=(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash}) }
    }
    return $plan
}

function Remove-UnlockOldVersion($Plan) {
    if ($Plan.Package) {
        $npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
        if ($npm) {
            Write-Host "Removing old unlock package only: $($Plan.Prefix)"
            & $npm.Source uninstall -g --prefix $Plan.Prefix --ignore-scripts --no-audit --no-fund $Plan.Package
            if ($LASTEXITCODE -ne 0) { Write-Warning 'Old unlock package removal failed; Node.js and npm were NOT uninstalled.' }
        } else { Write-Warning 'Old unlock npm package retained: npm is unavailable. No software was uninstalled.' }
    }
    foreach ($file in $Plan.Files) {
        if (-not (Test-Path -LiteralPath $file.Path -PathType Leaf)) { continue }
        $item = Get-Item -LiteralPath $file.Path -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or (Get-FileHash -LiteralPath $file.Path -Algorithm SHA256).Hash -ne $file.Hash) {
            Write-Warning "Changed or linked item retained: $($file.Path)"
            continue
        }
        try { Remove-Item -LiteralPath $file.Path -ErrorAction Stop; Write-Host "Removed old unlock script: $($file.Path)" }
        catch { Write-Warning "Old unlock script retained: $($file.Path) -- $($_.Exception.Message)" }
    }
}

if ($Library) { return }
try {
    $root = Split-Path $PSScriptRoot -Parent
    $src = Join-Path $root 'bin'
    foreach ($name in @('unlock-core.ps1', 'unlock.cmd')) {
        if (-not (Test-Path -LiteralPath (Join-Path $src $name) -PathType Leaf)) { throw "Missing file: bin\$name" }
    }
    # Verify the new engine before overwriting any installed entry points.
    $probe = Join-Path $src 'unlock-core.ps1'
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $probe -Library
    if ($LASTEXITCODE -ne 0) { throw 'PowerShell/.NET validation failed. No installation performed.' }

    $dst = Join-Path $env:LOCALAPPDATA 'Programs\unlock-cli'
    $legacy = Join-Path $env:APPDATA 'npm'
    $prefixes = @($dst, $legacy)
    foreach ($command in @(Get-Command unlock.cmd, unlock.ps1 -All -ErrorAction SilentlyContinue)) {
        if ($command.Source -and (Read-UnlockScript $command.Source) -match '@zlhy7[\\/]ld-decrypt-tool[\\/]bin[\\/]unlock\.js') {
            $prefixes += Split-Path $command.Source -Parent
        }
    }
    $plans = @()
    foreach ($prefix in @($prefixes | Select-Object -Unique)) { $plans += Get-UnlockCleanupPlan $prefix $dst $src }
    New-Item -ItemType Directory -Path $dst -Force | Out-Null
    foreach ($name in @('unlock-core.ps1', 'unlock.cmd')) {
        $from = Join-Path $src $name
        $to = Join-Path $dst $name
        if ([IO.Path]::GetFullPath($from) -ine [IO.Path]::GetFullPath($to)) { Copy-Item -LiteralPath $from -Destination $to -Force }
    }
    & (Join-Path $dst 'unlock.cmd') -Help
    if ($LASTEXITCODE -ne 0) { throw 'New command verification failed.' }

    $oldPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $entries = @($dst) + @($oldPath -split ';' | Where-Object { $_ })
    $seen = @{}
    $newPath = ($entries | Where-Object {
        $key = $_.TrimEnd('\').ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; $true } else { $false }
    }) -join ';'
    if ($newPath -ne $oldPath) { [Environment]::SetEnvironmentVariable('Path', $newPath, 'User') }
    $env:Path = "$dst;$env:Path"
    # Never clean an old entry point before the new command and PATH are ready.
    foreach ($plan in $plans) { Remove-UnlockOldVersion $plan }
    Write-Host "Installed/updated: $dst" -ForegroundColor Green
    Write-Host 'Old unlock scripts cleaned. Node.js, npm and unrelated software are kept.'
    Write-Host 'Open a NEW terminal and run: unlock "D:\folder"'
    exit 0
} catch {
    Write-Host ('Installation failed: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
