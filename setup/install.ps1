$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

function Find-Node {
    $command = Get-Command node.exe -ErrorAction SilentlyContinue
    $candidates = @(
        $(if ($command) { $command.Source }),
        "$env:ProgramFiles\nodejs\node.exe",
        "${env:ProgramFiles(x86)}\nodejs\node.exe",
        "$env:LOCALAPPDATA\Programs\nodejs\node.exe"
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            & $candidate -e 'process.exit(Number(process.versions.node.split(String.fromCharCode(46))[0]) >= 18 ? 0 : 1)' | Out-Null
            if ($LASTEXITCODE -eq 0) { return $candidate }
        }
    }
}

try {
    $src = Join-Path $root 'bin'
    foreach ($name in @('unlock.js', 'unlock.cmd')) {
        if (-not (Test-Path -LiteralPath (Join-Path $src $name) -PathType Leaf)) {
            throw "Missing file: bin\$name"
        }
    }

    Write-Host 'Checking Node.js...'
    $node = Find-Node
    if (-not $node) {
        $downloadDir = $null
        try {
            try {
                Write-Host 'Downloading official Node.js LTS using PowerShell...'
                [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
                $releases = Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json' -TimeoutSec 30
                $release = $releases | Where-Object { $_.lts -and $_.files -contains 'win-x64-msi' } | Select-Object -First 1
                if (-not $release) { throw 'No Windows x64 LTS release found.' }
                $name = "node-$($release.version)-x64.msi"
                $url = "https://nodejs.org/dist/$($release.version)"
                $downloadDir = Join-Path ([IO.Path]::GetTempPath()) ('unlock-node-' + [guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Path $downloadDir | Out-Null
                $msiPath = Join-Path $downloadDir $name
                Invoke-WebRequest -UseBasicParsing -Uri "$url/$name" -OutFile $msiPath -TimeoutSec 300
                $sums = (Invoke-WebRequest -UseBasicParsing -Uri "$url/SHASUMS256.txt" -TimeoutSec 30).Content
                $line = $sums -split "`n" | Where-Object { $_.Trim().EndsWith(" $name") } | Select-Object -First 1
                if (-not $line) { throw 'Official checksum not found.' }
                $expected = ($line.Trim() -split '\s+')[0]
                if ((Get-FileHash -LiteralPath $msiPath -Algorithm SHA256).Hash -ne $expected) { throw 'Installer checksum mismatch.' }
            } catch {
                Write-Warning ('Download unavailable: ' + $_.Exception.Message)
                $msi = Get-ChildItem -LiteralPath (Join-Path $root 'installers') -Filter 'node-*-x64.msi' -File | Select-Object -First 1
                if (-not $msi) { throw 'No offline installer found. Check the internet connection and retry.' }
                $msiPath = $msi.FullName
                Write-Host 'Using bundled offline installer.'
            }
            Write-Host 'Installing Node.js. Accept the Windows administrator prompt if shown.'
            $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList ('/i "' + $msiPath + '" /passive /norestart') -Wait -PassThru
            if ($process.ExitCode -notin @(0, 3010, 1641)) { throw "Node.js installer exited with code $($process.ExitCode)." }
            $node = Find-Node
        } finally {
            if ($downloadDir -and (Test-Path -LiteralPath $downloadDir)) {
                Remove-Item -LiteralPath $downloadDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        if (-not $node) { throw 'Node.js not detected. Restart Windows if requested, then run this BAT again.' }
    }

    & $node --check (Join-Path $src 'unlock.js')
    if ($LASTEXITCODE -ne 0) { throw 'JavaScript validation failed.' }
    $dst = Join-Path $env:LOCALAPPDATA 'Programs\unlock-cli'
    New-Item -ItemType Directory -Path $dst -Force | Out-Null
    foreach ($name in @('unlock.js', 'unlock.cmd')) {
        Copy-Item -LiteralPath (Join-Path $src $name) -Destination (Join-Path $dst $name) -Force
    }

    $nodeDir = Split-Path $node -Parent
    $oldPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $entries = @($dst, $nodeDir)
    $entries += @($oldPath -split ';' | Where-Object { $_ })
    $seen = @{}
    $newPath = ($entries | Where-Object {
        $key = $_.TrimEnd('\').ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; $true } else { $false }
    }) -join ';'
    if ($newPath -ne $oldPath) { [Environment]::SetEnvironmentVariable('Path', $newPath, 'User') }
    $env:Path = "$dst;$nodeDir;$env:Path"
    & (Join-Path $dst 'unlock.cmd') --help
    if ($LASTEXITCODE -ne 0) { throw 'Command verification failed.' }
    Write-Host "Installed: $dst" -ForegroundColor Green
    Write-Host 'Open a NEW terminal, then run: unlock "D:\folder"'
    exit 0
} catch {
    Write-Host ('Installation failed: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
