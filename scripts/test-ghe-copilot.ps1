#!/usr/bin/env pwsh
<#
.SYNOPSIS
  POC: End-to-end test of GitHub Enterprise Cloud (data residency) Copilot auth.
  Tests device-flow login, token exchange, model listing, and chat completion.

.DESCRIPTION
  1. Prompts for the GHE host (e.g. breitling-code.ghe.com)
  2. Runs the OAuth device-code flow to obtain a GitHub PAT
  3. Exchanges the PAT for a Copilot API token
  4. Lists available models from the Copilot API
  5. Lets you pick a model and send messages interactively

.NOTES
  Requires PowerShell 7+ (Invoke-RestMethod with -SkipHttpErrorCheck).
  Run: pwsh scripts/test-ghe-copilot.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Defaults ──────────────────────────────────────────────────────────────────
$DEFAULT_CLIENT_ID = "Iv1.b507a08c87ecfe98"
$EDITOR_VERSION    = "vscode/1.96.2"
$USER_AGENT        = "GitHubCopilotChat/0.26.7"

# ── 1. Ask for host ──────────────────────────────────────────────────────────
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  GitHub Enterprise Cloud — Copilot POC Test" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

$GheHost = Read-Host "GitHub Enterprise host (e.g. breitling-code.ghe.com)"
$GheHost = $GheHost.Trim()
if (-not $GheHost) {
    Write-Host "No host provided, aborting." -ForegroundColor Red
    exit 1
}

$ClientId = Read-Host "OAuth Client ID (press Enter for default: $DEFAULT_CLIENT_ID)"
$ClientId = $ClientId.Trim()
if (-not $ClientId) { $ClientId = $DEFAULT_CLIENT_ID }

# Derive URLs
$ApiBase      = "https://api.$GheHost"
$CopilotApi   = "https://copilot-api.$GheHost"
$DeviceCodeUrl   = "https://$GheHost/login/device/code"
$AccessTokenUrl  = "https://$GheHost/login/oauth/access_token"
$CopilotTokenUrl = "$ApiBase/copilot_internal/v2/token"
$CopilotUserUrl  = "$ApiBase/copilot_internal/user"
$ModelsUrl       = "$CopilotApi/models"

Write-Host ""
Write-Host "Derived endpoints:" -ForegroundColor DarkGray
Write-Host "  Device code:    $DeviceCodeUrl" -ForegroundColor DarkGray
Write-Host "  Access token:   $AccessTokenUrl" -ForegroundColor DarkGray
Write-Host "  Copilot token:  $CopilotTokenUrl" -ForegroundColor DarkGray
Write-Host "  Copilot user:   $CopilotUserUrl" -ForegroundColor DarkGray
Write-Host "  Models:         $ModelsUrl" -ForegroundColor DarkGray
Write-Host "  Chat base:      $CopilotApi" -ForegroundColor DarkGray
Write-Host ""

# ── 2. Device code flow ─────────────────────────────────────────────────────
Write-Host "Starting device code flow..." -ForegroundColor Yellow

$dcBody = @{
    client_id = $ClientId
    scope     = "read:user"
}
try {
    $dcResponse = Invoke-RestMethod -Uri $DeviceCodeUrl -Method Post -Body $dcBody `
        -ContentType "application/x-www-form-urlencoded" `
        -Headers @{ Accept = "application/json" }
} catch {
    Write-Host "ERROR requesting device code: $_" -ForegroundColor Red
    Write-Host "Response: $($_.Exception.Response)" -ForegroundColor Red
    exit 1
}

if (-not $dcResponse.device_code) {
    Write-Host "Unexpected device code response:" -ForegroundColor Red
    $dcResponse | ConvertTo-Json -Depth 5
    exit 1
}

$deviceCode  = $dcResponse.device_code
$userCode    = $dcResponse.user_code
$verifyUrl   = $dcResponse.verification_uri
$interval    = [int]($dcResponse.interval ?? 5)
$expiresIn   = [int]($dcResponse.expires_in ?? 900)

Write-Host ""
Write-Host "════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  Open: $verifyUrl" -ForegroundColor White
Write-Host "  Code: $userCode" -ForegroundColor White -BackgroundColor DarkBlue
Write-Host "════════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""

# Copy code to clipboard if possible
try { $userCode | Set-Clipboard; Write-Host "(Code copied to clipboard)" -ForegroundColor DarkGray } catch {}

Write-Host "Waiting for authorization..." -ForegroundColor Yellow

# ── 3. Poll for access token ────────────────────────────────────────────────
$githubToken = $null
$deadline = (Get-Date).AddSeconds([Math]::Max($expiresIn, 300))

