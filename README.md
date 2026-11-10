# Autonomous Retail Store Task Allocator: Foot-Traffic Ingestion & Teams Shifts Balancing

[![Pester Verification](https://img.shields.io/badge/pester-16%2F16%20passing-brightgreen)](tests/StoreTaskAllocator.Tests.ps1)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Architecture Deep-Dive](https://img.shields.io/badge/blog-alerasoul.net-0a1128)](https://alerasoul.net/autonomous-store-operations-task-allocator/)

> **Primary Governance Artefact:** Store Foot-Traffic Replenishment Dynamic Task Matrix  
> **Accountable Service Owner:** Retail Operations Director & Store Experience Lead  
> **Full Architectural Deep-Dive:** [https://alerasoul.net/autonomous-store-operations-task-allocator/](https://alerasoul.net/autonomous-store-operations-task-allocator/)

---

## Repository Layout (10 Files)

```text
├── .github/workflows/ci.yml
├── .gitignore
├── LICENSE
├── README.md
├── config/ergonomic-fatigue-thresholds.json
├── docs/STORE-OPS-RUNBOOK.md
├── queries/Store-Queue-Velocity.kql
├── schemas/pos-queue-telemetry.json
├── src/Invoke-StoreTaskRebalance.ps1
└── tests/StoreTaskAllocator.Tests.ps1
```

## Quickstart & Offline Verification

```powershell
# 1. Execute the primary PowerShell 7 evaluator
pwsh -NoProfile -File ./src/Invoke-StoreTaskRebalance.ps1

# 2. Run the 16-test Pester verification contract
Invoke-Pester -Path ./tests/StoreTaskAllocator.Tests.ps1 -Output Detailed
```

## License

Released under the [MIT License](LICENSE). Authored by **Shahrad Alerasoul** ([alerasoul.net](https://alerasoul.net)).
