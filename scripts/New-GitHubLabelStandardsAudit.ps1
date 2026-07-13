[CmdletBinding()]
param(
    [string[]] $Organizations = @('pylesoft', 'floorbox'),
    [string] $OutputDirectory = './artifacts/github-label-standards-audit',
    [switch] $IncludeArchived
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path $PSScriptRoot -Parent
$standards = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'standards/github-standards.json') | ConvertFrom-Json
$canonicalLabels = @{}
foreach ($label in $standards.labels) {
    $canonicalLabels[$label.name.ToLowerInvariant()] = $label
}
$legacyLabels = @{}
foreach ($property in $standards.legacy_labels.PSObject.Properties) {
    $legacyLabels[$property.Name.ToLowerInvariant()] = $property.Value
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

function New-Finding {
    param(
        [Parameter(Mandatory)] [string] $Organization,
        [Parameter(Mandatory)] [object] $Repository,
        [Parameter(Mandatory)] [string] $Kind,
        [Parameter(Mandatory)] [string] $Label,
        [Parameter(Mandatory)] [bool] $IsDrift,
        [int] $UsageCount,
        [AllowNull()] [object] $Current,
        [AllowNull()] [object] $Target,
        [Parameter(Mandatory)] [string] $Reason
    )

    return [pscustomobject]@{
        organization = $Organization
        repository = $Repository.name
        repository_archived = [bool] $Repository.archived
        kind = $Kind
        label = $Label
        is_drift = $IsDrift
        usage_count = $UsageCount
        current_color = if ($null -eq $Current) { $null } else { [string] $Current.color }
        current_description = if ($null -eq $Current) { $null } else { [string] $Current.description }
        expected_color = if ($null -eq $Target) { $null } else { [string] $Target.color }
        expected_description = if ($null -eq $Target) { $null } else { [string] $Target.description }
        reason = $Reason
    }
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'GitHub CLI (gh) is required.'
}

$resolvedOutput = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $resolvedOutput | Out-Null
$findings = [System.Collections.Generic.List[object]]::new()
$repositories = [System.Collections.Generic.List[object]]::new()
$errors = [System.Collections.Generic.List[object]]::new()

foreach ($organization in $Organizations) {
    Write-Host "Reading repositories for $organization..."
    $organizationRepositories = @(Invoke-GhGet -Endpoint "orgs/$organization/repos?type=all&per_page=100&sort=full_name" -Paginate)
    foreach ($repository in $organizationRepositories) {
        if ($repository.archived -and -not $IncludeArchived) {
            continue
        }

        Write-Host "  Auditing $organization/$($repository.name)..."
        try {
            $labels = @(Invoke-GhGet -Endpoint "repos/$organization/$($repository.name)/labels?per_page=100" -Paginate)
            $items = @(Invoke-GhGet -Endpoint "repos/$organization/$($repository.name)/issues?state=all&per_page=100" -Paginate)
            $usage = Get-LabelUsage -Items $items
            $currentByName = @{}
            foreach ($label in $labels) {
                $currentByName[$label.name.Trim().ToLowerInvariant()] = $label
            }

            $repositoryFindings = [System.Collections.Generic.List[object]]::new()
            foreach ($canonicalName in @($canonicalLabels.Keys | Sort-Object)) {
                $target = $canonicalLabels[$canonicalName]
                if (-not $currentByName.ContainsKey($canonicalName)) {
                    $repositoryFindings.Add((New-Finding -Organization $organization -Repository $repository -Kind 'missing_canonical_label' -Label $canonicalName -IsDrift $true -Target $target -Reason 'Canonical label is missing.'))
                    continue
                }

                $current = $currentByName[$canonicalName]
                if ($current.color.ToLowerInvariant() -ne $target.color.ToLowerInvariant() -or
                    [string] $current.description -ne [string] $target.description) {
                    $repositoryFindings.Add((New-Finding -Organization $organization -Repository $repository -Kind 'canonical_metadata_mismatch' -Label $canonicalName -IsDrift $true -Current $current -Target $target -Reason 'Canonical label metadata differs from the standards manifest.'))
                }
            }

            foreach ($currentName in @($currentByName.Keys | Sort-Object)) {
                if ($canonicalLabels.ContainsKey($currentName)) {
                    continue
                }

                $current = $currentByName[$currentName]
                $usageCount = if ($usage.ContainsKey($currentName)) { [int] $usage[$currentName] } else { 0 }
                $rule = if ($legacyLabels.ContainsKey($currentName)) { $legacyLabels[$currentName] } else { $null }
                $isLiveResolutionException = $usageCount -gt 0 -and $null -ne $rule -and
                    $rule.PSObject.Properties.Name -contains 'state_reason'

                if ($isLiveResolutionException) {
                    $repositoryFindings.Add((New-Finding -Organization $organization -Repository $repository -Kind 'live_resolution_exception' -Label $currentName -IsDrift $false -UsageCount $usageCount -Current $current -Reason 'Legacy resolution semantics remain attached and are reported as an explicit exception.'))
                }
                else {
                    $repositoryFindings.Add((New-Finding -Organization $organization -Repository $repository -Kind 'nonstandard_label' -Label $currentName -IsDrift $true -UsageCount $usageCount -Current $current -Reason 'Label is not part of the canonical organization catalog.'))
                }
            }

            foreach ($finding in $repositoryFindings) {
                $findings.Add($finding)
            }
            $repositories.Add([pscustomobject]@{
                organization = $organization
                repository = $repository.name
                archived = [bool] $repository.archived
                item_count = $items.Count
                label_count = $labels.Count
                drift_count = @($repositoryFindings | Where-Object is_drift).Count
                exception_count = @($repositoryFindings | Where-Object { -not $_.is_drift }).Count
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

$drift = @($findings | Where-Object is_drift)
$exceptions = @($findings | Where-Object { -not $_.is_drift })
$timestamp = [datetimeoffset]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$baseName = "github-label-standards-audit-$timestamp"
$jsonPath = Join-Path $resolvedOutput "$baseName.json"
$csvPath = Join-Path $resolvedOutput "$baseName.csv"
$repositoriesPath = Join-Path $resolvedOutput "$baseName-repositories.csv"
$errorsPath = Join-Path $resolvedOutput "$baseName-errors.csv"
$markdownPath = Join-Path $resolvedOutput "$baseName.md"

$findings | Export-Csv -NoTypeInformation -Encoding utf8 $csvPath
$repositories | Export-Csv -NoTypeInformation -Encoding utf8 $repositoriesPath
$errors | Export-Csv -NoTypeInformation -Encoding utf8 $errorsPath
[ordered]@{
    audit_schema_version = 1
    generated_at = [datetimeoffset]::UtcNow.ToString('o')
    mode = 'read-only'
    standards_version = $standards.version
    organizations = $Organizations
    include_archived = [bool] $IncludeArchived
    summary = [ordered]@{
        repositories = $repositories.Count
        findings = $findings.Count
        drift = $drift.Count
        live_resolution_exceptions = $exceptions.Count
        errors = $errors.Count
    }
    findings = $findings
    errors = $errors
} | ConvertTo-Json -Depth 12 | Set-Content -Encoding utf8 $jsonPath

@"
# GitHub label standards audit

- Generated: $([datetimeoffset]::UtcNow.ToString('u'))
- Mode: **read-only**
- Organizations: $([string]::Join(', ', $Organizations))
- Repositories inspected: $($repositories.Count)
- Drift findings: $($drift.Count)
- Live resolution exceptions: $($exceptions.Count)
- Repository read errors: $($errors.Count)

Live resolution exceptions are reported but do not count as drift. No GitHub data was changed.
"@ | Set-Content -Encoding utf8 $markdownPath

Write-Host "Label standards audit complete. Report: $markdownPath"
Write-Host 'No GitHub data was changed.'
