# Store Operations & Ergonomic Task-Allocation Runbook

## 1. Operational Scope

This runbook governs L2/L3 retail operations and platform engineering for the **Autonomous Store Task Allocator**, covering synthetic store cluster `STR-LON-042` (`198.51.100.0/24`). The system pairs 15-minute Point-of-Sale (POS) & door-footfall Z-score forecasting with deterministic ergonomic fatigue vetoes and Microsoft Graph v2.x Teams Shifts coordination.

## 2. Hysteresis & Ergonomic Guardrails

Naive queue-management bots thrash floor colleagues between shelf replenishment and checkout tills every five minutes, destroying productivity and causing colleague burnout. This platform enforces three non-negotiable guardrails:

1. **Ergonomic Fatigue Veto (`ai/Predict-StoreQueueSurge.ps1`)**:
   - Any colleague who has already been reassigned **2 or more times in a 4-hour rolling window**, or was reassigned within the last **20 minutes**, is automatically excluded from preemption (`VETO_ERGONOMIC_FATIGUE_LIMIT` if no fit colleagues remain).
2. **Task-Tier & Statutory Break Protection (`src/Invoke-StoreTaskRebalance.ps1`)**:
   - Only **Tier-3 deferrable tasks** (such as ambient facing or routine stock tidy) may be preempted.
   - `ChilledDeliveryUnload` (cold-chain compliance), `AgeRestrictedCheckout`, and `OnStatutoryBreak = $true` colleagues are never eligible.
   - Colleague-level cooldown requires `MinutesSinceLastReassignment >= 45` for full preemption.
3. **Store-Wide 20-Minute Hysteresis Damping (`graph/Invoke-TeamsShiftsRebalance.ps1`)**:
   - Even if a Z-score surge (`>= 2.2`) is detected, the Teams Shifts dispatcher suppresses duplicate rebalance cards (`DAMPED_HYSTERESIS_WINDOW`) if another store rebalance occurred within the preceding **20 minutes**.

## 3. L2/L3 Escalation Procedures

### 3.1 `ESCALATE_TO_DUTY_STORE_MANAGER`
- **Symptom**: `Footfall15Min > 150` or `EstimatedQueueWaitMinutes > 4.0`, but all floor colleagues are either on statutory breaks, unloading chilled deliveries, or within their 45-minute cooldown.
- **Action**:
  1. Duty Store Manager receives an escalation alert in Teams.
  2. Do **not** override `OnStatutoryBreak` or `ChilledDeliveryUnload` flags; open an express self-checkout lane or assist directly at the front bank.

### 3.2 `DAMPED_HYSTERESIS_WINDOW` During Sustained Peak
- **Symptom**: Repeated POS bursts within a 20-minute window trigger hysteresis damping.
- **Action**: Query `StoreTaskAllocationAudit_CL` (`queries/Store-Queue-Velocity.kql`) to verify whether `AvgBasketLabourCostGbp` is rising, and adjust baseline staffing on the next Teams Shifts schedule rather than lowering damping below 20 minutes.
