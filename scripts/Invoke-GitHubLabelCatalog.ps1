[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $PlanPath,
    [Parameter(Mandatory)] [string] $PlanSha256,
    [Parameter(Mandatory)] [switch] $Apply,
    [string[]] $Organizations,
    [string[]] $Repositories,
    [ValidateRange(1, 100)] [int] $BatchSize = 100,
    [ValidateRange(1, 168)] [int] $MaxPlanAgeHours = 24,
    [string] $OutputDirectory = './artifacts/github-label-catalog-apply',
    [string] $RunId,
    [switch] $Resume,
    [switch] $ApplySafeActionsWithBlockedExceptions,
    [ValidateRange(0, 10000)] [int] $DelayMilliseconds = 250
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$apiHeaders = @(
    '-H', 'Accept: application/vnd.github+json',
    '-H', 'X-GitHub-Api-Version: 2026-03-10'
)

function Test-StringEqual {
    param([AllowNull()] [string] $Left, [AllowNull()] [string] $Right)
    return [string]::Equals($Left, $Right, [System.StringComparison]::OrdinalIgnoreCase)
}

function ConvertTo-NormalizedSet {
    param([AllowNull()] [object] $Values)
    return @($Values | Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) } | ForEach-Object { ([string] $_).Trim().ToLowerInvariant() } | Sort-Object -Unique)
}

function Test-SetEqual {
    param([string[]] $Left, [string[]] $Right)
    $leftSet = @(ConvertTo-NormalizedSet $Left)
    $rightSet = @(ConvertTo-NormalizedSet $Right)
    return $leftSet.Count -eq $rightSet.Count -and @($leftSet | Where-Object { $rightSet -notcontains $_ }).Count -eq 0
}

function Get-ActionKey {
    param([Parameter(Mandatory)] [object] $Action)
    return "$($Action.organization)/$($Action.repository):$($Action.action):$($Action.label)"
}

function Invoke-GhApi {
    param(
        [Parameter(Mandatory)] [string] $Endpoint,
        [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')] [string] $Method = 'GET',
        [AllowNull()] [object] $Body,
        [switch] $Paginate,
        [ValidateRange(1, 5)] [int] $Attempts = 5
    )

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $stderrPath = [System.IO.Path]::GetTempFileName()
        $inputPath = $null
        try {
            $arguments = @('api') + $apiHeaders + @('--method', $Method, $Endpoint)
            if ($Paginate) {
                $arguments += @('--paginate', '--slurp')
            }
            if ($null -ne $Body) {
                $bodyJson = $Body | ConvertTo-Json -Depth 12 -Compress
                $inputPath = [System.IO.Path]::GetTempFileName()
                [System.IO.File]::WriteAllText($inputPath, $bodyJson, [System.Text.UTF8Encoding]::new($false))
                $arguments += @('--input', $inputPath)
            }

            $raw = (& gh @arguments 2> $stderrPath | Out-String).Trim()
            $exitCode = $LASTEXITCODE
            $stderr = (Get-Content -Raw -LiteralPath $stderrPath -ErrorAction SilentlyContinue | Out-String).Trim()
        }
        finally {
            Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
            if ($null -ne $inputPath) {
                Remove-Item -LiteralPath $inputPath -Force -ErrorAction SilentlyContinue
            }
        }

        if ($exitCode -eq 0) {
            if ([string]::IsNullOrWhiteSpace($raw)) {
                return $null
            }
            $parsed = $raw | ConvertFrom-Json
            if (-not $Paginate) {
                return $parsed
            }

            $items = [System.Collections.Generic.List[object]]::new()
            foreach ($page in @($parsed)) {
                foreach ($item in @($page)) {
                    if ($null -ne $item) {
                        $items.Add($item)
                    }
                }
            }
            return $items.ToArray()
        }

        if ($attempt -eq $Attempts -or $stderr -match 'HTTP (400|401|404|410|422)\b') {
            throw "GitHub $Method failed for $Endpoint.`n$stderr"
        }
        Start-Sleep -Seconds ([math]::Pow(2, $attempt - 1))
    }
}

function Get-RepositoryLabels {
    param([Parameter(Mandatory)] [object] $Action)
    return @(Invoke-GhApi -Endpoint "repos/$($Action.organization)/$($Action.repository)/labels?per_page=100" -Paginate)
}

