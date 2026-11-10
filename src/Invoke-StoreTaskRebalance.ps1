# Invoke-StoreTaskRebalance.ps1
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [PSCustomObject]$StoreTelemetry,
    [Parameter(Mandatory)] [PSCustomObject[]]$ActiveColleagues
)

$ErrorActionPreference = 'Stop'

if ($StoreTelemetry.Footfall15Min -le 150 -and $StoreTelemetry.EstimatedQueueWaitMinutes -le 4.0) {
    return [PSCustomObject]@{
        StoreId        = $StoreTelemetry.StoreId
        Action         = 'NO_REBALANCE_REQUIRED'
        ReassignedIds  = @()
    }
}

# Filter strictly for colleagues on Tier-3 deferrable tasks, register-certified, outside break windows, and >45m since last swap
$eligible = @($ActiveColleagues | Where-Object {
    $_.CurrentTaskTier -eq 3 -and
    $_.CurrentTaskCategory -ne 'ChilledDeliveryUnload' -and
    $_.OnStatutoryBreak -eq $false -and
    $_.IsRegisterCertified -eq $true -and
    $_.MinutesSinceLastReassignment -ge 45
})

if ($eligible.Count -eq 0) {
    return [PSCustomObject]@{
        StoreId        = $StoreTelemetry.StoreId
        Action         = 'ESCALATE_TO_DUTY_STORE_MANAGER'
        ReassignedIds  = @()
        Reason         = 'Surge detected (>150/15m), but all colleagues are locked in Tier-1/2 tasks, breaks, or 45m hysteresis cooldown.'
    }
}

$selected = @($eligible | Select-Object -First 2)
return [PSCustomObject]@{
    StoreId        = $StoreTelemetry.StoreId
    Action         = 'PREEMPT_TIER3_FOR_REGISTER_RELIEF'
    ReassignedIds  = @($selected.ColleagueId)
}
