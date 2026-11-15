BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:EvaluatorPath = Join-Path $script:RepoRoot 'src/Invoke-StoreTaskRebalance.ps1'
    $script:PredictPath = Join-Path $script:RepoRoot 'ai/Predict-StoreQueueSurge.ps1'
    $script:HarnessPath = Join-Path $script:RepoRoot 'ai/store-demand-eval-harness.json'
    $script:ShiftsPath = Join-Path $script:RepoRoot 'graph/Invoke-TeamsShiftsRebalance.ps1'
    $script:KqlPath = Join-Path $script:RepoRoot 'queries/Store-Queue-Velocity.kql'
}

Describe 'Autonomous Store Task Allocator - Verification Matrix' {
    Context 'Positive Path: Structural & Zero-IaC Contract Verification' {
        It 'P-01: All PowerShell scripts exist and parse with zero AST syntax errors' {
            foreach ($path in @($script:EvaluatorPath, $script:PredictPath, $script:ShiftsPath)) {
                Test-Path $path | Should -BeTrue
                $errors = $null
                [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
                $errors.Count | Should -Be 0
            }
        }

        It 'P-02: Zero declarative Bicep or Terraform files exist in repository' {
            $iacFiles = Get-ChildItem -Path $script:RepoRoot -Recurse -Include '*.bicep', '*.tf' -File
            $iacFiles.Count | Should -Be 0
        }

        It 'P-03: Demand eval harness defines Z-score threshold, 20m hysteresis, and ergonomic veto' {
            Test-Path $script:HarnessPath | Should -BeTrue
            $h = Get-Content $script:HarnessPath -Raw | ConvertFrom-Json
            $h.forecastingParameters.zScoreAnomalyThreshold | Should -Be 2.2
            $h.forecastingParameters.hysteresisDampingMinutes | Should -Be 20
            $h.ergonomicFatigueVeto.vetoCode | Should -Be 'VETO_ERGONOMIC_FATIGUE_LIMIT'
        }

        It 'P-04: KQL telemetry query, store ops runbook, and README meet depth standards' {
            (Get-Content $script:KqlPath -Raw) | Should -Match 'summarize|order by'
            (Get-Item (Join-Path $script:RepoRoot 'docs/STORE-OPS-RUNBOOK.md')).Length | Should -BeGreaterThan 2000
            (Get-Item (Join-Path $script:RepoRoot 'README.md')).Length | Should -BeGreaterThan 4000
        }
    }

    Context 'Functional AI Queue-Surge Forecasting & Ergonomic Fatigue Veto' {
        It 'AI-01: Returns STEADY_STATE_NO_ACTION during normal footfall' {
            $colleagues = @(
                [PSCustomObject]@{ ColleagueId = 'COL-101'; CurrentTaskTier = 3; CurrentTaskCategory = 'AmbientReplenishment'; OnStatutoryBreak = $false; IsRegisterCertified = $true; MinutesSinceLastReassignment = 60; ReassignmentsLast4Hours = 0 }
            )
            $res = & $script:PredictPath -StoreId 'STR-LON-042' -HistoricalFootfall15Min @(90, 95, 100, 92, 98) -CurrentFootfall15Min 102 -OpenTills 4 -ActiveColleagues $colleagues
            $res.ForecastVerdict | Should -Be 'STEADY_STATE_NO_ACTION'
        }

        It 'AI-02: Predicts surge via Z-score and delegates eligible Tier-3 colleague' {
            $colleagues = @(
                [PSCustomObject]@{ ColleagueId = 'COL-104'; CurrentTaskTier = 3; CurrentTaskCategory = 'AmbientReplenishment'; OnStatutoryBreak = $false; IsRegisterCertified = $true; MinutesSinceLastReassignment = 60; ReassignmentsLast4Hours = 0 }
            )
            $res = & $script:PredictPath -StoreId 'STR-LON-042' -HistoricalFootfall15Min @(90, 95, 100, 92, 98) -CurrentFootfall15Min 175 -OpenTills 3 -ActiveColleagues $colleagues
            $res.ForecastVerdict | Should -Be 'SURGE_PREDICTED_REBALANCE'
            $res.ZScore | Should -BeGreaterThan 2.2
            $res.RebalanceResult.Action | Should -Be 'PREEMPT_TIER3_FOR_REGISTER_RELIEF'
            $res.RebalanceResult.ReassignedIds | Should -Contain 'COL-104'
        }

        It 'AI-03: Triggers VETO_ERGONOMIC_FATIGUE_LIMIT when all colleagues hit 2 swaps / 4h' {
            $colleagues = @(
                [PSCustomObject]@{ ColleagueId = 'COL-105'; CurrentTaskTier = 3; CurrentTaskCategory = 'AmbientReplenishment'; OnStatutoryBreak = $false; IsRegisterCertified = $true; MinutesSinceLastReassignment = 50; ReassignmentsLast4Hours = 2 }
            )
            $res = & $script:PredictPath -StoreId 'STR-LON-042' -HistoricalFootfall15Min @(90, 95, 100, 92, 98) -CurrentFootfall15Min 180 -OpenTills 3 -ActiveColleagues $colleagues
            $res.ForecastVerdict | Should -Be 'VETO_ERGONOMIC_FATIGUE_LIMIT'
            $res.FatigueVetoedIds | Should -Contain 'COL-105'
        }

        It 'AI-04: Fails closed when -UseLiveFoundry is set without -FoundryEndpoint and supports mocked live Foundry REST call' {
            $colleagues = @(
                [PSCustomObject]@{ ColleagueId = 'COL-101'; CurrentTaskTier = 3; CurrentTaskCategory = 'AmbientReplenishment'; OnStatutoryBreak = $false; IsRegisterCertified = $true; MinutesSinceLastReassignment = 60; ReassignmentsLast4Hours = 0 }
            )

            { & $script:PredictPath -StoreId 'STR-LON-042' -HistoricalFootfall15Min @(90, 95, 100, 92, 98) -CurrentFootfall15Min 102 -OpenTills 4 -ActiveColleagues $colleagues -UseLiveFoundry } | Should -Throw '*FoundryEndpoint*'

            Mock Invoke-RestMethod {
                return [PSCustomObject]@{
                    choices = @(
                        [PSCustomObject]@{
                            message = [PSCustomObject]@{
                                content = '{"forecastVerdict":"STEADY_STATE_NO_ACTION","rationale":"Footfall within normal EWMA band."}'
                            }
                        }
                    )
                }
            }

            $res = & $script:PredictPath -StoreId 'STR-LON-042' -HistoricalFootfall15Min @(90, 95, 100, 92, 98) -CurrentFootfall15Min 102 -OpenTills 4 -ActiveColleagues $colleagues -UseLiveFoundry -FoundryEndpoint 'https://contoso-foundry.openai.azure.com' -FoundryApiKey 'test-key'
            $res.InferenceMode | Should -Be 'LIVE_FOUNDRY'
            $res.ForecastVerdict | Should -Be 'STEADY_STATE_NO_ACTION'
            Should -Invoke Invoke-RestMethod -Times 1
        }
    }

    Context 'Graph v2.x Teams Shifts & 20-Minute Hysteresis Damping' {
        It 'GRAPH-01: Suppresses rebalance card with DAMPED_HYSTERESIS_WINDOW when last swap < 20m' {
            $forecast = [PSCustomObject]@{
                StoreId              = 'STR-LON-042'
                ForecastVerdict      = 'SURGE_PREDICTED_REBALANCE'
                ZScore               = 3.4
                PredictedWaitMinutes = 6.2
                RebalanceResult      = [PSCustomObject]@{ Action = 'PREEMPT_TIER3_FOR_REGISTER_RELIEF'; ReassignedIds = @('COL-104') }
            }
            $res = & $script:ShiftsPath -ForecastResult $forecast -TeamId 'team-1' -ChannelId 'chan-1' -MinutesSinceLastStoreRebalance 12 -DryRun
            $res.Status | Should -Be 'DAMPED_HYSTERESIS_WINDOW'
            $res.Dispatched | Should -BeFalse
        }

        It 'GRAPH-02: Stages Teams Shifts & Adaptive Card v1.5 in DryRun mode after cooldown' {
            $forecast = [PSCustomObject]@{
                StoreId              = 'STR-LON-042'
                ForecastVerdict      = 'SURGE_PREDICTED_REBALANCE'
                ZScore               = 3.4
                PredictedWaitMinutes = 6.2
                RebalanceResult      = [PSCustomObject]@{ Action = 'PREEMPT_TIER3_FOR_REGISTER_RELIEF'; ReassignedIds = @('COL-104') }
            }
            $res = & $script:ShiftsPath -ForecastResult $forecast -TeamId 'team-1' -ChannelId 'chan-1' -MinutesSinceLastStoreRebalance 35 -DryRun
            $res.Status | Should -Be 'DRY_RUN_SHIFTS_CARD_STAGED'
            $res.GraphShiftsUri | Should -Match '/teams/team-1/schedule/shifts'
            $res.CardPayload.attachments[0].content | Should -Match 'ACCEPT_TILL_RELIEF'
        }

        It 'OPS-01: Protects ChilledDeliveryUnload colleagues and escalates to Duty Store Manager' {
            $telemetry = [PSCustomObject]@{ StoreId = 'STR-LON-042'; Footfall15Min = 180; EstimatedQueueWaitMinutes = 6.5 }
            $colleagues = @(
                [PSCustomObject]@{ ColleagueId = 'COL-201'; CurrentTaskTier = 3; CurrentTaskCategory = 'ChilledDeliveryUnload'; OnStatutoryBreak = $false; IsRegisterCertified = $true; MinutesSinceLastReassignment = 90 }
            )
            $res = & $script:EvaluatorPath -StoreTelemetry $telemetry -ActiveColleagues $colleagues
            $res.Action | Should -Be 'ESCALATE_TO_DUTY_STORE_MANAGER'
            $res.ReassignedIds.Count | Should -Be 0
        }
    }

    Context 'Zero-Leak Security & Governance Boundaries' {
        It 'N-01: Repository contains zero hardcoded secrets, private IPs, or internal sequence numbers' {
            $files = Get-ChildItem -Path $script:RepoRoot -Recurse -File -Include '*.ps1', '*.md', '*.kql', '*.json' | Where-Object { $_.Name -notlike '*.Tests.ps1' }
            foreach ($f in $files) {
                $raw = Get-Content $f.FullName -Raw
                $raw | Should -Not -Match 'AccountKey=|SharedAccessSignature=|192\.142\.41\.43|mvpfoundry\.alerasoul\.net|Decision Pack 0'
            }
        }
    }
}