function Find-Label {
    param([object[]] $Labels, [Parameter(Mandatory)] [string] $Name)
    return @($Labels | Where-Object { Test-StringEqual ([string] $_.name) $Name } | Select-Object -First 1)
}

function Test-TargetMetadata {
    param([Parameter(Mandatory)] [object] $Label, [Parameter(Mandatory)] [object] $Action)
    return (Test-StringEqual ([string] $Label.color) ([string] $Action.target_color)) -and
        [string] $Label.description -eq [string] $Action.target_description
}

function Assert-OriginalMetadata {
    param([Parameter(Mandatory)] [object] $Label, [Parameter(Mandatory)] [object] $Action)
    if (-not (Test-StringEqual ([string] $Label.color) ([string] $Action.current_color)) -or
        [string] $Label.description -ne [string] $Action.current_description) {
        throw "Label metadata drift detected for '$($Action.label)' in $($Action.organization)/$($Action.repository)."
    }
}

function Get-LiveUsageCount {
    param([Parameter(Mandatory)] [object] $Action)
    $encodedLabel = [uri]::EscapeDataString([string] $Action.label)
    $items = @(Invoke-GhApi -Endpoint "repos/$($Action.organization)/$($Action.repository)/issues?state=all&labels=$encodedLabel&per_page=1")
    return @($items | Where-Object { $null -ne $_ }).Count
}

function Write-RunEvent {
    param([Parameter(Mandatory)] [string] $Status, [AllowNull()] [object] $Action, [AllowNull()] [object] $Details)
    [ordered]@{
        recorded_at = (Get-Date).ToUniversalTime().ToString('o')
        status = $Status
        key = if ($null -eq $Action) { $null } else { Get-ActionKey $Action }
        details = $Details
    } | ConvertTo-Json -Depth 10 -Compress | Add-Content -Encoding utf8 $script:eventsPath
}

function Get-RunEvents {
    if (-not (Test-Path -LiteralPath $script:eventsPath)) { return @() }
    return @(Get-Content -LiteralPath $script:eventsPath | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
}

function Invoke-LabelAction {
    param([Parameter(Mandatory)] [object] $Action)

    $key = Get-ActionKey $Action
    $safeKey = $key -replace '[^a-zA-Z0-9._-]', '--'
    $beforePath = Join-Path $script:snapshotDirectory "$safeKey.before.json"
    $afterPath = Join-Path $script:snapshotDirectory "$safeKey.after.json"
    $labels = @(Get-RepositoryLabels $Action)
    $currentMatch = @(Find-Label -Labels $labels -Name $Action.label)
    if (-not (Test-Path -LiteralPath $beforePath)) {
        [ordered]@{ action = $Action; labels = $labels } | ConvertTo-Json -Depth 12 | Set-Content -Encoding utf8 $beforePath
    }

    Write-RunEvent -Status 'action_started' -Action $Action -Details $null
    switch ([string] $Action.action) {
        'create' {
            if ($currentMatch.Count -gt 0) {
                if (-not (Test-TargetMetadata -Label $currentMatch[0] -Action $Action)) {
                    throw "Label '$($Action.label)' appeared after planning with unexpected metadata."
                }
            }
            else {
                Invoke-GhApi -Method POST -Endpoint "repos/$($Action.organization)/$($Action.repository)/labels" -Body @{
                    name = [string] $Action.label
                    color = [string] $Action.target_color
                    description = [string] $Action.target_description
                } | Out-Null
            }
        }
        'update' {
            if ($currentMatch.Count -eq 0) {
                throw "Label '$($Action.label)' disappeared after planning."
            }
            if (-not (Test-TargetMetadata -Label $currentMatch[0] -Action $Action)) {
                Assert-OriginalMetadata -Label $currentMatch[0] -Action $Action
                $encodedLabel = [uri]::EscapeDataString([string] $Action.label)
                Invoke-GhApi -Method PATCH -Endpoint "repos/$($Action.organization)/$($Action.repository)/labels/$encodedLabel" -Body @{
                    name = [string] $Action.label
                    color = [string] $Action.target_color
                    description = [string] $Action.target_description
                } | Out-Null
            }
        }
        'delete' {
            if ($currentMatch.Count -gt 0) {
                Assert-OriginalMetadata -Label $currentMatch[0] -Action $Action
                $usageCount = Get-LiveUsageCount $Action
                if ($usageCount -gt 0) {
                    throw "Deletion blocked: '$($Action.label)' has at least one live association in $($Action.organization)/$($Action.repository)."
                }
                $encodedLabel = [uri]::EscapeDataString([string] $Action.label)
                Invoke-GhApi -Method DELETE -Endpoint "repos/$($Action.organization)/$($Action.repository)/labels/$encodedLabel" | Out-Null
            }
        }
        default { throw "Unsupported label catalog action '$($Action.action)'." }
    }

    $verifiedLabels = @(Get-RepositoryLabels $Action)
    $verifiedMatch = @(Find-Label -Labels $verifiedLabels -Name $Action.label)
    if ($Action.action -eq 'delete') {
        if ($verifiedMatch.Count -gt 0) { throw "Deleted label '$($Action.label)' is still present." }
    }
    else {
        if ($verifiedMatch.Count -ne 1 -or -not (Test-TargetMetadata -Label $verifiedMatch[0] -Action $Action)) {
            throw "Label '$($Action.label)' did not converge to the standards manifest."
        }
    }

    [ordered]@{ action = $Action; labels = $verifiedLabels } | ConvertTo-Json -Depth 12 | Set-Content -Encoding utf8 $afterPath
    Write-RunEvent -Status 'action_verified' -Action $Action -Details @{ repository = "$($Action.organization)/$($Action.repository)" }
}

if (-not $Apply) { throw 'Pass -Apply with the reviewed plan SHA-256 to acknowledge label catalog mutation.' }
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'GitHub CLI (gh) is required.' }
if (-not (Test-Path -LiteralPath $PlanPath -PathType Leaf)) { throw "Label catalog plan not found: $PlanPath" }

