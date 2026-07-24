[CmdletBinding()]
param(
    [ValidateRange(1, 65535)]
    [int]$Port = 8001
)

$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot
$exePath = Join-Path $projectRoot 'zed2api.exe'
$pidPath = Join-Path $projectRoot 'zed2api.pid'
$logDir = Join-Path $projectRoot 'logs'
$stdoutPath = Join-Path $logDir 'zed2api.out.log'
$stderrPath = Join-Path $logDir 'zed2api.err.log'

if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
    throw "Release binary not found: $exePath"
}

$listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($listener) {
    $owner = Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
    $ownerPath = if ($owner) { $owner.Path } else { '<unknown>' }
    throw "Port $Port is already owned by PID $($listener.OwningProcess): $ownerPath"
}

if (-not (Test-Path -LiteralPath (Join-Path $projectRoot 'accounts.json'))) {
    Write-Warning 'accounts.json is missing. Run .\zed2api.exe login my-account before sending model requests.'
}

New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$process = Start-Process `
    -FilePath $exePath `
    -ArgumentList @('serve', [string]$Port) `
    -WorkingDirectory $projectRoot `
    -WindowStyle Hidden `
    -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath `
    -PassThru

[System.IO.File]::WriteAllText($pidPath, [string]$process.Id, [System.Text.Encoding]::ASCII)

$ready = $false
for ($attempt = 0; $attempt -lt 40; $attempt++) {
    Start-Sleep -Milliseconds 250
    if ($process.HasExited) { break }
    try {
        $null = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/v1/models" -UseBasicParsing -TimeoutSec 3
        $ready = $true
        break
    } catch {
        # A short connection failure is expected while the listener starts.
    }
}

if (-not $ready) {
    $errorTail = if (Test-Path -LiteralPath $stderrPath) {
        (Get-Content -LiteralPath $stderrPath -Tail 20 -Encoding UTF8) -join [Environment]::NewLine
    } else {
        '<no log>'
    }
    throw "zed2api readiness check failed. PID=$($process.Id)`n$errorTail"
}

Write-Host "zed2api started: PID=$($process.Id), URL=http://127.0.0.1:$Port"
Write-Host "Error log: $stderrPath"
