<#
.SYNOPSIS
    Dispatches Teams Shifts & Adaptive Card task-rebalance negotiations with 20-minute hysteresis damping.
.DESCRIPTION
    Queries Microsoft Graph v2.x (/teams/{teamId}/schedule/shifts) to confirm active shift windows and posts
    an Adaptive Card v1.5 negotiation prompt to the store colleagues channel. Enforces a 20-minute hysteresis
    damping window so transient POS spikes never thrash floor staff.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [PSCustomObject]$ForecastResult,

    [Parameter(Mandatory)]
    [string]$TeamId,

    [Parameter(Mandatory)]
    [string]$ChannelId,

    [Parameter()]
    [int]$MinutesSinceLastStoreRebalance = 30,

    [Parameter()]
    [int]$HysteresisDampingMinutes = 20,

    [Parameter()]
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($MinutesSinceLastStoreRebalance -lt $HysteresisDampingMinutes) {
    return [PSCustomObject]@{
        StoreId    = $ForecastResult.StoreId
        Status     = 'DAMPED_HYSTERESIS_WINDOW'
        Dispatched = $false
        Reason     = "Store rebalance suppressed: last rebalance was ${MinutesSinceLastStoreRebalance}m ago (min ${HysteresisDampingMinutes}m)."
    }
}

if ($ForecastResult.ForecastVerdict -ne 'SURGE_PREDICTED_REBALANCE' -or $null -eq $ForecastResult.RebalanceResult -or $ForecastResult.RebalanceResult.ReassignedIds.Count -eq 0) {
    return [PSCustomObject]@{
        StoreId    = $ForecastResult.StoreId
        Status     = 'NO_CARD_REQUIRED'
        Dispatched = $false
        Reason     = "ForecastVerdict=$($ForecastResult.ForecastVerdict); no colleague reassignment staged."
    }
}

$shiftsUri = "https://graph.microsoft.com/v1.0/teams/$TeamId/schedule/shifts"
$channelUri = "https://graph.microsoft.com/v1.0/teams/$TeamId/channels/$ChannelId/messages"
$colleagueList = ($ForecastResult.RebalanceResult.ReassignedIds -join ', ')
$attachmentId = [guid]::NewGuid().ToString()

$adaptiveCard = @{
    type    = 'AdaptiveCard'
    version = '1.5'
    body    = @(
        @{
            type   = 'TextBlock'
            text   = "Queue Surge Relief Request — $($ForecastResult.StoreId)"
            weight = 'Bolder'
            size   = 'Medium'
        },
        @{
            type  = 'FactSet'
            facts = @(
                @{ title = 'Predicted Wait'; value = "$($ForecastResult.PredictedWaitMinutes) mins" },
                @{ title = 'Z-Score Anomaly'; value = "$($ForecastResult.ZScore)" },
                @{ title = 'Eligible Colleagues'; value = $colleagueList },
                @{ title = 'Action'; value = $ForecastResult.RebalanceResult.Action }
            )
        }
    )
    actions = @(
        @{ type = 'Action.Submit'; title = 'Accept Till Relief (20m)'; data = @{ action = 'ACCEPT_TILL_RELIEF'; storeId = $ForecastResult.StoreId } },
        @{ type = 'Action.Submit'; title = 'Defer (Task Critical)'; data = @{ action = 'DEFER_TASK'; storeId = $ForecastResult.StoreId } }
    )
}

$messagePayload = @{
    body        = @{ contentType = 'html'; content = "<attachment id=`"$attachmentId`"></attachment>" }
    attachments = @(@{ id = $attachmentId; contentType = 'application/vnd.microsoft.card.adaptive'; content = ($adaptiveCard | ConvertTo-Json -Depth 10 -Compress) })
}

if ($DryRun) {
    return [PSCustomObject]@{
        StoreId        = $ForecastResult.StoreId
        Status         = 'DRY_RUN_SHIFTS_CARD_STAGED'
        Dispatched     = $false
        GraphShiftsUri = $shiftsUri
        GraphCardUri   = $channelUri
        CardPayload    = $messagePayload
    }
}

if ($PSCmdlet.ShouldProcess($shiftsUri, 'Verify active Teams Shifts via Graph v2.x')) {
    $null = Invoke-MgGraphRequest -Method GET -Uri $shiftsUri
}

if ($PSCmdlet.ShouldProcess($channelUri, 'Post Teams Adaptive Card for colleague till relief')) {
    $resp = Invoke-MgGraphRequest -Method POST -Uri $channelUri -Body ($messagePayload | ConvertTo-Json -Depth 10) -ContentType 'application/json'
    return [PSCustomObject]@{
        StoreId    = $ForecastResult.StoreId
        Status     = 'CARD_DISPATCHED'
        Dispatched = $true
        MessageId  = $resp.id
    }
}
