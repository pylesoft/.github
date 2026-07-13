$script:repositoryRoot = Split-Path $PSScriptRoot -Parent
$script:auditScript = Join-Path $script:repositoryRoot 'scripts/New-GitHubLabelStandardsAudit.ps1'

function global:gh {
    $arguments = @($args)
    $endpoint = @($arguments | Where-Object { $_ -match '^(repos|orgs)/' })[0]
    $paginate = $arguments -contains '--slurp'
    $global:LASTEXITCODE = 0

    $value = if ($endpoint -like 'orgs/pylesoft/repos*') {
        @([pscustomobject]@{ name = 'example'; archived = $false })
    }
    elseif ($endpoint -like 'repos/pylesoft/example/labels*') {
        @($global:FakeGithub.labels)
    }
    elseif ($endpoint -like 'repos/pylesoft/example/issues*') {
        @($global:FakeGithub.items)
    }
    else {
        $global:LASTEXITCODE = 1
        Write-Error "Unexpected fake gh call: $endpoint" -ErrorAction Continue
        return
    }

    if ($paginate) {
        Write-Output (ConvertTo-Json -InputObject @(@($value)) -Depth 10 -Compress)
    }
    else {
        Write-Output (ConvertTo-Json -InputObject $value -Depth 10 -Compress)
    }
}

Describe 'New-GitHubLabelStandardsAudit' {
    BeforeEach {
        $global:FakeGithub = @{
            labels = @(
                [pscustomobject]@{ name = 'bug'; color = 'd73a4a'; description = 'Confirmed incorrect behavior or its fix' },
                [pscustomobject]@{ name = 'enhancement'; color = 'a2eeef'; description = 'New capability or meaningful improvement' },
                [pscustomobject]@{ name = 'documentation'; color = '0075ca'; description = 'Documentation-only or documentation-focused work' },
                [pscustomobject]@{ name = 'docs-needed'; color = '0e8a16'; description = 'Force post-merge documentation follow-up' },
                [pscustomobject]@{ name = 'wontfix'; color = 'ffffff'; description = 'This will not be worked on' }
            )
            items = @(
                [pscustomobject]@{ number = 1; labels = @([pscustomobject]@{ name = 'wontfix' }) }
            )
        }
    }

    It 'reports live resolution labels without treating them as drift' {
        $output = Join-Path $TestDrive 'compliant'
        & $script:auditScript -Organizations pylesoft -OutputDirectory $output

        $report = Get-Content -Raw (Get-ChildItem $output -Filter '*.json' | Select-Object -First 1 -ExpandProperty FullName) | ConvertFrom-Json
        $report.summary.repositories | Should Be 1
        $report.summary.drift | Should Be 0
        $report.summary.live_resolution_exceptions | Should Be 1
        $report.summary.errors | Should Be 0
    }

    It 'detects missing canonical labels and nonstandard labels' {
        $global:FakeGithub.labels = @($global:FakeGithub.labels | Where-Object name -ne 'docs-needed') + @(
            [pscustomobject]@{ name = 'feature'; color = 'a2eeef'; description = 'Legacy feature label' }
        )
        $output = Join-Path $TestDrive 'drift'
        & $script:auditScript -Organizations pylesoft -OutputDirectory $output

        $report = Get-Content -Raw (Get-ChildItem $output -Filter '*.json' | Select-Object -First 1 -ExpandProperty FullName) | ConvertFrom-Json
        $report.summary.drift | Should Be 2
        @($report.findings | Where-Object is_drift | Select-Object -ExpandProperty kind | Sort-Object) | Should Be @('missing_canonical_label', 'nonstandard_label')
    }

    AfterAll {
        Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
        Remove-Variable FakeGithub -Scope Global -ErrorAction SilentlyContinue
    }
}
