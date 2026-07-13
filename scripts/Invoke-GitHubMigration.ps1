[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $PlanPath,
    [Parameter(Mandatory)] [string] $PlanSha256,
    [Parameter(Mandatory)] [switch] $Apply,
    [string[]] $Organizations,
    [string[]] $Repositories,
    [ValidateRange(1, 64)] [int] $ShardCount = 1,
    [ValidateRange(0, 63)] [int] $ShardIndex = 0,
    [ValidateRange(1, 100)] [int] $BatchSize = 25,
    [ValidateRange(1, 168)] [int] $MaxPlanAgeHours = 24,
    [string] $OutputDirectory = './artifacts/github-migration-apply',
    [string] $RunId,
    [switch] $Resume,
    [switch] $ContinueOnError,
    [ValidateRange(0, 10000)] [int] $DelayMilliseconds = 250
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$apiHeaders = @(
    '-H', 'Accept: application/vnd.github+json',
    '-H', 'X-GitHub-Api-Version: 2026-03-10'
)

function ConvertTo-NormalizedLabels {
    param([AllowNull()] [object] $Labels)

    if ($null -eq $Labels) {
        return @()
    }

    if ($Labels -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Labels)) {
            return @()
        }

        return @($Labels -split '\|' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ } | Sort-Object -Unique)
    }

    return @($Labels | ForEach-Object {
        if ($_ -is [string]) {
            $_.Trim().ToLowerInvariant()
        }
        else {
            $_.name.Trim().ToLowerInvariant()
        }
    } | Where-Object { $_ } | Sort-Object -Unique)
}

function Get-IssueTypeName {
    param([AllowNull()] [object] $Issue)

    if ($null -eq $Issue -or $Issue.PSObject.Properties.Name -notcontains 'type' -or $null -eq $Issue.type) {
        return $null
    }

    if ($Issue.type -is [string]) {
        return [string] $Issue.type
    }

    return [string] $Issue.type.name
}

function Get-ProposalKey {
    param([Parameter(Mandatory)] [object] $Proposal)

    return "$($Proposal.organization)/$($Proposal.repository)#$($Proposal.number)"
}

function Get-ProposalShardIndex {
    param(
        [Parameter(Mandatory)] [object] $Proposal,
        [Parameter(Mandatory)] [int] $Count
    )

    $keyBytes = [System.Text.Encoding]::UTF8.GetBytes((Get-ProposalKey $Proposal).ToLowerInvariant())
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha256.ComputeHash($keyBytes)
    }
    finally {
        $sha256.Dispose()
    }

    [uint64] $value = ([uint64] $hash[0] -shl 24) -bor
        ([uint64] $hash[1] -shl 16) -bor
        ([uint64] $hash[2] -shl 8) -bor
        [uint64] $hash[3]

    return [int] ($value % $Count)
}

function Test-StringEqual {
    param(
        [AllowNull()] [string] $Left,
        [AllowNull()] [string] $Right
    )

    return [string]::Equals($Left, $Right, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-SetEqual {
    param(
        [string[]] $Left,
        [string[]] $Right
    )

    $leftNormalized = @(ConvertTo-NormalizedLabels $Left)
    $rightNormalized = @(ConvertTo-NormalizedLabels $Right)

    if ($leftNormalized.Count -ne $rightNormalized.Count) {
        return $false
    }

    return @($leftNormalized | Where-Object { $rightNormalized -notcontains $_ }).Count -eq 0
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
                $raw = (& gh @arguments 2> $stderrPath | Out-String).Trim()
            }
            else {
                $raw = (& gh @arguments 2> $stderrPath | Out-String).Trim()
            }

            $exitCode = $LASTEXITCODE
            $stderr = (Get-Content -Raw $stderrPath -ErrorAction SilentlyContinue | Out-String).Trim()
        }
        finally {
            Remove-Item $stderrPath -Force -ErrorAction SilentlyContinue
            if ($null -ne $inputPath) {
                Remove-Item $inputPath -Force -ErrorAction SilentlyContinue
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
                    $items.Add($item)
                }
            }

            return $items.ToArray()
        }

        if ($attempt -eq $Attempts) {
            throw "GitHub $Method failed for $Endpoint after $Attempts attempts.`n$stderr"
        }

        if ($stderr -match 'HTTP (400|401|404|410|422)\b') {
            throw "GitHub $Method failed for $Endpoint with a non-retryable response.`n$stderr"
        }

        Start-Sleep -Seconds ([math]::Pow(2, $attempt - 1))
    }
}

