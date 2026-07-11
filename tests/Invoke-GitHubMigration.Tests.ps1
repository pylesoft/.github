$script:repositoryRoot = Split-Path $PSScriptRoot -Parent
$script:applyScript = Join-Path $script:repositoryRoot 'scripts/Invoke-GitHubMigration.ps1'
$script:dryRunScript = Join-Path $script:repositoryRoot 'scripts/New-GitHubMigrationDryRun.ps1'

function global:gh {
    $arguments = @($args)
    $methodIndex = [array]::IndexOf($arguments, '--method')
    $method = if ($methodIndex -ge 0) { $arguments[$methodIndex + 1] } else { 'GET' }
    $endpoint = @($arguments | Where-Object { $_ -match '^(repos|orgs)/' })[0]
    $paginate = $arguments -contains '--slurp'
    $inputIndex = [array]::IndexOf($arguments, '--input')
    $inputSource = if ($inputIndex -ge 0) { $arguments[$inputIndex + 1] } else { $null }

    if ($method -ne 'GET' -and $inputSource -eq '-') {
        $global:LASTEXITCODE = 1
        Write-Error 'gh: Problems parsing JSON (HTTP 400)' -ErrorAction Continue
        return
    }

    $bodyText = if ($null -ne $inputSource) {
        $bytes = [System.IO.File]::ReadAllBytes($inputSource)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            throw 'Request JSON must be UTF-8 without a byte-order mark.'
        }
        [System.Text.Encoding]::UTF8.GetString($bytes).Trim()
    }
    else {
        ($input | Out-String).Trim()
    }
    $body = if ([string]::IsNullOrWhiteSpace($bodyText)) { $null } else { $bodyText | ConvertFrom-Json }

    function Write-Response {
        param([AllowNull()] [object] $Value)

        if ($null -eq $Value) {
            return
        }

        $payload = if ($paginate) { @(@($Value)) } else { $Value }
        Write-Output (ConvertTo-Json -InputObject $payload -Depth 12 -Compress)
    }

    function Touch-Issue {
        $global:FakeGithub.sequence++
        $global:FakeGithub.updated_at = '2026-07-11T12:00:{0:00}Z' -f $global:FakeGithub.sequence
    }

    $global:LASTEXITCODE = 0

    if ($method -eq 'GET' -and $endpoint -like 'orgs/pylesoft/repos*') {
        Write-Response @([pscustomobject]@{
            name = 'example'
            archived = $false
            has_issues = $true
            default_branch = 'master'
        })
        return
    }

    if ($method -eq 'GET' -and $endpoint -match '^repos/pylesoft/example/issues\?') {
        Write-Response @([pscustomobject]@{
            number = 1
            state = 'open'
            updated_at = $global:FakeGithub.updated_at
            type = if ($null -eq $global:FakeGithub.type) { $null } else { [pscustomobject]@{ name = $global:FakeGithub.type } }
            labels = @($global:FakeGithub.issue_labels | ForEach-Object { [pscustomobject]@{ name = $_ } })
            html_url = 'https://github.com/pylesoft/example/issues/1'
            pull_request = $null
        })
        return
    }

    if ($method -eq 'GET' -and $endpoint -eq 'repos/pylesoft/example/issues/1') {
        $labels = @($global:FakeGithub.issue_labels | ForEach-Object {
            $name = $_
            $definition = @($global:FakeGithub.repository_labels | Where-Object { $_.name -eq $name })
            if ($definition.Count -gt 0) {
                $definition[0]
            }
            else {
                [pscustomobject]@{ name = $name; color = 'ededed'; description = '' }
            }
        })

        Write-Response ([pscustomobject]@{
            number = 1
            state = 'open'
            updated_at = $global:FakeGithub.updated_at
            type = if ($null -eq $global:FakeGithub.type) { $null } else { [pscustomobject]@{ name = $global:FakeGithub.type } }
            labels = $labels
            html_url = 'https://github.com/pylesoft/example/issues/1'
        })
        return
    }

    if ($method -eq 'GET' -and $endpoint -like 'repos/pylesoft/example/issues/1/issue-field-values*') {
        $values = @()
        if ($null -ne $global:FakeGithub.priority) {
            $values = @([pscustomobject]@{
                issue_field_id = 10
                issue_field_name = 'Priority'
                data_type = 'single_select'
                single_select_option = [pscustomobject]@{ id = 101; name = $global:FakeGithub.priority; color = 'red' }
            })
        }
        Write-Response $values
        return
    }

    if ($method -eq 'GET' -and $endpoint -like 'orgs/pylesoft/issue-fields*') {
        Write-Response @([pscustomobject]@{ id = 10; name = 'Priority'; data_type = 'single_select' })
        return
    }

    if ($method -eq 'GET' -and $endpoint -like 'repos/pylesoft/example/labels*') {
        Write-Response @($global:FakeGithub.repository_labels)
        return
    }

    if ($method -eq 'PATCH' -and $endpoint -eq 'repos/pylesoft/example/issues/1') {
        if ($body.PSObject.Properties.Name -contains 'type') {
            $global:FakeGithub.type = [string] $body.type
        }
        Touch-Issue
        Write-Response @{ ok = $true }
        return
    }

    if ($method -eq 'POST' -and $endpoint -eq 'repos/pylesoft/example/issues/1/issue-field-values') {
        $global:FakeGithub.priority = [string] @($body.issue_field_values)[0].value
        Touch-Issue
        Write-Response @()
        return
    }

    if ($method -eq 'POST' -and $endpoint -eq 'repos/pylesoft/example/labels') {
        $global:FakeGithub.repository_labels = @($global:FakeGithub.repository_labels) + @([pscustomobject]@{
            name = [string] $body.name
            color = [string] $body.color
            description = [string] $body.description
        })
        Write-Response $body
        return
    }

    if ($method -eq 'PATCH' -and $endpoint -like 'repos/pylesoft/example/labels/*') {
        $name = [uri]::UnescapeDataString(($endpoint -split '/')[-1])
        $definition = @($global:FakeGithub.repository_labels | Where-Object { $_.name -eq $name })[0]
        $definition.color = [string] $body.color
        $definition.description = [string] $body.description
        Write-Response $definition
        return
    }

    if ($method -eq 'POST' -and $endpoint -eq 'repos/pylesoft/example/issues/1/labels') {
        $global:FakeGithub.issue_labels = @($global:FakeGithub.issue_labels + @($body.labels) | Sort-Object -Unique)
        Touch-Issue
        Write-Response @()
        return
    }

    if ($method -eq 'DELETE' -and $endpoint -like 'repos/pylesoft/example/issues/1/labels/*') {
        if ($global:FakeGithub.throw_on_delete) {
            throw 'Simulated interruption after replacement labels were written.'
        }

        $name = [uri]::UnescapeDataString(($endpoint -split '/')[-1])
        $global:FakeGithub.issue_labels = @($global:FakeGithub.issue_labels | Where-Object { $_ -ne $name })
        Touch-Issue
        return
    }

    $global:LASTEXITCODE = 1
    [Console]::Error.WriteLine("Unexpected fake gh call: $method $endpoint")
}

