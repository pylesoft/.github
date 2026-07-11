param(
    [string[]] $Organizations = @('pylesoft', 'floorbox'),
    [string] $OutputDirectory = './artifacts/github-migration-dry-run',
    [switch] $IncludeArchived
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path $PSScriptRoot -Parent
$standardsPath = Join-Path $repositoryRoot 'standards/github-standards.json'
$standards = Get-Content -Raw $standardsPath | ConvertFrom-Json
$canonicalLabels = @($standards.labels | ForEach-Object { $_.name.ToLowerInvariant() })
$legacyRules = @{}
foreach ($legacyProperty in $standards.legacy_labels.PSObject.Properties) {
    $rule = @{}
    foreach ($ruleProperty in $legacyProperty.Value.PSObject.Properties) {
        $rule[$ruleProperty.Name] = $ruleProperty.Value
    }

    $legacyRules[$legacyProperty.Name] = $rule
}

function Invoke-GhGet {
    param(
        [Parameter(Mandatory)] [string] $Endpoint,
        [switch] $Paginate
    )

    $arguments = @(
        'api',
        '-H', 'Accept: application/vnd.github+json',
        '-H', 'X-GitHub-Api-Version: 2026-03-10',
        $Endpoint
    )

    if ($Paginate) {
        $arguments += @('--paginate', '--slurp')
    }

    $stderrPath = [System.IO.Path]::GetTempFileName()

    try {
        $raw = (& gh @arguments 2> $stderrPath | Out-String).Trim()
        $stderr = (Get-Content -Raw $stderrPath -ErrorAction SilentlyContinue | Out-String).Trim()
    }
    finally {
        Remove-Item $stderrPath -Force -ErrorAction SilentlyContinue
    }

    if ($LASTEXITCODE -ne 0) {
        throw "GitHub GET failed for $Endpoint`n$stderr"
    }

    if (-not [string]::IsNullOrWhiteSpace($stderr)) {
        Write-Warning "GitHub CLI warning for ${Endpoint}: $stderr"
    }

    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @()
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

function Get-ItemTypeName {
    param([object] $Item)

    if ($Item.PSObject.Properties.Name -notcontains 'type' -or $null -eq $Item.type) {
        return $null
    }

    if ($Item.type -is [string]) {
        return $Item.type
    }

    return $Item.type.name
}

function Get-LabelNames {
    param([object] $Item)

    return @($Item.labels | ForEach-Object {
        if ($_ -is [string]) {
            $_.Trim().ToLowerInvariant()
        }
        else {
            $_.name.Trim().ToLowerInvariant()
        }
    } | Sort-Object -Unique)
}

function Get-IssuePriority {
    param(
        [Parameter(Mandatory)] [string] $Organization,
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [int] $Number,
        [Parameter(Mandatory)] [string] $Kind,
        [string[]] $Labels
    )

    if ($Kind -ne 'issue') {
        return $null
    }

    $hasPriorityMigration = $false
    foreach ($label in $Labels) {
        if ($legacyRules.ContainsKey($label) -and $legacyRules[$label].ContainsKey('priority')) {
            $hasPriorityMigration = $true
            break
        }
    }

    if (-not $hasPriorityMigration) {
        return $null
    }

    $fieldValues = @(Invoke-GhGet -Endpoint "repos/$Organization/$Repository/issues/$Number/issue-field-values?per_page=100")
    $priority = @($fieldValues | Where-Object {
        $null -ne $_ -and $_.PSObject.Properties.Name -contains 'issue_field_name' -and $_.issue_field_name -eq 'Priority'
    } | Select-Object -First 1)

    if ($priority.Count -eq 0 -or $null -eq $priority[0].single_select_option) {
        return $null
    }

    return [string] $priority[0].single_select_option.name
}

function New-Proposal {
    param(
        [Parameter(Mandatory)] [string] $Organization,
        [Parameter(Mandatory)] [object] $Repository,
        [Parameter(Mandatory)] [object] $Item,
        [AllowNull()] [string] $CurrentPriority
    )

    $kind = if ($Item.PSObject.Properties.Name -contains 'pull_request' -and $null -ne $Item.pull_request) { 'pull_request' } else { 'issue' }
    $currentLabels = @(Get-LabelNames -Item $Item)
    $currentType = if ($kind -eq 'issue') { Get-ItemTypeName -Item $Item } else { $null }
    $targetLabels = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $removeLabels = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $typeCandidates = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $priorityCandidates = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $notes = [System.Collections.Generic.List[string]]::new()
    $manualReview = $false
    $targetStateReason = $null
    $targetProjectStatus = $null

    foreach ($label in $currentLabels) {
        if ($canonicalLabels -contains $label) {
            $targetLabels.Add($label) | Out-Null
        }

        if (-not $legacyRules.ContainsKey($label)) {
            $manualReview = $true
            $notes.Add("Unknown label '$label' is not covered by the standards manifest.")
            continue
        }

        $rule = $legacyRules[$label]

        if ($rule.ContainsKey('label')) {
            $targetLabels.Add([string] $rule.label) | Out-Null
        }

        if ($kind -eq 'issue' -and $rule.ContainsKey('issue_type')) {
            $typeCandidates.Add([string] $rule.issue_type) | Out-Null
        }

        if ($kind -eq 'issue' -and [string]::IsNullOrWhiteSpace($currentType) -and $rule.ContainsKey('issue_type_if_missing')) {
            $typeCandidates.Add([string] $rule.issue_type_if_missing) | Out-Null
        }

        if ($kind -eq 'issue' -and $rule.ContainsKey('priority')) {
            $priorityCandidates.Add([string] $rule.priority) | Out-Null
        }

        if ($kind -eq 'issue' -and $rule.ContainsKey('state_reason')) {
            if ($Item.state -eq 'closed') {
                $targetStateReason = [string] $rule.state_reason
                $manualReview = $true
                $notes.Add("Closed-issue state reason migration is deferred because GitHub only applies state_reason when changing state.")
            }
            else {
                $manualReview = $true
                $notes.Add("Open issue has resolution label '$label'; state_reason cannot be applied until the issue is closed.")
            }
        }

        if ($rule.ContainsKey('project_status')) {
            $targetProjectStatus = [string] $rule.project_status
            $manualReview = $true
            $notes.Add("Project Status migration requires explicit project-item selection and is deferred from automatic apply.")
        }

        if (($rule.ContainsKey('preserve_in_ledger') -and $rule.preserve_in_ledger) -or
            ($rule.ContainsKey('manual_review') -and $rule.manual_review)) {
            $notes.Add("Preserve legacy label '$label' in the migration ledger.")
        }

        if ($rule.ContainsKey('manual_review') -and $rule.manual_review) {
            $manualReview = $true
        }

        if (-not $targetLabels.Contains($label)) {
            $removeLabels.Add($label) | Out-Null
        }
    }

    if ($typeCandidates.Count -gt 1) {
        $manualReview = $true
        $notes.Add("Conflicting issue type candidates: $([string]::Join(', ', $typeCandidates)).")
    }

    if ($priorityCandidates.Count -gt 1) {
        $manualReview = $true
        $notes.Add("Conflicting Priority candidates: $([string]::Join(', ', $priorityCandidates)).")
    }

    $proposedType = if ($typeCandidates.Count -eq 1) { @($typeCandidates)[0] } else { $currentType }
    $proposedPriority = if ($priorityCandidates.Count -eq 1) { @($priorityCandidates)[0] } else { $null }
    $sortedTargetLabels = @($targetLabels | Sort-Object)
    $sortedRemovedLabels = @($removeLabels | Sort-Object)
    $changes = [System.Collections.Generic.List[string]]::new()

    if ($kind -eq 'issue' -and $proposedType -ne $currentType) {
        $currentTypeLabel = if ([string]::IsNullOrWhiteSpace($currentType)) { '<none>' } else { $currentType }
        $changes.Add("type:$currentTypeLabel->$proposedType")
    }

    if ($proposedPriority -and $proposedPriority -ne $CurrentPriority) {
        $currentPriorityLabel = if ([string]::IsNullOrWhiteSpace($CurrentPriority)) { '<none>' } else { $CurrentPriority }
        $changes.Add("priority:$currentPriorityLabel->$proposedPriority")
    }

    if ($targetStateReason) {
        $changes.Add("state_reason:$targetStateReason")
    }

    if ($targetProjectStatus) {
        $changes.Add("project_status:$targetProjectStatus")
    }

    $addedLabels = @($sortedTargetLabels | Where-Object { $currentLabels -notcontains $_ })
    if ($addedLabels.Count -gt 0) {
        $changes.Add("add_labels:$([string]::Join('|', $addedLabels))")
    }

    if ($sortedRemovedLabels.Count -gt 0) {
        $changes.Add("remove_labels:$([string]::Join('|', $sortedRemovedLabels))")
    }

    return [pscustomobject]@{
        organization = $Organization
        repository = $Repository.name
        repository_archived = [bool] $Repository.archived
        number = [int] $Item.number
        kind = $kind
        state = $Item.state
        source_updated_at = $Item.updated_at
        url = $Item.html_url
        current_type = $currentType
        proposed_type = $proposedType
        current_priority = $CurrentPriority
        current_labels = [string]::Join('|', $currentLabels)
        proposed_labels = [string]::Join('|', $sortedTargetLabels)
        remove_labels = [string]::Join('|', $sortedRemovedLabels)
        proposed_priority = $proposedPriority
        proposed_state_reason = $targetStateReason
        proposed_project_status = $targetProjectStatus
        manual_review = $manualReview
        proposed_changes = [string]::Join(';', $changes)
        notes = [string]::Join(' ', $notes)
    }
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'GitHub CLI (gh) is required.'
}

$resolvedOutput = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $resolvedOutput | Out-Null

$proposals = [System.Collections.Generic.List[object]]::new()
$repositoryRows = [System.Collections.Generic.List[object]]::new()
$errors = [System.Collections.Generic.List[object]]::new()

foreach ($organization in $Organizations) {
    Write-Host "Reading repositories for $organization..."
    $repositories = @(Invoke-GhGet -Endpoint "orgs/$organization/repos?type=all&per_page=100&sort=full_name" -Paginate)

    foreach ($repository in $repositories) {
        if ($repository.archived -and -not $IncludeArchived) {
            continue
        }

        if (-not $repository.has_issues) {
            $repositoryRows.Add([pscustomobject]@{
                organization = $organization
                repository = $repository.name
                archived = [bool] $repository.archived
                default_branch = $repository.default_branch
                item_count = 0
                proposed_change_count = 0
                manual_review_count = 0
                note = 'Issues are disabled.'
            })
            continue
        }

        Write-Host "  Reading $organization/$($repository.name)..."

        try {
            $items = @(Invoke-GhGet -Endpoint "repos/$organization/$($repository.name)/issues?state=all&per_page=100" -Paginate)
            $repoProposals = @($items | ForEach-Object {
                $kind = if ($_.PSObject.Properties.Name -contains 'pull_request' -and $null -ne $_.pull_request) { 'pull_request' } else { 'issue' }
                $labels = @(Get-LabelNames -Item $_)
                $currentPriority = Get-IssuePriority -Organization $organization -Repository $repository.name -Number $_.number -Kind $kind -Labels $labels

                New-Proposal -Organization $organization -Repository $repository -Item $_ -CurrentPriority $currentPriority
            })

            foreach ($proposal in $repoProposals) {
                $proposals.Add($proposal)
            }

            $repositoryRows.Add([pscustomobject]@{
                organization = $organization
                repository = $repository.name
                archived = [bool] $repository.archived
                default_branch = $repository.default_branch
                item_count = $repoProposals.Count
                proposed_change_count = @($repoProposals | Where-Object { -not [string]::IsNullOrWhiteSpace($_.proposed_changes) }).Count
                manual_review_count = @($repoProposals | Where-Object manual_review).Count
                note = ''
            })
        }
        catch {
            $errors.Add([pscustomobject]@{
                organization = $organization
                repository = $repository.name
                error = $_.Exception.Message
            })
        }
    }
}

$timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$changed = @($proposals | Where-Object { -not [string]::IsNullOrWhiteSpace($_.proposed_changes) })
$manual = @($proposals | Where-Object manual_review)
$reportBase = "github-migration-dry-run-$timestamp"
$csvPath = Join-Path $resolvedOutput "$reportBase.csv"
$jsonPath = Join-Path $resolvedOutput "$reportBase.json"
$markdownPath = Join-Path $resolvedOutput "$reportBase.md"
$repositoriesPath = Join-Path $resolvedOutput "$reportBase-repositories.csv"
$errorsPath = Join-Path $resolvedOutput "$reportBase-errors.csv"

$proposals | Export-Csv -NoTypeInformation -Encoding utf8 $csvPath
$repositoryRows | Export-Csv -NoTypeInformation -Encoding utf8 $repositoriesPath
$errors | Export-Csv -NoTypeInformation -Encoding utf8 $errorsPath

[ordered]@{
    plan_schema_version = 2
    generated_at = (Get-Date).ToUniversalTime().ToString('o')
    mode = 'dry-run-read-only'
    standards_version = $standards.version
    organizations = $Organizations
    include_archived = [bool] $IncludeArchived
    summary = [ordered]@{
        repositories = $repositoryRows.Count
        items = $proposals.Count
        items_with_proposed_changes = $changed.Count
        manual_review_items = $manual.Count
        errors = $errors.Count
    }
    proposals = $proposals
    errors = $errors
} | ConvertTo-Json -Depth 12 | Set-Content -Encoding utf8 $jsonPath

$changeKinds = @($changed | ForEach-Object {
    $_.proposed_changes -split ';'
} | Where-Object { $_ } | ForEach-Object {
    ($_ -split ':', 2)[0]
} | Group-Object | Sort-Object Count -Descending)

$markdown = [System.Collections.Generic.List[string]]::new()
$markdown.Add('# GitHub migration dry-run')
$markdown.Add('')
$markdown.Add("- Generated: $((Get-Date).ToUniversalTime().ToString('u'))")
$markdown.Add('- Mode: **read-only**')
$markdown.Add("- Organizations: $([string]::Join(', ', $Organizations))")
$markdown.Add("- Repositories inspected: $($repositoryRows.Count)")
$markdown.Add("- Issues and pull requests inspected: $($proposals.Count)")
$markdown.Add("- Items with proposed changes: $($changed.Count)")
$markdown.Add("- Items requiring manual review: $($manual.Count)")
$markdown.Add("- Repository read errors: $($errors.Count)")
$markdown.Add('')
$markdown.Add('## Proposed change categories')
$markdown.Add('')
$markdown.Add('| Category | Occurrences |')
$markdown.Add('|---|---:|')
foreach ($changeKind in $changeKinds) {
    $markdown.Add("| $($changeKind.Name) | $($changeKind.Count) |")
}
$markdown.Add('')
$markdown.Add('## Safety')
$markdown.Add('')
$markdown.Add('This command performs only GitHub GET requests. It contains no apply mode and cannot mutate GitHub data.')
$markdown.Add('Review the CSV or JSON ledger before invoking the separate apply command with the plan SHA-256.')
$markdown.Add('Manual-review rows are skipped without mutation and must be resolved before obsolete label definitions are deleted.')
$markdown.Add('')
$markdown.Add('## Artifacts')
$markdown.Add('')
$markdown.Add(('- Item ledger: `{0}`' -f [System.IO.Path]::GetFileName($csvPath)))
$markdown.Add(('- Full JSON: `{0}`' -f [System.IO.Path]::GetFileName($jsonPath)))
$markdown.Add(('- Repository summary: `{0}`' -f [System.IO.Path]::GetFileName($repositoriesPath)))
$markdown.Add(('- Read errors: `{0}`' -f [System.IO.Path]::GetFileName($errorsPath)))

$markdown | Set-Content -Encoding utf8 $markdownPath

Write-Host "Dry-run complete. Report: $markdownPath"
Write-Host "No GitHub data was changed."