function Get-IssueState {
    param([Parameter(Mandatory)] [object] $Proposal)

    $issue = Invoke-GhApi -Endpoint "repos/$($Proposal.organization)/$($Proposal.repository)/issues/$($Proposal.number)"
    $fieldValues = @()
    if ($Proposal.kind -eq 'issue') {
        $fieldValues = @(Invoke-GhApi -Endpoint "repos/$($Proposal.organization)/$($Proposal.repository)/issues/$($Proposal.number)/issue-field-values?per_page=100")
    }

    $priorityField = @($fieldValues | Where-Object {
        $null -ne $_ -and $_.PSObject.Properties.Name -contains 'issue_field_name' -and $_.issue_field_name -eq 'Priority'
    } | Select-Object -First 1)
    $priority = $null
    if ($priorityField.Count -gt 0 -and $null -ne $priorityField[0].single_select_option) {
        $priority = [string] $priorityField[0].single_select_option.name
    }

    return [pscustomobject]@{
        issue = $issue
        labels = @(ConvertTo-NormalizedLabels $issue.labels)
        type = if ($Proposal.kind -eq 'issue') { Get-IssueTypeName $issue } else { $null }
        priority = $priority
        state = [string] $issue.state
        updated_at = [string] $issue.updated_at
        field_values = $fieldValues
    }
}

function Assert-SafeProgressState {
    param(
        [Parameter(Mandatory)] [object] $Proposal,
        [Parameter(Mandatory)] [object] $State,
        [bool] $Started
    )

    if ($State.state -ne $Proposal.state) {
        throw "State drift detected: plan has '$($Proposal.state)', GitHub has '$($State.state)'."
    }

    if (-not $Started -and $State.updated_at -ne $Proposal.source_updated_at) {
        throw "Updated-at drift detected: plan has '$($Proposal.source_updated_at)', GitHub has '$($State.updated_at)'. Regenerate the dry run."
    }

    $currentType = [string] $State.type
    $allowedTypes = @([string] $Proposal.current_type, [string] $Proposal.proposed_type) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique
    if (-not [string]::IsNullOrWhiteSpace($currentType) -and $allowedTypes -notcontains $currentType) {
        throw "Issue type drift detected: '$currentType' is neither the planned original nor target type."
    }

    if ([string]::IsNullOrWhiteSpace($currentType) -and -not [string]::IsNullOrWhiteSpace([string] $Proposal.current_type)) {
        throw 'Issue type was removed after the plan was generated.'
    }

    $currentPriority = [string] $State.priority
    $allowedPriorities = @([string] $Proposal.current_priority, [string] $Proposal.proposed_priority) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique
    if (-not [string]::IsNullOrWhiteSpace($currentPriority) -and $allowedPriorities -notcontains $currentPriority) {
        throw "Priority drift detected: '$currentPriority' is neither the planned original nor target Priority."
    }

    if ([string]::IsNullOrWhiteSpace($currentPriority) -and -not [string]::IsNullOrWhiteSpace([string] $Proposal.current_priority)) {
        throw 'Priority was removed after the plan was generated.'
    }

    $originalLabels = @(ConvertTo-NormalizedLabels $Proposal.current_labels)
    $targetLabels = @(ConvertTo-NormalizedLabels $Proposal.proposed_labels)
    $removeLabels = @(ConvertTo-NormalizedLabels $Proposal.remove_labels)
    $allowedLabels = @($originalLabels + $targetLabels | Sort-Object -Unique)
    $requiredLabels = @($originalLabels | Where-Object { $removeLabels -notcontains $_ })
    $unexpectedLabels = @($State.labels | Where-Object { $allowedLabels -notcontains $_ })
    $missingRequiredLabels = @($requiredLabels | Where-Object { $State.labels -notcontains $_ })

    if ($unexpectedLabels.Count -gt 0) {
        throw "Label drift detected; unexpected labels: $([string]::Join(', ', $unexpectedLabels))."
    }

    if ($missingRequiredLabels.Count -gt 0) {
        throw "Label drift detected; required labels disappeared: $([string]::Join(', ', $missingRequiredLabels))."
    }
}