function New-TestPlan {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [switch] $ManualReview
    )

    $proposal = [ordered]@{
        organization = 'pylesoft'
        repository = 'example'
        repository_archived = $false
        number = 1
        kind = 'issue'
        state = 'open'
        source_updated_at = '2026-07-11T12:00:00Z'
        url = 'https://github.com/pylesoft/example/issues/1'
        current_type = $null
        proposed_type = 'Feature'
        current_priority = $null
        current_labels = 'feature|urgent'
        proposed_labels = 'enhancement'
        remove_labels = 'feature|urgent'
        proposed_priority = 'Urgent'
        proposed_state_reason = $null
        proposed_project_status = $null
        manual_review = [bool] $ManualReview
        proposed_changes = 'type:<none>->Feature;priority:<none>->Urgent;add_labels:enhancement;remove_labels:feature|urgent'
        notes = if ($ManualReview) { 'Requires a decision.' } else { '' }
    }

    $plan = [ordered]@{
        plan_schema_version = 2
        generated_at = [datetimeoffset]::UtcNow.ToString('o')
        mode = 'dry-run-read-only'
        standards_version = 1
        organizations = @('pylesoft')
        include_archived = $false
        summary = @{ repositories = 1; items = 1; items_with_proposed_changes = 1; manual_review_items = if ($ManualReview) { 1 } else { 0 }; errors = 0 }
        proposals = @($proposal)
        errors = @()
    }

    ConvertTo-Json -InputObject $plan -Depth 12 | Set-Content -Encoding utf8 $Path
}

