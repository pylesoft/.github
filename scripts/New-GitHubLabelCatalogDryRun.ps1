param(
    [string[]] $Organizations = @('pylesoft'),
    [string] $OutputDirectory = './artifacts/github-label-catalog-dry-run',
    [switch] $IncludeArchived
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path $PSScriptRoot -Parent
$standardsPath = Join-Path $repositoryRoot 'standards/github-standards.json'
$standards = Get-Content -Raw -LiteralPath $standardsPath | ConvertFrom-Json
$canonicalLabels = @{}
foreach ($label in $standards.labels) {
    $canonicalLabels[$label.name.ToLowerInvariant()] = $label
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
        $exitCode = $LASTEXITCODE
        $stderr = (Get-Content -Raw -LiteralPath $stderrPath -ErrorAction SilentlyContinue | Out-String).Trim()
    }
    finally {
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }

    if ($exitCode -ne 0) {
        throw "GitHub GET failed for $Endpoint`n$stderr"
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
            if ($null -ne $item) {
                $items.Add($item)
            }
        }
    }

    return $items.ToArray()
}

function Get-LabelUsage {
    param([object[]] $Items)

    $usage = @{}
    foreach ($item in @($Items)) {
        foreach ($label in @($item.labels)) {
            if ($null -eq $label) {
                continue
            }

            $name = if ($label -is [string]) { $label } else { $label.name }
            if ([string]::IsNullOrWhiteSpace([string] $name)) {
                continue
            }

            $normalized = ([string] $name).Trim().ToLowerInvariant()
            if (-not $usage.ContainsKey($normalized)) {
                $usage[$normalized] = 0
            }
            $usage[$normalized]++
        }
    }

    return $usage
}

function New-LabelAction {
    param(
        [Parameter(Mandatory)] [string] $Organization,
        [Parameter(Mandatory)] [object] $Repository,
        [Parameter(Mandatory)] [string] $Action,
        [Parameter(Mandatory)] [string] $Label,
        [AllowNull()] [object] $Current,
        [AllowNull()] [object] $Target,
        [int] $UsageCount,
        [bool] $SafeToApply,
        [string] $Reason
    )

    return [pscustomobject]@{
        organization = $Organization
        repository = $Repository.name
        repository_archived = [bool] $Repository.archived
        action = $Action
        label = $Label
        current_color = if ($null -eq $Current) { $null } else { [string] $Current.color }
        current_description = if ($null -eq $Current) { $null } else { [string] $Current.description }
        target_color = if ($null -eq $Target) { $null } else { [string] $Target.color }
        target_description = if ($null -eq $Target) { $null } else { [string] $Target.description }
        usage_count = $UsageCount
        safe_to_apply = $SafeToApply
        reason = $Reason
    }
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'GitHub CLI (gh) is required.'
}

$resolvedOutput = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $resolvedOutput | Out-Null

$actions = [System.Collections.Generic.List[object]]::new()
$repositoryRows = [System.Collections.Generic.List[object]]::new()
$errors = [System.Collections.Generic.List[object]]::new()