function Write-RunEvent {
    param(
        [Parameter(Mandatory)] [string] $Status,
        [AllowNull()] [object] $Proposal,
        [AllowNull()] [object] $Details
    )

    $event = [ordered]@{
        recorded_at = (Get-Date).ToUniversalTime().ToString('o')
        status = $Status
        key = if ($null -eq $Proposal) { $null } else { Get-ProposalKey $Proposal }
        details = $Details
    }

    ($event | ConvertTo-Json -Depth 12 -Compress) | Add-Content -Encoding utf8 $script:eventsPath
}

function Get-RunEvents {
    if (-not (Test-Path -LiteralPath $script:eventsPath)) {
        return @()
    }

    return @(Get-Content -LiteralPath $script:eventsPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
}

function Get-PriorityFieldId {
    param([Parameter(Mandatory)] [string] $Organization)

    if ($script:priorityFieldIds.ContainsKey($Organization)) {
        return $script:priorityFieldIds[$Organization]
    }

    $fields = @(Invoke-GhApi -Endpoint "orgs/$Organization/issue-fields?per_page=100" -Paginate)
    $priorityFields = @($fields | Where-Object { $_.name -eq 'Priority' })
    if ($priorityFields.Count -ne 1) {
        throw "Expected exactly one organization issue field named Priority in $Organization; found $($priorityFields.Count)."
    }

    $fieldId = [int64] $priorityFields[0].id
    $script:priorityFieldIds[$Organization] = $fieldId

    return $fieldId
}

function Ensure-CanonicalLabels {
    param(
        [Parameter(Mandatory)] [string] $Organization,
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [string[]] $Names
    )

    if ($Names.Count -eq 0) {
        return
    }

    $repositoryKey = "$Organization/$Repository"
    $unpreparedNames = @($Names | Where-Object { -not $script:preparedLabels.Contains("$repositoryKey|$_") } | Sort-Object -Unique)
    if ($unpreparedNames.Count -eq 0) {
        return
    }

    $labels = @(Invoke-GhApi -Endpoint "repos/$Organization/$Repository/labels?per_page=100" -Paginate)
    $labelBackupPath = Join-Path $script:repositorySnapshotDirectory "$Organization--$Repository--labels.before.json"
    if (-not (Test-Path -LiteralPath $labelBackupPath)) {
        $labels | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8 $labelBackupPath
    }

    foreach ($name in $unpreparedNames) {
        $standard = @($script:standards.labels | Where-Object { $_.name -eq $name })
        if ($standard.Count -ne 1) {
            throw "Target label '$name' is not defined exactly once in the standards manifest."
        }

        $existing = @($labels | Where-Object { $_.name -eq $name })
        $body = [ordered]@{
            name = [string] $standard[0].name
            color = [string] $standard[0].color
            description = [string] $standard[0].description
        }

        if ($existing.Count -eq 0) {
            try {
                Invoke-GhApi -Method POST -Endpoint "repos/$Organization/$Repository/labels" -Body $body | Out-Null
                Write-RunEvent -Status 'label_definition_created' -Proposal $null -Details @{ repository = $repositoryKey; label = $name }
            }
            catch {
                $concurrentLabels = @(Invoke-GhApi -Endpoint "repos/$Organization/$Repository/labels?per_page=100" -Paginate)
                $concurrentLabel = @($concurrentLabels | Where-Object { $_.name -eq $name })
                if ($concurrentLabel.Count -ne 1 -or $concurrentLabel[0].color -ne $body.color -or
                    [string] $concurrentLabel[0].description -ne [string] $body.description) {
                    throw
                }
                Write-RunEvent -Status 'label_definition_converged_concurrently' -Proposal $null -Details @{ repository = $repositoryKey; label = $name }
            }
        }
        elseif ($existing[0].color -ne $body.color -or [string] $existing[0].description -ne $body.description) {
            $encodedName = [uri]::EscapeDataString($name)
            Invoke-GhApi -Method PATCH -Endpoint "repos/$Organization/$Repository/labels/$encodedName" -Body $body | Out-Null
            Write-RunEvent -Status 'label_definition_normalized' -Proposal $null -Details @{ repository = $repositoryKey; label = $name }
        }
    }

    $verifiedLabels = @(Invoke-GhApi -Endpoint "repos/$Organization/$Repository/labels?per_page=100" -Paginate)
    foreach ($name in $unpreparedNames) {
        $standard = @($script:standards.labels | Where-Object { $_.name -eq $name })[0]
        $verified = @($verifiedLabels | Where-Object { $_.name -eq $name })
        if ($verified.Count -ne 1 -or $verified[0].color -ne $standard.color -or [string] $verified[0].description -ne [string] $standard.description) {
            throw "Canonical label '$name' did not converge in $repositoryKey."
        }
    }

    foreach ($name in $unpreparedNames) {
        $script:preparedLabels.Add("$repositoryKey|$name") | Out-Null
    }
}

function Invoke-ProposalMigration {
    param(
        [Parameter(Mandatory)] [object] $Proposal,
        [bool] $Started
    )

    $key = Get-ProposalKey $Proposal
    $safeKey = $key -replace '[^a-zA-Z0-9._-]', '--'
    $beforePath = Join-Path $script:itemSnapshotDirectory "$safeKey.before.json"
    $afterPath = Join-Path $script:itemSnapshotDirectory "$safeKey.after.json"
    $state = Get-IssueState $Proposal
    Assert-SafeProgressState -Proposal $Proposal -State $state -Started $Started

    if (-not (Test-Path -LiteralPath $beforePath)) {
        $state | ConvertTo-Json -Depth 12 | Set-Content -Encoding utf8 $beforePath
    }

    Write-RunEvent -Status 'item_started' -Proposal $Proposal -Details @{ resumed = $Started }

    if ($Proposal.kind -eq 'issue' -and -not [string]::IsNullOrWhiteSpace([string] $Proposal.proposed_type) -and
        -not (Test-StringEqual $state.type ([string] $Proposal.proposed_type))) {
        Invoke-GhApi -Method PATCH -Endpoint "repos/$($Proposal.organization)/$($Proposal.repository)/issues/$($Proposal.number)" -Body @{ type = [string] $Proposal.proposed_type } | Out-Null
        $state = Get-IssueState $Proposal
        if (-not (Test-StringEqual $state.type ([string] $Proposal.proposed_type))) {
            throw "Issue type did not converge to '$($Proposal.proposed_type)'."
        }
        Write-RunEvent -Status 'type_verified' -Proposal $Proposal -Details @{ type = $state.type }
    }

    if ($Proposal.kind -eq 'issue' -and -not [string]::IsNullOrWhiteSpace([string] $Proposal.proposed_priority) -and
        -not (Test-StringEqual $state.priority ([string] $Proposal.proposed_priority))) {
        $priorityFieldId = Get-PriorityFieldId $Proposal.organization
        $priorityBody = @{ issue_field_values = @(@{ field_id = $priorityFieldId; value = [string] $Proposal.proposed_priority }) }
        Invoke-GhApi -Method POST -Endpoint "repos/$($Proposal.organization)/$($Proposal.repository)/issues/$($Proposal.number)/issue-field-values" -Body $priorityBody | Out-Null
        $state = Get-IssueState $Proposal
        if (-not (Test-StringEqual $state.priority ([string] $Proposal.proposed_priority))) {
            throw "Priority did not converge to '$($Proposal.proposed_priority)'."
        }
        Write-RunEvent -Status 'priority_verified' -Proposal $Proposal -Details @{ priority = $state.priority }
    }

    $targetLabels = @(ConvertTo-NormalizedLabels $Proposal.proposed_labels)
    $missingTargetLabels = @($targetLabels | Where-Object { $state.labels -notcontains $_ })
    if ($targetLabels.Count -gt 0) {
        Ensure-CanonicalLabels -Organization $Proposal.organization -Repository $Proposal.repository -Names $targetLabels
    }

    if ($missingTargetLabels.Count -gt 0) {
        Invoke-GhApi -Method POST -Endpoint "repos/$($Proposal.organization)/$($Proposal.repository)/issues/$($Proposal.number)/labels" -Body @{ labels = $missingTargetLabels } | Out-Null
        $state = Get-IssueState $Proposal
        $unverifiedAdds = @($missingTargetLabels | Where-Object { $state.labels -notcontains $_ })
        if ($unverifiedAdds.Count -gt 0) {
            throw "Replacement labels did not converge: $([string]::Join(', ', $unverifiedAdds))."
        }
        Write-RunEvent -Status 'replacement_labels_verified' -Proposal $Proposal -Details @{ labels = $missingTargetLabels }
    }

    foreach ($label in @(ConvertTo-NormalizedLabels $Proposal.remove_labels)) {
        if ($state.labels -notcontains $label) {
            continue
        }

        $encodedLabel = [uri]::EscapeDataString($label)
        Invoke-GhApi -Method DELETE -Endpoint "repos/$($Proposal.organization)/$($Proposal.repository)/issues/$($Proposal.number)/labels/$encodedLabel" | Out-Null
        $state = Get-IssueState $Proposal
        if ($state.labels -contains $label) {
            throw "Legacy label '$label' was still present after removal."
        }
        Write-RunEvent -Status 'legacy_label_removal_verified' -Proposal $Proposal -Details @{ label = $label }
    }

    $state = Get-IssueState $Proposal
    if ($Proposal.kind -eq 'issue' -and -not (Test-StringEqual $state.type ([string] $Proposal.proposed_type))) {
        throw "Final issue type verification failed; expected '$($Proposal.proposed_type)', got '$($state.type)'."
    }
    if (-not [string]::IsNullOrWhiteSpace([string] $Proposal.proposed_priority) -and -not (Test-StringEqual $state.priority ([string] $Proposal.proposed_priority))) {
        throw "Final Priority verification failed; expected '$($Proposal.proposed_priority)', got '$($state.priority)'."
    }
    if (-not (Test-SetEqual $state.labels $targetLabels)) {
        throw "Final label verification failed; expected '$([string]::Join('|', $targetLabels))', got '$([string]::Join('|', $state.labels))'."
    }

    $state | ConvertTo-Json -Depth 12 | Set-Content -Encoding utf8 $afterPath
    Write-RunEvent -Status 'item_verified' -Proposal $Proposal -Details @{ url = $Proposal.url }
}

if (-not $Apply) {
    throw 'This script mutates GitHub. Pass -Apply together with the reviewed plan SHA-256 to acknowledge that intent.'
}

if ($ShardIndex -ge $ShardCount) {
    throw "ShardIndex must be less than ShardCount (received index $ShardIndex for $ShardCount shard(s))."
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'GitHub CLI (gh) is required.'
}

if (-not (Test-Path -LiteralPath $PlanPath -PathType Leaf)) {
    $missingPlanPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PlanPath)
    throw "Migration plan not found: $missingPlanPath"
}

