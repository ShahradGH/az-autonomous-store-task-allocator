# Autonomous Store Task Allocator (Queue-Surge Forecasting & Hysteresis Damping)

> **Retail floor orchestration that pairs 15-minute POS/footfall EWMA + Z-score anomaly forecasting with deterministic ergonomic fatigue vetoes, 20-minute hysteresis damping, and Microsoft Graph v2.x Teams Shifts Adaptive Card negotiation.**

---

## 1. Executive & C-Suite Brief

### Business Risk & Retail Margin Impact
In high-footfall retail stores, unpredicted checkout queue spikes drive **basket abandonment**, while over-reactive floor-task bots cause **colleague thrashing**—pulling staff off cold-chain deliveries (`ChilledDeliveryUnload`) or reassigning the same person every 10 minutes until productivity collapses.

### Commercial & Workforce ROI
- **15-Minute Predictive Relief**: `ai/Predict-StoreQueueSurge.ps1` detects POS and door-counter surges (`Z-score >= 2.2` or predicted wait `> 4.0` mins) before queues spill into the aisles.
- **Ergonomic Fatigue Protection**: Hard-caps reassignments at **2 per 4-hour window** (`VETO_ERGONOMIC_FATIGUE_LIMIT`), protects statutory breaks and chilled-delivery compliance, and enforces a **20-minute store-wide hysteresis damper**.
- **Teams Shifts Native**: Integrates directly with Microsoft Graph v2.x `/teams/{id}/schedule/shifts` and posts non-intrusive Adaptive Card v1.5 relief requests rather than issuing rigid top-down commands.

---

## 2. Chief Architect & Engineer Blueprint

### Forecasting, Ergonomic Veto & Hysteresis Architecture

| Layer | Responsibility | Implementation | Guardrail / Veto |
| :--- | :--- | :--- | :--- |
| **1. Demand Forecasting** | 15-min EWMA + Z-score anomaly & wait projection | `ai/Predict-StoreQueueSurge.ps1` + `ai/store-demand-eval-harness.json` | Triggers only when `Z >= 2.2`, `Footfall > 150`, or `Wait > 4.0m` |
| **2. Ergonomic Fatigue Gate** | Enforces max 2 swaps / 4h & >= 20m colleague cooldown | `ai/Predict-StoreQueueSurge.ps1` | Emits `VETO_ERGONOMIC_FATIGUE_LIMIT` if all staff fatigued |
| **3. Task-Tier Rebalance** | Protects Tier-1/2, `ChilledDeliveryUnload`, & breaks | `src/Invoke-StoreTaskRebalance.ps1` | Escalates `ESCALATE_TO_DUTY_STORE_MANAGER` when locked |
| **4. Graph Shifts & Card** | Verifies `/schedule/shifts` & posts Adaptive Card v1.5 | `graph/Invoke-TeamsShiftsRebalance.ps1` | Suppresses thrashing via `DAMPED_HYSTERESIS_WINDOW` (<20m) |

### Store Operations & Edge Telemetry Topology

![Autonomous Store Operations Topology](diagrams/azure-stencil-store-operations-topology.png)

### Queue-Surge Forecasting & Hysteresis Damping Flow

![Task Allocation Hysteresis Flow](diagrams/azure-stencil-task-allocation-hysteresis-flow.png)

---

## 3. AI Subcomponent & Pilot Grafting Guide

### Prerequisites
- **PowerShell 7.4+** (`pwsh`)
- **Pester 6.x** (`Install-Module Pester -MinimumVersion 6.0.0 -Scope CurrentUser`)
- **Microsoft.Graph** (for live `/teams/{id}/schedule/shifts` and channel Adaptive Cards; `-DryRun` supported for CI)

### Local Verification & Pester 6.x Matrix

```powershell
# Run the full Pester 6.x forecasting, ergonomic veto, and Graph Shifts verification suite
Invoke-Pester -Path ./tests/StoreTaskAllocator.Tests.ps1 -Output Detailed
```

### Exercising Queue-Surge Forecasting & Teams Shifts DryRun

```powershell
$colleagues = @(
    [PSCustomObject]@{
        ColleagueId                  = 'COL-104'
        CurrentTaskTier              = 3
        CurrentTaskCategory          = 'AmbientReplenishment'
        OnStatutoryBreak             = $false
        IsRegisterCertified          = $true
        MinutesSinceLastReassignment = 60
        ReassignmentsLast4Hours      = 0
    }
)

$forecast = ./ai/Predict-StoreQueueSurge.ps1 `
    -StoreId 'STR-LON-042' `
    -HistoricalFootfall15Min @(90, 95, 102, 88, 96, 100) `
    -CurrentFootfall15Min 175 `
    -OpenTills 3 `
    -ActiveColleagues $colleagues

./graph/Invoke-TeamsShiftsRebalance.ps1 -ForecastResult $forecast -TeamId 'team-str-042' -ChannelId 'chan-floor-ops' -DryRun
```

---

## 4. Microsoft Learn References

- [Microsoft Graph Shifts API (`/teams/{id}/schedule/shifts`)](https://learn.microsoft.com/en-us/graph/api/schedule-list-shifts)
- [Send Adaptive Cards in Microsoft Teams Channels via Graph](https://learn.microsoft.com/en-us/graph/api/channel-post-messages)
- [Azure Monitor Log Analytics KQL Summarize Operator](https://learn.microsoft.com/en-us/kusto/query/summarize-operator)
- [Azure Well-Architected Framework Operational Excellence](https://learn.microsoft.com/en-us/azure/well-architected/operational-excellence/)
