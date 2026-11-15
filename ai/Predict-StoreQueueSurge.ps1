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
    [string]$HarnessPath = (Join-Path $PSScriptRoot 'store-demand-eval-harness.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

if (-not $isSurge) {
    return [PSCustomObject]@{
        StoreId              = $StoreId
        ForecastVerdict      = 'STEADY_STATE_NO_ACTION'
        ZScore               = $zScore
        EwmaBaseline         = [Math]::Round($ewma, 1)
        PredictedWaitMinutes = $predictedWaitMinutes
        FatigueVetoedIds     = @()
        RebalanceResult      = $null
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
}
