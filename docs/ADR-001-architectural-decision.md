# ADR-001: Autonomous Retail Store Task Allocator: Foot-Traffic Ingestion & Teams Shifts Balancing

## Status
Accepted

## Service Owner & Sign-Off Authority
Retail Operations Director & Store Experience Lead

## Dominant Artefact
Store Foot-Traffic Replenishment Dynamic Task Matrix

## Decision & Refusal Boundary
All production state mutations must pass deterministic pre-flight policy evaluation in `src/Invoke-StoreTaskRebalance.ps1` and satisfy the 16-test Pester verification contract in `tests/Boundary-Verification.Tests.ps1` before execution.
