<#
.SYNOPSIS
    15-minute POS/footfall anomaly & queue-surge forecasting model with deterministic ergonomic fatigue veto.
.DESCRIPTION
    Computes EWMA-smoothed arrival rate and Z-score anomaly over 15-minute POS and door-counter telemetry,
    projects queue wait time, filters colleagues through an ergonomic fatigue veto (max 2 swaps / 4h, >=20m cooldown),
    and delegates eligible surges to src/Invoke-StoreTaskRebalance.ps1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$StoreId,

    [Parameter(Mandatory)]
    [double[]]$HistoricalFootfall15Min,

    [Parameter(Mandatory)]
    [double]$CurrentFootfall15Min,

    [Parameter(Mandatory)]
    [int]$OpenTills,

    [Parameter(Mandatory)]
    [PSCustomObject[]]$ActiveColleagues,

    [Parameter()]
    [string]$HarnessPath = (Join-Path $PSScriptRoot 'store-demand-eval-harness.json'),

    [Parameter()]
    [string]$FoundryEndpoint = '',

    [Parameter()]
    [string]$FoundryApiKey = '',

    [Parameter()]
    [string]$FoundryDeployment = 'gpt-4o',

    [Parameter()]
    [string]$FoundryApiVersion = '2024-10-21',

    [Parameter()]
    [switch]$UseLiveFoundry
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($UseLiveFoundry) {
    if ([string]::IsNullOrWhiteSpace($FoundryEndpoint)) {
        throw [System.ArgumentException]::new('Fail-closed: -FoundryEndpoint is required when -UseLiveFoundry is specified.')
    }
    if ($FoundryEndpoint -notmatch '^https://') {
        throw [System.ArgumentException]::new('Fail-closed: -FoundryEndpoint must use https://.')
    }
}

function Get-FoundryAuthHeader {
    param([string]$ApiKey)
    if (-not [string]::IsNullOrWhiteSpace($ApiKey)) {
        return @{
            'api-key'      = $ApiKey
            'Content-Type' = 'application/json'
        }
    }
    if (Get-Command -Name 'Get-AzAccessToken' -ErrorAction SilentlyContinue) {
        $tok = Get-AzAccessToken -ResourceUrl 'https://cognitiveservices.azure.com' -ErrorAction Stop
        $rawToken = if ($tok.Token -is [System.Security.SecureString]) {
            [System.Net.NetworkCredential]::new('', $tok.Token).Password
        } else {
            [string]$tok.Token
        }
        return @{
            'Authorization' = "Bearer $rawToken"
            'Content-Type'  = 'application/json'
        }
    }
    $imdsUri = 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://cognitiveservices.azure.com'
    $imdsResp = Invoke-RestMethod -Method Get -Uri $imdsUri -Headers @{ Metadata = 'true' } -TimeoutSec 5 -ErrorAction Stop
    return @{
        'Authorization' = "Bearer $($imdsResp.access_token)"
        'Content-Type'  = 'application/json'
    }
}

function Invoke-FoundryJsonInference {
    param(
        [string]$Endpoint,
        [string]$ApiKey,
        [string]$Deployment,
        [string]$ApiVersion,
        [string]$SystemPrompt,
        [hashtable]$Payload
    )
    $uri = if ($Endpoint -match '/chat/completions') {
        $Endpoint
    } else {
        "$($Endpoint.TrimEnd('/'))/openai/deployments/$Deployment/chat/completions?api-version=$ApiVersion"
    }
    $headers = Get-FoundryAuthHeader -ApiKey $ApiKey
    $body = @{
        temperature     = 0.0
        response_format = @{ type = 'json_object' }
        messages        = @(
            @{ role = 'system'; content = $SystemPrompt },
            @{ role = 'user'; content = ($Payload | ConvertTo-Json -Depth 6 -Compress) }
        )
    } | ConvertTo-Json -Depth 8 -Compress

    $resp = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $body -TimeoutSec 30 -ErrorAction Stop
    $content = $resp.choices[0].message.content
    return ($content | ConvertFrom-Json -ErrorAction Stop)
}

$harness = Get-Content -Path $HarnessPath -Raw | ConvertFrom-Json
$alpha = [double]$harness.forecastingParameters.ewmaAlpha
$zThreshold = [double]$harness.forecastingParameters.zScoreAnomalyThreshold
$maxSwaps4h = [int]$harness.ergonomicFatigueVeto.maxReassignmentsPer4Hours
$minCooldown = [int]$harness.ergonomicFatigueVeto.minCooldownBetweenSwapsMinutes

# Compute baseline mean, stdDev, and EWMA
$n = [Math]::Max(1, $HistoricalFootfall15Min.Count)
$mean = ($HistoricalFootfall15Min | Measure-Object -Average).Average
$variance = 0.0
$ewma = [double]$HistoricalFootfall15Min[0]
foreach ($val in $HistoricalFootfall15Min) {
    $variance += [Math]::Pow(($val - $mean), 2)
    $ewma = ($alpha * $val) + ((1.0 - $alpha) * $ewma)
}
$stdDev = [Math]::Max(1.0, [Math]::Sqrt($variance / $n))
$zScore = [Math]::Round(($CurrentFootfall15Min - $mean) / $stdDev, 2)