$resolvedPlanPath = (Resolve-Path -LiteralPath $PlanPath).ProviderPath
if (-not (Test-Path -LiteralPath $resolvedPlanPath -PathType Leaf)) {
    throw "Migration plan not found: $resolvedPlanPath"
}

$actualPlanSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedPlanPath).Hash.ToLowerInvariant()
if (-not (Test-StringEqual $actualPlanSha256 $PlanSha256.ToLowerInvariant())) {
    throw "Plan SHA-256 mismatch. Expected '$PlanSha256', calculated '$actualPlanSha256'."
}

$plan = Get-Content -Raw -LiteralPath $resolvedPlanPath | ConvertFrom-Json
if ($plan.plan_schema_version -ne 2) {
    throw "Unsupported migration plan schema '$($plan.plan_schema_version)'. Generate a fresh dry run with schema 2."
}

$planGeneratedAt = [datetimeoffset]::Parse([string] $plan.generated_at)
$planAge = [datetimeoffset]::UtcNow - $planGeneratedAt.ToUniversalTime()
if ($planAge.TotalMinutes -lt -5 -or $planAge.TotalHours -gt $MaxPlanAgeHours) {
    throw "The migration plan is outside the permitted age window ($([math]::Round($planAge.TotalHours, 2)) hours; maximum $MaxPlanAgeHours). Generate and review a fresh dry run."
}