$resolvedPlanPath = (Resolve-Path -LiteralPath $PlanPath).ProviderPath
$actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedPlanPath).Hash.ToLowerInvariant()
if (-not (Test-StringEqual $actualHash $PlanSha256.ToLowerInvariant())) { throw 'Label catalog plan SHA-256 mismatch.' }
$plan = Get-Content -Raw -LiteralPath $resolvedPlanPath | ConvertFrom-Json
if ($plan.plan_schema_version -ne 1 -or $plan.mode -ne 'label-catalog-dry-run-read-only') { throw 'Unsupported label catalog plan.' }
$planAge = [datetimeoffset]::UtcNow - [datetimeoffset]::Parse([string] $plan.generated_at).ToUniversalTime()
if ($planAge.TotalMinutes -lt -5 -or $planAge.TotalHours -gt $MaxPlanAgeHours) { throw 'Label catalog plan is stale; generate and review a fresh dry run.' }
if (@($plan.errors).Count -gt 0) { throw 'Plan contains read errors.' }

[string[]] $selectedOrganizations = @()
if ($null -ne $Organizations) { $selectedOrganizations = @(ConvertTo-NormalizedSet $Organizations) }
if ($selectedOrganizations.Length -eq 0) { $selectedOrganizations = @(ConvertTo-NormalizedSet $plan.organizations) }
[string[]] $selectedRepositories = @()
if ($null -ne $Repositories) { $selectedRepositories = @(ConvertTo-NormalizedSet $Repositories) }

$blockedActions = @($plan.actions | Where-Object {
    $selectedOrganizations -contains $_.organization.ToLowerInvariant() -and
    ($selectedRepositories.Length -eq 0 -or $selectedRepositories -contains $_.repository.ToLowerInvariant()) -and
    -not $_.safe_to_apply
})
if ($blockedActions.Count -gt 0 -and -not $ApplySafeActionsWithBlockedExceptions) {
    throw 'The selected scope contains blocked actions. Pass -ApplySafeActionsWithBlockedExceptions to apply only its independently safe actions.'
}

$actions = @($plan.actions | Where-Object {
    $selectedOrganizations -contains $_.organization.ToLowerInvariant() -and
    ($selectedRepositories.Length -eq 0 -or $selectedRepositories -contains $_.repository.ToLowerInvariant()) -and
    $_.safe_to_apply
} | Sort-Object organization, repository, action, label)
if ($actions.Count -eq 0) { throw 'No label catalog actions match the selected filters.' }