while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds $interval

    $pollBody = @{
        client_id   = $ClientId
        device_code = $deviceCode
        grant_type  = "urn:ietf:params:oauth:grant-type:device_code"
    }

    $pollResponse = $null
    try {
        $pollResponse = Invoke-RestMethod -Uri $AccessTokenUrl -Method Post -Body $pollBody `
            -ContentType "application/x-www-form-urlencoded" `
            -Headers @{ Accept = "application/json" } `
            -SkipHttpErrorCheck
    } catch {
        Write-Host "  Poll error: $_" -ForegroundColor DarkGray
        continue
    }

    # Convert to hashtable-like access to avoid strict-mode property errors
    $asJson = $pollResponse | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable

    if ($asJson.ContainsKey("access_token") -and $asJson["access_token"]) {
        $githubToken = $asJson["access_token"]
        Write-Host ""
        Write-Host "Authorized!" -ForegroundColor Green
        break
    }
    elseif ($asJson.ContainsKey("error") -and $asJson["error"] -eq "authorization_pending") {
        Write-Host "." -ForegroundColor DarkGray -NoNewline
    }
    elseif ($asJson.ContainsKey("error") -and $asJson["error"] -eq "slow_down") {
        $interval = $interval + 5
        Write-Host ""
        Write-Host "  ...slowing down (interval=${interval}s)" -ForegroundColor DarkGray -NoNewline
    }
    else {
        Write-Host ""
        Write-Host "  Poll response: $($asJson | ConvertTo-Json -Compress)" -ForegroundColor DarkGray
    }
}

if (-not $githubToken) {
    Write-Host "Timed out waiting for authorization." -ForegroundColor Red
    exit 1
}

$tokenPreview = $githubToken.Substring(0, [Math]::Min(8, $githubToken.Length)) + "..."
Write-Host "GitHub token obtained: $tokenPreview" -ForegroundColor Green

# ── 4. Exchange for Copilot token ───────────────────────────────────────────
Write-Host ""
Write-Host "Exchanging GitHub token for Copilot API token..." -ForegroundColor Yellow
Write-Host "  URL: $CopilotTokenUrl" -ForegroundColor DarkGray

try {
    $copilotResponse = Invoke-RestMethod -Uri $CopilotTokenUrl -Method Get `
        -Headers @{
            Accept        = "application/json"
            Authorization = "Bearer $githubToken"
        }
} catch {
    Write-Host "ERROR exchanging token: $_" -ForegroundColor Red
    exit 1
}

if (-not $copilotResponse.token) {
    Write-Host "Unexpected Copilot token response:" -ForegroundColor Red
    $copilotResponse | ConvertTo-Json -Depth 5
    exit 1
}

$copilotToken = $copilotResponse.token
$expiresAt    = $copilotResponse.expires_at

# Show interesting fields from response
Write-Host "Copilot token obtained! (expires_at: $expiresAt)" -ForegroundColor Green

# Show endpoints from response if present (GHE Cloud includes these)
if ($copilotResponse.endpoints) {
    Write-Host "Token response includes endpoints:" -ForegroundColor DarkGray
    $copilotResponse.endpoints | ConvertTo-Json -Depth 3 | Write-Host -ForegroundColor DarkGray
}

# Check if token string contains proxy-ep (github.com style)
if ($copilotToken -match "proxy-ep=([^;\s]+)") {
    Write-Host "Token string contains proxy-ep: $($Matches[1])" -ForegroundColor DarkGray
} else {
    Write-Host "Token string does NOT contain proxy-ep (expected for GHE Cloud)" -ForegroundColor DarkGray
}

# ── 5. Fetch Copilot user info (optional) ───────────────────────────────────
Write-Host ""
Write-Host "Fetching Copilot user info..." -ForegroundColor Yellow
Write-Host "  URL: $CopilotUserUrl" -ForegroundColor DarkGray

