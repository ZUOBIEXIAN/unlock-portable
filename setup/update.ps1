# Online updater for this repository. Works both as a file and through IEX.
# The entire archive is one revision; no mixed-version individual downloads.
& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    $work = Join-Path ([IO.Path]::GetTempPath()) ('unlock-update-' + [guid]::NewGuid().ToString('N'))
    $created = $false
    $tlsBefore = [Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol = $tlsBefore -bor [Net.SecurityProtocolType]::Tls12
        New-Item -ItemType Directory -Path $work -ErrorAction Stop | Out-Null
        $created = $true
        $archive = Join-Path $work 'unlock-portable.zip'
        $expanded = Join-Path $work 'package'
        Write-Host 'Downloading the latest unlock package from GitHub...'
        Invoke-WebRequest -UseBasicParsing -Uri 'https://codeload.github.com/ZUOBIEXIAN/unlock-portable/zip/refs/heads/main' -OutFile $archive -TimeoutSec 180
        Write-Host ('Downloaded current snapshot: {0:N1} KB (no Git history).' -f ((Get-Item -LiteralPath $archive).Length / 1KB))
        Expand-Archive -LiteralPath $archive -DestinationPath $expanded -ErrorAction Stop
        $package = Join-Path $expanded 'unlock-portable-main'
        foreach ($relative in @('bin\unlock-core.ps1', 'bin\unlock.cmd', 'setup\install.ps1')) {
            $p = Join-Path $package $relative
            if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "Incomplete download: $relative" }
        }
        Write-Host 'Installing/updating unlock. Node.js and npm will be kept.'
        $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        & $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $package 'setup\install.ps1')
        if ($LASTEXITCODE -ne 0) { throw 'Installer reported a failure. Review the message above.' }
        $installed = Join-Path $env:LOCALAPPDATA 'Programs\unlock-cli'
        foreach ($name in @('unlock-core.ps1', 'unlock.cmd')) {
            $expected = (Get-FileHash -LiteralPath (Join-Path $package ('bin\' + $name)) -Algorithm SHA256).Hash
            $actual = (Get-FileHash -LiteralPath (Join-Path $installed $name) -Algorithm SHA256).Hash
            if ($actual -ne $expected) { throw "Installed file verification failed: $name" }
        }
        # Environment changes here apply immediately, even when invoked through IEX.
        $rest = @($env:Path -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ine $installed.TrimEnd('\') })
        $env:Path = (@($installed) + $rest) -join ';'
        Write-Host 'unlock update completed. You can use unlock in this terminal now.' -ForegroundColor Green
    } catch {
        throw ('unlock update failed: ' + $_.Exception.Message)
    } finally {
        [Net.ServicePointManager]::SecurityProtocol = $tlsBefore
        if ($created -and (Test-Path -LiteralPath $work)) {
            try { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction Stop }
            catch { Write-Warning "Temporary download folder retained: $work" }
        }
    }
}