$resolvedOutput = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = "plan-$($actualHash.Substring(0, 12))" }
elseif ($RunId -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]*$') { throw 'Invalid RunId.' }
$runRoot = Join-Path $resolvedOutput $RunId
$script:eventsPath = Join-Path $runRoot 'events.jsonl'
$script:snapshotDirectory = Join-Path $runRoot 'labels'
$manifestPath = Join-Path $runRoot 'run-manifest.json'
if ((Test-Path -LiteralPath $runRoot) -and -not $Resume) { throw "Run directory already exists: $runRoot" }
New-Item -ItemType Directory -Force -Path $script:snapshotDirectory | Out-Null

$lockPath = Join-Path $runRoot 'run.lock'
try {
    $runLock = [System.IO.File]::Open(
        $lockPath,
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
}
catch { throw "Another label catalog process is already using run '$RunId'." }

try {
    if ($Resume) {
        if (-not (Test-Path -LiteralPath $manifestPath)) { throw 'Cannot resume without the original run manifest.' }
        $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
        if (-not (Test-StringEqual ([string] $manifest.plan_sha256) $actualHash) -or
            -not (Test-SetEqual @($manifest.organizations) $selectedOrganizations) -or
            -not (Test-SetEqual @($manifest.repositories) $selectedRepositories) -or
            [bool] $manifest.apply_safe_actions_with_blocked_exceptions -ne [bool] $ApplySafeActionsWithBlockedExceptions) {
            throw 'Resume filters, blocked-exception acknowledgement, or plan hash do not match the original run.'
        }
    }
    else {
        [ordered]@{
            created_at = (Get-Date).ToUniversalTime().ToString('o')
            plan_path = $resolvedPlanPath
            plan_sha256 = $actualHash
            organizations = $selectedOrganizations
            repositories = $selectedRepositories
            apply_safe_actions_with_blocked_exceptions = [bool] $ApplySafeActionsWithBlockedExceptions
            blocked_actions_skipped = $blockedActions.Count
        } | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8 $manifestPath
    }

    $events = @(Get-RunEvents)
    $completedKeys = @($events | Where-Object status -eq 'action_verified' | ForEach-Object key | Sort-Object -Unique)
    $pending = @($actions | Where-Object { $completedKeys -notcontains (Get-ActionKey $_) })
    $batch = @($pending | Select-Object -First $BatchSize)
    $failures = 0
    foreach ($action in $batch) {
        Write-Host "Applying $($action.action) $($action.organization)/$($action.repository):$($action.label)..."
        try { Invoke-LabelAction $action }
        catch {
            $failures++
            Write-RunEvent -Status 'action_failed' -Action $action -Details @{ error = $_.Exception.Message }
            Write-Error "Label catalog action failed for $(Get-ActionKey $action): $($_.Exception.Message)" -ErrorAction Continue
            break
        }
        if ($DelayMilliseconds -gt 0) { Start-Sleep -Milliseconds $DelayMilliseconds }
    }

    $finalEvents = @(Get-RunEvents)
    $finalCompleted = @($finalEvents | Where-Object status -eq 'action_verified' | ForEach-Object key | Sort-Object -Unique)
    $remaining = @($actions | Where-Object { $finalCompleted -notcontains (Get-ActionKey $_) })
    $summary = [ordered]@{
        generated_at = (Get-Date).ToUniversalTime().ToString('o')
        run_id = $RunId
        plan_sha256 = $actualHash
        selected_actions = $actions.Count
        verified = @($actions | Where-Object { $finalCompleted -contains (Get-ActionKey $_) }).Count
        remaining = $remaining.Count
        blocked_actions_skipped = $blockedActions.Count
        failures_this_invocation = $failures
    }
    $summary | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8 (Join-Path $runRoot 'summary.json')
    Write-Host "Label catalog invocation complete. Verified: $($summary.verified). Remaining: $($summary.remaining)."
    Write-Host "Run evidence: $runRoot"
    if ($failures -gt 0) { throw 'A label catalog action failed. Review the event ledger before resuming.' }
}
finally { $runLock.Dispose() }
