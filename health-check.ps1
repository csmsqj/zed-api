[CmdletBinding()]
param(
    [ValidateRange(1, 65535)]
    [int]$Port = 8001,
    # One explicit low-cost inference probe for the active account.
    [switch]$Deep,
    # One explicit low-cost inference probe for every configured account.
    [switch]$AllAccounts,
    # Optional end-to-end SSE checks for Responses, Chat Completions and Messages.
    [switch]$Streaming
)

$ErrorActionPreference = 'Stop'
$baseUrl = "http://127.0.0.1:$Port"

# The default path is passive: it reads local models plus Zed token/billing
# status and therefore does not consume a model request.
$models = Invoke-RestMethod -Uri "$baseUrl/v1/models" -Method Get -TimeoutSec 30
$ids = @($models.data | ForEach-Object { $_.id })
$required = @('gpt-5.6', 'gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.6-luna', 'claude-sonnet-5')
$missing = @($required | Where-Object { $_ -notin $ids })

$accounts = Invoke-RestMethod -Uri "$baseUrl/zed/accounts" -Method Get -TimeoutSec 30
$statuses = Invoke-RestMethod -Uri "$baseUrl/zed/accounts/status" -Method Get -TimeoutSec 60
$tokenOk = @($statuses.accounts | Where-Object { $_.token_ok }).Count
$unavailable = @($statuses.accounts | Where-Object { -not $_.token_ok }).Count

Write-Host "Service is healthy: $baseUrl"
Write-Host "Models: $($ids -join ', ')"
Write-Host "Passive account check: $tokenOk token(s) available, $unavailable unavailable; no model request used."
if ($missing.Count -gt 0) {
    Write-Warning "Models missing from the current upstream catalog: $($missing -join ', ')"
}

if ($Deep -or $AllAccounts) {
    $probeBody = if ($AllAccounts) {
        '{}'
    } else {
        if (-not $accounts.current) {
            throw 'No active account is configured.'
        }
        @{ account = $accounts.current } | ConvertTo-Json -Compress
    }

    $probe = Invoke-RestMethod `
        -Uri "$baseUrl/zed/accounts/health" `
        -Method Post `
        -ContentType 'application/json' `
        -Body $probeBody `
        -TimeoutSec 180

    $passed = @($probe.accounts | Where-Object { $_.model_ok }).Count
    Write-Host "Model probes: $passed/$($probe.accounts.Count) passed."
    Write-Host "Probe policy: model=$($probe.probe.model), effort=$($probe.probe.reasoning_effort), max_output_tokens=$($probe.probe.max_output_tokens)."
    if ($passed -ne $probe.accounts.Count) {
        $failedStates = @($probe.accounts | Where-Object { -not $_.model_ok } | ForEach-Object { $_.model_state }) -join ', '
        throw "One or more account model probes failed: $failedStates"
    }
}

function Invoke-SseCheck {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [hashtable]$Body,
        [Parameter(Mandatory)] [string]$EndMarker
    )

    $response = Invoke-WebRequest `
        -Uri "$baseUrl$Path" `
        -Method Post `
        -ContentType 'application/json' `
        -Body ($Body | ConvertTo-Json -Depth 12 -Compress) `
        -TimeoutSec 180

    $content = [string]$response.Content
    if ($response.StatusCode -ne 200 -or $content -notmatch [regex]::Escape($EndMarker) -or $content -notmatch '(?i)ok') {
        throw "$Name streaming check failed: HTTP $($response.StatusCode), expected end marker '$EndMarker' and text 'ok'."
    }
    Write-Host "$Name streaming check passed."
}

if ($Streaming) {
    Write-Warning 'Streaming mode sends three deliberately small model requests; the default passive check sends none.'

    Invoke-SseCheck -Name 'OpenAI Responses' -Path '/v1/responses' -EndMarker 'response.completed' -Body @{
        model             = 'gpt-5.6-luna'
        stream            = $true
        input             = 'Reply with exactly: ok'
        reasoning         = @{ effort = 'none' }
        max_output_tokens = 32
        store             = $false
    }

    Invoke-SseCheck -Name 'OpenAI Chat Completions' -Path '/v1/chat/completions' -EndMarker '[DONE]' -Body @{
        model                 = 'gpt-5.6-luna'
        stream                = $true
        messages              = @(@{ role = 'user'; content = 'Reply with exactly: ok' })
        reasoning_effort      = 'none'
        max_completion_tokens = 32
    }

    # This direct protocol diagnostic is intentionally low effort. Normal
    # Claude Code templates in configs/ remain pinned to xhigh as requested.
    Invoke-SseCheck -Name 'Anthropic Messages' -Path '/v1/messages' -EndMarker 'message_stop' -Body @{
        model         = 'claude-sonnet-5'
        stream        = $true
        max_tokens    = 32
        output_config = @{ effort = 'low' }
        messages      = @(@{ role = 'user'; content = 'Reply with exactly: ok' })
    }
}