try {
    $userInfo = Invoke-RestMethod -Uri $CopilotUserUrl -Method Get `
        -Headers @{
            Authorization         = "token $githubToken"
            "Editor-Version"      = $EDITOR_VERSION
            "User-Agent"          = $USER_AGENT
            "X-Github-Api-Version" = "2025-04-01"
        }
    Write-Host "Copilot plan: $($userInfo.copilot_plan ?? 'unknown')" -ForegroundColor Green
    if ($userInfo.quota_snapshots) {
        Write-Host "Quota:" -ForegroundColor DarkGray
        $userInfo.quota_snapshots | ConvertTo-Json -Depth 3 | Write-Host -ForegroundColor DarkGray
    }
} catch {
    Write-Host "Could not fetch user info (non-fatal): $_" -ForegroundColor DarkYellow
}

# ── 6. List models ──────────────────────────────────────────────────────────
Write-Host ""
Write-Host "Fetching available models..." -ForegroundColor Yellow
Write-Host "  URL: $ModelsUrl" -ForegroundColor DarkGray

$copilotHeaders = @{
    Authorization            = "Bearer $copilotToken"
    "Editor-Version"         = $EDITOR_VERSION
    "User-Agent"             = $USER_AGENT
    "Copilot-Integration-Id" = "vscode-chat"
    "OpenAI-Intent"          = "conversation-panel"
}

$models = @()
try {
    $modelsResponse = Invoke-RestMethod -Uri $ModelsUrl -Method Get -Headers $copilotHeaders
    if ($modelsResponse.data) {
        $models = $modelsResponse.data
    } elseif ($modelsResponse -is [array]) {
        $models = $modelsResponse
    } else {
        Write-Host "Models response:" -ForegroundColor DarkGray
        $modelsResponse | ConvertTo-Json -Depth 3 | Write-Host -ForegroundColor DarkGray
    }
} catch {
    Write-Host "Could not list models from $ModelsUrl : $_" -ForegroundColor DarkYellow
    Write-Host ""
    Write-Host "Trying alternative URL: $CopilotApi/v1/models" -ForegroundColor Yellow
    try {
        $modelsResponse = Invoke-RestMethod -Uri "$CopilotApi/v1/models" -Method Get -Headers $copilotHeaders
        if ($modelsResponse.data) { $models = $modelsResponse.data }
    } catch {
        Write-Host "Also failed: $_" -ForegroundColor DarkYellow
    }
}

if ($models.Count -eq 0) {
    Write-Host "No models returned. You can enter a model ID manually." -ForegroundColor DarkYellow
    $selectedModel = Read-Host "Model ID (e.g. gpt-4o, claude-sonnet-4.5)"
} else {
    Write-Host ""
    Write-Host "Available models:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $models.Count; $i++) {
        $m = $models[$i]
        $modelId = if ($m.id) { $m.id } elseif ($m.name) { $m.name } else { $m.ToString() }
        Write-Host "  [$($i + 1)] $modelId" -ForegroundColor White
    }
    Write-Host ""
    $choice = Read-Host "Pick a model number (or type a model ID)"
    if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $models.Count) {
        $m = $models[[int]$choice - 1]
        $selectedModel = if ($m.id) { $m.id } elseif ($m.name) { $m.name } else { $m.ToString() }
    } else {
        $selectedModel = $choice.Trim()
    }
}

Write-Host ""
Write-Host "Selected model: $selectedModel" -ForegroundColor Green

# ── 7. Interactive chat ─────────────────────────────────────────────────────
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Interactive Chat  (type 'exit' to quit)" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

$conversation = [System.Collections.ArrayList]::new()
$chatUrl = "$CopilotApi/chat/completions"

Write-Host "Chat endpoint: $chatUrl" -ForegroundColor DarkGray
Write-Host ""

while ($true) {
    $userInput = Read-Host "You"
    if (-not $userInput -or $userInput.Trim().ToLower() -eq "exit") {
        Write-Host "Goodbye!" -ForegroundColor Cyan
        break
    }

    [void]$conversation.Add(@{ role = "user"; content = $userInput })

    $body = @{
        model    = $selectedModel
        messages = @($conversation)
        stream   = $false
    } | ConvertTo-Json -Depth 10

    Write-Host ""
    Write-Host "Sending to $chatUrl ..." -ForegroundColor DarkGray

    try {
        $chatResponse = Invoke-RestMethod -Uri $chatUrl -Method Post `
            -Body $body -ContentType "application/json" `
            -Headers $copilotHeaders `
            -SkipHttpErrorCheck

        $chatJson = $chatResponse | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable

        if ($chatJson.ContainsKey("error") -and $chatJson["error"]) {
            Write-Host "API Error: $($chatJson['error'] | ConvertTo-Json -Compress)" -ForegroundColor Red
            # Also try /v1/chat/completions
            Write-Host "Trying $CopilotApi/v1/chat/completions ..." -ForegroundColor DarkGray
            $chatResponse = Invoke-RestMethod -Uri "$CopilotApi/v1/chat/completions" -Method Post `
                -Body $body -ContentType "application/json" `
                -Headers $copilotHeaders `
                -SkipHttpErrorCheck
            $chatJson = $chatResponse | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
        }

        if ($chatJson.ContainsKey("choices") -and $chatJson["choices"].Count -gt 0) {
            $reply = $chatJson["choices"][0]["message"]["content"]
            Write-Host ""
            Write-Host "Assistant:" -ForegroundColor Green
            Write-Host $reply
            Write-Host ""
            [void]$conversation.Add(@{ role = "assistant"; content = $reply })
        } else {
            Write-Host "Unexpected response:" -ForegroundColor Red
            $chatJson | ConvertTo-Json -Depth 5 | Write-Host
        }
    } catch {
        Write-Host "Request failed: $_" -ForegroundColor Red
        Write-Host ""
    }
}

Write-Host ""
Write-Host "Done. All endpoints worked correctly if you got here!" -ForegroundColor Green
