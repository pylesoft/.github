[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SourcePlanPath,
    [Parameter(Mandatory)] [string] $OutputDirectory,
    [string[]] $TypePrecedence = @('Bug', 'Feature', 'Task', 'Support'),
    [string[]] $PriorityPrecedence = @('Urgent', 'High', 'Normal', 'Low'),
    [hashtable] $TypeLabels = @{ Bug = 'bug'; Feature = 'enhancement' },
    [string[]] $ConfirmedDoneProjectUrls = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Test-Path -LiteralPath $SourcePlanPath -PathType Leaf)) {
    throw "Source plan not found: $SourcePlanPath"
}

$resolvedSourcePlanPath = (Resolve-Path -LiteralPath $SourcePlanPath).ProviderPath
$sourcePlanSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedSourcePlanPath).Hash.ToLowerInvariant()
$sourcePlan = Get-Content -Raw -LiteralPath $resolvedSourcePlanPath | ConvertFrom-Json

if ($sourcePlan.plan_schema_version -ne 2) {
    throw "Unsupported migration plan schema '$($sourcePlan.plan_schema_version)'."
}
if (@($sourcePlan.errors).Count -gt 0) {
    throw 'The source plan contains repository read errors and cannot be resolved.'
}

$confirmedDoneUrls = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($url in $ConfirmedDoneProjectUrls) {
    $confirmedDoneUrls.Add($url) | Out-Null
}

$resolvedProposals = [System.Collections.Generic.List[object]]::new()

foreach ($proposal in @($sourcePlan.proposals | Where-Object { [bool] $_.manual_review })) {
    $resolved = $proposal | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $changes = @([string] $resolved.proposed_changes -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $decision = $null

    if ($resolved.notes -match 'Closed-issue state reason|resolution label') {
        $decision = 'Deferred: preserve the resolution label because GitHub ignores state_reason unless state changes.'
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string] $resolved.proposed_project_status)) {
        if (-not $confirmedDoneUrls.Contains([string] $resolved.url)) {
            $decision = 'Deferred: the current Project Status has not been explicitly verified.'
        }
        else {
            $changes = @($changes | Where-Object { $_ -notmatch '^project_status:' })
            $resolved.proposed_project_status = $null
            $resolved.manual_review = $false
            $decision = 'Resolved: preserve the verified Done Project Status and remove the stale to review label.'
        }
    }
    elseif ($resolved.notes -match 'Conflicting issue type candidates: ([^.]+)\.') {
        $candidates = @($Matches[1] -split ',' | ForEach-Object { $_.Trim() })
        $selectedType = @($TypePrecedence | Where-Object { $candidates -contains $_ } | Select-Object -First 1)
        if ($selectedType.Count -ne 1) {
            throw "No configured issue type precedence matches $($resolved.url): $([string]::Join(', ', $candidates))."
        }
        $changes = @($changes | Where-Object { $_ -notmatch '^type:' })
        $changes = @("type:$($resolved.current_type)->$($selectedType[0])") + $changes
        $resolved.proposed_type = $selectedType[0]

        $currentLabels = @([string] $resolved.current_labels -split '\|' | Where-Object { $_ })
        $targetLabels = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $removeLabels = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        @([string] $resolved.proposed_labels -split '\|' | Where-Object { $_ }) | ForEach-Object { $targetLabels.Add($_) | Out-Null }
        @([string] $resolved.remove_labels -split '\|' | Where-Object { $_ }) | ForEach-Object { $removeLabels.Add($_) | Out-Null }

        foreach ($candidate in $candidates) {
            if (-not $TypeLabels.ContainsKey($candidate)) {
                continue
            }

            $candidateLabel = [string] $TypeLabels[$candidate]
            if ($candidate -eq $selectedType[0]) {
                $targetLabels.Add($candidateLabel) | Out-Null
                $removeLabels.Remove($candidateLabel) | Out-Null
            }
            else {
                $targetLabels.Remove($candidateLabel) | Out-Null
                if ($currentLabels -contains $candidateLabel) {
                    $removeLabels.Add($candidateLabel) | Out-Null
                }
            }
        }

        $resolved.proposed_labels = [string]::Join('|', @($targetLabels | Sort-Object))
        $resolved.remove_labels = [string]::Join('|', @($removeLabels | Sort-Object))
        $changes = @($changes | Where-Object { $_ -notmatch '^(add|remove)_labels:' })
        $addedLabels = @($targetLabels | Where-Object { $currentLabels -notcontains $_ } | Sort-Object)
        if ($addedLabels.Count -gt 0) {
            $changes += "add_labels:$([string]::Join('|', $addedLabels))"
        }
        if ($removeLabels.Count -gt 0) {
            $changes += "remove_labels:$([string]::Join('|', @($removeLabels | Sort-Object)))"
        }

        $resolved.manual_review = $false
        $decision = "Resolved issue type conflict using precedence: $($selectedType[0]); incompatible canonical type labels removed."
    }
    elseif ($resolved.notes -match 'Conflicting Priority candidates: ([^.]+)\.') {
        $candidates = @($Matches[1] -split ',' | ForEach-Object { $_.Trim() })
        $selectedPriority = @($PriorityPrecedence | Where-Object { $candidates -contains $_ } | Select-Object -First 1)
        if ($selectedPriority.Count -ne 1) {
            throw "No configured Priority precedence matches $($resolved.url): $([string]::Join(', ', $candidates))."
        }
        $changes = @($changes | Where-Object { $_ -notmatch '^priority:' })
        $changes = @("priority:$($resolved.current_priority)->$($selectedPriority[0])") + $changes
        $resolved.proposed_priority = $selectedPriority[0]
        $resolved.manual_review = $false
        $decision = "Resolved Priority conflict using precedence: $($selectedPriority[0])."
    }
    else {
        $resolved.manual_review = $false
        $decision = 'Resolved: remove redundant or history-only labels after preserving the source plan ledger.'
    }

    $resolved.proposed_changes = [string]::Join(';', $changes)
    $resolved | Add-Member -NotePropertyName manual_resolution -NotePropertyValue $decision
    $resolvedProposals.Add($resolved)
}