# Estimate queue wait minutes: arrival pressure relative to till capacity (28 customers / 15m / till)
$tillCapacity = [Math]::Max(1, $OpenTills) * 28.0
$pressureRatio = $CurrentFootfall15Min / $tillCapacity
$predictedWaitMinutes = [Math]::Round([Math]::Max(0.5, $pressureRatio * 3.2), 2)

$isSurge = ($zScore -ge $zThreshold) -or ($CurrentFootfall15Min -gt [double]$harness.forecastingParameters.surgeFootfallThreshold) -or ($predictedWaitMinutes -gt [double]$harness.forecastingParameters.maxQueueWaitMinutes)

$inferenceMode = 'DETERMINISTIC_LOCAL'
$foundryRationale = $null

if ($UseLiveFoundry) {
    $allowedVerdicts = @('STEADY_STATE_NO_ACTION', 'SURGE_PREDICTED_REBALANCE', 'VETO_ERGONOMIC_FATIGUE_LIMIT')
    try {
        $foundryResult = Invoke-FoundryJsonInference `
            -Endpoint $FoundryEndpoint `
            -ApiKey $FoundryApiKey `
            -Deployment $FoundryDeployment `
            -ApiVersion $FoundryApiVersion `
            -SystemPrompt 'You are a retail store queue-surge forecaster. Return JSON with keys: forecastVerdict (STEADY_STATE_NO_ACTION|SURGE_PREDICTED_REBALANCE|VETO_ERGONOMIC_FATIGUE_LIMIT), rationale (string).' `
            -Payload @{
                storeId              = $StoreId
                currentFootfall15Min = $CurrentFootfall15Min
                ewmaBaseline         = [Math]::Round($ewma, 1)
                zScore               = $zScore
                predictedWaitMinutes = $predictedWaitMinutes
                openTills            = $OpenTills
                deterministicSurge   = $isSurge
            }

        $llmVerdict = if ($null -ne $foundryResult.PSObject.Properties['forecastVerdict']) { [string]$foundryResult.forecastVerdict } else { '' }
        if ($llmVerdict -in $allowedVerdicts) {
            $inferenceMode = 'LIVE_FOUNDRY'
            if ($null -ne $foundryResult.PSObject.Properties['rationale']) {
                $foundryRationale = [string]$foundryResult.rationale
            }
            if (-not $isSurge -and $llmVerdict -eq 'SURGE_PREDICTED_REBALANCE') {
                $isSurge = $true
            }
        } else {
            Write-Warning "Foundry returned invalid forecastVerdict '$llmVerdict'; falling back to deterministic EWMA/Z-score."
            $inferenceMode = 'DETERMINISTIC_FALLBACK'
        }
    } catch {
        Write-Warning "Live Foundry inference failed ($($_.Exception.Message)); falling back to deterministic EWMA/Z-score."
        $inferenceMode = 'DETERMINISTIC_FALLBACK'
    }
}

if (-not $isSurge) {
    return [PSCustomObject]@{
        StoreId              = $StoreId
        ForecastVerdict      = 'STEADY_STATE_NO_ACTION'
        ZScore               = $zScore
        EwmaBaseline         = [Math]::Round($ewma, 1)
        PredictedWaitMinutes = $predictedWaitMinutes
        FatigueVetoedIds     = @()
        RebalanceResult      = $null
        InferenceMode        = $inferenceMode
        FoundryRationale     = $foundryRationale
    }
}

# Ergonomic fatigue veto before task preemption
$fatigueVetoed = [System.Collections.Generic.List[string]]::new()
$fitColleagues = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($c in $ActiveColleagues) {
    $swaps = if ($null -ne $c.PSObject.Properties['ReassignmentsLast4Hours']) { [int]$c.ReassignmentsLast4Hours } else { 0 }
    if ($swaps -ge $maxSwaps4h -or [int]$c.MinutesSinceLastReassignment -lt $minCooldown) {
        $fatigueVetoed.Add($c.ColleagueId)
    } else {
        $fitColleagues.Add($c)
    }
}

if ($fitColleagues.Count -eq 0) {
    return [PSCustomObject]@{
        StoreId              = $StoreId
        ForecastVerdict      = 'VETO_ERGONOMIC_FATIGUE_LIMIT'
        ZScore               = $zScore
        EwmaBaseline         = [Math]::Round($ewma, 1)
        PredictedWaitMinutes = $predictedWaitMinutes
        FatigueVetoedIds     = $fatigueVetoed.ToArray()
        RebalanceResult      = $null
        InferenceMode        = $inferenceMode
        FoundryRationale     = $foundryRationale
    }
}

$telemetry = [PSCustomObject]@{
    StoreId                   = $StoreId
    Footfall15Min             = $CurrentFootfall15Min
    EstimatedQueueWaitMinutes = $predictedWaitMinutes
}

$rebalanceScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Invoke-StoreTaskRebalance.ps1'
$rebalance = & $rebalanceScript -StoreTelemetry $telemetry -ActiveColleagues $fitColleagues.ToArray()

return [PSCustomObject]@{
    StoreId              = $StoreId
    ForecastVerdict      = 'SURGE_PREDICTED_REBALANCE'
    ZScore               = $zScore
    EwmaBaseline         = [Math]::Round($ewma, 1)
    PredictedWaitMinutes = $predictedWaitMinutes
    FatigueVetoedIds     = $fatigueVetoed.ToArray()
    RebalanceResult      = $rebalance
    InferenceMode        = $inferenceMode
    FoundryRationale     = $foundryRationale
}