$repositoryRoot = Split-Path $PSScriptRoot -Parent
$standardsPath = Join-Path $repositoryRoot 'standards/github-standards.json'
$script:standards = Get-Content -Raw -LiteralPath $standardsPath | ConvertFrom-Json
if ($plan.standards_version -ne $script:standards.version) {
    throw "Plan standards version '$($plan.standards_version)' does not match current version '$($script:standards.version)'."
}

[string[]] $selectedOrganizations = @()
if ($null -ne $Organizations) {
    $selectedOrganizations = @($Organizations | ForEach-Object { $_.ToLowerInvariant() })
}
if ($selectedOrganizations.Length -eq 0) {
    $selectedOrganizations = @($plan.organizations | ForEach-Object { $_.ToLowerInvariant() })
}

[string[]] $selectedRepositories = @()
if ($null -ne $Repositories) {
    $selectedRepositories = @($Repositories | ForEach-Object { $_.ToLowerInvariant() })
}
$planErrors = @($plan.errors | Where-Object { $selectedOrganizations -contains $_.organization.ToLowerInvariant() })
if ($planErrors.Count -gt 0) {
    throw "The plan contains $($planErrors.Count) repository read error(s) in the selected organizations. Apply is blocked."
}

$proposals = @($plan.proposals | Where-Object {
    $selectedOrganizations -contains $_.organization.ToLowerInvariant() -and
    ($selectedRepositories.Count -eq 0 -or $selectedRepositories -contains $_.repository.ToLowerInvariant()) -and
    -not [string]::IsNullOrWhiteSpace([string] $_.proposed_changes)
} | Where-Object {
    (Get-ProposalShardIndex -Proposal $_ -Count $ShardCount) -eq $ShardIndex
} | Sort-Object organization, repository, number)