foreach ($organization in $Organizations) {
    Write-Host "Reading repositories for $organization..."
    $repositories = @(Invoke-GhGet -Endpoint "orgs/$organization/repos?type=all&per_page=100&sort=full_name" -Paginate)

    foreach ($repository in $repositories) {
        if ($repository.archived -and -not $IncludeArchived) {
            continue
        }

        Write-Host "  Reading labels and usage for $organization/$($repository.name)..."
        try {
            $labels = @(Invoke-GhGet -Endpoint "repos/$organization/$($repository.name)/labels?per_page=100" -Paginate)
            $items = @(Invoke-GhGet -Endpoint "repos/$organization/$($repository.name)/issues?state=all&per_page=100" -Paginate)
            $usage = Get-LabelUsage -Items $items
            $currentByName = @{}
            foreach ($label in $labels) {
                $currentByName[$label.name.Trim().ToLowerInvariant()] = $label
            }

            $repositoryActions = [System.Collections.Generic.List[object]]::new()
            foreach ($canonicalName in @($canonicalLabels.Keys | Sort-Object)) {
                $target = $canonicalLabels[$canonicalName]
                $usageCount = if ($usage.ContainsKey($canonicalName)) { [int] $usage[$canonicalName] } else { 0 }

                if (-not $currentByName.ContainsKey($canonicalName)) {
                    $repositoryActions.Add((New-LabelAction -Organization $organization -Repository $repository -Action 'create' -Label $canonicalName -Current $null -Target $target -UsageCount $usageCount -SafeToApply $true -Reason 'Canonical label is missing.'))
                    continue
                }

                $current = $currentByName[$canonicalName]
                if ($current.color.ToLowerInvariant() -ne $target.color.ToLowerInvariant() -or
                    [string] $current.description -ne [string] $target.description) {
                    $repositoryActions.Add((New-LabelAction -Organization $organization -Repository $repository -Action 'update' -Label $canonicalName -Current $current -Target $target -UsageCount $usageCount -SafeToApply $true -Reason 'Canonical label metadata differs from the standards manifest.'))
                }
            }

            foreach ($currentName in @($currentByName.Keys | Sort-Object)) {
                if ($canonicalLabels.ContainsKey($currentName)) {
                    continue
                }

                $current = $currentByName[$currentName]
                $usageCount = if ($usage.ContainsKey($currentName)) { [int] $usage[$currentName] } else { 0 }
                $safeToDelete = $usageCount -eq 0
                $repositoryActions.Add((New-LabelAction -Organization $organization -Repository $repository -Action $(if ($safeToDelete) { 'delete' } else { 'blocked_delete' }) -Label $currentName -Current $current -Target $null -UsageCount $usageCount -SafeToApply $safeToDelete -Reason $(if ($safeToDelete) { 'Obsolete label has zero live associations.' } else { 'Obsolete label still has live associations.' })))
            }

            foreach ($action in $repositoryActions) {
                $actions.Add($action)
            }

            $repositoryRows.Add([pscustomobject]@{
                organization = $organization
                repository = $repository.name
                archived = [bool] $repository.archived
                item_count = $items.Count
                label_definition_count = $labels.Count
                proposed_action_count = $repositoryActions.Count
                safe_action_count = @($repositoryActions | Where-Object safe_to_apply).Count
                blocked_action_count = @($repositoryActions | Where-Object { -not $_.safe_to_apply }).Count
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
$reportBase = "github-label-catalog-dry-run-$timestamp"
$jsonPath = Join-Path $resolvedOutput "$reportBase.json"
$csvPath = Join-Path $resolvedOutput "$reportBase.csv"
$repositoriesPath = Join-Path $resolvedOutput "$reportBase-repositories.csv"
$errorsPath = Join-Path $resolvedOutput "$reportBase-errors.csv"
$markdownPath = Join-Path $resolvedOutput "$reportBase.md"

$actions | Export-Csv -NoTypeInformation -Encoding utf8 $csvPath
$repositoryRows | Export-Csv -NoTypeInformation -Encoding utf8 $repositoriesPath
$errors | Export-Csv -NoTypeInformation -Encoding utf8 $errorsPath

$safeActions = @($actions | Where-Object safe_to_apply)
$blockedActions = @($actions | Where-Object { -not $_.safe_to_apply })
[ordered]@{
    plan_schema_version = 1
    generated_at = (Get-Date).ToUniversalTime().ToString('o')
    mode = 'label-catalog-dry-run-read-only'
    standards_version = $standards.version
    organizations = $Organizations
    include_archived = [bool] $IncludeArchived
    summary = [ordered]@{
        repositories = $repositoryRows.Count
        actions = $actions.Count
        safe_actions = $safeActions.Count
        blocked_actions = $blockedActions.Count
        errors = $errors.Count
    }
    actions = $actions
    errors = $errors
} | ConvertTo-Json -Depth 12 | Set-Content -Encoding utf8 $jsonPath

$actionKinds = @($actions | Group-Object action | Sort-Object Name)
$markdown = [System.Collections.Generic.List[string]]::new()
$markdown.Add('# GitHub label catalog dry-run')
$markdown.Add('')
$markdown.Add("- Generated: $((Get-Date).ToUniversalTime().ToString('u'))")
$markdown.Add('- Mode: **read-only**')
$markdown.Add("- Organizations: $([string]::Join(', ', $Organizations))")
$markdown.Add("- Repositories inspected: $($repositoryRows.Count)")
$markdown.Add("- Proposed actions: $($actions.Count)")
$markdown.Add("- Safe actions: $($safeActions.Count)")
$markdown.Add("- Blocked actions: $($blockedActions.Count)")
$markdown.Add("- Repository read errors: $($errors.Count)")
$markdown.Add('')
$markdown.Add('## Actions')
$markdown.Add('')
$markdown.Add('| Action | Count |')
$markdown.Add('|---|---:|')
foreach ($kind in $actionKinds) {
    $markdown.Add("| $($kind.Name) | $($kind.Count) |")
}
$markdown.Add('')
$markdown.Add('## Safety')
$markdown.Add('')
$markdown.Add('This command performs only GitHub GET requests. A delete is considered safe only when the current audit found zero issue or pull-request associations for that label in the repository.')
$markdown.Add('Any repository read error or blocked action must prevent catalog apply.')
$markdown.Add('')
$markdown.Add('## Artifacts')
$markdown.Add('')
$markdown.Add(('- Full JSON plan: `{0}`' -f [System.IO.Path]::GetFileName($jsonPath)))
$markdown.Add(('- Action ledger: `{0}`' -f [System.IO.Path]::GetFileName($csvPath)))
$markdown.Add(('- Repository summary: `{0}`' -f [System.IO.Path]::GetFileName($repositoriesPath)))
$markdown.Add(('- Read errors: `{0}`' -f [System.IO.Path]::GetFileName($errorsPath)))
$markdown | Set-Content -Encoding utf8 $markdownPath

Write-Host "Label catalog dry-run complete. Report: $markdownPath"
Write-Host 'No GitHub data was changed.'
