$ErrorActionPreference = 'Stop'
$project = Join-Path $PSScriptRoot 'UnlockPortable.Desktop.csproj'
$output = Join-Path $PSScriptRoot 'release'
dotnet publish $project -c Release -r win-x64 --self-contained true `
    -p:PublishSingleFile=true `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:EnableCompressionInSingleFile=true `
    -o $output
if ($LASTEXITCODE -ne 0) { throw 'Managed publish failed.' }
Get-Item (Join-Path $output 'UnlockPortable.exe') | Select-Object FullName, Length, LastWriteTime