if ($proposals.Count -eq 0) {
    throw 'No changed proposals match the selected organization/repository filters.'
}

$resolvedOutputDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
if ([string]::IsNullOrWhiteSpace($RunId)) {
    $RunId = "plan-$($actualPlanSha256.Substring(0, 12))"
}
elseif ($RunId -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]*$') {
    throw 'RunId may contain only letters, numbers, periods, underscores, and hyphens.'
}

$runRoot = Join-Path $resolvedOutputDirectory $RunId
$script:eventsPath = Join-Path $runRoot 'events.jsonl'
$script:itemSnapshotDirectory = Join-Path $runRoot 'items'
$script:repositorySnapshotDirectory = Join-Path $runRoot 'repositories'
$manifestPath = Join-Path $runRoot 'run-manifest.json'

if ((Test-Path -LiteralPath $runRoot) -and -not $Resume) {
    throw "Run directory already exists: $runRoot. Pass -Resume to continue the exact plan."
}

New-Item -ItemType Directory -Force -Path $script:itemSnapshotDirectory, $script:repositorySnapshotDirectory | Out-Null

$lockPath = Join-Path $runRoot 'run.lock'
try {
    $runLock = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
}
catch {
    throw "Another migration process is already using run '$RunId'. Wait for it to finish before resuming."
}