Describe 'Invoke-GitHubMigration' {
    BeforeEach {
        $global:FakeGithub = @{
            type = $null
            priority = $null
            issue_labels = @('feature', 'urgent')
            repository_labels = @(
                [pscustomobject]@{ name = 'feature'; color = 'a2eeef'; description = '' },
                [pscustomobject]@{ name = 'urgent'; color = 'b60205'; description = '' }
            )
            updated_at = '2026-07-11T12:00:00Z'
            sequence = 0
            throw_on_delete = $false
        }

        $script:planPath = Join-Path $TestDrive 'plan.json'
        $script:outputPath = Join-Path $TestDrive 'runs'
        New-TestPlan -Path $script:planPath
        $script:planHash = (Get-FileHash -Algorithm SHA256 $script:planPath).Hash
    }

    It 'applies replacements before removals and verifies the final state' {
        Push-Location $script:repositoryRoot
        try {
            & $script:applyScript -PlanPath $script:planPath -PlanSha256 $script:planHash -Apply -OutputDirectory $script:outputPath -DelayMilliseconds 0
        }
        finally {
            Pop-Location
        }

        $global:FakeGithub.type | Should Be 'Feature'
        $global:FakeGithub.priority | Should Be 'Urgent'
        @($global:FakeGithub.issue_labels) | Should Be @('enhancement')

        $summary = Get-Content -Raw (Join-Path $script:outputPath "plan-$($script:planHash.Substring(0, 12).ToLowerInvariant())/summary.json") | ConvertFrom-Json
        $summary.verified | Should Be 1
        $summary.remaining | Should Be 0

        $events = Get-Content (Join-Path $script:outputPath "plan-$($script:planHash.Substring(0, 12).ToLowerInvariant())/events.jsonl") | ForEach-Object { $_ | ConvertFrom-Json }
        $replacementIndex = [array]::IndexOf(@($events.status), 'replacement_labels_verified')
        $removalIndex = [array]::IndexOf(@($events.status), 'legacy_label_removal_verified')
        ($replacementIndex -ge 0) | Should Be $true
        ($removalIndex -gt $replacementIndex) | Should Be $true
    }

    It 'generates a schema 2 plan with the current Priority and source timestamp' {
        $global:FakeGithub.priority = 'Urgent'
        $dryRunOutput = Join-Path $TestDrive 'dry-run'

        Push-Location $script:repositoryRoot
        try {
            & $script:dryRunScript -Organizations pylesoft -OutputDirectory $dryRunOutput
        }
        finally {
            Pop-Location
        }

        $planFile = Get-ChildItem -LiteralPath $dryRunOutput -Filter '*.json' | Select-Object -First 1
        $plan = Get-Content -Raw $planFile.FullName | ConvertFrom-Json
        $plan.plan_schema_version | Should Be 2
        $plan.proposals[0].source_updated_at | Should Be '2026-07-11T12:00:00Z'
        $plan.proposals[0].current_priority | Should Be 'Urgent'
        ($plan.proposals[0].proposed_changes -match 'priority:') | Should Be $false
    }

    It 'rejects a plan whose hash does not match' {
        Push-Location $script:repositoryRoot
        try {
            { & $script:applyScript -PlanPath $script:planPath -PlanSha256 ('0' * 64) -Apply -OutputDirectory $script:outputPath } | Should Throw
        }
        finally {
            Pop-Location
        }

        $global:FakeGithub.type | Should Be $null
        @($global:FakeGithub.issue_labels) | Should Be @('feature', 'urgent')
    }

    It 'stops before mutation when GitHub changed after the dry run' {
        $global:FakeGithub.updated_at = '2026-07-11T12:30:00Z'

        Push-Location $script:repositoryRoot
        try {
            { & $script:applyScript -PlanPath $script:planPath -PlanSha256 $script:planHash -Apply -OutputDirectory $script:outputPath -DelayMilliseconds 0 *> $null } | Should Throw
        }
        finally {
            Pop-Location
        }

        $global:FakeGithub.type | Should Be $null
        @($global:FakeGithub.issue_labels) | Should Be @('feature', 'urgent')
    }

    It 'records manual-review proposals without mutating them' {
        New-TestPlan -Path $script:planPath -ManualReview
        $script:planHash = (Get-FileHash -Algorithm SHA256 $script:planPath).Hash

        Push-Location $script:repositoryRoot
        try {
            & $script:applyScript -PlanPath $script:planPath -PlanSha256 $script:planHash -Apply -OutputDirectory $script:outputPath -DelayMilliseconds 0
        }
        finally {
            Pop-Location
        }

        $global:FakeGithub.type | Should Be $null
        @($global:FakeGithub.issue_labels) | Should Be @('feature', 'urgent')
        $summary = Get-Content -Raw (Join-Path $script:outputPath "plan-$($script:planHash.Substring(0, 12).ToLowerInvariant())/summary.json") | ConvertFrom-Json
        $summary.manual_review_skipped | Should Be 1
        $summary.verified | Should Be 0
    }

    It 'resumes an item that stopped after replacement data was verified' {
        $global:FakeGithub.throw_on_delete = $true

        Push-Location $script:repositoryRoot
        try {
            { & $script:applyScript -PlanPath $script:planPath -PlanSha256 $script:planHash -Apply -OutputDirectory $script:outputPath -DelayMilliseconds 0 *> $null } | Should Throw
            $global:FakeGithub.throw_on_delete = $false
            & $script:applyScript -PlanPath $script:planPath -PlanSha256 $script:planHash -Apply -OutputDirectory $script:outputPath -DelayMilliseconds 0 -Resume
        }
        finally {
            Pop-Location
        }

        $global:FakeGithub.type | Should Be 'Feature'
        $global:FakeGithub.priority | Should Be 'Urgent'
        @($global:FakeGithub.issue_labels) | Should Be @('enhancement')
        $summary = Get-Content -Raw (Join-Path $script:outputPath "plan-$($script:planHash.Substring(0, 12).ToLowerInvariant())/summary.json") | ConvertFrom-Json
        $summary.verified | Should Be 1
        $summary.remaining | Should Be 0
    }

    AfterAll {
        Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
        Remove-Variable FakeGithub -Scope Global -ErrorAction SilentlyContinue
    }
}