$remainingManual = @($resolvedProposals | Where-Object manual_review)
$resolvedAutomatic = @($resolvedProposals | Where-Object { -not [bool] $_.manual_review })
$resolvedOutput = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $resolvedOutput | Out-Null
$timestamp = [datetimeoffset]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$baseName = "github-manual-resolution-plan-$timestamp"
$jsonPath = Join-Path $resolvedOutput "$baseName.json"
$csvPath = Join-Path $resolvedOutput "$baseName.csv"
$markdownPath = Join-Path $resolvedOutput "$baseName.md"

$plan = [ordered]@{
    plan_schema_version = 2
    generated_at = [datetimeoffset]::UtcNow.ToString('o')
    mode = 'manual-resolution-dry-run'
    standards_version = $sourcePlan.standards_version
    organizations = @($sourcePlan.organizations)
    include_archived = [bool] $sourcePlan.include_archived
    source_plan_path = $resolvedSourcePlanPath
    source_plan_sha256 = $sourcePlanSha256
    resolution_policy = [ordered]@{
        type_precedence = $TypePrecedence
        type_labels = $TypeLabels
        priority_precedence = $PriorityPrecedence
        confirmed_done_project_urls = @($ConfirmedDoneProjectUrls)
        resolution_state_reason = 'deferred-with-label-preserved'
    }
    summary = [ordered]@{
        repositories = @($resolvedProposals.repository | Sort-Object -Unique).Count
        items = $resolvedProposals.Count
        items_with_proposed_changes = $resolvedProposals.Count
        resolved_items = $resolvedAutomatic.Count
        manual_review_items = $remainingManual.Count
        errors = 0
    }
    proposals = $resolvedProposals.ToArray()
    errors = @()
}

$plan | ConvertTo-Json -Depth 14 | Set-Content -Encoding utf8 $jsonPath
$resolvedProposals | Export-Csv -NoTypeInformation -Encoding utf8 $csvPath

@"
# GitHub manual resolution plan

- Generated: $([datetimeoffset]::UtcNow.ToString('u'))
- Mode: **read-only plan generation**
- Source plan SHA-256: $sourcePlanSha256
- Manual rows inspected: $($resolvedProposals.Count)
- Rows resolved for guarded apply: $($resolvedAutomatic.Count)
- Rows intentionally deferred: $($remainingManual.Count)
- Read errors: 0

## Policy

- Issue type precedence: $([string]::Join(' > ', $TypePrecedence))
- Priority precedence: $([string]::Join(' > ', $PriorityPrecedence))
- Verified Done Project statuses are preserved while stale to review labels are removed.
- Resolution labels remain until GitHub can represent their semantics without a state transition.

No GitHub data was changed.
"@ | Set-Content -Encoding utf8 $markdownPath

Write-Host "Manual resolution dry-run complete. Report: $markdownPath"
Write-Host 'No GitHub data was changed.'
