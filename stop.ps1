[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot
$pidPath = Join-Path $projectRoot 'zed2api.pid'
$expectedExe = [System.IO.Path]::GetFullPath((Join-Path $projectRoot 'zed2api.exe'))

if (-not (Test-Path -LiteralPath $pidPath -PathType Leaf)) {
    Write-Host 'zed2api.pid was not found; no process was recorded by start.ps1.'
    exit 0
}

$processIdText = (Get-Content -LiteralPath $pidPath -Raw -Encoding ASCII).Trim()
$processId = 0
if (-not [int]::TryParse($processIdText, [ref]$processId)) {
    throw "Invalid PID file content: $processIdText"
}

$process = Get-Process -Id $processId -ErrorAction SilentlyContinue
if (-not $process) {
    Remove-Item -LiteralPath $pidPath -Force
    Write-Host "PID $processId no longer exists; the stale PID file was removed."
    exit 0
}

$actualExe = [System.IO.Path]::GetFullPath($process.Path)
if ($process.ProcessName -ne 'zed2api' -or $actualExe -ne $expectedExe) {
    throw "PID $processId is not this directory's zed2api. Stop cancelled. Actual path: $actualExe"
}

Stop-Process -Id $processId -Force
$process.WaitForExit()
Remove-Item -LiteralPath $pidPath -Force
Write-Host "zed2api stopped: PID=$processId"