try {
if ($Resume) {
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Cannot resume because the run manifest is missing: $manifestPath"
    }

    $runManifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    if (-not (Test-StringEqual ([string] $runManifest.plan_sha256) $actualPlanSha256)) {
        throw 'Run manifest plan hash does not match the supplied plan.'
    }
    if (-not (Test-SetEqual @($runManifest.organizations) $selectedOrganizations)) {
        throw 'Resume organization filters do not match the original run manifest.'
    }
    if (-not (Test-SetEqual @($runManifest.repositories) $selectedRepositories)) {
        throw 'Resume repository filters do not match the original run manifest.'
    }
    if ([int] $runManifest.shard_count -ne $ShardCount -or [int] $runManifest.shard_index -ne $ShardIndex) {
        throw 'Resume shard settings do not match the original run manifest.'
    }
}
else {
    [ordered]@{
        created_at = (Get-Date).ToUniversalTime().ToString('o')
        plan_path = $resolvedPlanPath
        plan_sha256 = $actualPlanSha256
        standards_version = $script:standards.version
        organizations = $selectedOrganizations
        repositories = $selectedRepositories
        shard_count = $ShardCount
        shard_index = $ShardIndex
        batch_size = $BatchSize
    } | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8 $manifestPath
}

$events = @(Get-RunEvents)
$completedKeys = @($events | Where-Object { $_.status -eq 'item_verified' } | ForEach-Object { $_.key } | Sort-Object -Unique)
$startedKeys = @($events | Where-Object { $_.status -eq 'item_started' } | ForEach-Object { $_.key } | Sort-Object -Unique)
$manualProposals = @($proposals | Where-Object { [bool] $_.manual_review })
$pendingProposals = @($proposals | Where-Object { -not [bool] $_.manual_review -and $completedKeys -notcontains (Get-ProposalKey $_) })
$batch = @($pendingProposals | Select-Object -First $BatchSize)

$script:priorityFieldIds = @{}
$script:preparedLabels = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

foreach ($proposal in $manualProposals) {
    $key = Get-ProposalKey $proposal
    if (@($events | Where-Object { $_.status -eq 'manual_review_skipped' -and $_.key -eq $key }).Count -eq 0) {
        Write-RunEvent -Status 'manual_review_skipped' -Proposal $proposal -Details @{ notes = $proposal.notes }
    }
}

$failures = 0
foreach ($proposal in $batch) {
    $key = Get-ProposalKey $proposal
    Write-Host "Migrating $key..."

    try {
        Invoke-ProposalMigration -Proposal $proposal -Started ($startedKeys -contains $key)
    }
    catch {
        $failures++
        Write-RunEvent -Status 'item_failed' -Proposal $proposal -Details @{ error = $_.Exception.Message }
        Write-Error "Migration failed for ${key}: $($_.Exception.Message)" -ErrorAction Continue

        if (-not $ContinueOnError) {
            break
        }
    }

    if ($DelayMilliseconds -gt 0) {
        Start-Sleep -Milliseconds $DelayMilliseconds
    }
}

$finalEvents = @(Get-RunEvents)
$finalCompletedKeys = @($finalEvents | Where-Object { $_.status -eq 'item_verified' } | ForEach-Object { $_.key } | Sort-Object -Unique)
$remaining = @($proposals | Where-Object { -not [bool] $_.manual_review -and $finalCompletedKeys -notcontains (Get-ProposalKey $_) })
$summary = [ordered]@{
    generated_at = (Get-Date).ToUniversalTime().ToString('o')
    run_id = $RunId
    plan_sha256 = $actualPlanSha256
    selected_changes = $proposals.Count
    verified = @($proposals | Where-Object { $finalCompletedKeys -contains (Get-ProposalKey $_) }).Count
    manual_review_skipped = $manualProposals.Count
    remaining = $remaining.Count
    failures_this_invocation = $failures
    next_command = if ($remaining.Count -gt 0) { "Re-run this command with -Resume to process the next batch." } else { $null }
}

$summary | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8 (Join-Path $runRoot 'summary.json')
$summary | Format-List | Out-String | Set-Content -Encoding utf8 (Join-Path $runRoot 'summary.txt')

Write-Host "Migration invocation complete. Verified: $($summary.verified). Manual review: $($summary.manual_review_skipped). Remaining: $($summary.remaining)."
Write-Host "Run evidence: $runRoot"

if ($failures -gt 0) {
    throw "$failures migration item(s) failed during this invocation. Review events.jsonl and resume after correcting the cause."
}
}
finally {
    $runLock.Dispose()
}
