#Requires -Version 5.1
<#
    run-tests.ps1

    Offline logic tests for CDA Repository Lifecycle Tooling v1 -- BOTH
    lifecycle paths (src/provisioner for NEW repositories, src/adopter for
    EXISTING repositories) plus src/common (the shared core). No `gh`
    call, no network access, no real GitHub repository. Fixture-based,
    plain assertions, no test-framework dependency.

    This suite is the union of the two source tools' own proven test
    suites (see docs/lifecycle.md's "Testing" note): everything sections
    1-23 below cover is migrated, unchanged in intent, from the adopter's
    own 354-assertion suite; sections 24+ add provisioner-specific tests
    (migrated from its own suite), common-core tests, JSON Schema
    validation, and the destructive-operations-registry / capability-model
    regression guards this formalization introduces.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$commandsDir = Join-Path $root 'commands'
$adopterLib = Join-Path $root 'src\adopter\lib'
$provisionerLib = Join-Path $root 'src\provisioner\lib'
$commonGithub = Join-Path $root 'src\common\github'
$commonRepo = Join-Path $root 'src\common\repository'
$commonProfile = Join-Path $root 'src\common\profile'
$schemasDir = Join-Path $root 'schemas'
$fixturesDir = Join-Path $root 'tests\fixtures'

# Same nested-module import-order requirement as the commands themselves --
# see commands/assess-npm-library.ps1's own comment for why this exact
# order is needed. Approval.psm1 / Apply.psm1 / Verification.psm1 /
# MutationGitHub.psm1 do not nest-import anything themselves, so their
# position relative to each other does not matter.
Import-Module (Join-Path $adopterLib 'Comparison.psm1') -Force
Import-Module (Join-Path $adopterLib 'AdoptionPlan.psm1') -Force
Import-Module (Join-Path $adopterLib 'Discovery.psm1') -Force
Import-Module (Join-Path $adopterLib 'Classification.psm1') -Force
Import-Module (Join-Path $adopterLib 'Approval.psm1') -Force
Import-Module (Join-Path $adopterLib 'Apply.psm1') -Force
Import-Module (Join-Path $adopterLib 'Verification.psm1') -Force
Import-Module (Join-Path $commonGithub 'MutationGitHub.psm1') -Force
Import-Module (Join-Path $adopterLib 'MergeReproducibility.psm1') -Force
Import-Module (Join-Path $commonProfile 'ProfileLoader.psm1') -Force
# Provisioner chain, WITH the known nested-import re-registration fix
# (Orchestration.psm1 nest-imports Provisioner.psm1, which un-registers
# Provisioner.psm1's own top-level visibility -- re-importing it once more
# restores direct callability for the tests below; same pattern the
# original provisioner test suite already used).
Import-Module (Join-Path $provisionerLib 'Provisioner.psm1') -Force
Import-Module (Join-Path $provisionerLib 'Orchestration.psm1') -Force
Import-Module (Join-Path $provisionerLib 'Provisioner.psm1') -Force
# The four common modules MUST be (re-)imported LAST, in this exact
# relative order, after EVERYTHING above: several already-imported modules
# (Discovery.psm1; Orchestration.psm1, which itself nest-imports
# MutationGitHub.psm1; Provisioner.psm1, re-imported via Orchestration.psm1)
# each nest-import RepositoryDiscovery.psm1/Validation.psm1/
# ReadOnlyGitHub.psm1/MutationGitHub.psm1 themselves, and whichever import
# touches a given module LAST determines its top-level visibility for the
# rest of this script -- confirmed empirically (importing any of these
# earlier than this left it silently un-registered as a top-level module
# again). RepositoryDiscovery.psm1, Validation.psm1, and MutationGitHub.psm1
# do not nest each other, so their relative order doesn't matter, but
# ReadOnlyGitHub.psm1 -- nested by BOTH RepositoryDiscovery.psm1 and
# Validation.psm1 -- must be the absolute last line in this entire import
# block.
Import-Module (Join-Path $commonGithub 'RepositoryDiscovery.psm1') -Force
Import-Module (Join-Path $commonRepo 'Validation.psm1') -Force
Import-Module (Join-Path $commonGithub 'MutationGitHub.psm1') -Force
Import-Module (Join-Path $commonGithub 'ReadOnlyGitHub.psm1') -Force

$script:PassCount = 0
$script:FailCount = 0

function Assert-True {
    param([Parameter(Mandatory)] [string]$Name, [Parameter(Mandatory)] [bool]$Condition, [string]$Detail = '')
    if ($Condition) { $script:PassCount++; Write-Host "  PASS: $Name" -ForegroundColor Green }
    else { $script:FailCount++; Write-Host "  FAIL: $Name $Detail" -ForegroundColor Red }
}
function Assert-Equal {
    param([Parameter(Mandatory)] [string]$Name, $Expected, $Actual)
    Assert-True -Name $Name -Condition ("$Expected" -ceq "$Actual") -Detail "(expected '$Expected', got '$Actual')"
}

# ---------------------------------------------------------------------------
Write-Host "1. PowerShell syntax" -ForegroundColor Cyan
foreach ($f in @(
        (Join-Path $commandsDir 'assess-npm-library.ps1'),
        (Join-Path $commandsDir 'approve-plan.ps1'),
        (Join-Path $commandsDir 'apply-plan.ps1'),
        (Join-Path $commandsDir 'provision-npm-library.ps1'),
        (Join-Path $commandsDir 'provision-repository.ps1'),
        (Join-Path $commonGithub 'ReadOnlyGitHub.psm1'),
        (Join-Path $commonGithub 'MutationGitHub.psm1'),
        (Join-Path $commonGithub 'RepositoryDiscovery.psm1'),
        (Join-Path $commonRepo 'Validation.psm1'),
        (Join-Path $commonProfile 'ProfileLoader.psm1'),
        (Join-Path $adopterLib 'Discovery.psm1'),
        (Join-Path $adopterLib 'Classification.psm1'),
        (Join-Path $adopterLib 'Comparison.psm1'),
        (Join-Path $adopterLib 'AdoptionPlan.psm1'),
        (Join-Path $adopterLib 'Approval.psm1'),
        (Join-Path $adopterLib 'Apply.psm1'),
        (Join-Path $adopterLib 'Verification.psm1'),
        (Join-Path $adopterLib 'MergeReproducibility.psm1'),
        (Join-Path $provisionerLib 'Provisioner.psm1'),
        (Join-Path $provisionerLib 'Orchestration.psm1')
    )) {
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$parseErrors)
    Assert-True -Name "parses cleanly: $(Split-Path -Leaf $f)" -Condition (@($parseErrors).Count -eq 0) -Detail (($parseErrors | ForEach-Object { $_.Message }) -join '; ')
}

# ---------------------------------------------------------------------------
Write-Host "2. Mutation guard (hard safety mechanism)" -ForegroundColor Cyan

$roModule = Get-Module ReadOnlyGitHub
Assert-True -Name 'ReadOnlyGitHub module is loaded' -Condition ($null -ne $roModule)

$exported = @((Get-Command -Module ReadOnlyGitHub).Name | Sort-Object)
$expectedExports = @('Get-ReadOnlyGitHubPaged', 'Invoke-ReadOnlyGitHub', 'Test-GhAuthenticated') | Sort-Object
Assert-True -Name 'ReadOnlyGitHub exports exactly the 3 expected read-only functions, nothing else' -Condition (@(Compare-Object $exported $expectedExports).Count -eq 0) -Detail "(actual: $($exported -join ', '))"

$invokeCmd = Get-Command Invoke-ReadOnlyGitHub
$paramNames = @($invokeCmd.Parameters.Keys | Where-Object { $_ -notin @('Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction', 'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable') })
Assert-True -Name 'Invoke-ReadOnlyGitHub has no -Method parameter' -Condition ($paramNames -notcontains 'Method')
Assert-True -Name 'Invoke-ReadOnlyGitHub has no -BodyObject / body-carrying parameter' -Condition ($paramNames -notcontains 'BodyObject' -and $paramNames -notcontains 'Body')
Assert-True -Name 'Invoke-ReadOnlyGitHub accepts only -Path' -Condition (@(Compare-Object $paramNames @('Path')).Count -eq 0) -Detail "(actual params: $($paramNames -join ', '))"

$roApiSource = Get-Content -LiteralPath (Join-Path $commonGithub 'ReadOnlyGitHub.psm1') -Raw
$xFlagMatches = [regex]::Matches($roApiSource, "'-X',\s*'([A-Z]+)'")
$xFlagValues = @($xFlagMatches | ForEach-Object { $_.Groups[1].Value })
$nonGetXFlags = @($xFlagValues | Where-Object { $_ -ne 'GET' })
Assert-True -Name 'every -X flag construction in ReadOnlyGitHub.psm1 is a literal, hardcoded GET' -Condition (($xFlagValues.Count -ge 1) -and ($nonGetXFlags.Count -eq 0)) -Detail "(found: $($xFlagValues -join ', '))"

$mutModule = Get-Module MutationGitHub
Assert-True -Name 'MutationGitHub module is loaded' -Condition ($null -ne $mutModule)
$mutExported = @((Get-Command -Module MutationGitHub).Name | Sort-Object)
Assert-True -Name 'MutationGitHub exports exactly Invoke-MutationGitHub, nothing else' -Condition (@(Compare-Object $mutExported @('Invoke-MutationGitHub')).Count -eq 0) -Detail "(actual: $($mutExported -join ', '))"

$mutCmd = Get-Command Invoke-MutationGitHub
$methodParam = $mutCmd.Parameters['Method']
Assert-True -Name 'Invoke-MutationGitHub -Method has no GET in its ValidateSet (mutation-only)' -Condition ($null -ne $methodParam -and ($methodParam.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } | ForEach-Object { $_.ValidValues }) -notcontains 'GET')
$methodParamAttr = @($mutCmd.Parameters['Method'].Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] })
Assert-True -Name 'Invoke-MutationGitHub -Method is Mandatory (no accidental default verb)' -Condition ($methodParamAttr.Count -gt 0 -and $methodParamAttr[0].Mandatory)

$mutApiSource = Get-Content -LiteralPath (Join-Path $commonGithub 'MutationGitHub.psm1') -Raw
$mutXFlagValues = @([regex]::Matches($mutApiSource, "'-X',\s*\`$Method") | ForEach-Object { 'DYNAMIC-VIA-METHOD-PARAM' })
Assert-True -Name 'MutationGitHub.psm1''s -X flag is driven by the mandatory -Method parameter, not a hardcoded verb' -Condition ($mutXFlagValues.Count -ge 1)

# STRUCTURAL read-only/mutation isolation, scanned across the WHOLE
# repository source (both lifecycle paths + common), not asserted by
# convention alone -- see docs/safety-model.md, "Read-only/mutation
# isolation". Every assess/discovery-only file must never import
# MutationGitHub.psm1; only the two mutation choke-points
# (src/adopter/lib/Apply.psm1 and src/provisioner/lib/Orchestration.psm1)
# and the commands that explicitly perform a mutation (apply-plan.ps1,
# provision-npm-library.ps1) may.
$allSourceFiles = Get-ChildItem -Path $root -Recurse -Include *.ps1, *.psm1 | Where-Object { $_.FullName -notmatch '\\tests\\' }
$assessOnlyFiles = @(
    (Join-Path $adopterLib 'Discovery.psm1'), (Join-Path $adopterLib 'Classification.psm1'), (Join-Path $adopterLib 'Comparison.psm1'),
    (Join-Path $adopterLib 'MergeReproducibility.psm1'), (Join-Path $adopterLib 'AdoptionPlan.psm1'), (Join-Path $adopterLib 'Approval.psm1'),
    (Join-Path $provisionerLib 'Provisioner.psm1'),
    (Join-Path $commonGithub 'ReadOnlyGitHub.psm1'), (Join-Path $commonGithub 'RepositoryDiscovery.psm1'),
    (Join-Path $commonRepo 'Validation.psm1'), (Join-Path $commonProfile 'ProfileLoader.psm1'),
    (Join-Path $commandsDir 'assess-npm-library.ps1'), (Join-Path $commandsDir 'approve-plan.ps1')
)
$violations = @()
foreach ($f in $assessOnlyFiles) {
    $text = Get-Content -LiteralPath $f -Raw
    # Matches an actual Import-Module STATEMENT or a real function CALL
    # (a following space-dash or paren) -- deliberately does NOT match a
    # bare mention of the module/function name inside a documentation
    # comment (several of these files' own header comments explicitly
    # restate "never MutationGitHub.psm1" as the safety invariant being
    # described, which a naive substring match would misreport as a
    # violation of itself).
    if ($text -match 'Import-Module[^\r\n]*MutationGitHub\.psm1' -or $text -match 'Invoke-MutationGitHub\s+-' -or $text -match 'Invoke-MutationGitHub\(') { $violations += $f }
}
Assert-True -Name 'no assess/discovery-only file in either lifecycle path imports or calls the mutation module' -Condition ($violations.Count -eq 0) -Detail "(violations: $($violations -join ', '))"

$orchestrationReferencedInAdopter = $false
foreach ($f in (Get-ChildItem -Path $adopterLib -Include *.ps1, *.psm1)) {
    if ((Get-Content -LiteralPath $f.FullName -Raw) -match 'Orchestration\.psm1|Invoke-Provisioning|Invoke-CapabilityMutation') { $orchestrationReferencedInAdopter = $true }
}
Assert-True -Name 'the adopter lifecycle path never references the provisioner lifecycle path''s Bootstrap/Finalize/convergence code' -Condition (-not $orchestrationReferencedInAdopter)

$assessSource = Get-Content -LiteralPath (Join-Path $commandsDir 'assess-npm-library.ps1') -Raw
$approveSource = Get-Content -LiteralPath (Join-Path $commandsDir 'approve-plan.ps1') -Raw
Assert-True -Name 'assess-npm-library.ps1 never imports MutationGitHub.psm1 (structurally cannot mutate)' -Condition ($assessSource -notmatch 'MutationGitHub\.psm1')
Assert-True -Name 'approve-plan.ps1 never imports MutationGitHub.psm1 (approval makes no GitHub call)' -Condition ($approveSource -notmatch 'Import-Module[^\r\n]*MutationGitHub\.psm1')

# ---------------------------------------------------------------------------
Write-Host "3. Repository validation" -ForegroundColor Cyan
$valid = Test-RepositoryNameFormat -Repository 'Continuous-DrivenArchitecture/adapter-xma'
Assert-True -Name 'accepts well-formed owner/repo' -Condition $valid.Valid
Assert-Equal -Name 'extracts owner' -Expected 'Continuous-DrivenArchitecture' -Actual $valid.Owner
foreach ($bad in @('no-slash', 'too/many/slashes')) {
    $r = Test-RepositoryNameFormat -Repository $bad
    Assert-True -Name "rejects malformed input: '$bad'" -Condition (-not $r.Valid)
}

# ---------------------------------------------------------------------------
Write-Host "4. Classification taxonomy" -ForegroundColor Cyan
$taxonomy = Get-AdopterClassificationTaxonomy
Assert-Equal -Name 'taxonomy has exactly 8 categories' -Expected 8 -Actual $taxonomy.Count
foreach ($expected in @('COMPLIANT', 'SAFE_CHANGE', 'REVIEW_REQUIRED', 'BLOCKED', 'KEEP_STRONGER', 'REMOVE_CANDIDATE', 'NOT_AVAILABLE', 'UNKNOWN')) {
    Assert-True -Name "taxonomy includes $expected" -Condition ($taxonomy -contains $expected)
}
try {
    New-CapabilityRow -Capability 'x' -Current 'a' -Target 'b' -Classification 'NOT_A_REAL_CATEGORY' -Rationale 'test' | Out-Null
    Assert-True -Name 'New-CapabilityRow rejects an invalid classification' -Condition $false -Detail '(did not throw)'
}
catch {
    Assert-True -Name 'New-CapabilityRow rejects an invalid classification' -Condition $true
}

# ---------------------------------------------------------------------------
Write-Host "5. Boolean/structural capability classification" -ForegroundColor Cyan
$compliantBool = Get-BooleanToggleClassification -Capability 'x' -Applicable $true -Current $true -TargetOn $true
Assert-Equal -Name 'boolean: matches -> COMPLIANT' -Expected 'COMPLIANT' -Actual $compliantBool.Classification
$safeBool = Get-BooleanToggleClassification -Capability 'x' -Applicable $true -Current $false -TargetOn $true
Assert-Equal -Name 'boolean: off, target on -> SAFE_CHANGE' -Expected 'SAFE_CHANGE' -Actual $safeBool.Classification
$reviewBool = Get-BooleanToggleClassification -Capability 'x' -Applicable $true -Current $true -TargetOn $false
Assert-Equal -Name 'boolean: on, target off -> REVIEW_REQUIRED (never auto-weaken)' -Expected 'REVIEW_REQUIRED' -Actual $reviewBool.Classification
$naBool = Get-BooleanToggleClassification -Capability 'x' -Applicable $false -Current $null -TargetOn $true
Assert-Equal -Name 'boolean: not applicable -> NOT_AVAILABLE' -Expected 'NOT_AVAILABLE' -Actual $naBool.Classification
$unkBool = Get-BooleanToggleClassification -Capability 'x' -Applicable $true -Current $null -TargetOn $true
Assert-Equal -Name 'boolean: unreadable -> UNKNOWN' -Expected 'UNKNOWN' -Actual $unkBool.Classification

$structReview = Get-StructuralCapabilityClassification -Capability 'x' -Applicable $true -Current 'develop' -Target 'main'
Assert-Equal -Name 'structural: differs -> REVIEW_REQUIRED' -Expected 'REVIEW_REQUIRED' -Actual $structReview.Classification
$structCompliant = Get-StructuralCapabilityClassification -Capability 'x' -Applicable $true -Current 'main' -Target 'main'
Assert-Equal -Name 'structural: matches -> COMPLIANT' -Expected 'COMPLIANT' -Actual $structCompliant.Classification

# ---------------------------------------------------------------------------
Write-Host "6. KEEP_STRONGER (approval count)" -ForegroundColor Cyan
$stronger = Get-ApprovalCountClassification -CurrentCount 1 -TargetCount 0
Assert-Equal -Name 'existing approvals (1) > CDA minimum (0) -> KEEP_STRONGER' -Expected 'KEEP_STRONGER' -Actual $stronger.Classification
Assert-True -Name 'KEEP_STRONGER rationale does not suggest lowering the value' -Condition ($stronger.Rationale -notmatch '(?i)lower|reduce|weaken to|update to 0')
$equalApprovals = Get-ApprovalCountClassification -CurrentCount 0 -TargetCount 0
Assert-Equal -Name 'existing approvals (0) == CDA minimum (0) -> COMPLIANT' -Expected 'COMPLIANT' -Actual $equalApprovals.Classification
$weakerApprovals = Get-ApprovalCountClassification -CurrentCount 0 -TargetCount 1
Assert-Equal -Name 'existing approvals (0) < a hypothetical higher target -> REVIEW_REQUIRED' -Expected 'REVIEW_REQUIRED' -Actual $weakerApprovals.Classification

# ---------------------------------------------------------------------------
Write-Host "7. BLOCKED / REVIEW_REQUIRED / SAFE_CHANGE branch-deletion scenarios" -ForegroundColor Cyan

$blockedDevelop = Get-DevelopDeletionClassification -HasCommitsNotInMain $true -HasOpenPRsTargetingDevelop $false -WorkflowsReferenceDevelop $false -DependabotTargetsDevelop $false -DocsReferenceDevelop $false
Assert-Equal -Name 'develop has unique commits -> BLOCKED' -Expected 'BLOCKED' -Actual $blockedDevelop.Classification

$reviewDevelopWorkflow = Get-DevelopDeletionClassification -HasCommitsNotInMain $false -HasOpenPRsTargetingDevelop $false -WorkflowsReferenceDevelop $true -DependabotTargetsDevelop $false -DocsReferenceDevelop $false
Assert-Equal -Name 'develop fully merged but referenced by a workflow -> REVIEW_REQUIRED' -Expected 'REVIEW_REQUIRED' -Actual $reviewDevelopWorkflow.Classification

$reviewDevelopPR = Get-DevelopDeletionClassification -HasCommitsNotInMain $false -HasOpenPRsTargetingDevelop $true -WorkflowsReferenceDevelop $false -DependabotTargetsDevelop $false -DocsReferenceDevelop $false
Assert-Equal -Name 'develop fully merged but an open PR targets it -> REVIEW_REQUIRED' -Expected 'REVIEW_REQUIRED' -Actual $reviewDevelopPR.Classification

$reviewDevelopDependabot = Get-DevelopDeletionClassification -HasCommitsNotInMain $false -HasOpenPRsTargetingDevelop $false -WorkflowsReferenceDevelop $false -DependabotTargetsDevelop $true -DocsReferenceDevelop $false
Assert-Equal -Name 'develop fully merged but Dependabot targets it -> REVIEW_REQUIRED' -Expected 'REVIEW_REQUIRED' -Actual $reviewDevelopDependabot.Classification

$safeDevelop = Get-DevelopDeletionClassification -HasCommitsNotInMain $false -HasOpenPRsTargetingDevelop $false -WorkflowsReferenceDevelop $false -DependabotTargetsDevelop $false -DocsReferenceDevelop $false
Assert-Equal -Name 'develop fully merged and completely unreferenced -> SAFE_CHANGE candidate' -Expected 'SAFE_CHANGE' -Actual $safeDevelop.Classification
Assert-True -Name 'SAFE_CHANGE develop rationale still says explicit approval is required' -Condition ($safeDevelop.Rationale -match '(?i)explicit')

# ---------------------------------------------------------------------------
Write-Host "8. REMOVE_CANDIDATE (legacy sentinel / NPM_TOKEN)" -ForegroundColor Cyan

$sentinelSecret = Get-SecretClassification -SecretName 'RELEASE_APP_PRIVATE_KEY' -ReferencedByWorkflows @('release.yml') -ReleaseWorkflowUsesSentinelPattern $true
Assert-Equal -Name 'RELEASE_APP_PRIVATE_KEY used by a sentinel-shaped release workflow -> REMOVE_CANDIDATE' -Expected 'REMOVE_CANDIDATE' -Actual $sentinelSecret.Classification
Assert-True -Name 'REMOVE_CANDIDATE rationale frames this as a proven legacy mechanism, not a defect' -Condition ($sentinelSecret.Rationale -match '(?i)not a defect|proven|legacy')
Assert-True -Name 'REMOVE_CANDIDATE rationale never instructs immediate deletion' -Condition ($sentinelSecret.Rationale -notmatch '(?i)delete (it )?now|delete immediately')

$npmTokenSecret = Get-SecretClassification -SecretName 'NPM_TOKEN' -ReferencedByWorkflows @('release.yml') -ReleaseWorkflowUsesSentinelPattern $false
Assert-Equal -Name 'NPM_TOKEN referenced by release workflow -> REMOVE_CANDIDATE' -Expected 'REMOVE_CANDIDATE' -Actual $npmTokenSecret.Classification

$unknownSecret = Get-SecretClassification -SecretName 'SOME_OTHER_SECRET' -ReferencedByWorkflows @('ci.yml') -ReleaseWorkflowUsesSentinelPattern $false
Assert-Equal -Name 'unrecognized secret with a real reference -> REVIEW_REQUIRED (never guessed)' -Expected 'REVIEW_REQUIRED' -Actual $unknownSecret.Classification

$unreferencedSecret = Get-SecretClassification -SecretName 'MYSTERY_SECRET' -ReferencedByWorkflows @() -ReleaseWorkflowUsesSentinelPattern $false
Assert-Equal -Name 'secret with no discovered reference -> REVIEW_REQUIRED (not assumed unused)' -Expected 'REVIEW_REQUIRED' -Actual $unreferencedSecret.Classification

# --- secret metadata never carries a value ---
foreach ($row in @($sentinelSecret, $npmTokenSecret, $unknownSecret, $unreferencedSecret)) {
    Assert-True -Name "$($row.Capability): Current field contains no 'value'/'secret=' pattern" -Condition ($row.Current -notmatch '(?i)value\s*[:=]')
}
$secretFnParams = (Get-Command Get-SecretClassification).Parameters.Keys
Assert-True -Name 'Get-SecretClassification has no parameter that could carry a secret value' -Condition ($secretFnParams -notcontains 'Value' -and $secretFnParams -notcontains 'SecretValue')

# ---------------------------------------------------------------------------
Write-Host "9. UNKNOWN on unreadable API state" -ForegroundColor Cyan
$unknownRow = New-CapabilityRow -Capability 'x' -Current 'unknown' -Target 'y' -Classification UNKNOWN -Rationale 'test'
Assert-Equal -Name 'explicit UNKNOWN row is representable' -Expected 'UNKNOWN' -Actual $unknownRow.Classification

# ---------------------------------------------------------------------------
Write-Host "10. Multiple-rulesets handling (never picks one arbitrarily)" -ForegroundColor Cyan
$twoNamedRulesets = [PSCustomObject]@{
    Available = $true
    ErrorKind = $null
    Rulesets  = @(
        [PSCustomObject]@{ id = 1; name = 'Protect main'; target = 'branch'; enforcement = 'active'; bypass_actors = @(); rules = @() }
        [PSCustomObject]@{ id = 2; name = 'Protect main'; target = 'branch'; enforcement = 'active'; bypass_actors = @(); rules = @() }
    )
}
$targetRulesetFixture = [PSCustomObject]@{
    name             = 'Protect main'
    target           = 'branch'
    enforcement      = 'active'
    bypassActors     = @()
    pullRequest      = [PSCustomObject]@{ requiredApprovingReviewCount = 0; requireCodeOwnerReview = $false; requiredReviewThreadResolution = $true; allowedMergeMethods = @('squash') }
    requiredStatusChecks = [PSCustomObject]@{ context = 'ci-required'; strict = $true }
}
$multiRows = @(New-RulesetCapabilityRows -RulesetsState $twoNamedRulesets -TargetRuleset $targetRulesetFixture)
Assert-Equal -Name 'two rulesets both named Protect main -> exactly one BLOCKED row, no guessing' -Expected 1 -Actual $multiRows.Count
Assert-Equal -Name 'multiple-ruleset row classification' -Expected 'BLOCKED' -Actual $multiRows[0].Classification

# Regression for a real inconsistency found live during the same
# PRODUCTION migration (2026-08-23), right after Get-RulesetOperationMutationSpec
# gained a 'ruleset.requiredStatusChecks' mutation: this row was still
# marked -RequiresManualChange from before that mutation existed, which
# meant Invoke-ApprovedPlan short-circuited it to MANUAL_CHANGE_REQUIRED
# before ever reaching the new, working mutation code.
$matrixLegRuleset = [PSCustomObject]@{
    Available = $true; ErrorKind = $null
    Rulesets  = @([PSCustomObject]@{ id = 1; name = 'Protect main'; target = 'branch'; enforcement = 'active'; bypass_actors = @(); rules = @(@{ type = 'required_status_checks'; parameters = @{ strict_required_status_checks_policy = $true; required_status_checks = @(@{ context = 'validate (20)' }, @{ context = 'audit' }) } }) })
}
$matrixLegRows = @(New-RulesetCapabilityRows -RulesetsState $matrixLegRuleset -TargetRuleset $targetRulesetFixture)
$rscRow = @($matrixLegRows | Where-Object { $_.Capability -eq 'Ruleset: required status checks' })[0]
Assert-True -Name 'a matrix-leg-dependent required_status_checks row is NOT marked RequiresManualChange (regression: Apply now supports this mutation directly)' -Condition (-not [bool]$rscRow.RequiresManualChange)
Assert-Equal -Name 'that row is still REVIEW_REQUIRED (a real behavioral change, just not a file edit)' -Expected 'REVIEW_REQUIRED' -Actual $rscRow.Classification

$noRulesets = [PSCustomObject]@{ Available = $true; ErrorKind = $null; Rulesets = @() }
$absentRows = @(New-RulesetCapabilityRows -RulesetsState $noRulesets -TargetRuleset $targetRulesetFixture)
Assert-Equal -Name 'no Protect main ruleset -> REVIEW_REQUIRED (creating a ruleset is a real behavior change)' -Expected 'REVIEW_REQUIRED' -Actual $absentRows[0].Classification

$otherRulesetOnly = [PSCustomObject]@{
    Available = $true
    ErrorKind = $null
    Rulesets  = @([PSCustomObject]@{ id = 9; name = 'Some other rule'; target = 'branch'; enforcement = 'active'; bypass_actors = @(); rules = @() })
}
$otherRows = @(New-RulesetCapabilityRows -RulesetsState $otherRulesetOnly -TargetRuleset $targetRulesetFixture)
$otherRulesetMatches = @($otherRows | Where-Object { $_.Capability -match 'Some other rule' })
Assert-True -Name 'a differently-named ruleset is reported, not silently ignored or judged incorrect' -Condition ($otherRulesetMatches.Count -eq 1)
if ($otherRulesetMatches.Count -eq 1) {
    Assert-Equal -Name 'differently-named ruleset -> REVIEW_REQUIRED, not COMPLIANT/BLOCKED' -Expected 'REVIEW_REQUIRED' -Actual $otherRulesetMatches[0].Classification
}
else {
    $script:FailCount++
    Write-Host "  FAIL: differently-named ruleset -> REVIEW_REQUIRED, not COMPLIANT/BLOCKED (skipped, row not found)" -ForegroundColor Red
}

# ---------------------------------------------------------------------------
Write-Host "11. Report generation (Markdown + JSON)" -ForegroundColor Cyan

$fixtureAssessment = [PSCustomObject]@{
    Repository        = 'Continuous-DrivenArchitecture/fixture-repo'
    ProfileName       = 'cda-npm-library-v1'
    ProfileSourcePath = 'C:\fixture\npm-library.json'
    AssessmentDate    = '2026-01-01 00:00:00'
    StateFingerprint  = [PSCustomObject]@{
        CapturedAt        = '2026-01-01 00:00:00'
        DefaultBranch     = 'main'
        DefaultBranchSha  = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        MainSha           = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        DevelopSha        = $null
        Rulesets          = @()
        WorkflowShas      = @([PSCustomObject]@{ File = 'ci.yml'; Sha = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' })
        ReleaseConfigFile = 'release.config.js'
        ReleaseConfigSha  = 'cccccccccccccccccccccccccccccccccccccccc'
        PackageJsonSha    = 'dddddddddddddddddddddddddddddddddddddddd'
    }
    Overview          = [PSCustomObject]@{ DefaultBranch = 'main'; AllowSquashMerge = $true; AllowMergeCommit = $false; AllowRebaseMerge = $false }
    BranchAnalysis    = [PSCustomObject]@{
        PermanentBranchNames = @('main')
        EffectiveDevelopmentBranch = 'main'
        AllBranchNames = @('main')
        MainDevelopComparison = $null
        OpenPRsTargetingDevelop = @()
        WorkflowsReferencingDevelop = @()
        DependabotTargetsDevelop = $false
        DocsReferencingDevelop = @()
    }
    ReleaseModel      = [PSCustomObject]@{ Model = 'CDA_MODEL_B (fixture)'; ReleaseWorkflowFile = 'release.yml' }
    Workflows         = @([PSCustomObject]@{ File = 'ci.yml' })
    SecretsMeta       = [PSCustomObject]@{ Secrets = @() }
    VariablesMeta     = [PSCustomObject]@{ Variables = @() }
    PackageName       = '@cda/fixture'
    PackageJsonVersion = '1.0.0'
    NpmRegistryVersion = '1.0.0'
    TagsAndReleases   = [PSCustomObject]@{ Tags = @(); Releases = @() }
    CapabilityRows    = @(
        (New-CapabilityRow -Capability 'Default branch' -Current 'main' -Target 'main' -Classification COMPLIANT -Rationale 'match')
        (New-CapabilityRow -Capability 'Secret scanning' -Current $false -Target $true -Classification SAFE_CHANGE -Rationale 'enable it')
    )
    Blockers          = @()
    Plan              = (New-AdoptionPlan -CapabilityRows @((New-CapabilityRow -Capability 'Secret scanning' -Current $false -Target $true -Classification SAFE_CHANGE -Rationale 'enable it')))
    ApprovalBoundary  = (Get-ApprovalBoundary -CapabilityRows @((New-CapabilityRow -Capability 'Secret scanning' -Current $false -Target $true -Classification SAFE_CHANGE -Rationale 'enable it')))
}

$md = ConvertTo-AdoptionMarkdownReport -Assessment $fixtureAssessment
Assert-True -Name 'Markdown report starts with the required H1' -Condition ($md.StartsWith('# CDA Repository Adoption Assessment'))
Assert-True -Name 'Markdown report contains the CDA comparison table' -Condition ($md -match '## CDA comparison')
Assert-True -Name 'Markdown report contains "Mutations performed" / NONE' -Condition ($md -match '(?s)## Mutations performed\s*\r?\n\s*NONE')
Assert-True -Name 'Markdown report includes the fixture repository name' -Condition ($md -match [regex]::Escape('Continuous-DrivenArchitecture/fixture-repo'))

$jsonText = ConvertTo-AdoptionJsonReport -Assessment $fixtureAssessment
$parsedBack = $null
try { $parsedBack = $jsonText | ConvertFrom-Json; Assert-True -Name 'JSON report parses back as valid JSON' -Condition $true }
catch { Assert-True -Name 'JSON report parses back as valid JSON' -Condition $false -Detail $_.Exception.Message }
if ($parsedBack) {
    Assert-Equal -Name 'JSON report: repository field' -Expected 'Continuous-DrivenArchitecture/fixture-repo' -Actual $parsedBack.repository
    Assert-True -Name 'JSON report: capabilities array present' -Condition ($null -ne $parsedBack.capabilities -and @($parsedBack.capabilities).Count -eq 2)
    Assert-True -Name 'JSON report: plan array present' -Condition ($null -ne $parsedBack.plan)
}

# ---------------------------------------------------------------------------
Write-Host "12. Approval: plan hash determinism and tamper detection" -ForegroundColor Cyan

function New-FixtureAssessmentWithPlan {
    <# Builds a minimal but real assess-npm-library.ps1-shaped JSON object
       (round-tripped through ConvertTo-Json/ConvertFrom-Json, same as a
       real assessment file) with one op per classification so approval
       rule tests exercise every branch. #>
    $rows = @(
        (New-CapabilityRow -Capability 'Secret scanning' -Current $false -Target $true -Classification SAFE_CHANGE -Rationale 'enable it')
        (New-CapabilityRow -Capability 'Allow merge commit' -Current $true -Target $false -Classification REVIEW_REQUIRED -Rationale 'in use')
        (New-CapabilityRow -Capability 'Secret: RELEASE_APP_ID' -Current 'used by release.yml' -Target 'not required' -Classification REMOVE_CANDIDATE -Rationale 'legacy sentinel' -Destructive)
        (New-CapabilityRow -Capability 'Branch: delete develop' -Current 'ahead' -Target 'deleted' -Classification BLOCKED -Rationale 'unmerged commits' -Destructive)
    )
    $plan = New-AdoptionPlan -CapabilityRows $rows
    $fixture = [PSCustomObject]@{
        repository       = 'Continuous-DrivenArchitecture/fixture-repo'
        profile          = 'cda-npm-library-v1'
        assessedAt       = '2026-01-01 00:00:00'
        stateFingerprint = [PSCustomObject]@{
            CapturedAt = '2026-01-01 00:00:00'; DefaultBranch = 'main'; DefaultBranchSha = 'a' * 40; MainSha = 'a' * 40; DevelopSha = 'b' * 40
            Rulesets = @(); WorkflowShas = @(); ReleaseConfigFile = $null; ReleaseConfigSha = $null; PackageJsonSha = 'c' * 40
        }
        capabilities     = @($rows | ForEach-Object { [PSCustomObject]@{ id = $_.Id; name = $_.Capability; current = "$($_.Current)"; target = "$($_.Target)"; classification = $_.Classification; rationale = $_.Rationale; requiresManualChange = [bool]$_.RequiresManualChange; destructive = [bool]$_.Destructive } })
        plan             = @()
    }
    foreach ($phaseKey in $plan.Keys) {
        $phaseItems = @(@($plan[$phaseKey].Items) | ForEach-Object {
                [PSCustomObject]@{ id = $_.Id; capability = $_.Capability; current = "$($_.Current)"; target = "$($_.Target)"; classification = $_.Classification; rationale = $_.Rationale; requiresManualChange = [bool]$_.RequiresManualChange; destructive = [bool]$_.Destructive }
            })
        $fixture.plan += [PSCustomObject]@{ phase = [int]$phaseKey; name = $plan[$phaseKey].Name; items = $phaseItems }
    }
    return ($fixture | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
}

$fixtureA = New-FixtureAssessmentWithPlan
$opsA1 = ConvertTo-PlanOperations -Assessment $fixtureA
$opsA2 = ConvertTo-PlanOperations -Assessment $fixtureA
$hash1 = Get-PlanHash -Repository $fixtureA.repository -Profile $fixtureA.profile -Operations $opsA1
$hash2 = Get-PlanHash -Repository $fixtureA.repository -Profile $fixtureA.profile -Operations $opsA2
Assert-Equal -Name 'plan hash is stable across independent re-derivations of the same operations' -Expected $hash1 -Actual $hash2
Assert-True -Name 'plan hash is a 64-char lowercase hex SHA-256' -Condition ($hash1 -cmatch '^[0-9a-f]{64}$')

$approvedPlanA = New-ApprovedPlan -Assessment $fixtureA -Operations $opsA1 -ApprovedBy 'test-user'
$hashCheckOk = Test-ApprovedPlanHash -ApprovedPlan $approvedPlanA
Assert-True -Name 'freshly built approved plan hash is valid' -Condition $hashCheckOk.Valid

$tamperedPlan = $approvedPlanA | ConvertTo-Json -Depth 12 | ConvertFrom-Json
$tamperedPlan.operations[0].desired = 'TAMPERED'
$hashCheckTampered = Test-ApprovedPlanHash -ApprovedPlan $tamperedPlan
Assert-True -Name 'a modified plan (operation desired value changed) invalidates the stored hash' -Condition (-not $hashCheckTampered.Valid)

$tamperedPlan2 = $approvedPlanA | ConvertTo-Json -Depth 12 | ConvertFrom-Json
$tamperedPlan2.operations[0].classification = 'COMPLIANT'
$hashCheckTampered2 = Test-ApprovedPlanHash -ApprovedPlan $tamperedPlan2
Assert-True -Name 'a modified plan (operation classification changed) invalidates the stored hash' -Condition (-not $hashCheckTampered2.Valid)

$roundTripped = $approvedPlanA | ConvertTo-Json -Depth 12 | ConvertFrom-Json
$hashCheckRT = Test-ApprovedPlanHash -ApprovedPlan $roundTripped
Assert-True -Name 'an UNMODIFIED plan stays valid across a JSON round-trip (no accidental property-order dependency)' -Condition $hashCheckRT.Valid

$approvedPlanRequiredFields = @('repository', 'profile', 'assessmentGeneratedAt', 'assessmentCommitOrHead', 'planHash', 'approvedAt', 'approvedBy', 'operations')
$missingFields = @($approvedPlanRequiredFields | Where-Object { $approvedPlanA.PSObject.Properties.Name -notcontains $_ })
Assert-True -Name 'approved-plan schema includes every field required by the brief' -Condition ($missingFields.Count -eq 0) -Detail "(missing: $($missingFields -join ', '))"

# ---------------------------------------------------------------------------
Write-Host "13. Approval rules per classification" -ForegroundColor Cyan

Assert-True -Name 'BLOCKED is never approvable (Test-OperationApprovable)' -Condition (-not (Test-OperationApprovable -Operation ([PSCustomObject]@{ classification = 'BLOCKED' })).Approvable)
Assert-True -Name 'UNKNOWN is never approvable (Test-OperationApprovable)' -Condition (-not (Test-OperationApprovable -Operation ([PSCustomObject]@{ classification = 'UNKNOWN' })).Approvable)
Assert-True -Name 'NOT_AVAILABLE is never approvable (defense in depth -- it never even reaches an operations array)' -Condition (-not (Test-OperationApprovable -Operation ([PSCustomObject]@{ classification = 'NOT_AVAILABLE' })).Approvable)
Assert-True -Name 'KEEP_STRONGER is never approvable (defense in depth -- never generates a downgrade)' -Condition (-not (Test-OperationApprovable -Operation ([PSCustomObject]@{ classification = 'KEEP_STRONGER' })).Approvable)
Assert-True -Name 'SAFE_CHANGE is approvable' -Condition ((Test-OperationApprovable -Operation ([PSCustomObject]@{ classification = 'SAFE_CHANGE' })).Approvable)
Assert-True -Name 'REVIEW_REQUIRED is approvable (via explicit id only)' -Condition ((Test-OperationApprovable -Operation ([PSCustomObject]@{ classification = 'REVIEW_REQUIRED' })).Approvable)
Assert-True -Name 'REMOVE_CANDIDATE is approvable (via explicit id only)' -Condition ((Test-OperationApprovable -Operation ([PSCustomObject]@{ classification = 'REMOVE_CANDIDATE' })).Approvable)

Assert-True -Name 'NOT_AVAILABLE / KEEP_STRONGER / COMPLIANT never appear in ConvertTo-PlanOperations output (AdoptionPlan already excludes them)' -Condition (@($opsA1 | Where-Object { "$($_.classification)" -in @('NOT_AVAILABLE', 'KEEP_STRONGER', 'COMPLIANT') }).Count -eq 0)

$opsB = ConvertTo-PlanOperations -Assessment (New-FixtureAssessmentWithPlan)
$safeSweep = Approve-PlanOperations -Operations $opsB -ApproveSafeChanges
Assert-True -Name '-ApproveSafeChanges approves every SAFE_CHANGE operation' -Condition (@($safeSweep.ApprovedIds | Where-Object { $_ -eq 'security.secretScanning' }).Count -eq 1)
Assert-True -Name '-ApproveSafeChanges does NOT approve REVIEW_REQUIRED' -Condition (@($opsB | Where-Object { $_.id -eq 'repo.allowMergeCommit' })[0].approved -eq $false)
Assert-True -Name '-ApproveSafeChanges does NOT approve REMOVE_CANDIDATE (never swept in with safe changes)' -Condition (@($opsB | Where-Object { $_.id -eq 'secret.RELEASE_APP_ID' })[0].approved -eq $false)
Assert-True -Name '-ApproveSafeChanges alone: BLOCKED rejected list is empty (nothing attempted it)' -Condition ($safeSweep.Rejected.Count -eq 0)

# SECURITY REGRESSION (found during live sandbox integration testing,
# 2026-08-23): a real repository's develop-deletion legitimately reached
# SAFE_CHANGE classification once every precondition was clean, and
# -ApproveSafeChanges swept it in with no explicit id -- silently
# approving a destructive, irreversible operation. Fixed in
# Approve-PlanOperations to require -ApproveOperation for ANY destructive
# operation regardless of classification.
$destructiveSafeChangeOps = @(
    [PSCustomObject]@{ id = 'branch.delete.develop'; capability = 'Branch: delete develop'; classification = 'SAFE_CHANGE'; current = 'exists, unreferenced'; desired = 'deleted'; rationale = 'fully merged, no references'; requiresManualChange = $false; destructive = $true; dependencies = @(); action = 'DESTRUCTIVE OPERATION: DELETE the develop branch ref.'; approved = $false }
    [PSCustomObject]@{ id = 'security.secretScanning'; capability = 'Secret scanning'; classification = 'SAFE_CHANGE'; current = 'False'; desired = 'True'; rationale = 'enable it'; requiresManualChange = $false; destructive = $false; dependencies = @(); action = 'x'; approved = $false }
)
$null = Approve-PlanOperations -Operations $destructiveSafeChangeOps -ApproveSafeChanges
Assert-True -Name 'SECURITY: -ApproveSafeChanges never approves a destructive operation, even when its classification is SAFE_CHANGE' -Condition (@($destructiveSafeChangeOps | Where-Object { $_.id -eq 'branch.delete.develop' })[0].approved -eq $false)
Assert-True -Name '-ApproveSafeChanges still approves a NON-destructive SAFE_CHANGE in the same sweep' -Condition (@($destructiveSafeChangeOps | Where-Object { $_.id -eq 'security.secretScanning' })[0].approved -eq $true)
$null = Approve-PlanOperations -Operations $destructiveSafeChangeOps -ApproveOperationIds @('branch.delete.develop')
Assert-True -Name 'a destructive SAFE_CHANGE CAN be approved via explicit -ApproveOperation (individual, deliberate approval still works)' -Condition (@($destructiveSafeChangeOps | Where-Object { $_.id -eq 'branch.delete.develop' })[0].approved -eq $true)

$opsC = ConvertTo-PlanOperations -Assessment (New-FixtureAssessmentWithPlan)
$explicitReview = Approve-PlanOperations -Operations $opsC -ApproveOperationIds @('repo.allowMergeCommit')
Assert-True -Name 'REVIEW_REQUIRED can be approved via explicit -ApproveOperation id' -Condition (@($opsC | Where-Object { $_.id -eq 'repo.allowMergeCommit' })[0].approved -eq $true)
Assert-True -Name 'explicit REVIEW_REQUIRED approval does not also approve unrelated SAFE_CHANGE ops' -Condition (@($opsC | Where-Object { $_.id -eq 'security.secretScanning' })[0].approved -eq $false)

$opsD = ConvertTo-PlanOperations -Assessment (New-FixtureAssessmentWithPlan)
$explicitRemove = Approve-PlanOperations -Operations $opsD -ApproveOperationIds @('secret.RELEASE_APP_ID')
Assert-True -Name 'REMOVE_CANDIDATE can be approved via explicit -ApproveOperation id' -Condition (@($opsD | Where-Object { $_.id -eq 'secret.RELEASE_APP_ID' })[0].approved -eq $true)

$opsE = ConvertTo-PlanOperations -Assessment (New-FixtureAssessmentWithPlan)
$blockedAttempt = Approve-PlanOperations -Operations $opsE -ApproveOperationIds @('branch.delete.develop')
Assert-True -Name 'explicit -ApproveOperation on a BLOCKED id is rejected, not approved' -Condition (@($opsE | Where-Object { $_.id -eq 'branch.delete.develop' })[0].approved -eq $false)
Assert-True -Name 'BLOCKED rejection is reported with a reason' -Condition ($blockedAttempt.Rejected.Count -eq 1 -and $blockedAttempt.Rejected[0].Reason -match 'BLOCKED')

# ---------------------------------------------------------------------------
Write-Host "14. Destructive marking and secret-value hygiene" -ForegroundColor Cyan

$opsF = ConvertTo-PlanOperations -Assessment (New-FixtureAssessmentWithPlan)
$secretOp = @($opsF | Where-Object { $_.id -eq 'secret.RELEASE_APP_ID' })[0]
$branchOp = @($opsF | Where-Object { $_.id -eq 'branch.delete.develop' })[0]
$safeOp = @($opsF | Where-Object { $_.id -eq 'security.secretScanning' })[0]
Assert-True -Name 'secret deletion operation is marked destructive=true' -Condition ($secretOp.destructive -eq $true)
Assert-True -Name 'secret deletion operation''s action text says DESTRUCTIVE OPERATION' -Condition ($secretOp.action -match 'DESTRUCTIVE OPERATION')
Assert-True -Name 'branch deletion operation is marked destructive=true' -Condition ($branchOp.destructive -eq $true)
Assert-True -Name 'branch deletion operation''s action text says DESTRUCTIVE OPERATION' -Condition ($branchOp.action -match 'DESTRUCTIVE OPERATION')
Assert-True -Name 'a non-destructive SAFE_CHANGE operation is NOT marked destructive' -Condition ($safeOp.destructive -eq $false)

foreach ($op in $opsF) {
    Assert-True -Name "operation $($op.id): action text contains no 'value='/'secret=' pattern" -Condition ($op.action -notmatch '(?i)(value|secret)\s*=\s*\S')
    Assert-True -Name "operation $($op.id): current/desired fields contain no 'value='/'secret=' pattern" -Condition ("$($op.current) $($op.desired)" -notmatch '(?i)(value|secret)\s*=\s*\S')
}

# ---------------------------------------------------------------------------
Write-Host "15. Apply pre-flight: state-fingerprint drift and stale-ruleset detection (mocked GitHub API)" -ForegroundColor Cyan

# Mocking strategy (verified empirically before writing these tests):
# overriding a function AFTER Import-Module shadows it for calls made
# from a DIFFERENT module (e.g. Apply.psm1 calling Invoke-ReadOnlyGitHub,
# or Apply.psm1 calling Discovery.psm1-exported Get-BranchComparison /
# Get-OpenPullRequestsByBase / Get-WorkflowsInventory /
# Get-DependabotConfigText). It does NOT shadow a call made from WITHIN
# the function's own defining module (e.g. Get-ReadOnlyGitHubPaged calling
# Invoke-ReadOnlyGitHub from inside ReadOnlyGitHub.psm1 itself) -- confirmed
# by direct experiment, not assumed. Every mock below targets a function
# actually called cross-module from Apply.psm1 / Verification.psm1.
$script:MockRoutes = @{}
function ConvertTo-NormalizedMockResult {
    <# Route lambdas below only bother setting the fields each test cares
       about (usually just Success/Data). Fill in the rest of the real
       Invoke-ReadOnlyGitHub result shape so strict-mode property access on
       StatusCode/ErrorKind/RawBody never throws regardless of which
       fields a given route lambda set. #>
    param($Result)
    $props = @{ StatusCode = 200; Success = $true; Data = $null; ErrorKind = $null; RawBody = '' }
    # .ToArray() the key list before iterating -- do not enumerate
    # $props.Keys while also writing into $props inside the same loop
    # (Hashtable throws InvalidOperationException on that, confirmed
    # empirically, not assumed).
    foreach ($name in @($props.Keys)) {
        if ($Result.PSObject.Properties[$name]) { $props[$name] = $Result.$name }
    }
    return [PSCustomObject]$props
}
function Invoke-ReadOnlyGitHub {
    param([Parameter(Mandatory)] [string]$Path)
    foreach ($key in $script:MockRoutes.Keys) {
        if ($Path -eq $key -or $Path -match $key) { return ConvertTo-NormalizedMockResult (& $script:MockRoutes[$key]) }
    }
    return [PSCustomObject]@{ StatusCode = 404; Success = $false; Data = $null; ErrorKind = 'NotFound'; RawBody = '' }
}
function Test-GhAuthenticated { return $true }
function Get-BranchComparison { param($Owner, $Repo, $Base, $Head) return [PSCustomObject]@{ Available = $true; AheadBy = 0; BehindBy = 0; Status = 'identical' } }
function Get-OpenPullRequestsByBase { param($Owner, $Repo) return @() }
function Get-WorkflowsInventory { param($Owner, $Repo) return @() }
function Get-DependabotConfigText { param($Owner, $Repo) return $null }
function Get-FileSha { param($Owner, $Repo, $Path, $Ref) return $script:MockFileShas[$Path] }
$script:MutationCallLog = New-Object System.Collections.Generic.List[object]
function Invoke-MutationGitHub {
    param([Parameter(Mandatory)] [string]$Path, [Parameter(Mandatory)] [string]$Method, [object]$BodyObject)
    $script:MutationCallLog.Add([PSCustomObject]@{ Path = $Path; Method = $Method }) | Out-Null
    if ($script:MockMutationShouldFail) { return [PSCustomObject]@{ StatusCode = 422; Success = $false; Data = $null; ErrorKind = 'Unprocessable'; RawBody = '' } }
    return [PSCustomObject]@{ StatusCode = 200; Success = $true; Data = $null; ErrorKind = $null; RawBody = '' }
}

function New-MockApprovedPlan {
    <# A hand-built approved plan (not derived from a real gh call) with
       one approved SAFE_CHANGE operation and a known-good state
       fingerprint, matched by the mock routes configured below. #>
    param([string]$DefaultBranchSha = ('a' * 40), [string]$RulesetUpdatedAt = '2026-01-01T00:00:00Z')
    $ops = @(
        [PSCustomObject]@{ id = 'repo.deleteBranchOnMerge'; phase = 1; phaseName = 'PHASE 1 - Repository hygiene and safe settings'; capability = 'Delete branch on merge'; classification = 'SAFE_CHANGE'; current = 'False'; desired = 'True'; rationale = 'x'; requiresManualChange = $false; destructive = $false; dependencies = @(); action = 'x'; approved = $true }
    )
    return [PSCustomObject]@{
        schemaVersion           = '1.0'
        repository             = 'Continuous-DrivenArchitecture/mock-repo'
        profile                = 'cda-npm-library-v1'
        assessmentGeneratedAt  = '2026-01-01 00:00:00'
        assessmentCommitOrHead = $DefaultBranchSha
        stateFingerprint        = [PSCustomObject]@{
            CapturedAt = '2026-01-01 00:00:00'; DefaultBranch = 'main'; DefaultBranchSha = $DefaultBranchSha; MainSha = $DefaultBranchSha; DevelopSha = $null
            Rulesets = @([PSCustomObject]@{ Id = '999'; Name = 'Protect main'; UpdatedAt = $RulesetUpdatedAt }); WorkflowShas = @(); ReleaseConfigFile = $null; ReleaseConfigSha = $null; PackageJsonSha = $null
        }
        planHash               = (Get-PlanHash -Repository 'Continuous-DrivenArchitecture/mock-repo' -Profile 'cda-npm-library-v1' -Operations $ops)
        approvedAt              = '2026-01-01 01:00:00'
        approvedBy              = 'test-user'
        operations              = $ops
    }
}

$script:MockFileShas = @{}
$script:MockRoutes = @{
    '^repos/Continuous-DrivenArchitecture/mock-repo$'          = { [PSCustomObject]@{ Success = $true; Data = [PSCustomObject]@{ default_branch = 'main'; archived = $false; fork = $false; permissions = [PSCustomObject]@{ admin = $true } } } }.GetNewClosure()
    '^repos/Continuous-DrivenArchitecture/mock-repo/branches\?' = { [PSCustomObject]@{ Success = $true; Data = @([PSCustomObject]@{ name = 'main'; commit = [PSCustomObject]@{ sha = ('a' * 40) } }) } }.GetNewClosure()
}
$goodPlan = New-MockApprovedPlan
$pf1 = Invoke-Preflight -ApprovedPlan $goodPlan -Repository 'Continuous-DrivenArchitecture/mock-repo'
Assert-True -Name 'pre-flight passes when live state matches the assessment-time state fingerprint exactly' -Condition $pf1.Passed -Detail (($pf1.Checks | Where-Object { -not $_.Passed } | ForEach-Object { $_.Name }) -join '; ')

$staleShaPlan = New-MockApprovedPlan -DefaultBranchSha ('a' * 40)
$script:MockRoutes['^repos/Continuous-DrivenArchitecture/mock-repo/branches\?'] = { [PSCustomObject]@{ Success = $true; Data = @([PSCustomObject]@{ name = 'main'; commit = [PSCustomObject]@{ sha = ('f' * 40) } }) } }.GetNewClosure()
$pf2 = Invoke-Preflight -ApprovedPlan $staleShaPlan -Repository 'Continuous-DrivenArchitecture/mock-repo'
Assert-True -Name 'a stale default-branch HEAD SHA (repo advanced since assessment) stops pre-flight' -Condition (-not $pf2.Passed)
Assert-True -Name 'stale-HEAD failure is reported as a named, specific check' -Condition (@($pf2.Checks | Where-Object { $_.Name -match 'default branch HEAD SHA' -and -not $_.Passed }).Count -eq 1)

$script:MockRoutes['^repos/Continuous-DrivenArchitecture/mock-repo/branches\?'] = { [PSCustomObject]@{ Success = $true; Data = @([PSCustomObject]@{ name = 'main'; commit = [PSCustomObject]@{ sha = ('a' * 40) } }) } }.GetNewClosure()

$rulesetPlan = New-MockApprovedPlan -RulesetUpdatedAt '2026-01-01T00:00:00Z'
$rulesetPlan.operations = @($rulesetPlan.operations + [PSCustomObject]@{ id = 'ruleset.bypassActors'; phase = 4; capability = 'Ruleset: bypass actors'; classification = 'REVIEW_REQUIRED'; current = 'x'; desired = 'none'; rationale = 'y'; requiresManualChange = $false; destructive = $true; dependencies = @(); action = 'z'; approved = $true })
$rulesetPlan.planHash = Get-PlanHash -Repository $rulesetPlan.repository -Profile $rulesetPlan.profile -Operations $rulesetPlan.operations
$script:MockRoutes['^repos/Continuous-DrivenArchitecture/mock-repo/rulesets/999$'] = { [PSCustomObject]@{ Success = $true; Data = [PSCustomObject]@{ id = 999; updated_at = '2026-06-01T00:00:00Z'; bypass_actors = @(); rules = @() } } }.GetNewClosure()
$pf3 = Invoke-Preflight -ApprovedPlan $rulesetPlan -Repository 'Continuous-DrivenArchitecture/mock-repo'
Assert-True -Name 'a stale ruleset id/updated_at (ruleset edited since assessment) stops pre-flight' -Condition (-not $pf3.Passed)
Assert-True -Name 'stale-ruleset failure names the ruleset check specifically' -Condition (@($pf3.Checks | Where-Object { $_.Name -match "ruleset 'Protect main'" -and -not $_.Passed }).Count -eq 1)

$script:MockRoutes['^repos/Continuous-DrivenArchitecture/mock-repo/rulesets/999$'] = { [PSCustomObject]@{ Success = $true; Data = [PSCustomObject]@{ id = 999; updated_at = '2026-01-01T00:00:00Z'; bypass_actors = @(); rules = @() } } }.GetNewClosure()
$pf4 = Invoke-Preflight -ApprovedPlan $rulesetPlan -Repository 'Continuous-DrivenArchitecture/mock-repo'
$pf4FailedChecks = @($pf4.Checks | Where-Object { -not $_.Passed } | ForEach-Object { $_.Name })
$pf4FailedOps = @($pf4.OperationChecks | Where-Object { -not $_.Satisfied } | ForEach-Object { $_.Id })
Assert-True -Name 'an unchanged ruleset (matching id + updated_at) passes pre-flight' -Condition $pf4.Passed -Detail (($pf4FailedChecks + $pf4FailedOps) -join '; ')

$badApprovalPlan = New-MockApprovedPlan
$badApprovalPlan.operations += [PSCustomObject]@{ id = 'branch.delete.develop'; phase = 0; capability = 'Branch: delete develop'; classification = 'BLOCKED'; current = 'x'; desired = 'y'; rationale = 'z'; requiresManualChange = $false; destructive = $true; dependencies = @(); action = 'a'; approved = $true }
$pfBad = Invoke-Preflight -ApprovedPlan $badApprovalPlan -Repository 'Continuous-DrivenArchitecture/mock-repo'
Assert-True -Name 'pre-flight independently re-detects a BLOCKED operation marked approved=true (defense in depth beyond the hash)' -Condition (-not $pfBad.Passed)
Assert-True -Name 'the BLOCKED-approved failure is reported by its own named check' -Condition (@($pfBad.Checks | Where-Object { $_.Name -match 'No BLOCKED or UNKNOWN' -and -not $_.Passed }).Count -eq 1)

# Regression test for a real bug found during live sandbox integration
# testing (2026-08-23): Invoke-Preflight's own per-operation loop built
# `$priorOps = if ($i -gt 0) {...} else { @() }` as a plain assignment --
# the classic PowerShell gotcha where an empty array returned as a
# branch's pipeline output (as opposed to assigned as a literal)
# collapses to $null on capture. That $null then crossed
# Test-OperationPreconditions' typed [array]$PriorPlanOps parameter
# boundary, got coerced to a real $null, and calling `-PriorPlanOps $null
# | Where-Object { $_.id -eq ... }` inside the function invoked the block
# once with $_ = $null and threw under strict mode -- this broke
# Invoke-Preflight for ANY single-operation plan whose one operation was
# branch.delete.develop (i=0, the very first loop iteration, is exactly
# when the else branch fires). Fixed by wrapping the whole if/else in
# @(...) at the call site AND hardening Test-OperationPreconditions
# itself to coerce its own parameter back to a real array on entry.
$singleOpPlan = New-MockApprovedPlan
$singleOpPlan.operations = @([PSCustomObject]@{ id = 'branch.delete.develop'; phase = 3; capability = 'Branch: delete develop'; classification = 'SAFE_CHANGE'; current = 'x'; desired = 'deleted'; rationale = 'y'; requiresManualChange = $false; destructive = $true; dependencies = @(); action = 'z'; approved = $true })
$singleOpPlan.planHash = Get-PlanHash -Repository $singleOpPlan.repository -Profile $singleOpPlan.profile -Operations $singleOpPlan.operations
$script:MockRoutes = @{
    '^repos/Continuous-DrivenArchitecture/mock-repo$'           = { [PSCustomObject]@{ Success = $true; Data = [PSCustomObject]@{ default_branch = 'main'; archived = $false; fork = $false; permissions = [PSCustomObject]@{ admin = $true } } } }.GetNewClosure()
    '^repos/Continuous-DrivenArchitecture/mock-repo/branches\?' = { [PSCustomObject]@{ Success = $true; Data = @([PSCustomObject]@{ name = 'main'; commit = [PSCustomObject]@{ sha = ('a' * 40) } }) } }.GetNewClosure()
    '^repos/Continuous-DrivenArchitecture/mock-repo/branches/develop$' = { [PSCustomObject]@{ Success = $true; Data = [PSCustomObject]@{ name = 'develop' } } }.GetNewClosure()
}
function Get-BranchComparison { param($Owner, $Repo, $Base, $Head) return [PSCustomObject]@{ Available = $true; AheadBy = 0; BehindBy = 0; Status = 'identical' } }
function Get-OpenPullRequestsByBase { param($Owner, $Repo) return @() }
function Get-WorkflowsInventory { param($Owner, $Repo) return @() }
function Get-DependabotConfigText { param($Owner, $Repo) return $null }
$pfSingleOp = $null
$pfSingleOpError = $null
try { $pfSingleOp = Invoke-Preflight -ApprovedPlan $singleOpPlan -Repository 'Continuous-DrivenArchitecture/mock-repo' } catch { $pfSingleOpError = "$_" }
Assert-True -Name 'Invoke-Preflight does not throw on a plan whose ONLY approved operation is the first one checked (i=0, the empty-prior-ops case)' -Condition ($null -eq $pfSingleOpError) -Detail "$pfSingleOpError"
Assert-True -Name 'that single-operation preflight actually passes' -Condition ($null -ne $pfSingleOp -and $pfSingleOp.Passed)

# ---------------------------------------------------------------------------
Write-Host "16. Apply per-operation preconditions (mocked GitHub API)" -ForegroundColor Cyan

$develpOp = [PSCustomObject]@{ id = 'branch.delete.develop'; desired = 'deleted' }
$fp0 = [PSCustomObject]@{ Rulesets = @() }

$script:MockRoutes = @{
    '^repos/Owner/Repo$'              = { [PSCustomObject]@{ Success = $true; Data = [PSCustomObject]@{ default_branch = 'main' } } }.GetNewClosure()
    '^repos/Owner/Repo/branches/develop$' = { [PSCustomObject]@{ Success = $true; Data = [PSCustomObject]@{ name = 'develop' } } }.GetNewClosure()
}
$pc1 = Test-OperationPreconditions -Op $develpOp -Owner 'Owner' -Repo 'Repo' -StateFingerprint $fp0
Assert-True -Name 'develop deletion: satisfied when default is main, fully merged, no PR, no workflow/dependabot reference' -Condition $pc1.Satisfied -Detail ($pc1.Reasons -join '; ')

function Get-BranchComparison { param($Owner, $Repo, $Base, $Head) return [PSCustomObject]@{ Available = $true; AheadBy = 2; BehindBy = 0; Status = 'ahead' } }
$pc2 = Test-OperationPreconditions -Op $develpOp -Owner 'Owner' -Repo 'Repo' -StateFingerprint $fp0
Assert-True -Name 'a branch gaining a new commit (ahead_by > 0 at apply time) blocks its deletion' -Condition (-not $pc2.Satisfied)
Assert-True -Name 'the new-commit block gives a specific reason' -Condition (@($pc2.Reasons -match 'not reachable from main').Count -gt 0)
function Get-BranchComparison { param($Owner, $Repo, $Base, $Head) return [PSCustomObject]@{ Available = $true; AheadBy = 0; BehindBy = 0; Status = 'identical' } }

function Get-OpenPullRequestsByBase { param($Owner, $Repo) return @([PSCustomObject]@{ Number = 42; Title = 'x'; Base = 'develop'; Head = 'feature' }) }
$pc3 = Test-OperationPreconditions -Op $develpOp -Owner 'Owner' -Repo 'Repo' -StateFingerprint $fp0
Assert-True -Name 'a branch gaining an open pull request targeting it blocks its deletion' -Condition (-not $pc3.Satisfied)
Assert-True -Name 'the open-PR block references the PR number' -Condition (@($pc3.Reasons -match '#42').Count -gt 0)
function Get-OpenPullRequestsByBase { param($Owner, $Repo) return @() }

$secretOp2 = [PSCustomObject]@{ id = 'secret.NPM_TOKEN'; desired = 'deleted' }
function Get-WorkflowsInventory { param($Owner, $Repo) return @([PSCustomObject]@{ File = 'release.yml' }) }
function Get-WorkflowFileText { param($Owner, $Repo, $Path) return 'run: npm publish`nenv:`n  NODE_AUTH_TOKEN: ${{ secrets.NPM_TOKEN }}' }
$pc4 = Test-OperationPreconditions -Op $secretOp2 -Owner 'Owner' -Repo 'Repo' -StateFingerprint $fp0
Assert-True -Name 'a secret gaining a new workflow reference blocks its deletion' -Condition (-not $pc4.Satisfied)
Assert-True -Name 'the new-reference block names the referencing workflow file' -Condition (@($pc4.Reasons -match 'release\.yml').Count -gt 0)
function Get-WorkflowsInventory { param($Owner, $Repo) return @() }
function Get-WorkflowFileText { param($Owner, $Repo, $Path) return $null }

$pc5 = Test-OperationPreconditions -Op $secretOp2 -Owner 'Owner' -Repo 'Repo' -StateFingerprint $fp0
Assert-True -Name 'a secret with zero live workflow references satisfies its deletion precondition' -Condition $pc5.Satisfied -Detail ($pc5.Reasons -join '; ')

$defBranchOp = [PSCustomObject]@{ id = 'repo.defaultBranch'; desired = 'main' }
$script:MockRoutes['^repos/Owner/Repo/branches/main$'] = { [PSCustomObject]@{ Success = $false; Data = $null; ErrorKind = 'NotFound' } }.GetNewClosure()
$pc6 = Test-OperationPreconditions -Op $defBranchOp -Owner 'Owner' -Repo 'Repo' -StateFingerprint $fp0
Assert-True -Name 'changing the default branch to a target that does not exist is blocked' -Condition (-not $pc6.Satisfied)
$script:MockRoutes['^repos/Owner/Repo/branches/main$'] = { [PSCustomObject]@{ Success = $true; Data = [PSCustomObject]@{ name = 'main' } } }.GetNewClosure()
$pc7 = Test-OperationPreconditions -Op $defBranchOp -Owner 'Owner' -Repo 'Repo' -StateFingerprint $fp0
Assert-True -Name 'changing the default branch to a target that exists satisfies its precondition' -Condition $pc7.Satisfied -Detail ($pc7.Reasons -join '; ')

$develpOpB = [PSCustomObject]@{ id = 'branch.delete.develop'; desired = 'deleted' }
$priorDefaultBranchOp = [PSCustomObject]@{ id = 'repo.defaultBranch'; desired = 'main' }
$script:MockRoutes['^repos/Owner/Repo$'] = { [PSCustomObject]@{ Success = $true; Data = [PSCustomObject]@{ default_branch = 'develop' } } }.GetNewClosure()
$pc8 = Test-OperationPreconditions -Op $develpOpB -Owner 'Owner' -Repo 'Repo' -StateFingerprint $fp0 -PriorPlanOps @($priorDefaultBranchOp)
Assert-True -Name 'develop deletion is satisfiable when an earlier approved repo.defaultBranch->main operation precedes it in the SAME plan, even though live default branch has not changed yet' -Condition $pc8.Satisfied -Detail ($pc8.Reasons -join '; ')
$pc9 = Test-OperationPreconditions -Op $develpOpB -Owner 'Owner' -Repo 'Repo' -StateFingerprint $fp0
Assert-True -Name 'without that prior operation, the same live state correctly blocks develop deletion' -Condition (-not $pc9.Satisfied)
$script:MockRoutes['^repos/Owner/Repo$'] = { [PSCustomObject]@{ Success = $true; Data = [PSCustomObject]@{ default_branch = 'main' } } }.GetNewClosure()

# Regression test for a real bug found during live sandbox integration
# testing (2026-08-23): Test-OperationPreconditions' ruleset.* branch used
# to call Get-ProtectMainRulesetId unconditionally, so a WHOLE-RULESET
# operation about a differently-named ruleset (e.g. ruleset.protectDevelop)
# was silently checked against "Protect main"'s identity instead of its
# own -- which could mask real drift on the ruleset the operation actually
# concerns. Fixed to resolve the target ruleset by name (derived from
# $Op.capability for whole-ruleset ops; hardcoded to "Protect main" only
# for the fixed sub-field ops that really are about it).
$protectDevelopOp = [PSCustomObject]@{ id = 'ruleset.protectDevelop'; capability = 'Ruleset: Protect develop'; desired = 'n/a' }
$twoRulesetFp = [PSCustomObject]@{
    Rulesets = @(
        [PSCustomObject]@{ Id = '100'; Name = 'Protect develop'; UpdatedAt = '2026-01-01T00:00:00Z' }
        [PSCustomObject]@{ Id = '200'; Name = 'Protect main'; UpdatedAt = '2026-01-01T00:00:00Z' }
    )
}
$script:MockRoutes = @{
    '^repos/Owner/Repo/rulesets/100$' = { [PSCustomObject]@{ Success = $true; Data = [PSCustomObject]@{ id = 100; updated_at = '2026-01-01T00:00:00Z' } } }.GetNewClosure()
    '^repos/Owner/Repo/rulesets/200$' = { [PSCustomObject]@{ Success = $true; Data = [PSCustomObject]@{ id = 200; updated_at = '2026-06-01T00:00:00Z' } } }.GetNewClosure()
}
$pc10 = Test-OperationPreconditions -Op $protectDevelopOp -Owner 'Owner' -Repo 'Repo' -StateFingerprint $twoRulesetFp
Assert-True -Name 'ruleset.protectDevelop checks the Protect develop ruleset''s own identity, not Protect main''s (regression: was previously always Protect main)' -Condition $pc10.Satisfied -Detail ($pc10.Reasons -join '; ')

$script:MockRoutes['^repos/Owner/Repo/rulesets/100$'] = { [PSCustomObject]@{ Success = $true; Data = [PSCustomObject]@{ id = 100; updated_at = '2026-07-01T00:00:00Z' } } }.GetNewClosure()
$pc11 = Test-OperationPreconditions -Op $protectDevelopOp -Owner 'Owner' -Repo 'Repo' -StateFingerprint $twoRulesetFp
Assert-True -Name 'ruleset.protectDevelop correctly detects staleness on ITS OWN ruleset (Protect develop edited), even while an unrelated Protect main is also stale' -Condition (-not $pc11.Satisfied)
Assert-True -Name 'the staleness reason names the correct ruleset (Protect develop, not Protect main)' -Condition (@($pc11.Reasons -match "'Protect develop'").Count -gt 0)

# ---------------------------------------------------------------------------
Write-Host "17. Apply execution: DryRun zero-mutation, stop-on-failure, MANUAL_CHANGE_REQUIRED" -ForegroundColor Cyan

function Get-BranchComparison { param($Owner, $Repo, $Base, $Head) return [PSCustomObject]@{ Available = $true; AheadBy = 0; BehindBy = 0; Status = 'identical' } }
function Get-OpenPullRequestsByBase { param($Owner, $Repo) return @() }
function Get-WorkflowsInventory { param($Owner, $Repo) return @() }
function Get-DependabotConfigText { param($Owner, $Repo) return $null }

$script:MockRoutes = @{
    '^repos/Continuous-DrivenArchitecture/mock-repo$'           = { [PSCustomObject]@{ Success = $true; Data = [PSCustomObject]@{ default_branch = 'main'; delete_branch_on_merge = $false; archived = $false; fork = $false; permissions = [PSCustomObject]@{ admin = $true } } } }.GetNewClosure()
    '^repos/Continuous-DrivenArchitecture/mock-repo/branches\?' = { [PSCustomObject]@{ Success = $true; Data = @([PSCustomObject]@{ name = 'main'; commit = [PSCustomObject]@{ sha = ('a' * 40) } }) } }.GetNewClosure()
}
$script:MutationCallLog.Clear()
$dryPlan = New-MockApprovedPlan
$dryExec = Invoke-ApprovedPlan -ApprovedPlan $dryPlan -Owner 'Continuous-DrivenArchitecture' -Repo 'mock-repo' -DryRun
Assert-True -Name '-DryRun reports WOULD_APPLY for an approved, well-defined, precondition-satisfied operation' -Condition (@($dryExec.Results | Where-Object { $_.Status -eq 'WOULD_APPLY' }).Count -eq 1)
Assert-True -Name '-DryRun never calls Invoke-MutationGitHub (zero mutations, verified by call log, not just by trust)' -Condition ($script:MutationCallLog.Count -eq 0)

$script:MockMutationShouldFail = $false
$script:MutationCallLog.Clear()
$multiOps = @(
    [PSCustomObject]@{ id = 'repo.deleteBranchOnMerge'; capability = 'Delete branch on merge'; classification = 'SAFE_CHANGE'; current = 'False'; desired = 'True'; rationale = 'x'; requiresManualChange = $false; destructive = $false; dependencies = @(); action = 'x'; approved = $true }
    [PSCustomObject]@{ id = 'security.secretScanning'; capability = 'Secret scanning'; classification = 'SAFE_CHANGE'; current = 'False'; desired = 'True'; rationale = 'x'; requiresManualChange = $false; destructive = $false; dependencies = @(); action = 'x'; approved = $true }
)
$multiPlan = New-MockApprovedPlan
$multiPlan.operations = $multiOps
$multiPlan.planHash = Get-PlanHash -Repository $multiPlan.repository -Profile $multiPlan.profile -Operations $multiOps
$script:MockMutationShouldFail = $true
$multiExec = Invoke-ApprovedPlan -ApprovedPlan $multiPlan -Owner 'Continuous-DrivenArchitecture' -Repo 'mock-repo'
Assert-True -Name 'a failed mutation stops the plan (Stopped=true)' -Condition $multiExec.Stopped
Assert-True -Name 'the failing operation is reported FAILED' -Condition (@($multiExec.Results | Where-Object { $_.Status -eq 'FAILED' }).Count -eq 1)
Assert-True -Name 'a failure stops subsequent operations -- they are reported NOT_EXECUTED, never silently skipped or attempted' -Condition (@($multiExec.Results | Where-Object { $_.Status -eq 'NOT_EXECUTED' }).Count -eq 1)
Assert-True -Name 'only ONE mutation call was actually made (the one that failed) -- no blind continuation' -Condition ($script:MutationCallLog.Count -eq 1)
$script:MockMutationShouldFail = $false

$manualOps = @([PSCustomObject]@{ id = 'release.createStableCiRequiredJob'; capability = 'Release: create stable ci-required job'; classification = 'REVIEW_REQUIRED'; current = 'x'; desired = 'y'; rationale = 'z'; requiresManualChange = $true; destructive = $false; dependencies = @(); action = 'MANUAL_REPOSITORY_CHANGE_REQUIRED: ...'; approved = $true })
$manualPlan = New-MockApprovedPlan
$manualPlan.operations = $manualOps
$manualPlan.planHash = Get-PlanHash -Repository $manualPlan.repository -Profile $manualPlan.profile -Operations $manualOps
$script:MutationCallLog.Clear()
$manualExec = Invoke-ApprovedPlan -ApprovedPlan $manualPlan -Owner 'Continuous-DrivenArchitecture' -Repo 'mock-repo'
Assert-True -Name 'a requiresManualChange operation is reported MANUAL_CHANGE_REQUIRED, never attempted' -Condition (@($manualExec.Results | Where-Object { $_.Status -eq 'MANUAL_CHANGE_REQUIRED' }).Count -eq 1)
Assert-True -Name 'Apply makes zero mutation calls for a manual-change-only plan' -Condition ($script:MutationCallLog.Count -eq 0)
Assert-True -Name 'a manual-change operation alone does not stop the plan (Stopped=false)' -Condition (-not $manualExec.Stopped)

# Deliberately an id namespace with no precondition special-case (not
# branch.delete.develop / secret.* / repo.defaultBranch / ruleset.*) so
# this isolates "no mutation mapping" from "precondition failed" -- both
# are covered separately elsewhere in this section.
$undefinedOps = @([PSCustomObject]@{ id = 'dependabot.changeTargetBranchDevelopMain'; capability = 'Dependabot: change target-branch develop -> main'; classification = 'REVIEW_REQUIRED'; current = 'x'; desired = 'main'; rationale = 'z'; requiresManualChange = $false; destructive = $false; dependencies = @(); action = 'y'; approved = $true })
$undefinedPlan = New-MockApprovedPlan
$undefinedPlan.operations = $undefinedOps
$undefinedPlan.planHash = Get-PlanHash -Repository $undefinedPlan.repository -Profile $undefinedPlan.profile -Operations $undefinedOps
$script:MutationCallLog.Clear()
$undefinedExec = Invoke-ApprovedPlan -ApprovedPlan $undefinedPlan -Owner 'Continuous-DrivenArchitecture' -Repo 'mock-repo'
Assert-True -Name 'an operation id with no known mutation mapping is reported NOT_EXECUTED, never guessed at' -Condition (@($undefinedExec.Results | Where-Object { $_.Status -eq 'NOT_EXECUTED' }).Count -eq 1)
Assert-True -Name 'an unmapped operation makes zero mutation calls' -Condition ($script:MutationCallLog.Count -eq 0)

$appliedOps = @([PSCustomObject]@{ id = 'repo.deleteBranchOnMerge'; capability = 'Delete branch on merge'; classification = 'SAFE_CHANGE'; current = 'False'; desired = 'True'; rationale = 'x'; requiresManualChange = $false; destructive = $false; dependencies = @(); action = 'x'; approved = $true })
$appliedPlan = New-MockApprovedPlan
$appliedPlan.operations = $appliedOps
$appliedPlan.planHash = Get-PlanHash -Repository $appliedPlan.repository -Profile $appliedPlan.profile -Operations $appliedOps
$script:MutationCallLog.Clear()
$appliedExec = Invoke-ApprovedPlan -ApprovedPlan $appliedPlan -Owner 'Continuous-DrivenArchitecture' -Repo 'mock-repo'
Assert-True -Name 'a well-defined, precondition-satisfied, approved operation is APPLIED for real (not -DryRun)' -Condition (@($appliedExec.Results | Where-Object { $_.Status -eq 'APPLIED' }).Count -eq 1)
Assert-True -Name 'exactly one mutation call was made for the one applied operation' -Condition ($script:MutationCallLog.Count -eq 1)
Assert-Equal -Name 'the mutation call used PATCH (repo.deleteBranchOnMerge''s real mapping)' -Expected 'PATCH' -Actual $script:MutationCallLog[0].Method

# ---------------------------------------------------------------------------
Write-Host "17b. Ruleset creation (Protect main from scratch)" -ForegroundColor Cyan

$profilePath = Join-Path $root 'profiles\npm-library.json'
$protectMainOp = [PSCustomObject]@{ id = 'ruleset.protectMain'; capability = 'Ruleset: Protect main'; desired = 'active' }
$emptyRulesetFp = [PSCustomObject]@{ Rulesets = @() }

$script:MockRoutes = @{
    '^repos/Owner/Repo$' = { [PSCustomObject]@{ Success = $true; Data = [PSCustomObject]@{ default_branch = 'main' } } }.GetNewClosure()
    '^repos/Owner/Repo/commits/main/check-runs$' = { [PSCustomObject]@{ Success = $true; Data = [PSCustomObject]@{ check_runs = @([PSCustomObject]@{ name = 'ci-required'; conclusion = 'success' }) } } }.GetNewClosure()
}
$createSpec = Get-CreateProtectMainRulesetSpec -Op $protectMainOp -Owner 'Owner' -Repo 'Repo' -StateFingerprint $emptyRulesetFp -ProfilePath $profilePath
Assert-True -Name 'creating Protect main is defined when absent from the fingerprint and ci-required has real evidence' -Condition $createSpec.Defined -Detail "$($createSpec.Description)"
Assert-Equal -Name 'ruleset creation uses POST' -Expected 'POST' -Actual $createSpec.Method
Assert-Equal -Name 'ruleset creation posts to the rulesets collection endpoint' -Expected 'repos/Owner/Repo/rulesets' -Actual $createSpec.Path
if ($createSpec.Defined) {
    Assert-Equal -Name 'created ruleset name matches the CDA profile' -Expected 'Protect main' -Actual $createSpec.Body.name
    Assert-True -Name 'created ruleset has zero bypass actors' -Condition (@($createSpec.Body.bypass_actors).Count -eq 0)
    Assert-True -Name 'created ruleset includes a pull_request rule' -Condition (@($createSpec.Body.rules | Where-Object { $_.type -eq 'pull_request' }).Count -eq 1)
    Assert-True -Name 'created ruleset includes a required_status_checks rule for ci-required' -Condition (@($createSpec.Body.rules | Where-Object { $_.type -eq 'required_status_checks' -and $_.parameters.required_status_checks[0].context -eq 'ci-required' }).Count -eq 1)
    Assert-True -Name 'created ruleset blocks deletion' -Condition (@($createSpec.Body.rules | Where-Object { $_.type -eq 'deletion' }).Count -eq 1)
    Assert-True -Name 'created ruleset blocks non-fast-forward (force push)' -Condition (@($createSpec.Body.rules | Where-Object { $_.type -eq 'non_fast_forward' }).Count -eq 1)
}

Assert-True -Name 'creating Protect main is REFUSED when a ruleset by that name already exists in the fingerprint (create-only, never silently converts to update)' -Condition (-not (Get-CreateProtectMainRulesetSpec -Op $protectMainOp -Owner 'Owner' -Repo 'Repo' -StateFingerprint ([PSCustomObject]@{ Rulesets = @([PSCustomObject]@{ Id = '1'; Name = 'Protect main'; UpdatedAt = 'x' }) }) -ProfilePath $profilePath).Defined)

$script:MockRoutes['^repos/Owner/Repo/commits/main/check-runs$'] = { [PSCustomObject]@{ Success = $true; Data = [PSCustomObject]@{ check_runs = @() } } }.GetNewClosure()
$noEvidenceSpec = Get-CreateProtectMainRulesetSpec -Op $protectMainOp -Owner 'Owner' -Repo 'Repo' -StateFingerprint $emptyRulesetFp -ProfilePath $profilePath
Assert-True -Name 'creating Protect main is REFUSED when ci-required has no real execution evidence yet (never requires a check that has never run)' -Condition (-not $noEvidenceSpec.Defined)

$script:MockRoutes['^repos/Owner/Repo/rulesets$'] = { [PSCustomObject]@{ Success = $true; Data = @([PSCustomObject]@{ id = 1; name = 'Protect main'; enforcement = 'active' }) } }.GetNewClosure()
$rbCreate = Test-OperationApplied -Op $protectMainOp -Owner 'Owner' -Repo 'Repo'
Assert-True -Name 'read-back confirms a newly created, active Protect main ruleset' -Condition ($rbCreate.Matches -eq $true) -Detail "$($rbCreate.Observed)"

# Regression tests for a real gap found during live sandbox integration
# testing (2026-08-23): the "a ruleset not named Protect main exists" row
# was not marked destructive, and Apply had no mutation mapping at all
# for deleting it -- approving it would have silently done nothing.
$legacyRulesetOp = [PSCustomObject]@{ id = 'ruleset.protectDevelop'; capability = 'Ruleset: Protect develop'; desired = 'n/a (not part of the npm-library profile)' }
$twoRulesetFpForDelete = [PSCustomObject]@{
    Rulesets = @(
        [PSCustomObject]@{ Id = '100'; Name = 'Protect develop'; UpdatedAt = '2026-01-01T00:00:00Z' }
        [PSCustomObject]@{ Id = '200'; Name = 'Protect main'; UpdatedAt = '2026-01-01T00:00:00Z' }
    )
}
$deleteSpec = Get-RulesetOperationMutationSpec -Op $legacyRulesetOp -Owner 'Owner' -Repo 'Repo' -StateFingerprint $twoRulesetFpForDelete -ProfilePath $profilePath
Assert-True -Name 'deleting a differently-named legacy ruleset (resolved by its OWN id, not Protect main''s) is a defined mutation' -Condition $deleteSpec.Defined -Detail "$($deleteSpec.Description)"
Assert-Equal -Name 'legacy ruleset deletion uses DELETE' -Expected 'DELETE' -Actual $deleteSpec.Method
Assert-Equal -Name 'legacy ruleset deletion targets ITS OWN id (100), not Protect main''s (200)' -Expected 'repos/Owner/Repo/rulesets/100' -Actual $deleteSpec.Path
Assert-True -Name 'legacy ruleset deletion is marked DESTRUCTIVE in its description' -Condition ($deleteSpec.Description -match 'DESTRUCTIVE')

$unknownRulesetOp = [PSCustomObject]@{ id = 'ruleset.someOtherRuleset'; capability = 'Ruleset: Some other ruleset'; desired = 'n/a' }
$noMatchSpec = Get-RulesetOperationMutationSpec -Op $unknownRulesetOp -Owner 'Owner' -Repo 'Repo' -StateFingerprint $twoRulesetFpForDelete -ProfilePath $profilePath
Assert-True -Name 'deleting a ruleset with no matching name in the fingerprint refuses to guess (NOT_EXECUTED, never falls back to deleting something else)' -Condition (-not $noMatchSpec.Defined)

$legacyRow = New-CapabilityRow -Capability 'Ruleset: Protect develop' -Current 'x' -Target 'n/a' -Classification REVIEW_REQUIRED -Rationale 'y' -Destructive
Assert-True -Name 'Comparison.psm1 marks the "differently-named ruleset" row destructive (regression: was not marked before)' -Condition ([bool]$legacyRow.Destructive)

$rbDelete = Test-OperationApplied -Op $legacyRulesetOp -Owner 'Owner' -Repo 'Repo'
Assert-True -Name 'read-back for a deleted-by-name ruleset (Protect develop now absent) reports Matches=true' -Condition ($rbDelete.Matches -eq $true) -Detail "$($rbDelete.Observed)"

# Added live during the real PRODUCTION migration (2026-08-23): Apply v1
# initially had no mutation mapping for swapping a ruleset's
# required_status_checks list from matrix-leg-dependent checks to the
# CDA profile's stable "ci-required" context -- a real gap discovered
# once every other Protect main sub-field (bypass actors, merge methods,
# strict checks) had already been migrated on a real repository. Guarded
# by the same execution-evidence check as ruleset creation.
$requiredChecksOp = [PSCustomObject]@{ id = 'ruleset.requiredStatusChecks'; capability = 'Ruleset: required status checks'; desired = 'ci-required' }
$protectMainFp = [PSCustomObject]@{ Rulesets = @([PSCustomObject]@{ Id = '999'; Name = 'Protect main'; UpdatedAt = '2026-01-01T00:00:00Z' }) }
$script:MockRoutes = @{
    '^repos/Owner/Repo$' = { [PSCustomObject]@{ Success = $true; Data = [PSCustomObject]@{ default_branch = 'main' } } }.GetNewClosure()
    '^repos/Owner/Repo/commits/main/check-runs$' = { [PSCustomObject]@{ Success = $true; Data = [PSCustomObject]@{ check_runs = @([PSCustomObject]@{ name = 'ci-required'; conclusion = 'success' }) } } }.GetNewClosure()
    '^repos/Owner/Repo/rulesets/999$' = { [PSCustomObject]@{ Success = $true; Data = [PSCustomObject]@{ id = 999; name = 'Protect main'; target = 'branch'; enforcement = 'active'; bypass_actors = @(); conditions = @{}; rules = @(@{ type = 'required_status_checks'; parameters = @{ required_status_checks = @(@{ context = 'validate (20)' }, @{ context = 'audit' }) } }) } } }.GetNewClosure()
}
$rscSpec = Get-RulesetOperationMutationSpec -Op $requiredChecksOp -Owner 'Owner' -Repo 'Repo' -StateFingerprint $protectMainFp -ProfilePath $profilePath
Assert-True -Name 'swapping required_status_checks to ci-required is defined when ci-required has real execution evidence' -Condition $rscSpec.Defined -Detail "$($rscSpec.Description)"
if ($rscSpec.Defined) {
    $rscRuleInBody = @($rscSpec.Body.rules | Where-Object { $_.type -eq 'required_status_checks' })
    Assert-Equal -Name 'the new required_status_checks list contains only ci-required' -Expected 'ci-required' -Actual (@($rscRuleInBody[0].parameters.required_status_checks | ForEach-Object { $_.context }) -join ',')
}

$script:MockRoutes['^repos/Owner/Repo/commits/main/check-runs$'] = { [PSCustomObject]@{ Success = $true; Data = [PSCustomObject]@{ check_runs = @() } } }.GetNewClosure()
$rscSpecNoEvidence = Get-RulesetOperationMutationSpec -Op $requiredChecksOp -Owner 'Owner' -Repo 'Repo' -StateFingerprint $protectMainFp -ProfilePath $profilePath
Assert-True -Name 'swapping required_status_checks to ci-required is REFUSED when ci-required has no execution evidence (never requires a check that has never run)' -Condition (-not $rscSpecNoEvidence.Defined)

$rbRequiredChecks = Test-RulesetOperationApplied -Op $requiredChecksOp -Owner 'Owner' -Repo 'Repo' -RulesetId '999'
Assert-True -Name 'read-back for required_status_checks correctly reports the CURRENT (still matrix-leg) list as a mismatch before the swap applies' -Condition ($rbRequiredChecks.Matches -eq $false) -Detail "$($rbRequiredChecks.Observed)"

$script:MockRoutes['^repos/Owner/Repo/rulesets/999$'] = { [PSCustomObject]@{ Success = $true; Data = [PSCustomObject]@{ id = 999; name = 'Protect main'; rules = @(@{ type = 'required_status_checks'; parameters = @{ required_status_checks = @(@{ context = 'ci-required' }) } }) } } }.GetNewClosure()
$rbRequiredChecksAfter = Test-RulesetOperationApplied -Op $requiredChecksOp -Owner 'Owner' -Repo 'Repo' -RulesetId '999'
Assert-True -Name 'read-back for required_status_checks reports Matches=true once only ci-required is required' -Condition ($rbRequiredChecksAfter.Matches -eq $true) -Detail "$($rbRequiredChecksAfter.Observed)"

# ---------------------------------------------------------------------------
Write-Host "18. Verification: read-back and full-CDA-compliance distinction" -ForegroundColor Cyan

$script:MockRoutes = @{
    '^repos/Owner/Repo$' = { [PSCustomObject]@{ Success = $true; Data = [PSCustomObject]@{ delete_branch_on_merge = $true } } }.GetNewClosure()
}
$rbOp = [PSCustomObject]@{ id = 'repo.deleteBranchOnMerge'; desired = 'True' }
$rb1 = Test-OperationApplied -Op $rbOp -Owner 'Owner' -Repo 'Repo'
Assert-True -Name 'read-back reports Matches=true when live state now equals desired' -Condition ($rb1.Matches -eq $true)

$script:MockRoutes['^repos/Owner/Repo$'] = { [PSCustomObject]@{ Success = $true; Data = [PSCustomObject]@{ delete_branch_on_merge = $false } } }.GetNewClosure()
$rb2 = Test-OperationApplied -Op $rbOp -Owner 'Owner' -Repo 'Repo'
Assert-True -Name 'read-back reports Matches=false (MISMATCH) when live state still differs from desired' -Condition ($rb2.Matches -eq $false)

$unknownOp = [PSCustomObject]@{ id = 'release.createStableCiRequiredJob'; capability = 'Release: create stable ci-required job'; desired = 'n/a' }
$rb3 = Test-OperationApplied -Op $unknownOp -Owner 'Owner' -Repo 'Repo'
Assert-True -Name 'read-back for an id with no mapping reports Matches=$null (UNVERIFIABLE), never a false "success"' -Condition ($null -eq $rb3.Matches)

Assert-True -Name 'Invoke-FullCdaVerification and per-operation read-back are separate functions (PLAN APPLIED vs FULL CDA COMPLIANCE are never the same claim)' -Condition ((Get-Command Test-OperationApplied).Name -ne (Get-Command Invoke-FullCdaVerification).Name)

$fullCdaError = Invoke-FullCdaVerification -Repository 'Continuous-DrivenArchitecture/does-not-exist-fixture' -AssessScriptPath (Join-Path $root 'does-not-exist.ps1')
Assert-True -Name 'Invoke-FullCdaVerification fails closed (Available=false, FullyCompliant=$null) rather than silently claiming compliance when the underlying re-assessment cannot run' -Condition (-not $fullCdaError.Available -and $null -eq $fullCdaError.FullyCompliant)

# ---------------------------------------------------------------------------
Write-Host "18b. Required-check evidence: job-name vs workflow-name (false-blocker regression)" -ForegroundColor Cyan

# Regression test for a real bug found during live sandbox integration
# testing (2026-08-23): assess-npm-library.ps1's "required status check
# not observed" blocker compared a check's CONTEXT (a job/check name like
# "ci-required") against Get-RecentWorkflowRuns' `.Name` (the WORKFLOW's
# own name, e.g. "CI") -- a category error that could never match a
# correctly-configured matrix-independent summary job living inside a
# workflow, producing a false blocker even when the check had genuinely
# just succeeded (confirmed live: check-runs showed ci-required succeeded
# on main's tip while the old logic still reported it "not observed").
# Fixed by reading actual named check runs via the check-runs API
# (Get-CheckRunsForRef) instead. Get-CheckRunsForRef itself is not
# mock-unit-testable here: it calls Invoke-ReadOnlyGitHub from WITHIN
# Discovery.psm1, its own defining module, which (per the mocking-
# strategy comment in section 15 above) a test-scope override cannot
# reach -- consistent with how this suite already treats every other
# thin Discovery.psm1 API wrapper. Covered instead by the source-pattern
# checks below plus the real sandbox integration run this was found in.
$assessSourceForBlockerCheck = Get-Content -LiteralPath (Join-Path $commandsDir 'assess-npm-library.ps1') -Raw
Assert-True -Name 'assess-npm-library.ps1''s required-check blocker no longer compares a check context against workflow-run names ($recentRuns removed)' -Condition ($assessSourceForBlockerCheck -notmatch '\$recentRuns')
Assert-True -Name 'assess-npm-library.ps1''s required-check blocker now uses Get-CheckRunsForRef' -Condition ($assessSourceForBlockerCheck -match 'Get-CheckRunsForRef')

# ---------------------------------------------------------------------------
Write-Host "18c. develop-vs-main comparison base branch (self-comparison regression)" -ForegroundColor Cyan

# SEVERE regression found during a real PRODUCTION migration (2026-08-23):
# the develop-deletion safety comparison used to call
# Get-BranchComparison -Base $defaultBranch -Head 'develop'. When the
# repository's CURRENT default branch is literally 'develop' -- the
# single most common legacy-drift scenario this tool exists to detect --
# that degenerates into comparing develop against itself, which is
# ALWAYS "identical, ahead_by=0, behind_by=0" no matter what the real
# 'main' branch actually contains. Confirmed live against
# Continuous-DrivenArchitecture/adapter-xma, where main had genuinely
# diverged by 45 commits (including real semantic-release commits) while
# a fresh assessment still reported develop as safely mergeable. Source-
# pattern regression test only (see the 18b comment immediately above for
# why: this logic lives in the orchestrator script and calls
# Get-BranchComparison, a Discovery.psm1 function this suite's mocking
# strategy cannot reach from outside Discovery.psm1's own module scope).
Assert-True -Name 'assess-npm-library.ps1 no longer compares develop against $defaultBranch (the self-comparison bug)' -Condition ($assessSourceForBlockerCheck -notmatch "Get-BranchComparison[^\r\n]*-Base\s+\`$defaultBranch")
Assert-True -Name 'assess-npm-library.ps1 resolves the develop-comparison base to $contentRef (the actual ''main''/legacy ''master'' resolution), never the current default directly' -Condition ($assessSourceForBlockerCheck -match "compareBaseBranch = if \(\`$contentRef -ne 'develop'\)")
Assert-True -Name '$contentRef itself resolves main, then master, then falls back to the live default branch' -Condition ($assessSourceForBlockerCheck -match "contentRef = if \(\`$branchNamesEarly -contains 'main'\) \{ 'main' \} elseif \(\`$branchNamesEarly -contains 'master'\) \{ 'master' \}")
Assert-True -Name 'assess-npm-library.ps1 treats develop as UNKNOWN (never silently safe) when neither main nor master exists to compare it against' -Condition ($assessSourceForBlockerCheck -match 'No ''main'' or ''master'' branch exists to compare develop against')

# ---------------------------------------------------------------------------
Write-Host "18d. Content reference branch: package.json / release config / workflows / ci-required evidence (SEVERE regression)" -ForegroundColor Cyan

# SEVERE regression found during a real PRODUCTION migration (2026-08-23),
# immediately after the 18c fix above: Get-PackageJsonInfo used to read
# package.json via an IMPLICIT-default-branch Get-WorkflowFileText call
# FIRST and only fell back to its own -Ref parameter if that read failed
# -- meaning -Ref was silently ignored whenever the file existed on
# GitHub's actual default branch (nearly always). Get-ReleaseConfigText
# and Get-WorkflowsInventory had no -Ref parameter at all and always read
# implicitly. For Continuous-DrivenArchitecture/adapter-xma, whose
# default branch was still 'develop' while real development (a fully
# different package.json, a working semantic-release + npm-Trusted-
# Publishing release job in ci.yml, a .releaserc.json) had moved to
# 'main', this made the assessment completely blind to all of it --
# reporting "no release workflow found" and a fabricated version
# mismatch for a repository that actually had neither problem. Fixed by
# giving every content-read an explicit, honored -Ref, and having
# assess-npm-library.ps1 resolve $contentRef (main, then master, else the
# live default) instead of using $defaultBranch for any of them.
# Source-pattern regression tests only -- see the 18b/18c comments above
# for why these Discovery.psm1 functions cannot be mock-unit-tested from
# outside their own defining module.
$discoverySource = Get-Content -LiteralPath (Join-Path $adopterLib 'Discovery.psm1') -Raw
Assert-True -Name 'Get-PackageJsonInfo no longer tries an implicit-default-branch read before its own -Ref (the silently-ignored-Ref bug)' -Condition ($discoverySource -notmatch 'Get-WorkflowFileText -Owner \$Owner -Repo \$Repo -Path "package\.json"\s*\r?\n\s*if \(\$null -eq \$text\)')
Assert-True -Name 'Get-PackageJsonInfo always passes its own -Ref through to Get-WorkflowFileText' -Condition ($discoverySource -match 'Get-WorkflowFileText -Owner \$Owner -Repo \$Repo -Path "package\.json" -Ref \$Ref')
Assert-True -Name 'Get-ReleaseConfigText now requires and honors -Ref' -Condition ($discoverySource -match 'function Get-ReleaseConfigText \{[\s\S]{0,400}Mandatory\)\] \[string\]\$Ref')
Assert-True -Name 'Get-WorkflowsInventory accepts -Ref and threads it into both the directory listing and each file read' -Condition ($discoverySource -match 'function Get-WorkflowsInventory \{[\s\S]{0,1200}\[string\]\$Ref')

Assert-True -Name 'assess-npm-library.ps1 resolves $contentRef (main, then master, else live default) before any content read' -Condition ($assessSourceForBlockerCheck -match "contentRef = if \(\`$branchNamesEarly -contains 'main'\)")
Assert-True -Name 'assess-npm-library.ps1 reads package.json via $contentRef, never $defaultBranch directly' -Condition ($assessSourceForBlockerCheck -match 'Get-PackageJsonInfo -Owner \$owner -Repo \$repo -Ref \$contentRef') -Detail 'package.json read must use $contentRef'
Assert-True -Name 'assess-npm-library.ps1 reads the release config via $contentRef' -Condition ($assessSourceForBlockerCheck -match 'Get-ReleaseConfigText -Owner \$owner -Repo \$repo -Ref \$contentRef')
Assert-True -Name 'assess-npm-library.ps1 inventories workflows via $contentRef' -Condition ($assessSourceForBlockerCheck -match 'Get-WorkflowsInventory -Owner \$owner -Repo \$repo -Ref \$contentRef')
Assert-True -Name 'assess-npm-library.ps1 reads ci-required evidence via $contentRef' -Condition ($assessSourceForBlockerCheck -match 'Get-CheckRunsForRef -Owner \$owner -Repo \$repo -Ref \$contentRef')
Assert-True -Name 'assess-npm-library.ps1 still reads dependabot.yml via the REAL default branch (deliberate -- GitHub''s Dependabot only honors config on the true default branch, not $contentRef)' -Condition ($assessSourceForBlockerCheck -match 'Get-DependabotConfigText -Owner \$owner -Repo \$repo\s*\r?\n')

$applySourceForContentRef = Get-Content -LiteralPath (Join-Path $adopterLib 'Apply.psm1') -Raw
Assert-True -Name 'Apply.psm1''s preflight staleness re-check resolves the SAME content branch (main/master/live-default) as the assessment did, never $repoData.default_branch directly, for workflow/release-config/package.json SHAs' -Condition ($applySourceForContentRef -match "liveContentRef = if \(\`$liveBranches\.ContainsKey\('main'\)\)")
Assert-True -Name 'Apply.psm1''s workflow SHA staleness check uses $liveContentRef' -Condition ($applySourceForContentRef -match 'Path "\.github/workflows/\$\(\$wf\.File\)" -Ref \$liveContentRef')
Assert-True -Name 'Apply.psm1''s package.json SHA staleness check uses $liveContentRef' -Condition ($applySourceForContentRef -match "Path 'package\.json' -Ref \`$liveContentRef")

# ---------------------------------------------------------------------------
Write-Host "18e. Release model detection: embedded release job, not just a release-named file (regression)" -ForegroundColor Cyan

# SEVERE regression found during the same real PRODUCTION migration
# (2026-08-23): Get-ReleaseModelSummary required the release logic to
# live in a workflow whose FILE or NAME contains "release" (e.g.
# release.yml). A real repository had its release job embedded as a
# conditional job inside ci.yml (workflow name "CI", gated on
# `needs: [validate, audit]` so it only runs after the rest of CI passes)
# and was reported as NO_RELEASE_WORKFLOW_FOUND despite having a real,
# working semantic-release + npm-Trusted-Publishing job. This is a pure
# function (no network calls) -- tested directly with fixture data, no
# mocking needed.
$embeddedReleaseWorkflow = [PSCustomObject]@{
    Name = 'CI'; File = 'ci.yml'
    ReferencesSentinel = $false; ReferencesSemanticRelease = $true; ReferencesNpmToken = $false; ReferencesIdToken = $true
}
$modelWithEmbeddedRelease = Get-ReleaseModelSummary -Workflows @($embeddedReleaseWorkflow) -ReleaseConfig $null -SecretsMeta ([PSCustomObject]@{ Secrets = @() })
Assert-True -Name 'a release job embedded in a workflow NOT named "release" is still detected as the release workflow (regression: used to require the name/file to contain "release")' -Condition ($null -ne $modelWithEmbeddedRelease.ReleaseWorkflowFile -and $modelWithEmbeddedRelease.ReleaseWorkflowFile -eq 'ci.yml')
Assert-True -Name 'that repository is never misreported as NO_RELEASE_WORKFLOW_FOUND when it demonstrably runs semantic-release' -Condition ($modelWithEmbeddedRelease.Model -ne 'NO_RELEASE_WORKFLOW_FOUND')

$namedReleaseWorkflow = [PSCustomObject]@{
    Name = 'Release'; File = 'release.yml'
    ReferencesSentinel = $false; ReferencesSemanticRelease = $true; ReferencesNpmToken = $false; ReferencesIdToken = $true
}
$modelWithNamedRelease = Get-ReleaseModelSummary -Workflows @($namedReleaseWorkflow, $embeddedReleaseWorkflow) -ReleaseConfig $null -SecretsMeta ([PSCustomObject]@{ Secrets = @() })
Assert-Equal -Name 'a name-matched release workflow is still preferred over a content-only match when both exist' -Expected 'release.yml' -Actual $modelWithNamedRelease.ReleaseWorkflowFile

$noReleaseAtAll = [PSCustomObject]@{
    Name = 'CI'; File = 'ci.yml'
    ReferencesSentinel = $false; ReferencesSemanticRelease = $false; ReferencesNpmToken = $false; ReferencesIdToken = $false
}
$modelWithNoRelease = Get-ReleaseModelSummary -Workflows @($noReleaseAtAll) -ReleaseConfig $null -SecretsMeta ([PSCustomObject]@{ Secrets = @() })
Assert-Equal -Name 'a repository with genuinely no release workflow (name or content) is still correctly reported NO_RELEASE_WORKFLOW_FOUND' -Expected 'NO_RELEASE_WORKFLOW_FOUND' -Actual $modelWithNoRelease.Model

# SEVERE regression found during the same real PRODUCTION migration,
# immediately after merging a PR that removed @semantic-release/git:
# '@semantic-release/git' (no boundary) also matches as a plain substring
# of '@semantic-release/github' -- a DIFFERENT, correct, required plugin.
# A release config with @semantic-release/github present but
# @semantic-release/git genuinely removed was STILL reported as needing
# the git plugin removed, because the regex matched inside "github".
$configWithOnlyGithubPlugin = [PSCustomObject]@{ File = '.releaserc.json'; Text = '{"plugins": ["@semantic-release/commit-analyzer", "@semantic-release/github"]}' }
$modelGithubOnly = Get-ReleaseModelSummary -Workflows @($embeddedReleaseWorkflow) -ReleaseConfig $configWithOnlyGithubPlugin -SecretsMeta ([PSCustomObject]@{ Secrets = @() })
Assert-True -Name 'a release config with ONLY @semantic-release/github (no git plugin) is never misreported as having the git plugin (regression: "git" matched inside "github")' -Condition (-not $modelGithubOnly.HasSemanticReleaseGitPlugin)

$configWithBothGitAndGithub = [PSCustomObject]@{ File = '.releaserc.json'; Text = '{"plugins": ["@semantic-release/git", "@semantic-release/github"]}' }
$modelBoth = Get-ReleaseModelSummary -Workflows @($embeddedReleaseWorkflow) -ReleaseConfig $configWithBothGitAndGithub -SecretsMeta ([PSCustomObject]@{ Secrets = @() })
Assert-True -Name 'a release config with BOTH @semantic-release/git and @semantic-release/github still correctly detects the git plugin as present' -Condition ($modelBoth.HasSemanticReleaseGitPlugin)

# ---------------------------------------------------------------------------
Write-Host "19. Synthetic-fixture regression: approved-plan shapes seen in real production use" -ForegroundColor Cyan
# Rebuilt from SYNTHETIC data reproducing the shapes of two real approved
# plans observed during this tooling's original validation (a legacy
# repository with an unmerged develop branch, and a repository migrating
# its default branch from develop to main) -- no production repository
# name, id, SHA, or report file is read here; see docs/artifact-model.md,
# "Synthetic fixtures only".

$legacyRepoOps = @(
    [PSCustomObject]@{ id = 'branch.delete.develop'; capability = 'Branch: delete develop'; classification = 'BLOCKED'; current = 'exists, contains commits not reachable from main'; desired = 'deleted (main-only)'; rationale = 'unmerged commits'; requiresManualChange = $false; destructive = $true; dependencies = @('default branch is main, not develop'); action = 'x'; approved = $false }
    [PSCustomObject]@{ id = 'release.removeSemanticReleaseGitPlugin'; capability = 'Release: remove @semantic-release/git plugin'; classification = 'REVIEW_REQUIRED'; current = 'present'; desired = 'absent'; rationale = 'x'; requiresManualChange = $true; destructive = $false; dependencies = @(); action = 'x'; approved = $false }
    [PSCustomObject]@{ id = 'release.createStableCiRequiredJob'; capability = 'Release: create stable ci-required job'; classification = 'REVIEW_REQUIRED'; current = 'absent'; desired = 'present with execution evidence'; rationale = 'x'; requiresManualChange = $true; destructive = $false; dependencies = @(); action = 'x'; approved = $false }
)
$legacyRepoFixture = New-MockApprovedPlan
$legacyRepoFixture.operations = $legacyRepoOps
$legacyRepoFixture.planHash = Get-PlanHash -Repository $legacyRepoFixture.repository -Profile $legacyRepoFixture.profile -Operations $legacyRepoOps
$legacyHashCheck = Test-ApprovedPlanHash -ApprovedPlan $legacyRepoFixture
Assert-True -Name 'synthetic legacy-repo fixture: approved-plan hash is valid as generated' -Condition $legacyHashCheck.Valid
$legacyBlocked = @($legacyRepoFixture.operations | Where-Object { $_.id -eq 'branch.delete.develop' })
Assert-True -Name 'synthetic legacy-repo fixture: develop deletion is present but NOT approved (remains BLOCKED-unapprovable)' -Condition ($legacyBlocked.Count -eq 1 -and $legacyBlocked[0].approved -eq $false -and $legacyBlocked[0].classification -eq 'BLOCKED')
$legacyManual = @($legacyRepoFixture.operations | Where-Object { $_.id -match '^release\.' })
Assert-True -Name 'synthetic legacy-repo fixture: release-model migration items are present and marked requiresManualChange (Apply v1 cannot execute them)' -Condition ($legacyManual.Count -gt 0 -and (@($legacyManual | Where-Object { -not $_.requiresManualChange }).Count -eq 0))

$migratingRepoOps = @(
    [PSCustomObject]@{ id = 'repo.defaultBranch'; capability = 'Default branch'; classification = 'REVIEW_REQUIRED'; current = 'develop'; desired = 'main'; rationale = 'x'; requiresManualChange = $false; destructive = $false; dependencies = @('the target branch exists'); action = 'x'; approved = $true }
    [PSCustomObject]@{ id = 'security.secretScanning'; capability = 'Secret scanning'; classification = 'SAFE_CHANGE'; current = 'False'; desired = 'True'; rationale = 'x'; requiresManualChange = $false; destructive = $false; dependencies = @(); action = 'x'; approved = $true }
)
$migratingRepoFixture = New-MockApprovedPlan
$migratingRepoFixture.operations = $migratingRepoOps
$migratingRepoFixture.planHash = Get-PlanHash -Repository $migratingRepoFixture.repository -Profile $migratingRepoFixture.profile -Operations $migratingRepoOps
$migratingHashCheck = Test-ApprovedPlanHash -ApprovedPlan $migratingRepoFixture
Assert-True -Name 'synthetic migrating-repo fixture: approved-plan hash is valid as generated' -Condition $migratingHashCheck.Valid
$migratingDefaultBranch = @($migratingRepoFixture.operations | Where-Object { $_.id -eq 'repo.defaultBranch' })
Assert-True -Name 'synthetic migrating-repo fixture: default-branch change (develop->main) is REVIEW_REQUIRED and was explicitly approved' -Condition ($migratingDefaultBranch.Count -eq 1 -and $migratingDefaultBranch[0].classification -eq 'REVIEW_REQUIRED' -and $migratingDefaultBranch[0].approved -eq $true)
$migratingRulesetOps = @($migratingRepoFixture.operations | Where-Object { $_.id -match '^ruleset\.' })
Assert-True -Name 'synthetic migrating-repo fixture: an UNKNOWN ruleset capability generates zero ruleset.* operations (never guessed at)' -Condition ($migratingRulesetOps.Count -eq 0)

# ---------------------------------------------------------------------------
Write-Host "20. actions.shaPinningRequired mutation mapping (added for CDA finalization, 2026-08-23)" -ForegroundColor Cyan

# Same GET-modify-PUT endpoint/body shape already validated live by
# repository-provisioner's Get-ActionsPlan (PUT actions/permissions with
# enabled + allowed_actions + sha_pinning_required together) -- see brief
# section 1. Apply v1 previously had NO mapping for this operation id at
# all (NOT_EXECUTED, confirmed live on adapter-xma before this fix).

$shaOp = [PSCustomObject]@{ id = 'actions.shaPinningRequired'; capability = 'SHA pinning required'; classification = 'SAFE_CHANGE'; current = 'False'; desired = 'True'; rationale = 'x'; requiresManualChange = $false; destructive = $false; dependencies = @(); action = 'x'; approved = $true }

$script:MockRoutes = @{
    '^repos/Owner/Repo/actions/permissions$' = { [PSCustomObject]@{ Success = $true; Data = [PSCustomObject]@{ enabled = $true; allowed_actions = 'selected'; sha_pinning_required = $false } } }.GetNewClosure()
}
$shaSpec = Get-OperationMutationSpec -Op $shaOp -Owner 'Owner' -Repo 'Repo'
Assert-True -Name 'actions.shaPinningRequired (false->true) is a defined mutation' -Condition $shaSpec.Defined -Detail "$($shaSpec.Description)"
Assert-Equal -Name 'actions.shaPinningRequired uses PUT' -Expected 'PUT' -Actual $shaSpec.Method
Assert-Equal -Name 'actions.shaPinningRequired targets actions/permissions' -Expected 'repos/Owner/Repo/actions/permissions' -Actual $shaSpec.Path
Assert-True -Name 'the PUT body sets sha_pinning_required=true' -Condition ([bool]$shaSpec.Body.sha_pinning_required -eq $true)
Assert-True -Name 'the PUT body preserves live enabled (true) -- this operation changes SHA pinning ONLY' -Condition ([bool]$shaSpec.Body.enabled -eq $true)
Assert-Equal -Name 'the PUT body preserves live allowed_actions (selected) -- this operation changes SHA pinning ONLY' -Expected 'selected' -Actual $shaSpec.Body.allowed_actions

$script:MockRoutes['^repos/Owner/Repo/actions/permissions$'] = { [PSCustomObject]@{ Success = $true; Data = [PSCustomObject]@{ enabled = $true; allowed_actions = 'all' } } }.GetNewClosure()
$shaSpecUnavailable = Get-OperationMutationSpec -Op $shaOp -Owner 'Owner' -Repo 'Repo'
Assert-True -Name 'actions.shaPinningRequired is REFUSED (not guessed) when sha_pinning_required is absent from the live response' -Condition (-not $shaSpecUnavailable.Defined)

# Read-back (Verification.psm1)
$script:MockRoutes['^repos/Owner/Repo/actions/permissions$'] = { [PSCustomObject]@{ Success = $true; Data = [PSCustomObject]@{ enabled = $true; allowed_actions = 'selected'; sha_pinning_required = $true } } }.GetNewClosure()
$shaRbTrue = Test-OperationApplied -Op $shaOp -Owner 'Owner' -Repo 'Repo'
Assert-True -Name 'read-back reports Matches=true once live sha_pinning_required=true' -Condition ($shaRbTrue.Matches -eq $true) -Detail "$($shaRbTrue.Observed)"

$script:MockRoutes['^repos/Owner/Repo/actions/permissions$'] = { [PSCustomObject]@{ Success = $true; Data = [PSCustomObject]@{ enabled = $true; allowed_actions = 'selected'; sha_pinning_required = $false } } }.GetNewClosure()
$shaRbFalse = Test-OperationApplied -Op $shaOp -Owner 'Owner' -Repo 'Repo'
Assert-True -Name 'read-back reports Matches=false while live sha_pinning_required is still false' -Condition ($shaRbFalse.Matches -eq $false) -Detail "$($shaRbFalse.Observed)"

$script:MockRoutes['^repos/Owner/Repo/actions/permissions$'] = { [PSCustomObject]@{ Success = $true; Data = [PSCustomObject]@{ enabled = $true; allowed_actions = 'all' } } }.GetNewClosure()
$shaRbAbsent = Test-OperationApplied -Op $shaOp -Owner 'Owner' -Repo 'Repo'
Assert-True -Name 'read-back reports Matches=$null (UNVERIFIABLE) when the field is absent live, never a false positive' -Condition ($null -eq $shaRbAbsent.Matches)

# Staleness precondition (Apply.psm1's Test-OperationPreconditions)
$shaFpMatch = [PSCustomObject]@{ ActionsPermissions = [PSCustomObject]@{ Enabled = $true; AllowedActionsPolicy = 'selected'; ShaPinningRequired = $false } }
$script:MockRoutes['^repos/Owner/Repo/actions/permissions$'] = { [PSCustomObject]@{ Success = $true; Data = [PSCustomObject]@{ enabled = $true; allowed_actions = 'selected'; sha_pinning_required = $false } } }.GetNewClosure()
$shaPcOk = Test-OperationPreconditions -Op $shaOp -Owner 'Owner' -Repo 'Repo' -StateFingerprint $shaFpMatch
Assert-True -Name 'precondition PASSES when live sha_pinning_required still matches the assessment-time snapshot' -Condition $shaPcOk.Satisfied -Detail "$($shaPcOk.Reasons -join '; ')"

$script:MockRoutes['^repos/Owner/Repo/actions/permissions$'] = { [PSCustomObject]@{ Success = $true; Data = [PSCustomObject]@{ enabled = $true; allowed_actions = 'selected'; sha_pinning_required = $true } } }.GetNewClosure()
$shaPcStale = Test-OperationPreconditions -Op $shaOp -Owner 'Owner' -Repo 'Repo' -StateFingerprint $shaFpMatch
Assert-True -Name 'STALE SNAPSHOT: precondition FAILS when live sha_pinning_required drifted since assessment (someone else already changed it)' -Condition (-not $shaPcStale.Satisfied) -Detail "$($shaPcStale.Reasons -join '; ')"

$shaFpNoSnapshot = [PSCustomObject]@{ DefaultBranch = 'main' }
$shaPcNoSnapshot = Test-OperationPreconditions -Op $shaOp -Owner 'Owner' -Repo 'Repo' -StateFingerprint $shaFpNoSnapshot
Assert-True -Name 'a plan whose fingerprint predates this feature (no ActionsPermissions snapshot) fails closed, never silently allowed' -Condition (-not $shaPcNoSnapshot.Satisfied)

# API 403 / unavailable -> fail safe (real MutationGitHub.psm1 maps HTTP
# 403 to ErrorKind='Forbidden'; Invoke-ApprovedPlan treats any !Success
# as FAILED and stops -- exercised here with a dedicated 403 mock rather
# than the generic 422 already covered in section 17, for fidelity to
# brief section 2's explicit scenario).
function Get-BranchComparison { param($Owner, $Repo, $Base, $Head) return [PSCustomObject]@{ Available = $true; AheadBy = 0; BehindBy = 0; Status = 'identical' } }
function Get-OpenPullRequestsByBase { param($Owner, $Repo) return @() }
function Get-WorkflowsInventory { param($Owner, $Repo) return @() }
function Get-DependabotConfigText { param($Owner, $Repo) return $null }
$script:MockRoutes = @{
    '^repos/Continuous-DrivenArchitecture/mock-repo$'                    = { [PSCustomObject]@{ Success = $true; Data = [PSCustomObject]@{ default_branch = 'main'; archived = $false; fork = $false; permissions = [PSCustomObject]@{ admin = $true } } } }.GetNewClosure()
    '^repos/Continuous-DrivenArchitecture/mock-repo/branches\?'          = { [PSCustomObject]@{ Success = $true; Data = @([PSCustomObject]@{ name = 'main'; commit = [PSCustomObject]@{ sha = ('a' * 40) } }) } }.GetNewClosure()
    '^repos/Continuous-DrivenArchitecture/mock-repo/actions/permissions$' = { [PSCustomObject]@{ Success = $true; Data = [PSCustomObject]@{ enabled = $true; allowed_actions = 'selected'; sha_pinning_required = $false } } }.GetNewClosure()
}
$shaPlan403 = New-MockApprovedPlan
$shaOps403 = @($shaOp)
$shaPlan403.operations = $shaOps403
$shaPlan403.stateFingerprint = [PSCustomObject]@{
    CapturedAt = '2026-01-01 00:00:00'; DefaultBranch = 'main'; DefaultBranchSha = ('a' * 40); MainSha = ('a' * 40); DevelopSha = $null
    Rulesets = @(); WorkflowShas = @(); ReleaseConfigFile = $null; ReleaseConfigSha = $null; PackageJsonSha = $null
    ActionsPermissions = [PSCustomObject]@{ Enabled = $true; AllowedActionsPolicy = 'selected'; ShaPinningRequired = $false }
}
$shaPlan403.planHash = Get-PlanHash -Repository $shaPlan403.repository -Profile $shaPlan403.profile -Operations $shaOps403
function Invoke-MutationGitHub {
    param([Parameter(Mandatory)] [string]$Path, [Parameter(Mandatory)] [string]$Method, [object]$BodyObject)
    $script:MutationCallLog.Add([PSCustomObject]@{ Path = $Path; Method = $Method }) | Out-Null
    return [PSCustomObject]@{ StatusCode = 403; Success = $false; Data = $null; ErrorKind = 'Forbidden'; RawBody = '' }
}
$script:MutationCallLog.Clear()
$sha403Exec = Invoke-ApprovedPlan -ApprovedPlan $shaPlan403 -Owner 'Continuous-DrivenArchitecture' -Repo 'mock-repo'
Assert-True -Name 'HTTP 403 on the mutation call is reported FAILED (fail-safe, never silently ignored)' -Condition (@($sha403Exec.Results | Where-Object { $_.Status -eq 'FAILED' -and $_.Detail -match 'Forbidden' }).Count -eq 1) -Detail "$($sha403Exec.Results | ConvertTo-Json -Compress)"
Assert-True -Name 'a 403 failure stops the plan' -Condition $sha403Exec.Stopped
Assert-True -Name 'exactly one mutation call was attempted before stopping on 403' -Condition ($script:MutationCallLog.Count -eq 1)

# Restore the success-returning mock used by later assertions in this section.
function Invoke-MutationGitHub {
    param([Parameter(Mandatory)] [string]$Path, [Parameter(Mandatory)] [string]$Method, [object]$BodyObject)
    $script:MutationCallLog.Add([PSCustomObject]@{ Path = $Path; Method = $Method }) | Out-Null
    if ($script:MockMutationShouldFail) { return [PSCustomObject]@{ StatusCode = 422; Success = $false; Data = $null; ErrorKind = 'Unprocessable'; RawBody = '' } }
    return [PSCustomObject]@{ StatusCode = 200; Success = $true; Data = $null; ErrorKind = $null; RawBody = '' }
}

# DryRun -> zero mutations, WOULD_APPLY.
$shaPlanOk = New-MockApprovedPlan
$shaPlanOk.operations = @($shaOp)
$shaPlanOk.stateFingerprint = $shaPlan403.stateFingerprint
$shaPlanOk.planHash = Get-PlanHash -Repository $shaPlanOk.repository -Profile $shaPlanOk.profile -Operations @($shaOp)
$script:MockMutationShouldFail = $false
$script:MutationCallLog.Clear()
$shaDryExec = Invoke-ApprovedPlan -ApprovedPlan $shaPlanOk -Owner 'Continuous-DrivenArchitecture' -Repo 'mock-repo' -DryRun
Assert-True -Name 'DryRun reports WOULD_APPLY for actions.shaPinningRequired' -Condition (@($shaDryExec.Results | Where-Object { $_.Id -eq 'actions.shaPinningRequired' -and $_.Status -eq 'WOULD_APPLY' }).Count -eq 1)
Assert-True -Name 'DryRun performs ZERO mutation calls' -Condition ($script:MutationCallLog.Count -eq 0)

# Real Apply (mocked success) -> APPLIED, exactly one mutation call.
$script:MutationCallLog.Clear()
$shaApplyExec = Invoke-ApprovedPlan -ApprovedPlan $shaPlanOk -Owner 'Continuous-DrivenArchitecture' -Repo 'mock-repo'
Assert-True -Name 'real Apply reports APPLIED for actions.shaPinningRequired' -Condition (@($shaApplyExec.Results | Where-Object { $_.Id -eq 'actions.shaPinningRequired' -and $_.Status -eq 'APPLIED' }).Count -eq 1)
Assert-True -Name 'real Apply makes exactly one mutation call' -Condition ($script:MutationCallLog.Count -eq 1)
Assert-Equal -Name 'the mutation call used PUT to actions/permissions' -Expected 'PUT' -Actual $script:MutationCallLog[0].Method

# Operation NOT approved -> never even attempted, zero mutation calls.
$shaOpUnapproved = $shaOp.PSObject.Copy()
$shaOpUnapproved.approved = $false
$shaPlanUnapproved = New-MockApprovedPlan
$shaPlanUnapproved.operations = @($shaOpUnapproved)
$shaPlanUnapproved.stateFingerprint = $shaPlan403.stateFingerprint
$shaPlanUnapproved.planHash = Get-PlanHash -Repository $shaPlanUnapproved.repository -Profile $shaPlanUnapproved.profile -Operations @($shaOpUnapproved)
$script:MutationCallLog.Clear()
$shaUnapprovedExec = Invoke-ApprovedPlan -ApprovedPlan $shaPlanUnapproved -Owner 'Continuous-DrivenArchitecture' -Repo 'mock-repo'
Assert-True -Name 'an operation with approved=false produces NO result entry at all (never attempted, not even NOT_EXECUTED)' -Condition ($shaUnapprovedExec.Results.Count -eq 0)
Assert-True -Name 'an unapproved operation makes zero mutation calls' -Condition ($script:MutationCallLog.Count -eq 0)

# ---------------------------------------------------------------------------
Write-Host "21. Branch retirement evidence: GRAPH vs UNIQUE CONTENT divergence (added for archi-semantic-core Phase 6, 2026-08-24)" -ForegroundColor Cyan

# Get-BranchRetirementEvidence (Discovery.psm1) internally calls
# Invoke-ReadOnlyGitHub via a nested `Import-Module ReadOnlyGitHub.psm1`
# INSIDE Discovery.psm1 itself (confirmed empirically, not assumed, while
# building this section: a global-scope override of Invoke-ReadOnlyGitHub
# does NOT shadow it here, unlike the cross-module cases documented in
# section 15 -- Discovery.psm1's own nested import binds its OWN private
# reference, immune to what any OTHER caller's scope later defines,
# regardless of which module that caller lives in). This is a DIFFERENT,
# newly-discovered variant of the known mocking limitation, not the same
# one. Consequence: the core evidence ALGORITHM was pulled out into a
# separate PURE function, Test-BranchRetirementSemantics (no API calls,
# takes already-fetched tree SHAs), specifically so it CAN be unit-tested
# directly -- cases A-D below. Cases E-G (staleness re-detection inside
# Test-OperationPreconditions) still route through the unmockable I/O
# wrapper, so they are covered as source-pattern assertions instead,
# exactly like the established precedent for this class of limitation.

function New-ParentInfo($Sha, $Tree, $Reachable) {
    return [PSCustomObject]@{ Sha = $Sha; TreeSha = $Tree; ReachableFromTarget = $Reachable }
}
function New-RawExclusiveCommit($Sha, $Subject, $Tree, $ParentInfo) {
    return [PSCustomObject]@{ Sha = $Sha; Subject = $Subject; TreeSha = $Tree; ParentInfo = @($ParentInfo) }
}

# CASE A: one exclusive commit whose OWN tree matches nothing reachable
# from target => unique content => NOT proven equivalent => BLOCKED.
$caseACommits = @(
    (New-RawExclusiveCommit 'EXCL1' 'feat: unique work' 'EXCL1_TREE' @((New-ParentInfo 'MERGEBASE' 'MERGEBASE_TREE' $true)))
)
$caseA = Test-BranchRetirementSemantics -BranchHeadTreeSha 'EXCL1_TREE' -TargetHeadTreeSha 'MAINHEAD_TREE' -MergeBaseTreeSha 'MERGEBASE_TREE' -ExclusiveCommits $caseACommits
Assert-True -Name 'CASE A: a genuinely new tree is detected as content unique to the branch' -Condition ([bool]$caseA.ContentUniqueToBranch)
Assert-True -Name 'CASE A: semantic equivalence is NOT proven' -Condition (-not [bool]$caseA.SemanticEquivalenceProven)
$caseARow = Get-DevelopDeletionClassification -HasCommitsNotInMain $true -HasOpenPRsTargetingDevelop $false -WorkflowsReferenceDevelop $false -DependabotTargetsDevelop $false -DocsReferenceDevelop $false -SemanticEquivalenceProven $caseA.SemanticEquivalenceProven -BranchExclusiveCommitCount 1
Assert-Equal -Name 'CASE A: classification is BLOCKED' -Expected 'BLOCKED' -Actual $caseARow.Classification

# CASE B: two exclusive merge commits (mirrors the real archi-semantic-core
# "merge: sync develop with main" pair) whose own trees each match a tree
# reachable from target's history via a reachable parent => semantic
# equivalence proven, but classification must STILL be REVIEW_REQUIRED
# (never SAFE_CHANGE) because deletion remains destructive.
$caseBCommits = @(
    (New-RawExclusiveCommit 'EXCL_A' 'merge: sync develop with main (release 0.1)' 'MID_MAIN_TREE' @((New-ParentInfo 'OLDDEV_START' 'OLDDEV_START_TREE' $false), (New-ParentInfo 'MID_MAIN' 'MID_MAIN_TREE' $true))),
    (New-RawExclusiveCommit 'EXCL_B' 'merge: sync develop with main (release 0.2)' 'SHARED_TREE' @((New-ParentInfo 'EXCL_A' 'MID_MAIN_TREE' $false), (New-ParentInfo 'ANCESTOR_OF_MAIN' 'SHARED_TREE' $true)))
)
$caseB = Test-BranchRetirementSemantics -BranchHeadTreeSha 'SHARED_TREE' -TargetHeadTreeSha 'MAINHEAD_TREE' -MergeBaseTreeSha 'MERGEBASE_TREE' -ExclusiveCommits $caseBCommits
Assert-True -Name 'CASE B: no exclusive commit introduces unique content (both merge commits'' trees are already reachable from main)' -Condition (-not [bool]$caseB.ContentUniqueToBranch)
Assert-True -Name 'CASE B: semantic equivalence IS proven' -Condition ([bool]$caseB.SemanticEquivalenceProven)
Assert-Equal -Name 'CASE B: 2 exclusive commits carried through evidence' -Expected 2 -Actual $caseB.ExclusiveCommitEvidence.Count
$caseBRow = Get-DevelopDeletionClassification -HasCommitsNotInMain $true -HasOpenPRsTargetingDevelop $false -WorkflowsReferenceDevelop $false -DependabotTargetsDevelop $false -DocsReferenceDevelop $false -SemanticEquivalenceProven $caseB.SemanticEquivalenceProven -BranchExclusiveCommitCount 2
Assert-Equal -Name 'CASE B: classification is REVIEW_REQUIRED, never SAFE_CHANGE, even with zero other consumers' -Expected 'REVIEW_REQUIRED' -Actual $caseBRow.Classification
Assert-True -Name 'CASE B: row is marked destructive' -Condition ([bool]$caseBRow.Destructive)

# CASE C: final (head) tree matches, but an INTERMEDIATE exclusive commit
# carries a tree matching nothing reachable -- must NOT be waved through
# just because the final tree looks fine (proves per-commit evidence
# drives the result, not a naive head-tree-only comparison).
$caseCCommits = @(
    (New-RawExclusiveCommit 'EXCL_A' 'merge: sync develop with main (release 0.1)' 'UNIQUE_INTERMEDIATE_TREE' @((New-ParentInfo 'OLDDEV_START' 'OLDDEV_START_TREE' $false), (New-ParentInfo 'MID_MAIN' 'MID_MAIN_TREE' $true))),
    (New-RawExclusiveCommit 'EXCL_B' 'merge: sync develop with main (release 0.2)' 'SHARED_TREE' @((New-ParentInfo 'EXCL_A' 'UNIQUE_INTERMEDIATE_TREE' $false), (New-ParentInfo 'ANCESTOR_OF_MAIN' 'SHARED_TREE' $true)))
)
$caseC = Test-BranchRetirementSemantics -BranchHeadTreeSha 'SHARED_TREE' -TargetHeadTreeSha 'MAINHEAD_TREE' -MergeBaseTreeSha 'MERGEBASE_TREE' -ExclusiveCommits $caseCCommits
Assert-True -Name 'CASE C: an intermediate exclusive commit''s unique tree is detected even though the final tree matches' -Condition ([bool]$caseC.ContentUniqueToBranch)
Assert-True -Name 'CASE C: semantic equivalence is NOT proven (per-commit evidence overrides a merely-matching final tree)' -Condition (-not [bool]$caseC.SemanticEquivalenceProven)
$caseCRow = Get-DevelopDeletionClassification -HasCommitsNotInMain $true -HasOpenPRsTargetingDevelop $false -WorkflowsReferenceDevelop $false -DependabotTargetsDevelop $false -DocsReferenceDevelop $false -SemanticEquivalenceProven $caseC.SemanticEquivalenceProven -BranchExclusiveCommitCount 2
Assert-Equal -Name 'CASE C: classification is BLOCKED' -Expected 'BLOCKED' -Actual $caseCRow.Classification

# CASE D: no unique commits at all -- omitting/nulling the new semantic
# parameters must reproduce EXACTLY the pre-existing behavior (regression
# guard: adding branch-retirement support must not change this path).
$caseDSafe = Get-DevelopDeletionClassification -HasCommitsNotInMain $false -HasOpenPRsTargetingDevelop $false -WorkflowsReferenceDevelop $false -DependabotTargetsDevelop $false -DocsReferenceDevelop $false
Assert-Equal -Name 'CASE D: no unique commits, no consumers -> SAFE_CHANGE (unchanged pre-existing behavior)' -Expected 'SAFE_CHANGE' -Actual $caseDSafe.Classification
$caseDReview = Get-DevelopDeletionClassification -HasCommitsNotInMain $false -HasOpenPRsTargetingDevelop $true -WorkflowsReferenceDevelop $false -DependabotTargetsDevelop $false -DocsReferenceDevelop $false -SemanticEquivalenceProven $null
Assert-Equal -Name 'CASE D: no unique commits but a consumer exists -> REVIEW_REQUIRED (unchanged pre-existing behavior)' -Expected 'REVIEW_REQUIRED' -Actual $caseDReview.Classification

# A plan predating this feature (no DevelopRetirementEvidence in its
# fingerprint) must still work via the original AheadBy-based check --
# this call DOES shadow correctly, because it overrides Get-BranchComparison
# itself (the whole function, called cross-module from Apply.psm1), not
# one of ITS internal calls.
function Get-OpenPullRequestsByBase { param($Owner, $Repo) return @() }
function Get-WorkflowsInventory { param($Owner, $Repo) return @() }
function Get-DependabotConfigText { param($Owner, $Repo) return $null }
$develpOpStale = [PSCustomObject]@{ id = 'branch.delete.develop'; desired = 'deleted' }
$script:MockRoutes = @{
    '^repos/Owner/Repo$'                  = { [PSCustomObject]@{ Success = $true; Data = [PSCustomObject]@{ default_branch = 'main' } } }.GetNewClosure()
    '^repos/Owner/Repo/branches/develop$' = { [PSCustomObject]@{ Success = $true; Data = [PSCustomObject]@{ name = 'develop' } } }.GetNewClosure()
}
function Get-BranchComparison { param($Owner, $Repo, $Base, $Head) return [PSCustomObject]@{ Available = $true; AheadBy = 0; BehindBy = 0; Status = 'identical' } }
$fpNoEvidence = [PSCustomObject]@{ Rulesets = @() }
$pcLegacy = Test-OperationPreconditions -Op $develpOpStale -Owner 'Owner' -Repo 'Repo' -StateFingerprint $fpNoEvidence
Assert-True -Name 'a plan predating branch-retirement evidence still uses the original AheadBy check and passes when AheadBy=0' -Condition $pcLegacy.Satisfied -Detail "$($pcLegacy.Reasons -join '; ')"

# CASES E/F/G (source-pattern only -- see comment above): the staleness
# comparisons must exist in Apply.psm1's source, each keyed to its own
# field, each explicitly naming "STALE PLAN".
$applySource = Get-Content -LiteralPath (Join-Path $adopterLib 'Apply.psm1') -Raw
Assert-True -Name 'CASE E (source): Apply.psm1 compares live BranchHeadSha against the fingerprint and calls it a STALE PLAN' -Condition ($applySource -match "develop HEAD changed since assessment[^`"]*STALE PLAN")
Assert-True -Name 'CASE F (source): Apply.psm1 compares live MergeBaseSha against the fingerprint and calls it a STALE PLAN' -Condition ($applySource -match "merge-base with main changed since assessment[^`"]*STALE PLAN")
Assert-True -Name 'CASE G (source): Apply.psm1 compares live BranchHeadTreeSha against the fingerprint and calls it a STALE PLAN' -Condition ($applySource -match "develop HEAD tree changed since assessment[^`"]*STALE PLAN")
Assert-True -Name 'CASE E/F/G (source): staleness checks run before live content-uniqueness/equivalence checks (fail closed on drift, never re-approve on top of moved evidence)' -Condition ($applySource -match 'BranchHeadSha[\s\S]{0,400}MergeBaseSha[\s\S]{0,400}BranchHeadTreeSha[\s\S]{0,400}ContentUniqueToBranch')
Assert-True -Name 'the semantic path is only used when the plan''s fingerprint actually carries DevelopRetirementEvidence -- a plan predating this feature falls back to the original AheadBy check' -Condition ($applySource -match "StateFingerprint\.PSObject\.Properties\['DevelopRetirementEvidence'\]")

# ---------------------------------------------------------------------------
Write-Host "22. Merge reproducibility evidence (added for archi-semantic-core Phase 6, 2026-08-24)" -ForegroundColor Cyan

# Test-GitMergeReproducible / Get-MergeIntroducedBlobPaths shell out to a
# REAL local `git` process against REAL tiny scratch repos built here on
# the fly -- no GitHub API involved, so none of the mocking limitations
# from earlier sections apply. This is the most faithful way to test
# code whose entire job is "ask Git a question".
$mergeTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "cda-adopter-mergetest-$([Guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $mergeTestRoot -Force | Out-Null

function New-ScratchGitRepo([string]$Name) {
    $path = Join-Path $mergeTestRoot $Name
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    Push-Location $path
    try {
        & git init -q 2>&1 | Out-Null
        & git config user.email 'test@test.com' 2>&1 | Out-Null
        & git config user.name 'Test' 2>&1 | Out-Null
        & git config core.autocrlf false 2>&1 | Out-Null
    }
    finally { Pop-Location }
    return $path
}
function Get-CurrentBranchName([string]$Path) {
    return (& git -C $Path branch --show-current).Trim()
}

# --- Clean (non-conflicting) two-parent merge: parents touch different
# files, so Git can auto-combine them with zero manual resolution. ---
$cleanRepo = New-ScratchGitRepo 'clean-merge'
Set-Content -LiteralPath (Join-Path $cleanRepo 'a.txt') -Value 'base' -NoNewline
Set-Content -LiteralPath (Join-Path $cleanRepo 'b.txt') -Value 'base' -NoNewline
& git -C $cleanRepo add -A 2>&1 | Out-Null
& git -C $cleanRepo commit -q -m 'base' 2>&1 | Out-Null
$baseBranch = Get-CurrentBranchName $cleanRepo
& git -C $cleanRepo checkout -q -b feature-a 2>&1 | Out-Null
Add-Content -LiteralPath (Join-Path $cleanRepo 'a.txt') -Value "`nfeature-a change"
& git -C $cleanRepo commit -q -am 'feature-a change' 2>&1 | Out-Null
$cleanP1 = (& git -C $cleanRepo rev-parse HEAD).Trim()
& git -C $cleanRepo checkout -q $baseBranch 2>&1 | Out-Null
Add-Content -LiteralPath (Join-Path $cleanRepo 'b.txt') -Value "`nmain change"
& git -C $cleanRepo commit -q -am 'main change' 2>&1 | Out-Null
$cleanP2 = (& git -C $cleanRepo rev-parse HEAD).Trim()
$cleanMerge = & git -C $cleanRepo merge-tree --write-tree --no-messages $cleanP1 $cleanP2
$cleanMergeTree = @($cleanMerge)[0].Trim()

$reproClean = Test-GitMergeReproducible -RepoPath $cleanRepo -Parent1Sha $cleanP1 -Parent2Sha $cleanP2 -RecordedTreeSha $cleanMergeTree
Assert-True -Name 'CASE A: a clean, non-conflicting merge reproduces exactly -> Reproducible=true' -Condition ($reproClean.Reproducible -eq $true) -Detail "$($reproClean.Detail)"
Assert-Equal -Name 'CASE A: reproduced tree SHA matches the recorded tree SHA' -Expected $cleanMergeTree -Actual $reproClean.ReproducedTreeSha
Assert-True -Name 'CASE A: no conflict detected' -Condition ($reproClean.ConflictDetected -eq $false)

# A deliberate mismatch: claim a WRONG recorded tree (simulating a merge
# commit whose author manually edited the result after resolving) --
# reproduction still succeeds cleanly, but Reproducible must be false
# because it disagrees with what was actually recorded.
$reproMismatch = Test-GitMergeReproducible -RepoPath $cleanRepo -Parent1Sha $cleanP1 -Parent2Sha $cleanP2 -RecordedTreeSha ('0' * 40)
Assert-True -Name 'CASE B: reproduction succeeds but disagrees with the recorded tree -> Reproducible=false' -Condition ($reproMismatch.Reproducible -eq $false)
Assert-True -Name 'CASE B: this mismatch is NOT reported as a conflict (it was a clean merge, just not the recorded one)' -Condition ($reproMismatch.ConflictDetected -eq $false)

# --- Conflicting two-parent merge: both branches edit the SAME line, so
# Git cannot auto-resolve -- real evidence of manual resolution. ---
$conflictRepo = New-ScratchGitRepo 'conflict-merge'
Set-Content -LiteralPath (Join-Path $conflictRepo 'shared.txt') -Value 'base line' -NoNewline
& git -C $conflictRepo add -A 2>&1 | Out-Null
& git -C $conflictRepo commit -q -m 'base' 2>&1 | Out-Null
$conflictBaseBranch = Get-CurrentBranchName $conflictRepo
& git -C $conflictRepo checkout -q -b feature-b 2>&1 | Out-Null
Set-Content -LiteralPath (Join-Path $conflictRepo 'shared.txt') -Value 'feature-b edit' -NoNewline
& git -C $conflictRepo commit -q -am 'feature-b edit' 2>&1 | Out-Null
$conflictP1 = (& git -C $conflictRepo rev-parse HEAD).Trim()
& git -C $conflictRepo checkout -q $conflictBaseBranch 2>&1 | Out-Null
Set-Content -LiteralPath (Join-Path $conflictRepo 'shared.txt') -Value 'main edit' -NoNewline
& git -C $conflictRepo commit -q -am 'main edit' 2>&1 | Out-Null
$conflictP2 = (& git -C $conflictRepo rev-parse HEAD).Trim()

$reproConflict = Test-GitMergeReproducible -RepoPath $conflictRepo -Parent1Sha $conflictP1 -Parent2Sha $conflictP2 -RecordedTreeSha ('1' * 40)
Assert-True -Name 'a genuinely conflicting merge is reported Reproducible=false' -Condition ($reproConflict.Reproducible -eq $false)
Assert-True -Name 'a genuinely conflicting merge sets ConflictDetected=true' -Condition ($reproConflict.ConflictDetected -eq $true)

# Missing parent object -> UNKNOWN, never guessed as either true or false.
$reproMissing = Test-GitMergeReproducible -RepoPath $cleanRepo -Parent1Sha ('f' * 40) -Parent2Sha $cleanP2 -RecordedTreeSha $cleanMergeTree
Assert-True -Name 'a missing parent object is reported Reproducible=$null (UNKNOWN), never guessed' -Condition ($null -eq $reproMissing.Reproducible)

# --- CASE C: merge-introduced blob detection (supporting evidence). ---
$blobRepo = New-ScratchGitRepo 'blob-merge'
Set-Content -LiteralPath (Join-Path $blobRepo 'x.txt') -Value 'base' -NoNewline
& git -C $blobRepo add -A 2>&1 | Out-Null
& git -C $blobRepo commit -q -m 'base' 2>&1 | Out-Null
$blobBaseBranch = Get-CurrentBranchName $blobRepo
& git -C $blobRepo checkout -q -b feature-c 2>&1 | Out-Null
Set-Content -LiteralPath (Join-Path $blobRepo 'y.txt') -Value 'feature-c only file' -NoNewline
& git -C $blobRepo add -A 2>&1 | Out-Null
& git -C $blobRepo commit -q -m 'feature-c adds y.txt' 2>&1 | Out-Null
$blobP1 = (& git -C $blobRepo rev-parse HEAD).Trim()
& git -C $blobRepo checkout -q $blobBaseBranch 2>&1 | Out-Null
Set-Content -LiteralPath (Join-Path $blobRepo 'z.txt') -Value 'main only file' -NoNewline
& git -C $blobRepo add -A 2>&1 | Out-Null
& git -C $blobRepo commit -q -m 'main adds z.txt' 2>&1 | Out-Null
$blobP2 = (& git -C $blobRepo rev-parse HEAD).Trim()
$blobMergeOut = & git -C $blobRepo merge-tree --write-tree --no-messages $blobP1 $blobP2
$blobMergeTree = @($blobMergeOut)[0].Trim()
# Simulate a merge commit whose committed tree ALSO adds a third file that
# exists in NEITHER parent (as if manually added during merge resolution).
& git -C $blobRepo read-tree $blobMergeTree 2>&1 | Out-Null
Set-Content -LiteralPath (Join-Path $blobRepo 'manually-added.txt') -Value 'not from either parent' -NoNewline
& git -C $blobRepo add manually-added.txt 2>&1 | Out-Null
$manualTree = (& git -C $blobRepo write-tree).Trim()
& git -C $blobRepo read-tree $blobBaseBranch 2>&1 | Out-Null  # restore working tree/index to a known state

$blobEvidence = Get-MergeIntroducedBlobPaths -RepoPath $blobRepo -RecordedTreeSha $manualTree -Parent1Sha $blobP1 -Parent2Sha $blobP2
Assert-True -Name 'CASE C: a blob present in neither parent is flagged as merge-introduced' -Condition ($blobEvidence.Available -and (@($blobEvidence.MergeIntroducedPaths) -contains 'manually-added.txt'))
Assert-True -Name 'CASE C: files that genuinely came from a parent are NOT flagged' -Condition (@($blobEvidence.MergeIntroducedPaths) -notcontains 'y.txt' -and @($blobEvidence.MergeIntroducedPaths) -notcontains 'z.txt')

Remove-Item -LiteralPath $mergeTestRoot -Recurse -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
Write-Host "23. Test-BranchRetirementSemantics: merge-reproducibility decision tree" -ForegroundColor Cyan

function New-Repro($Reproducible, $ReproducedTreeSha, $ConflictDetected = $false) {
    return [PSCustomObject]@{ Reproducible = $Reproducible; ReproducedTreeSha = $ReproducedTreeSha; ExitCode = $null; ConflictDetected = $ConflictDetected; Detail = '' }
}

# CASE A (decision tree): both parents reachable, reproduction exact match
# -> MERGE_HISTORY_REPRODUCIBLE, UniqueAuthoredContent=false.
$dtCommitsA = @(
    (New-RawExclusiveCommit 'M1' 'merge commit' 'NEW_MERGE_TREE' @((New-ParentInfo 'P1' 'P1_TREE' $true), (New-ParentInfo 'P2' 'P2_TREE' $true)))
)
$dtCommitsA[0] | Add-Member -NotePropertyName MergeReproducibility -NotePropertyValue (New-Repro $true 'NEW_MERGE_TREE')
$dtA = Test-BranchRetirementSemantics -BranchHeadTreeSha 'NEW_MERGE_TREE' -TargetHeadTreeSha 'MAINHEAD_TREE' -MergeBaseTreeSha 'MERGEBASE_TREE' -ExclusiveCommits $dtCommitsA
Assert-True -Name 'CASE A (decision tree): UniqueAuthoredContent is false when the merge reproduces exactly' -Condition (-not [bool]$dtA.ExclusiveCommitEvidence[0].UniqueAuthoredContent)
Assert-Equal -Name 'CASE A (decision tree): evidence level is MERGE_HISTORY_REPRODUCIBLE' -Expected 'MERGE_HISTORY_REPRODUCIBLE' -Actual $dtA.ExclusiveCommitEvidence[0].RetirementEvidenceLevel
Assert-True -Name 'CASE A (decision tree): semantic equivalence proven overall (branch tip tree also matches)' -Condition ([bool]$dtA.SemanticEquivalenceProven)

# CASE B (decision tree): reproduction mismatch -> unique authored content,
# manual resolution detected, semantic equivalence NOT proven.
$dtCommitsB = @(
    (New-RawExclusiveCommit 'M1' 'merge commit' 'NEW_MERGE_TREE' @((New-ParentInfo 'P1' 'P1_TREE' $true), (New-ParentInfo 'P2' 'P2_TREE' $true)))
)
$dtCommitsB[0] | Add-Member -NotePropertyName MergeReproducibility -NotePropertyValue (New-Repro $false 'DIFFERENT_TREE')
$dtB = Test-BranchRetirementSemantics -BranchHeadTreeSha 'NEW_MERGE_TREE' -TargetHeadTreeSha 'MAINHEAD_TREE' -MergeBaseTreeSha 'MERGEBASE_TREE' -ExclusiveCommits $dtCommitsB
Assert-True -Name 'CASE B (decision tree): reproduction mismatch is NOT automatically proven equivalent' -Condition (-not [bool]$dtB.SemanticEquivalenceProven)
Assert-True -Name 'CASE B (decision tree): manualMergeResolutionDetected is set with actual evidence' -Condition ([bool]$dtB.ExclusiveCommitEvidence[0].ManualMergeResolutionDetected)
Assert-Equal -Name 'CASE B (decision tree): evidence level is UNIQUE_AUTHORED_CONTENT' -Expected 'UNIQUE_AUTHORED_CONTENT' -Actual $dtB.ExclusiveCommitEvidence[0].RetirementEvidenceLevel

# CASE D: parents not both reachable from target -> BLOCKED regardless of
# what a (hypothetical) reproduction might say.
$dtCommitsD = @(
    (New-RawExclusiveCommit 'M1' 'merge commit' 'NEW_MERGE_TREE' @((New-ParentInfo 'P1' 'P1_TREE' $true), (New-ParentInfo 'P2' 'P2_TREE' $false)))
)
$dtCommitsD[0] | Add-Member -NotePropertyName MergeReproducibility -NotePropertyValue (New-Repro $true 'NEW_MERGE_TREE')
$dtD = Test-BranchRetirementSemantics -BranchHeadTreeSha 'NEW_MERGE_TREE' -TargetHeadTreeSha 'MAINHEAD_TREE' -MergeBaseTreeSha 'MERGEBASE_TREE' -ExclusiveCommits $dtCommitsD
Assert-True -Name 'CASE D: not-both-parents-reachable blocks retirement even when reproduction would otherwise match' -Condition (-not [bool]$dtD.SemanticEquivalenceProven)
Assert-True -Name 'CASE D: UniqueAuthoredContent is true (conservative) when parents are not both reachable' -Condition ([bool]$dtD.ExclusiveCommitEvidence[0].UniqueAuthoredContent)

# CASE E: every exclusive commit individually clears, but the branch TIP
# tree itself still doesn't match anything reachable -> BLOCKED.
$dtCommitsE = @(
    (New-RawExclusiveCommit 'M1' 'merge commit' 'MERGEBASE_TREE' @((New-ParentInfo 'P1' 'P1_TREE' $true), (New-ParentInfo 'P2' 'P2_TREE' $true)))
)
$dtE = Test-BranchRetirementSemantics -BranchHeadTreeSha 'SOME_OTHER_UNEXPLAINED_TREE' -TargetHeadTreeSha 'MAINHEAD_TREE' -MergeBaseTreeSha 'MERGEBASE_TREE' -ExclusiveCommits $dtCommitsE
Assert-True -Name 'CASE E: branch tip tree not represented in target history blocks retirement even if all exclusive commits individually clear' -Condition (-not [bool]$dtE.SemanticEquivalenceProven)

# CASE F: full pass -- all exclusive merges reproducible, tip represented,
# no unproven commits -> SemanticEquivalenceProven=true, and the
# classification layer still requires REVIEW_REQUIRED + destructive.
# Mirrors the REAL archi-semantic-core finding exactly: M1's two parents
# (an old develop tip and a point on main) are BOTH independently
# reachable from current main even though M1 itself is not, and its tree
# is a genuine 3-way-merge combination of the two (this is what actually
# happened with f1143b0/221b512/298ad8c -- confirmed live).
$dtCommitsF = @(
    (New-RawExclusiveCommit 'M1' 'merge: sync 1' 'INTERMEDIATE_TREE' @((New-ParentInfo 'OLDDEV' 'OLDDEV_TREE' $true), (New-ParentInfo 'MID_MAIN' 'MID_MAIN_TREE' $true))),
    (New-RawExclusiveCommit 'M2' 'merge: sync 2' 'MAINHEAD_TREE' @((New-ParentInfo 'M1' 'INTERMEDIATE_TREE' $false), (New-ParentInfo 'MID_MAIN2' 'MAINHEAD_TREE' $true)))
)
$dtCommitsF[0] | Add-Member -NotePropertyName MergeReproducibility -NotePropertyValue (New-Repro $true 'INTERMEDIATE_TREE')
$dtF = Test-BranchRetirementSemantics -BranchHeadTreeSha 'MAINHEAD_TREE' -TargetHeadTreeSha 'MAINHEAD_TREE' -MergeBaseTreeSha 'MERGEBASE_TREE' -ExclusiveCommits $dtCommitsF
Assert-True -Name 'CASE F: full retirement evidence -- SemanticEquivalenceProven=true' -Condition ([bool]$dtF.SemanticEquivalenceProven)
Assert-Equal -Name 'CASE F: overall RetirementEvidenceLevel is FULL_RETIREMENT_EVIDENCE' -Expected 'FULL_RETIREMENT_EVIDENCE' -Actual $dtF.RetirementEvidenceLevel
$dtFRow = Get-DevelopDeletionClassification -HasCommitsNotInMain $true -HasOpenPRsTargetingDevelop $false -WorkflowsReferenceDevelop $false -DependabotTargetsDevelop $false -DocsReferenceDevelop $false -SemanticEquivalenceProven $dtF.SemanticEquivalenceProven -BranchExclusiveCommitCount 2
Assert-Equal -Name 'CASE F: classification is REVIEW_REQUIRED (never SAFE_CHANGE), even at FULL_RETIREMENT_EVIDENCE' -Expected 'REVIEW_REQUIRED' -Actual $dtFRow.Classification
Assert-True -Name 'CASE F: row remains destructive' -Condition ([bool]$dtFRow.Destructive)

# CASE G: explicit approval is still required -- -ApproveSafeChanges can
# never approve branch.delete.develop, confirmed directly through the
# real approval engine (Approval.psm1), not just inferred from
# classification.
$caseGOps = @([PSCustomObject]@{ id = 'branch.delete.develop'; capability = 'Branch: delete develop'; classification = 'REVIEW_REQUIRED'; current = 'x'; desired = 'deleted'; rationale = 'full retirement evidence'; requiresManualChange = $false; destructive = $true; dependencies = @(); action = 'x'; approved = $false })
$null = Approve-PlanOperations -Operations $caseGOps -ApproveSafeChanges
Assert-True -Name 'CASE G: -ApproveSafeChanges alone does NOT approve branch.delete.develop even at REVIEW_REQUIRED/FULL_RETIREMENT_EVIDENCE' -Condition (-not [bool]$caseGOps[0].approved)
$null = Approve-PlanOperations -Operations $caseGOps -ApproveOperationIds @('branch.delete.develop')
Assert-True -Name 'CASE G: explicit -ApproveOperation branch.delete.develop still works' -Condition ([bool]$caseGOps[0].approved)

# CASE I: merge/reproducibility evidence changing WITHOUT the cheap SHA
# fields (BranchHeadSha/MergeBaseSha/BranchHeadTreeSha) changing must
# still block -- Apply.psm1 achieves this by re-deriving
# SemanticEquivalenceProven fresh (not just comparing SHAs) every time,
# confirmed here as a source-pattern assertion (already found also to
# functionally exercise cases E/F/G above).
Assert-True -Name 'CASE I: Apply.psm1 re-checks live ContentUniqueToBranch/SemanticEquivalenceProven fresh, not just the three SHA fields (protects against reproduction becoming unavailable/different even if no SHA moved)' -Condition ($applySource -match 'live re-verification now finds content unique to develop' -and $applySource -match 'live re-verification could not \(re-\)prove semantic equivalence')

# ---------------------------------------------------------------------------
Write-Host "24. Baseline hygiene: GitHub Pages / orphan environments (added for archi-semantic-core Phase 7, 2026-08-24)" -ForegroundColor Cyan

# --- Pure classification: Get-PagesHygieneClassification (Cases A-D) ---

# CASE A: absent -> COMPLIANT
$pagesA = Get-PagesHygieneClassification -EvidenceAvailable $true -Configured $false
Assert-Equal -Name 'CASE A: Pages absent -> COMPLIANT' -Expected 'COMPLIANT' -Actual $pagesA.Classification
Assert-Equal -Name 'CASE A: Pages hygiene row Category is BaselineHygiene' -Expected 'BaselineHygiene' -Actual $pagesA.Category
Assert-True -Name 'CASE A: Pages hygiene row is not destructive' -Condition (-not [bool]$pagesA.Destructive)

# CASE B: active (a current workflow deploys to it) -> COMPLIANT, never removed
$pagesB = Get-PagesHygieneClassification -EvidenceAvailable $true -Configured $true -WorkflowDeploysPages $true -WorkflowReferencesPages $true -HasActiveOrRecentBuild $true -HasAnyBuildHistory $true -HasCustomDomain $false -LiveUrlServing $true -DocReferencesPages $false
Assert-Equal -Name 'CASE B: Pages actively deployed by a current workflow -> COMPLIANT (presence with active use is not a defect)' -Expected 'COMPLIANT' -Actual $pagesB.Classification

# CASE B2: a bare custom domain alone (no workflow signal at all) is still a strong-enough active signal
$pagesB2 = Get-PagesHygieneClassification -EvidenceAvailable $true -Configured $true -WorkflowDeploysPages $false -WorkflowReferencesPages $false -HasActiveOrRecentBuild $false -HasAnyBuildHistory $false -HasCustomDomain $true -LiveUrlServing $false -DocReferencesPages $false
Assert-Equal -Name 'CASE B2: Pages with only a bound custom domain -> COMPLIANT, not removed' -Expected 'COMPLIANT' -Actual $pagesB2.Classification

# CASE C: strongly proven orphaned (every strict-bar signal negative) -> REMOVE_CANDIDATE, destructive
$pagesC = Get-PagesHygieneClassification -EvidenceAvailable $true -Configured $true -WorkflowDeploysPages $false -WorkflowReferencesPages $false -HasActiveOrRecentBuild $false -HasAnyBuildHistory $false -HasCustomDomain $false -LiveUrlServing $false -DocReferencesPages $false
Assert-Equal -Name 'CASE C: Pages configured with zero active/weak signals -> REMOVE_CANDIDATE (direct archi-semantic-core scenario)' -Expected 'REMOVE_CANDIDATE' -Actual $pagesC.Classification
Assert-True -Name 'CASE C: REMOVE_CANDIDATE Pages row is marked destructive' -Condition ([bool]$pagesC.Destructive)
Assert-Equal -Name 'CASE C: Pages hygiene operation id is hygiene.pages' -Expected 'hygiene.pages' -Actual $pagesC.Id

# Weak-signal-only (e.g. a stale, non-deploying workflow mention) is never forced to either extreme
$pagesWeak = Get-PagesHygieneClassification -EvidenceAvailable $true -Configured $true -WorkflowDeploysPages $false -WorkflowReferencesPages $true -HasActiveOrRecentBuild $false -HasAnyBuildHistory $false -HasCustomDomain $false -LiveUrlServing $false -DocReferencesPages $false
Assert-Equal -Name 'weak-signal-only Pages (workflow mentions it, does not deploy to it) -> REVIEW_REQUIRED, never forced to COMPLIANT or REMOVE_CANDIDATE' -Expected 'REVIEW_REQUIRED' -Actual $pagesWeak.Classification

# CASE D: incomplete evidence -> UNKNOWN, never treated as orphaned
$pagesD = Get-PagesHygieneClassification -EvidenceAvailable $false -Configured $true
Assert-Equal -Name 'CASE D: Pages configured but evidence incomplete -> UNKNOWN (never inferred as orphaned)' -Expected 'UNKNOWN' -Actual $pagesD.Classification
Assert-True -Name 'CASE D: UNKNOWN Pages row is never approvable' -Condition (-not (Test-OperationApprovable -Operation ([PSCustomObject]@{ classification = $pagesD.Classification })).Approvable)

# --- Pure classification: Get-EnvironmentHygieneClassification (Cases H-L) ---

# CASE H: absent -> COMPLIANT
$envH = Get-EnvironmentHygieneClassification -EnvironmentName 'github-pages' -EvidenceAvailable $true -Exists $false
Assert-Equal -Name 'CASE H: github-pages environment absent -> COMPLIANT' -Expected 'COMPLIANT' -Actual $envH.Classification
Assert-Equal -Name 'CASE H: environment hygiene row Category is BaselineHygiene' -Expected 'BaselineHygiene' -Actual $envH.Category

# CASE I: referenced by a current workflow -> COMPLIANT, no deletion
$envI = Get-EnvironmentHygieneClassification -EnvironmentName 'github-pages' -EvidenceAvailable $true -Exists $true -WorkflowReferencesEnvironment $true -HasActiveOrRecentDeployment $false -HasAnyDeploymentHistory $true -HasOperationalProtectionRule $false -HasSecretsOrVariables $false
Assert-Equal -Name 'CASE I: environment referenced by a current workflow -> COMPLIANT, not a removal candidate' -Expected 'COMPLIANT' -Actual $envI.Classification

# Active/recent deployment alone (no workflow reference discovered) is also a strong active signal -> COMPLIANT
$envActiveDeploy = Get-EnvironmentHygieneClassification -EnvironmentName 'github-pages' -EvidenceAvailable $true -Exists $true -WorkflowReferencesEnvironment $false -HasActiveOrRecentDeployment $true -HasAnyDeploymentHistory $true -HasOperationalProtectionRule $false -HasSecretsOrVariables $false
Assert-Equal -Name 'environment with an active/recent deployment -> COMPLIANT (real active use, not a hygiene defect)' -Expected 'COMPLIANT' -Actual $envActiveDeploy.Classification

# CASE J: strongly proven orphaned -> REMOVE_CANDIDATE, destructive
$envJ = Get-EnvironmentHygieneClassification -EnvironmentName 'github-pages' -EvidenceAvailable $true -Exists $true -WorkflowReferencesEnvironment $false -HasActiveOrRecentDeployment $false -HasAnyDeploymentHistory $false -HasOperationalProtectionRule $false -HasSecretsOrVariables $false
Assert-Equal -Name 'CASE J: environment unreferenced, no deployment history, no protection, no secrets/variables -> REMOVE_CANDIDATE' -Expected 'REMOVE_CANDIDATE' -Actual $envJ.Classification
Assert-True -Name 'CASE J: REMOVE_CANDIDATE environment row is marked destructive' -Condition ([bool]$envJ.Destructive)
Assert-Equal -Name 'CASE J: environment hygiene operation id is hygiene.environment.githubPages' -Expected 'hygiene.environment.githubPages' -Actual $envJ.Id

# CASE K: unreferenced by any workflow, but still carries secrets/variables -> REVIEW_REQUIRED, never silently discarded
$envK = Get-EnvironmentHygieneClassification -EnvironmentName 'github-pages' -EvidenceAvailable $true -Exists $true -WorkflowReferencesEnvironment $false -HasActiveOrRecentDeployment $false -HasAnyDeploymentHistory $false -HasOperationalProtectionRule $false -HasSecretsOrVariables $true
Assert-Equal -Name 'CASE K: workflow-unreferenced environment that still has a secret/variable -> REVIEW_REQUIRED, not REMOVE_CANDIDATE (never silently discard real configuration)' -Expected 'REVIEW_REQUIRED' -Actual $envK.Classification

# Same principle for an operational protection rule (wait timer / required reviewers / branch policy)
$envProtected = Get-EnvironmentHygieneClassification -EnvironmentName 'github-pages' -EvidenceAvailable $true -Exists $true -WorkflowReferencesEnvironment $false -HasActiveOrRecentDeployment $false -HasAnyDeploymentHistory $false -HasOperationalProtectionRule $true -HasSecretsOrVariables $false
Assert-Equal -Name 'workflow-unreferenced environment with an operational protection rule -> REVIEW_REQUIRED, not REMOVE_CANDIDATE' -Expected 'REVIEW_REQUIRED' -Actual $envProtected.Classification

# Evidence incomplete -> UNKNOWN, never orphaned
$envUnknown = Get-EnvironmentHygieneClassification -EnvironmentName 'github-pages' -EvidenceAvailable $false -Exists $true
Assert-Equal -Name 'environment exists but evidence incomplete -> UNKNOWN (never inferred as orphaned)' -Expected 'UNKNOWN' -Actual $envUnknown.Classification

# --- Approval engine: hygiene operations require explicit approval (Cases E / M) ---

$hygienePagesOp = [PSCustomObject]@{ id = 'hygiene.pages'; capability = 'Hygiene: GitHub Pages configuration'; classification = 'REMOVE_CANDIDATE'; current = 'orphaned'; desired = 'absent'; rationale = 'x'; requiresManualChange = $false; destructive = $true; dependencies = @(); action = 'x'; approved = $false }
$hygieneEnvOp = [PSCustomObject]@{ id = 'hygiene.environment.githubPages'; capability = 'Hygiene: github-pages environment'; classification = 'REMOVE_CANDIDATE'; current = 'orphaned'; desired = 'absent'; rationale = 'x'; requiresManualChange = $false; destructive = $true; dependencies = @(); action = 'x'; approved = $false }
$hygieneOps = @($hygienePagesOp, $hygieneEnvOp)
$null = Approve-PlanOperations -Operations $hygieneOps -ApproveSafeChanges
Assert-True -Name 'CASE E/M: -ApproveSafeChanges alone never approves hygiene.pages' -Condition (-not [bool]$hygienePagesOp.approved)
Assert-True -Name 'CASE E/M: -ApproveSafeChanges alone never approves hygiene.environment.githubPages' -Condition (-not [bool]$hygieneEnvOp.approved)
$null = Approve-PlanOperations -Operations $hygieneOps -ApproveOperationIds @('hygiene.pages', 'hygiene.environment.githubPages')
Assert-True -Name 'CASE E/M: explicit -ApproveOperation approves hygiene.pages' -Condition ([bool]$hygienePagesOp.approved)
Assert-True -Name 'CASE E/M: explicit -ApproveOperation approves hygiene.environment.githubPages' -Condition ([bool]$hygieneEnvOp.approved)

# --- Apply mutation-spec mapping ---

$pagesMutationOp = [PSCustomObject]@{ id = 'hygiene.pages'; capability = 'Hygiene: GitHub Pages configuration'; desired = 'absent' }
$pagesSpec = Get-OperationMutationSpec -Op $pagesMutationOp -Owner 'Continuous-DrivenArchitecture' -Repo 'archi-semantic-core'
Assert-True -Name 'hygiene.pages has a defined mutation mapping' -Condition ([bool]$pagesSpec.Defined)
Assert-Equal -Name 'hygiene.pages mutation is DELETE' -Expected 'DELETE' -Actual $pagesSpec.Method
Assert-Equal -Name 'hygiene.pages mutation targets repos/{owner}/{repo}/pages' -Expected 'repos/Continuous-DrivenArchitecture/archi-semantic-core/pages' -Actual $pagesSpec.Path

$envMutationOp = [PSCustomObject]@{ id = 'hygiene.environment.githubPages'; capability = 'Hygiene: github-pages environment'; desired = 'absent' }
$envSpec = Get-OperationMutationSpec -Op $envMutationOp -Owner 'Continuous-DrivenArchitecture' -Repo 'archi-semantic-core'
Assert-True -Name 'hygiene.environment.githubPages has a defined mutation mapping' -Condition ([bool]$envSpec.Defined)
Assert-Equal -Name 'hygiene.environment.githubPages mutation is DELETE' -Expected 'DELETE' -Actual $envSpec.Method
Assert-Equal -Name 'hygiene.environment.githubPages mutation targets repos/{owner}/{repo}/environments/github-pages' -Expected 'repos/Continuous-DrivenArchitecture/archi-semantic-core/environments/github-pages' -Actual $envSpec.Path

# CASE N: wrong identity -- Apply v1 refuses to delete any environment other than github-pages, by construction, regardless of what a hypothetical future classification pass might name.
$wrongEnvOp = [PSCustomObject]@{ id = 'hygiene.environment.someOtherEnv'; capability = 'Hygiene: some-other-env environment'; desired = 'absent' }
$wrongEnvSpec = Get-OperationMutationSpec -Op $wrongEnvOp -Owner 'Continuous-DrivenArchitecture' -Repo 'archi-semantic-core'
Assert-True -Name 'CASE N: Apply v1 refuses to define a mutation for any environment other than github-pages' -Condition (-not [bool]$wrongEnvSpec.Defined)
Assert-True -Name 'CASE N: the refusal reason explicitly names github-pages as the only supported target' -Condition ($wrongEnvSpec.Description -match 'github-pages')

# --- Test-OperationPreconditions: fail-closed staleness re-checks (Cases G / O) ---

function Get-WorkflowsInventory { param($Owner, $Repo) return @() }
$fpHygiene = [PSCustomObject]@{ Rulesets = @() }

# hygiene.pages: still absent at Apply time (404) -> nothing to re-verify, satisfied.
$script:MockRoutes = @{ '^repos/Owner/Repo/pages$' = { [PSCustomObject]@{ Success = $false; ErrorKind = 'NotFound' } }.GetNewClosure() }
$pgPc1 = Test-OperationPreconditions -Op $pagesMutationOp -Owner 'Owner' -Repo 'Repo' -StateFingerprint $fpHygiene
Assert-True -Name 'hygiene.pages: Pages already absent at Apply time -> precondition satisfied (nothing left to re-verify)' -Condition $pgPc1.Satisfied -Detail ($pgPc1.Reasons -join '; ')

# hygiene.pages: Pages reappeared with a bound custom domain -> STOP, no longer orphaned.
$script:MockRoutes = @{ '^repos/Owner/Repo/pages$' = { [PSCustomObject]@{ Success = $true; Data = [PSCustomObject]@{ cname = 'docs.example.com' } } }.GetNewClosure() }
$pgPc2 = Test-OperationPreconditions -Op $pagesMutationOp -Owner 'Owner' -Repo 'Repo' -StateFingerprint $fpHygiene
Assert-True -Name 'CASE G: hygiene.pages -- a custom domain bound since assessment blocks the deletion (fail closed on drift)' -Condition (-not $pgPc2.Satisfied)
Assert-True -Name 'CASE G: the block reason mentions the custom domain' -Condition (@($pgPc2.Reasons -match 'custom domain').Count -gt 0)

# hygiene.pages: a workflow now deploys to Pages -> STOP.
$script:MockRoutes = @{ '^repos/Owner/Repo/pages$' = { [PSCustomObject]@{ Success = $true; Data = [PSCustomObject]@{ cname = $null } } }.GetNewClosure() }
function Get-WorkflowsInventory { param($Owner, $Repo) return @([PSCustomObject]@{ File = 'deploy-docs.yml'; ReferencesPagesDeployment = $true }) }
$pgPc3 = Test-OperationPreconditions -Op $pagesMutationOp -Owner 'Owner' -Repo 'Repo' -StateFingerprint $fpHygiene
Assert-True -Name 'CASE G: hygiene.pages -- a workflow now deploying to Pages blocks the deletion' -Condition (-not $pgPc3.Satisfied)
Assert-True -Name 'CASE G: the block reason names the deploying workflow file' -Condition (@($pgPc3.Reasons -match 'deploy-docs\.yml').Count -gt 0)
function Get-WorkflowsInventory { param($Owner, $Repo) return @() }

# hygiene.environment.githubPages: refuses to even re-verify a non-github-pages target.
$wrongEnvPc = Test-OperationPreconditions -Op $wrongEnvOp -Owner 'Owner' -Repo 'Repo' -StateFingerprint $fpHygiene
Assert-True -Name 'hygiene.environment.*: precondition check itself refuses any target other than github-pages' -Condition (-not $wrongEnvPc.Satisfied)

# hygiene.environment.githubPages: Pages configuration still exists -> STOP (dependency order, section 6).
$script:MockRoutes = @{ '^repos/Owner/Repo/pages$' = { [PSCustomObject]@{ Success = $true; Data = [PSCustomObject]@{ cname = $null } } }.GetNewClosure() }
$envPc1 = Test-OperationPreconditions -Op $envMutationOp -Owner 'Owner' -Repo 'Repo' -StateFingerprint $fpHygiene
Assert-True -Name 'CASE O: hygiene.environment.githubPages -- Pages still exists blocks environment deletion (dependency order: Pages must be removed first)' -Condition (-not $envPc1.Satisfied)
Assert-True -Name 'CASE O: the block reason names dependency order explicitly' -Condition (@($envPc1.Reasons -match 'dependency order').Count -gt 0)

# hygiene.environment.githubPages: Pages already removed IN THIS SAME approved plan (prior op) -> dependency satisfied even though a stale mock still reports it present would otherwise block; verified instead via the more realistic path below (Pages genuinely absent).
$script:MockRoutes = @{ '^repos/Owner/Repo/pages$' = { [PSCustomObject]@{ Success = $false; ErrorKind = 'NotFound' } }.GetNewClosure() }
$envPc2 = Test-OperationPreconditions -Op $envMutationOp -Owner 'Owner' -Repo 'Repo' -StateFingerprint $fpHygiene
Assert-True -Name 'hygiene.environment.githubPages: Pages genuinely absent and no workflow references the environment -> precondition satisfied' -Condition $envPc2.Satisfied -Detail ($envPc2.Reasons -join '; ')

# hygiene.environment.githubPages: a workflow now references the environment -> STOP.
function Get-WorkflowsInventory { param($Owner, $Repo) return @([PSCustomObject]@{ File = 'deploy.yml'; Text = "environment:`n  name: github-pages" }) }
$envPc3 = Test-OperationPreconditions -Op $envMutationOp -Owner 'Owner' -Repo 'Repo' -StateFingerprint $fpHygiene
Assert-True -Name 'CASE O: hygiene.environment.githubPages -- a workflow now referencing the environment blocks its deletion' -Condition (-not $envPc3.Satisfied)
function Get-WorkflowsInventory { param($Owner, $Repo) return @() }

# --- DryRun: zero mutations for a hygiene operation (Case F) ---

function Get-BranchComparison { param($Owner, $Repo, $Base, $Head) return [PSCustomObject]@{ Available = $true; AheadBy = 0; BehindBy = 0; Status = 'identical' } }
function Get-OpenPullRequestsByBase { param($Owner, $Repo) return @() }
function Get-DependabotConfigText { param($Owner, $Repo) return $null }
$script:MockRoutes = @{
    '^repos/Continuous-DrivenArchitecture/mock-repo$'           = { [PSCustomObject]@{ Success = $true; Data = [PSCustomObject]@{ default_branch = 'main'; archived = $false; fork = $false; permissions = [PSCustomObject]@{ admin = $true } } } }.GetNewClosure()
    '^repos/Continuous-DrivenArchitecture/mock-repo/branches\?' = { [PSCustomObject]@{ Success = $true; Data = @([PSCustomObject]@{ name = 'main'; commit = [PSCustomObject]@{ sha = ('a' * 40) } }) } }.GetNewClosure()
    '^repos/Continuous-DrivenArchitecture/mock-repo/pages$'     = { [PSCustomObject]@{ Success = $false; ErrorKind = 'NotFound' } }.GetNewClosure()
}
$hygieneDryPlan = New-MockApprovedPlan
$hygieneDryPlan.operations = @([PSCustomObject]@{ id = 'hygiene.pages'; capability = 'Hygiene: GitHub Pages configuration'; classification = 'REMOVE_CANDIDATE'; current = 'orphaned'; desired = 'absent'; rationale = 'x'; requiresManualChange = $false; destructive = $true; dependencies = @(); action = 'x'; approved = $true })
$hygieneDryPlan.planHash = Get-PlanHash -Repository $hygieneDryPlan.repository -Profile $hygieneDryPlan.profile -Operations $hygieneDryPlan.operations
$script:MutationCallLog.Clear()
$hygieneDryExec = Invoke-ApprovedPlan -ApprovedPlan $hygieneDryPlan -Owner 'Continuous-DrivenArchitecture' -Repo 'mock-repo' -DryRun
Assert-True -Name 'CASE F: -DryRun reports WOULD_APPLY for hygiene.pages (destructive, still simulated, never executed)' -Condition (@($hygieneDryExec.Results | Where-Object { $_.Id -eq 'hygiene.pages' -and $_.Status -eq 'WOULD_APPLY' }).Count -eq 1)
Assert-True -Name 'CASE F: hygiene.pages -DryRun marks the DryRun detail as a DESTRUCTIVE OPERATION' -Condition (@($hygieneDryExec.Results | Where-Object { $_.Id -eq 'hygiene.pages' })[0].Detail -match 'DESTRUCTIVE OPERATION')
Assert-True -Name 'CASE F: -DryRun on hygiene.pages performs zero mutation calls' -Condition ($script:MutationCallLog.Count -eq 0)

# --- Get-FullCdaComplianceResult: FullCompliance cannot be true while a mandatory hygiene gap remains ---

function New-ProfileCompliantRows {
    return @(
        (New-CapabilityRow -Capability 'Default branch' -Current 'main' -Target 'main' -Classification COMPLIANT -Rationale 'match')
        (New-CapabilityRow -Capability 'Secret scanning' -Current $true -Target $true -Classification COMPLIANT -Rationale 'match')
    )
}

$allCompliantRows = @(New-ProfileCompliantRows) + @(
    (Get-PagesHygieneClassification -EvidenceAvailable $true -Configured $false)
    (Get-EnvironmentHygieneClassification -EnvironmentName 'github-pages' -EvidenceAvailable $true -Exists $false)
)
$fullCdaPass = Get-FullCdaComplianceResult -CapabilityRows $allCompliantRows
Assert-Equal -Name 'every profile row AND every hygiene row COMPLIANT -> Result PASS' -Expected 'PASS' -Actual $fullCdaPass.Result
Assert-True -Name 'PASS: ProfileCompliance is true' -Condition $fullCdaPass.ProfileCompliance
Assert-True -Name 'PASS: BaselineHygieneCompliance is true' -Condition $fullCdaPass.BaselineHygieneCompliance
Assert-Equal -Name 'PASS: zero remaining gaps' -Expected 0 -Actual $fullCdaPass.RemainingGaps.Count

# THE regression this whole task exists to fix: every PROFILE row compliant
# (the old 24/24 signal a prior version of this tool would have reported as
# "Full CDA compliant"), but ONE baseline-hygiene row is an unresolved
# REMOVE_CANDIDATE (an orphaned github-pages environment) -- overall result
# must NOT be PASS.
$orphanEnvRow = Get-EnvironmentHygieneClassification -EnvironmentName 'github-pages' -EvidenceAvailable $true -Exists $true -WorkflowReferencesEnvironment $false -HasActiveOrRecentDeployment $false -HasAnyDeploymentHistory $false -HasOperationalProtectionRule $false -HasSecretsOrVariables $false
$rowsWithOrphanEnv = @(New-ProfileCompliantRows) + @(
    (Get-PagesHygieneClassification -EvidenceAvailable $true -Configured $false)
    $orphanEnvRow
)
$fullCdaWithGap = Get-FullCdaComplianceResult -CapabilityRows $rowsWithOrphanEnv
Assert-True -Name 'REGRESSION GUARD: every profile row COMPLIANT does NOT by itself make Result PASS when a hygiene gap remains' -Condition ($fullCdaWithGap.Result -ne 'PASS')
Assert-True -Name 'REGRESSION GUARD: ProfileCompliance is still reported true (the profile itself really is compliant)' -Condition $fullCdaWithGap.ProfileCompliance
Assert-True -Name 'REGRESSION GUARD: BaselineHygieneCompliance is reported false' -Condition (-not $fullCdaWithGap.BaselineHygieneCompliance)
Assert-True -Name 'REGRESSION GUARD: the remaining gap is reported with Category=BaselineHygiene' -Condition (@($fullCdaWithGap.RemainingGaps | Where-Object { $_.Category -eq 'BaselineHygiene' -and $_.Classification -eq 'REMOVE_CANDIDATE' }).Count -eq 1)

# A BLOCKED or UNKNOWN hygiene row forces Result=BLOCKED specifically (distinct from a merely-unresolved PARTIAL).
$unknownEnvRow = Get-EnvironmentHygieneClassification -EnvironmentName 'github-pages' -EvidenceAvailable $false -Exists $true
$rowsWithUnknownHygiene = @(New-ProfileCompliantRows) + @(
    (Get-PagesHygieneClassification -EvidenceAvailable $true -Configured $false)
    $unknownEnvRow
)
$fullCdaUnknown = Get-FullCdaComplianceResult -CapabilityRows $rowsWithUnknownHygiene
Assert-Equal -Name 'an UNKNOWN hygiene row forces Result=BLOCKED (never PASS, never silently treated as resolved)' -Expected 'BLOCKED' -Actual $fullCdaUnknown.Result

# --- Verification.psm1: read-back for hygiene.pages / hygiene.environment.* ---
# (regression found live during the real archi-semantic-core Phase 7 Apply:
# without these mappings, Test-OperationApplied fell through to its default
# "no read-back mapping defined" case, reporting Matches=$null (UNVERIFIABLE)
# for an operation that had genuinely succeeded -- which in turn made
# apply-plan.ps1 report "PLAN APPLIED SUCCESSFULLY: False" despite the live
# HTTP 204 and a confirmed-absent live re-read. Fixed by giving both ids a
# real read-back mapping, same discipline as branch.delete.develop/secret.*.)

$pagesVerifyOp = [PSCustomObject]@{ id = 'hygiene.pages'; capability = 'Hygiene: GitHub Pages configuration'; desired = 'absent' }
$script:MockRoutes = @{ '^repos/Owner/Repo/pages$' = { [PSCustomObject]@{ Success = $false; ErrorKind = 'NotFound' } }.GetNewClosure() }
$pagesRb1 = Test-OperationApplied -Op $pagesVerifyOp -Owner 'Owner' -Repo 'Repo'
Assert-Equal -Name 'hygiene.pages read-back: 404 on GET /pages -> Observed=absent' -Expected 'absent' -Actual $pagesRb1.Observed
Assert-True -Name 'hygiene.pages read-back: 404 -> Matches=true (VERIFIED, not UNVERIFIABLE)' -Condition ($pagesRb1.Matches -eq $true)

$script:MockRoutes = @{ '^repos/Owner/Repo/pages$' = { [PSCustomObject]@{ Success = $true; Data = [PSCustomObject]@{ build_type = 'workflow' } } }.GetNewClosure() }
$pagesRb2 = Test-OperationApplied -Op $pagesVerifyOp -Owner 'Owner' -Repo 'Repo'
Assert-True -Name 'hygiene.pages read-back: still configured (200) -> Matches=false (MISMATCH, deletion did not take)' -Condition ($pagesRb2.Matches -eq $false)

$script:MockRoutes = @{ '^repos/Owner/Repo/pages$' = { [PSCustomObject]@{ Success = $false; ErrorKind = 'Forbidden' } }.GetNewClosure() }
$pagesRb3 = Test-OperationApplied -Op $pagesVerifyOp -Owner 'Owner' -Repo 'Repo'
Assert-True -Name 'hygiene.pages read-back: a 403 (not a 404) is never treated as proof of absence -> Matches=$null (UNVERIFIABLE)' -Condition ($null -eq $pagesRb3.Matches)

$envVerifyOp = [PSCustomObject]@{ id = 'hygiene.environment.githubPages'; capability = 'Hygiene: github-pages environment'; desired = 'absent' }
$script:MockRoutes = @{ '^repos/Owner/Repo/environments/github-pages$' = { [PSCustomObject]@{ Success = $false; ErrorKind = 'NotFound' } }.GetNewClosure() }
$envRb1 = Test-OperationApplied -Op $envVerifyOp -Owner 'Owner' -Repo 'Repo'
Assert-Equal -Name 'hygiene.environment.githubPages read-back: 404 -> Observed=absent' -Expected 'absent' -Actual $envRb1.Observed
Assert-True -Name 'hygiene.environment.githubPages read-back: 404 -> Matches=true (VERIFIED)' -Condition ($envRb1.Matches -eq $true)

$script:MockRoutes = @{ '^repos/Owner/Repo/environments/github-pages$' = { [PSCustomObject]@{ Success = $true; Data = [PSCustomObject]@{ name = 'github-pages' } } }.GetNewClosure() }
$envRb2 = Test-OperationApplied -Op $envVerifyOp -Owner 'Owner' -Repo 'Repo'
Assert-True -Name 'hygiene.environment.githubPages read-back: environment still exists (200) -> Matches=false (MISMATCH)' -Condition ($envRb2.Matches -eq $false)

# ---------------------------------------------------------------------------
Write-Host "25. Provisioner: profile parse, diff/planning logic, exit codes (migrated from the provisioner's own suite)" -ForegroundColor Cyan

$provProfilePath = Join-Path $root 'profiles\npm-library.json'
# Get-EffectiveCdaProfile, not the raw Get-CdaProfile: npm-library.json is
# now a thin overlay on profiles/repository-baseline.json (see
# docs/profiles.md) -- a raw parse would not see repositorySettings/
# actions/ruleset at all, since this profile inherits them rather than
# restating them.
$provProfileResult = Get-EffectiveCdaProfile -Path $provProfilePath
Assert-True -Name 'provisioner: real (effective, composed) profile JSON parses via Get-EffectiveCdaProfile' -Condition $provProfileResult.Success -Detail "$($provProfileResult.Error)"
$provProfileObj = $provProfileResult.Profile
if ($provProfileObj) {
    Assert-Equal -Name 'provisioner: profileName' -Expected 'cda-npm-library-v1' -Actual $provProfileObj.profileName
    Assert-Equal -Name 'provisioner: schemaVersion present' -Expected '1.0' -Actual $provProfileObj.schemaVersion
    Assert-True -Name 'provisioner: has repositorySettings' -Condition ($null -ne $provProfileObj.repositorySettings)
    Assert-True -Name 'provisioner: has actions' -Condition ($null -ne $provProfileObj.actions)
    Assert-True -Name 'provisioner: has security' -Condition ($null -ne $provProfileObj.security)
    Assert-True -Name 'provisioner: has ruleset' -Condition ($null -ne $provProfileObj.ruleset)
    Assert-Equal -Name 'provisioner: required check context' -Expected 'ci-required' -Actual $provProfileObj.ruleset.requiredStatusChecks.context
    Assert-Equal -Name 'provisioner: bypass actors empty' -Expected 0 -Actual @($provProfileObj.ruleset.bypassActors).Count
    Assert-Equal -Name 'provisioner: allowed merge methods = squash only' -Expected 'squash' -Actual (@($provProfileObj.ruleset.pullRequest.allowedMergeMethods) -join ',')
}

$provMatchItem = New-PlanItem -Capability 'x' -Current $true -Desired $true
Assert-Equal -Name 'provisioner: matching values -> Action NONE' -Expected 'NONE' -Actual $provMatchItem.Action
Assert-Equal -Name 'provisioner: matching values -> Result PASS' -Expected 'PASS' -Actual $provMatchItem.Result
$provDiffItem = New-PlanItem -Capability 'x' -Current $true -Desired $false
Assert-Equal -Name 'provisioner: differing values -> Action UPDATE' -Expected 'UPDATE' -Actual $provDiffItem.Action
Assert-Equal -Name 'provisioner: differing values -> Result DRIFT' -Expected 'DRIFT' -Actual $provDiffItem.Result
$provNaItem = New-PlanItem -Capability 'x' -Current 'irrelevant' -Desired 'y' -Applicable $false
Assert-Equal -Name 'provisioner: not applicable -> Action SKIP' -Expected 'SKIP' -Actual $provNaItem.Action
$provUnknownItem = New-PlanItem -Capability 'x' -Current $null -Desired 'y'
Assert-Equal -Name 'provisioner: null current -> Result UNKNOWN' -Expected 'UNKNOWN' -Actual $provUnknownItem.Result

Assert-True -Name 'provisioner: Compare-StringArray order-independent match' -Condition (Compare-StringArray -A @('a', 'b', 'c') -B @('c', 'a', 'b'))
Assert-True -Name 'provisioner: Compare-StringArray detects real difference' -Condition (-not (Compare-StringArray -A @('a', 'b') -B @('a', 'c')))

# Ruleset diff, against a fixture shaped like a real GitHub ruleset API response.
$provCurrentRulesetDetail = [PSCustomObject]@{
    enforcement   = 'active'
    bypass_actors = @()
    rules         = @(
        [PSCustomObject]@{ type = 'pull_request'; parameters = [PSCustomObject]@{ required_approving_review_count = 0; dismiss_stale_reviews_on_push = $false; require_code_owner_review = $false; required_review_thread_resolution = $true; allowed_merge_methods = @('squash') } },
        [PSCustomObject]@{ type = 'required_status_checks'; parameters = [PSCustomObject]@{ strict_required_status_checks_policy = $true; required_status_checks = @([PSCustomObject]@{ context = 'ci-required' }) } },
        [PSCustomObject]@{ type = 'non_fast_forward'; parameters = $null },
        [PSCustomObject]@{ type = 'deletion'; parameters = $null }
    )
}
if ($provProfileObj) {
    $provDesiredWithCheck = New-DesiredRulesetBody -CdaProfile $provProfileObj -IncludeRequiredStatusChecks $true
    Assert-True -Name 'provisioner: ruleset matches when identical to desired (with check)' -Condition (Compare-RulesetToDesired -CurrentDetail $provCurrentRulesetDetail -DesiredBody $provDesiredWithCheck)
    $provDesiredWithoutCheck = New-DesiredRulesetBody -CdaProfile $provProfileObj -IncludeRequiredStatusChecks $false
    Assert-True -Name 'provisioner: a check current has vs. desired without -> DRIFT (Bootstrap re-run must never silently drop an already-wired check)' -Condition (-not (Compare-RulesetToDesired -CurrentDetail $provCurrentRulesetDetail -DesiredBody $provDesiredWithoutCheck))
    $provBypassedDetail = $provCurrentRulesetDetail | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $provBypassedDetail.bypass_actors = @([PSCustomObject]@{ actor_id = 12345 })
    Assert-True -Name 'provisioner: ruleset diff detects a non-empty bypass_actors list' -Condition (-not (Compare-RulesetToDesired -CurrentDetail $provBypassedDetail -DesiredBody $provDesiredWithCheck))
}

Assert-Equal -Name 'provisioner: Verify, all PASS -> exit 0' -Expected 0 -Actual (Get-ProvisioningExitCode -Plan @([PSCustomObject]@{ Action = 'NONE'; Result = 'PASS' }) -Mode 'Verify' -DryRun $false)
Assert-Equal -Name 'provisioner: Verify with drift -> exit 1' -Expected 1 -Actual (Get-ProvisioningExitCode -Plan @([PSCustomObject]@{ Action = 'UPDATE'; Result = 'DRIFT' }) -Mode 'Verify' -DryRun $false)
Assert-Equal -Name 'provisioner: Finalize blocked (FAIL_SAFE) -> exit 2' -Expected 2 -Actual (Get-ProvisioningExitCode -Plan @([PSCustomObject]@{ Capability = 'Protect main (ruleset)'; Action = 'FAIL_SAFE'; Result = 'PENDING' }) -Mode 'Finalize' -DryRun $false)
Assert-Equal -Name 'provisioner: an UNKNOWN capability -> exit 3' -Expected 3 -Actual (Get-ProvisioningExitCode -Plan @([PSCustomObject]@{ Action = 'SKIP'; Result = 'UNKNOWN' }) -Mode 'Bootstrap' -DryRun $false)
Assert-Equal -Name 'provisioner: a failed mutation -> exit 1' -Expected 1 -Actual (Get-ProvisioningExitCode -Plan @([PSCustomObject]@{ Action = 'UPDATE'; Result = 'FAIL' }) -Mode 'Bootstrap' -DryRun $false)
Assert-Equal -Name 'provisioner: Bootstrap, everything applied successfully -> exit 0' -Expected 0 -Actual (Get-ProvisioningExitCode -Plan @([PSCustomObject]@{ Action = 'UPDATE'; Result = 'PASS' }, [PSCustomObject]@{ Action = 'NONE'; Result = 'PASS' }) -Mode 'Bootstrap' -DryRun $false)

# ---------------------------------------------------------------------------
Write-Host "26. Provisioner: -Mode parameter validation (no network reached)" -ForegroundColor Cyan
try {
    & (Join-Path $commandsDir 'provision-npm-library.ps1') -Repository 'Continuous-DrivenArchitecture/whatever' -Mode 'NotARealMode' -DryRun 2>$null
    Assert-True -Name 'invalid -Mode value is rejected' -Condition $false -Detail '(script did not throw)'
}
catch {
    Assert-True -Name 'invalid -Mode value is rejected' -Condition ($_.Exception.Message -match 'NotARealMode' -or $_.CategoryInfo.Category -eq 'InvalidData' -or $_.FullyQualifiedErrorId -match 'ParameterArgumentValidationError')
}

# ---------------------------------------------------------------------------
Write-Host "27. Common core: fork handling (the one deliberate difference between lifecycle paths)" -ForegroundColor Cyan

# Test-ForkPolicy is the pure decision Test-RepositoryEligibility applies
# internally -- tested directly (see its own header comment for why: a
# global override of Invoke-ReadOnlyGitHub cannot reach
# Test-RepositoryEligibility's internal call, since Validation.psm1
# nest-imports ReadOnlyGitHub.psm1 itself).
$forkNoReject = Test-ForkPolicy -IsFork $true
Assert-True -Name 'without -RejectForks (adopter default): a fork is eligible' -Condition $forkNoReject.Eligible
$forkRejected = Test-ForkPolicy -IsFork $true -RejectForks
Assert-True -Name 'with -RejectForks (provisioner default): a fork is ineligible unless -AllowFork' -Condition (-not $forkRejected.Eligible)
$forkRejectedButAllowed = Test-ForkPolicy -IsFork $true -RejectForks -AllowFork
Assert-True -Name 'with -RejectForks -AllowFork: a fork is eligible again (explicit override)' -Condition $forkRejectedButAllowed.Eligible
$nonForkAlwaysEligible = Test-ForkPolicy -IsFork $false -RejectForks
Assert-True -Name 'a non-fork is always eligible regardless of -RejectForks' -Condition $nonForkAlwaysEligible.Eligible

$wrongOrg = Test-RepositoryEligibility -Owner 'SomeOtherOrg' -Repo 'x'
Assert-True -Name 'wrong owner is ineligible before any network call is even needed' -Condition (-not $wrongOrg.Eligible)

# Source-pattern check that Test-RepositoryEligibility actually WIRES
# Test-ForkPolicy's result into its own Eligible decision (the pure-function
# test above proves the policy is correct in isolation; this proves it is
# actually consulted).
$validationSource = Get-Content -LiteralPath (Join-Path $commonRepo 'Validation.psm1') -Raw
Assert-True -Name 'Test-RepositoryEligibility calls Test-ForkPolicy and returns Eligible=false when it says so' -Condition ($validationSource -match 'Test-ForkPolicy -IsFork \$isFork -RejectForks:\$RejectForks -AllowFork:\$AllowFork' -and $validationSource -match 'if \(-not \$forkPolicy\.Eligible\)')

# ---------------------------------------------------------------------------
Write-Host "28. Common core: pure-transform / discovery-shape tests" -ForegroundColor Cyan

$overviewFixture = Get-RepositoryOverview -RepoData ([PSCustomObject]@{
        visibility = 'public'; default_branch = 'main'; allow_squash_merge = $true; allow_merge_commit = $false; allow_rebase_merge = $false; allow_auto_merge = $false
        delete_branch_on_merge = $true; is_template = $false; has_pages = $false
    })
Assert-Equal -Name 'Get-RepositoryOverview: DefaultBranch' -Expected 'main' -Actual $overviewFixture.DefaultBranch
Assert-Equal -Name 'Get-RepositoryOverview: SecretScanning is null when security_and_analysis is entirely absent (never throws under strict mode)' -Expected $null -Actual $overviewFixture.SecretScanning

$badProfileResult = Get-CdaProfile -Path (Join-Path $fixturesDir 'does-not-exist.json')
Assert-True -Name 'Get-CdaProfile: a missing file reports Success=false with a clear error, never throws' -Condition (-not $badProfileResult.Success -and $badProfileResult.Error -match 'not found')

$nameFormatFixture = Test-RepositoryNameFormat -Repository 'Continuous-DrivenArchitecture/example-repo'
Assert-True -Name 'Test-RepositoryNameFormat (common): accepts well-formed owner/repo' -Condition $nameFormatFixture.Valid
Assert-Equal -Name 'Test-RepositoryNameFormat (common): extracts owner' -Expected 'Continuous-DrivenArchitecture' -Actual $nameFormatFixture.Owner

# ---------------------------------------------------------------------------
Write-Host "29. Destructive-operations registry: independent safety property, checked across BOTH lifecycle paths" -ForegroundColor Cyan

# Section 15's own guard (Approve-PlanOperations) already proves -ApproveSafeChanges
# can never approve a destructive operation. This section proves the
# INVENTORY of known destructive operation ids is what the safety model
# actually expects -- i.e. that the classification functions which
# generate them still mark Destructive=true, so that guard has something
# real to check. A regression here (a classifier silently dropping
# -Destructive) would otherwise only be caught indirectly.
$destructiveCapabilityChecks = @(
    @{ Name = 'Branch: delete develop (BLOCKED)'; Row = (Get-DevelopDeletionClassification -HasCommitsNotInMain $true -HasOpenPRsTargetingDevelop $false -WorkflowsReferenceDevelop $false -DependabotTargetsDevelop $false -DocsReferenceDevelop $false) }
    @{ Name = 'Branch: delete develop (SAFE_CHANGE)'; Row = (Get-DevelopDeletionClassification -HasCommitsNotInMain $false -HasOpenPRsTargetingDevelop $false -WorkflowsReferenceDevelop $false -DependabotTargetsDevelop $false -DocsReferenceDevelop $false) }
    @{ Name = 'Secret: legacy sentinel (REMOVE_CANDIDATE)'; Row = (Get-SecretClassification -SecretName 'RELEASE_APP_ID' -ReferencedByWorkflows @('release.yml') -ReleaseWorkflowUsesSentinelPattern $true) }
    @{ Name = 'Hygiene: Pages (REMOVE_CANDIDATE)'; Row = (Get-PagesHygieneClassification -EvidenceAvailable $true -Configured $true -WorkflowDeploysPages $false -WorkflowReferencesPages $false -HasActiveOrRecentBuild $false -HasAnyBuildHistory $false -HasCustomDomain $false -LiveUrlServing $false -DocReferencesPages $false) }
    @{ Name = 'Hygiene: environment (REMOVE_CANDIDATE)'; Row = (Get-EnvironmentHygieneClassification -EnvironmentName 'github-pages' -EvidenceAvailable $true -Exists $true -WorkflowReferencesEnvironment $false -HasActiveOrRecentDeployment $false -HasAnyDeploymentHistory $false -HasOperationalProtectionRule $false -HasSecretsOrVariables $false) }
)
foreach ($check in $destructiveCapabilityChecks) {
    Assert-True -Name "destructive registry: $($check.Name) is marked Destructive=true" -Condition ([bool]$check.Row.Destructive)
}
$nonDestructiveCheck = Get-BooleanToggleClassification -Capability 'Secret scanning' -Applicable $true -Current $false -TargetOn $true
Assert-True -Name 'destructive registry: an ordinary SAFE_CHANGE settings toggle is NOT marked destructive (registry is precise, not overbroad)' -Condition (-not [bool]$nonDestructiveCheck.Destructive)

# ---------------------------------------------------------------------------
Write-Host "30. JSON Schema validation (lightweight local-`$ref validator; no external dependency)" -ForegroundColor Cyan

function Resolve-SchemaRef {
    param($Schema, $RootSchema)
    if ($Schema.PSObject.Properties['$ref']) {
        $ref = "$($Schema.'$ref')"
        if ($ref -match '^#/\$defs/(.+)$') { return $RootSchema.'$defs'.($Matches[1]) }
        throw "unsupported `$ref (local #/`$defs/name only): $ref"
    }
    return $Schema
}
function Test-JsonSchemaLite {
    param($Value, $Schema, $RootSchema, [string]$Path = '$')
    $errs = New-Object System.Collections.Generic.List[string]
    $s = Resolve-SchemaRef -Schema $Schema -RootSchema $RootSchema

    if ($s.PSObject.Properties['const'] -and "$Value" -ne "$($s.const)") { $errs.Add("${Path}: expected const '$($s.const)', got '$Value'") }
    if ($s.PSObject.Properties['enum']) {
        $allowed = @($s.enum | ForEach-Object { "$_" })
        if ($allowed -notcontains "$Value") { $errs.Add("${Path}: '$Value' not in enum [$($allowed -join ', ')]") }
    }
    if ($s.PSObject.Properties['pattern'] -and "$Value" -notmatch $s.pattern) { $errs.Add("${Path}: '$Value' does not match pattern '$($s.pattern)'") }
    if ($s.PSObject.Properties['type']) {
        $types = @($s.type)
        $isArrayLike = ($Value -is [array]) -or ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string] -and $Value -isnot [PSCustomObject] -and $Value -isnot [System.Collections.IDictionary])
        $ok = $false
        foreach ($t in $types) {
            switch ($t) {
                'object' { if ($Value -is [PSCustomObject] -or $Value -is [System.Collections.IDictionary]) { $ok = $true } }
                'array' { if ($isArrayLike) { $ok = $true } }
                'string' { if ($Value -is [string]) { $ok = $true } }
                'boolean' { if ($Value -is [bool]) { $ok = $true } }
                'integer' { if ($Value -is [int] -or $Value -is [long] -or ($Value -is [double] -and $Value -eq [math]::Floor($Value))) { $ok = $true } }
                'null' { if ($null -eq $Value) { $ok = $true } }
            }
        }
        if (-not $ok) { $errs.Add("${Path}: type mismatch, expected [$($types -join ',')], got $(if ($null -eq $Value) { 'null' } else { $Value.GetType().Name })") }
    }
    if ($null -ne $Value -and $s.PSObject.Properties['required']) {
        foreach ($req in @($s.required)) {
            if (-not $Value.PSObject.Properties[$req]) { $errs.Add("${Path}: missing required property '$req'") }
        }
    }
    if ($null -ne $Value -and $s.PSObject.Properties['properties']) {
        foreach ($propName in $s.properties.PSObject.Properties.Name) {
            if ($Value.PSObject.Properties[$propName]) {
                foreach ($e in (Test-JsonSchemaLite -Value $Value.$propName -Schema $s.properties.$propName -RootSchema $RootSchema -Path "$Path.$propName")) { $errs.Add($e) }
            }
        }
    }
    if ($null -ne $Value -and $s.PSObject.Properties['items']) {
        $i = 0
        foreach ($item in @($Value)) {
            foreach ($e in (Test-JsonSchemaLite -Value $item -Schema $s.items -RootSchema $RootSchema -Path "$Path[$i]")) { $errs.Add($e) }
            $i++
        }
    }
    return $errs.ToArray()
}

# NOTE (the exact, oft-repeated lesson this whole codebase's own comments
# document elsewhere): Test-JsonSchemaLite's `return $errs.ToArray()` on a
# ZERO-error result collapses to $null when captured by a bare
# `$x = Function-Call` assignment -- every capture below is wrapped in
# @(...) for this reason (confirmed empirically while writing this very
# section: the "PASS" case, zero errors, was the one that crashed).

$repoProfileSchema = Get-Content -LiteralPath (Join-Path $schemasDir 'repository-profile.schema.json') -Raw | ConvertFrom-Json

# profiles/repository-baseline.json is a complete, standalone profile
# (nothing to compose) -- validated directly.
$realBaselineForSchema = Get-Content -LiteralPath (Join-Path $root 'profiles\repository-baseline.json') -Raw | ConvertFrom-Json
$baselineSchemaErrors = @(Test-JsonSchemaLite -Value $realBaselineForSchema -Schema $repoProfileSchema -RootSchema $repoProfileSchema)
Assert-True -Name 'profiles/repository-baseline.json validates against repository-profile.schema.json' -Condition ($baselineSchemaErrors.Count -eq 0) -Detail ($baselineSchemaErrors -join '; ')

# profiles/npm-library.json is a thin OVERLAY (see docs/profiles.md) --
# only its EFFECTIVE, composed form (repository-baseline.json + this
# overlay) is a complete profile and meaningful to validate against the
# full schema; the raw overlay file is deliberately incomplete on its own.
$realProfileForSchema = (Get-EffectiveCdaProfile -Path (Join-Path $root 'profiles\npm-library.json')).Profile
$profileSchemaErrors = @(Test-JsonSchemaLite -Value $realProfileForSchema -Schema $repoProfileSchema -RootSchema $repoProfileSchema)
Assert-True -Name 'profiles/npm-library.json''s EFFECTIVE (composed) profile validates against repository-profile.schema.json' -Condition ($profileSchemaErrors.Count -eq 0) -Detail ($profileSchemaErrors -join '; ')

$assessmentSchema = Get-Content -LiteralPath (Join-Path $schemasDir 'assessment.schema.json') -Raw | ConvertFrom-Json
$syntheticAssessmentRows = @(
    (New-CapabilityRow -Capability 'Default branch' -Current 'main' -Target 'main' -Classification COMPLIANT -Rationale 'match')
    (New-CapabilityRow -Capability 'Hygiene: GitHub Pages configuration' -Current 'absent' -Target 'absent' -Classification COMPLIANT -Rationale 'match')
)
$syntheticAssessmentFixture = [PSCustomObject]@{
    Repository = 'Continuous-DrivenArchitecture/example-npm-library'
    ProfileName = 'cda-npm-library-v1'
    AssessmentDate = '2026-01-01 00:00:00'
    StateFingerprint = [PSCustomObject]@{ CapturedAt = '2026-01-01 00:00:00'; DefaultBranch = 'main'; DefaultBranchSha = ('a' * 40); MainSha = ('a' * 40); DevelopSha = $null; Rulesets = @(); WorkflowShas = @(); ReleaseConfigFile = $null; ReleaseConfigSha = $null; PackageJsonSha = $null }
    CapabilityRows = $syntheticAssessmentRows
    Blockers = @()
    Plan = (New-AdoptionPlan -CapabilityRows $syntheticAssessmentRows)
}
$syntheticAssessmentJson = ConvertTo-AdoptionJsonReport -Assessment $syntheticAssessmentFixture | ConvertFrom-Json
$assessmentSchemaErrors = @(Test-JsonSchemaLite -Value $syntheticAssessmentJson -Schema $assessmentSchema -RootSchema $assessmentSchema)
Assert-True -Name 'a synthetic assessment (via the real ConvertTo-AdoptionJsonReport) validates against assessment.schema.json' -Condition ($assessmentSchemaErrors.Count -eq 0) -Detail ($assessmentSchemaErrors -join '; ')

$approvedPlanSchema = Get-Content -LiteralPath (Join-Path $schemasDir 'approved-plan.schema.json') -Raw | ConvertFrom-Json
$syntheticApprovedPlanJson = New-MockApprovedPlan | ConvertTo-Json -Depth 12 | ConvertFrom-Json
$approvedPlanSchemaErrors = @(Test-JsonSchemaLite -Value $syntheticApprovedPlanJson -Schema $approvedPlanSchema -RootSchema $approvedPlanSchema)
Assert-True -Name 'a synthetic approved-plan (via the real New-ApprovedPlan-shaped fixture) validates against approved-plan.schema.json' -Condition ($approvedPlanSchemaErrors.Count -eq 0) -Detail ($approvedPlanSchemaErrors -join '; ')

$adoptionPlanSchema = Get-Content -LiteralPath (Join-Path $schemasDir 'adoption-plan.schema.json') -Raw | ConvertFrom-Json
$syntheticPlanArrayJson = @($syntheticAssessmentJson.plan)
$adoptionPlanSchemaErrors = @()
foreach ($phase in $syntheticPlanArrayJson) { $adoptionPlanSchemaErrors += @(Test-JsonSchemaLite -Value $phase -Schema (Resolve-SchemaRef -Schema $adoptionPlanSchema.items -RootSchema $adoptionPlanSchema) -RootSchema $adoptionPlanSchema) }
Assert-True -Name 'the same synthetic plan array validates against the standalone adoption-plan.schema.json' -Condition (@($adoptionPlanSchemaErrors).Count -eq 0) -Detail ($adoptionPlanSchemaErrors -join '; ')

# ---------------------------------------------------------------------------
Write-Host "31. Public repository safety scan" -ForegroundColor Cyan

$sensitivePatterns = @('C:\\\\data', 'C:/data', 'gho_[A-Za-z0-9]', 'ghp_[A-Za-z0-9]', 'github_pat_', '4614226', 'miguelcespedes')
$sensitiveHits = @()
foreach ($f in $allSourceFiles) {
    $text = Get-Content -LiteralPath $f.FullName -Raw
    foreach ($pat in $sensitivePatterns) {
        if ($text -match $pat) { $sensitiveHits += "$($f.FullName): $pat" }
    }
}
Assert-True -Name 'no source file contains an absolute local path, a live token shape, or a known production identity' -Condition ($sensitiveHits.Count -eq 0) -Detail ($sensitiveHits -join '; ')

# Checks git's own TRACKED-file list, not raw filesystem existence -- a
# local, gitignored reports/ directory is expected and correct (see
# docs/artifact-model.md, "Report output location"); what must never
# happen is one of its files becoming TRACKED (committed).
$reportsTrackedFiles = @()
if (Test-Path -LiteralPath (Join-Path $root '.git')) {
    $gitOutput = & git -C $root ls-files 2>&1
    if ($LASTEXITCODE -eq 0) {
        $reportsTrackedFiles = @($gitOutput | Where-Object { $_ -match '^reports/' })
    }
}
Assert-True -Name 'no reports/ file is tracked by git (production evidence lives only in the gitignored local workspace, never committed)' -Condition ($reportsTrackedFiles.Count -eq 0) -Detail ($reportsTrackedFiles -join '; ')

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "32. Baseline profile: parsing, normative levels, no npm content" -ForegroundColor Cyan

$baselinePath = Join-Path $root 'profiles\repository-baseline.json'
$baselineOwn = Get-CdaProfile -Path $baselinePath
Assert-True -Name 'repository-baseline.json parses' -Condition $baselineOwn.Success -Detail "$($baselineOwn.Error)"
if ($baselineOwn.Success) {
    Assert-Equal -Name 'repository-baseline: profileName' -Expected 'cda-repository-baseline-v1' -Actual $baselineOwn.Profile.profileName
    Assert-True -Name 'repository-baseline: has no `extends` (it implements the baseline directly, it does not extend anything)' -Condition (-not $baselineOwn.Profile.PSObject.Properties['extends'] -or [string]::IsNullOrEmpty("$($baselineOwn.Profile.extends)"))
    Assert-True -Name 'repository-baseline: has no `npm` section' -Condition (-not $baselineOwn.Profile.PSObject.Properties['npm'])
    Assert-True -Name 'repository-baseline: security.codeQLDefaultSetup.applicableLanguages is empty (MAY-level, language-dependent, never guessed)' -Condition (@($baselineOwn.Profile.security.codeQLDefaultSetup.applicableLanguages).Count -eq 0)
    Assert-True -Name 'repository-baseline: has a normativeLevels block' -Condition ($null -ne $baselineOwn.Profile.normativeLevels)
    Assert-Equal -Name 'repository-baseline: bypassActors MUST-level normative field' -Expected 'MUST be empty by default' -Actual $baselineOwn.Profile.normativeLevels.'ruleset.bypassActors'
    Assert-True -Name 'repository-baseline: allowedActionsPolicy is recorded as SHOULD, never silently elevated to MUST' -Condition ($baselineOwn.Profile.normativeLevels.'actions.allowedActionsPolicy' -match '^SHOULD')
    Assert-True -Name 'repository-baseline: codeQLDefaultSetup is recorded as MAY' -Condition ($baselineOwn.Profile.normativeLevels.'security.codeQLDefaultSetup' -match '^MAY')
    Assert-Equal -Name 'repository-baseline: ruleset required check context is ci-required (this profile''s own concrete instantiation)' -Expected 'ci-required' -Actual $baselineOwn.Profile.ruleset.requiredStatusChecks.context
    Assert-Equal -Name 'repository-baseline: default branch main (MUST)' -Expected 'main' -Actual $baselineOwn.Profile.repositorySettings.defaultBranch
    Assert-True -Name 'repository-baseline: squash-only (MUST)' -Condition ($baselineOwn.Profile.repositorySettings.allowSquashMerge -eq $true -and $baselineOwn.Profile.repositorySettings.allowMergeCommit -eq $false -and $baselineOwn.Profile.repositorySettings.allowRebaseMerge -eq $false)
}

# ---------------------------------------------------------------------------
Write-Host "33. Profile composition: Merge-CdaProfileObject + Get-EffectiveCdaProfile" -ForegroundColor Cyan

# Pure merge tests (no file I/O)
$mergeBase = [PSCustomObject]@{ a = 1; nested = [PSCustomObject]@{ x = 'base-x'; y = 'base-y' }; arr = @(1, 2, 3) }
$mergeChildEmpty = [PSCustomObject]@{}
$mergedNoOverride = Merge-CdaProfileObject -Base $mergeBase -Child $mergeChildEmpty
Assert-Equal -Name 'Merge-CdaProfileObject: child with no properties -> base values pass through unchanged' -Expected 'base-x' -Actual $mergedNoOverride.nested.x

$mergeChildPartial = [PSCustomObject]@{ nested = [PSCustomObject]@{ x = 'child-x' } }
$mergedPartial = Merge-CdaProfileObject -Base $mergeBase -Child $mergeChildPartial
Assert-Equal -Name 'Merge-CdaProfileObject: nested object merge overrides only the specified sub-field' -Expected 'child-x' -Actual $mergedPartial.nested.x
Assert-Equal -Name 'Merge-CdaProfileObject: nested object merge leaves an unspecified sibling sub-field from base intact' -Expected 'base-y' -Actual $mergedPartial.nested.y
Assert-Equal -Name 'Merge-CdaProfileObject: a top-level scalar not touched by the child is preserved from base' -Expected 1 -Actual $mergedPartial.a

$mergeChildArray = [PSCustomObject]@{ arr = @(9) }
$mergedArray = Merge-CdaProfileObject -Base $mergeBase -Child $mergeChildArray
Assert-Equal -Name 'Merge-CdaProfileObject: an array on the child REPLACES the base array wholesale, never merges element-wise' -Expected 1 -Actual (@($mergedArray.arr).Count)

$mergeChildNewProp = [PSCustomObject]@{ brandNew = 'added' }
$mergedNewProp = Merge-CdaProfileObject -Base $mergeBase -Child $mergeChildNewProp
Assert-Equal -Name 'Merge-CdaProfileObject: a property the base never had is added from the child' -Expected 'added' -Actual $mergedNewProp.brandNew

# File-based composition tests (real profiles/*.json)
$npmLibraryPath = Join-Path $root 'profiles\npm-library.json'
$npmEffective = Get-EffectiveCdaProfile -Path $npmLibraryPath
Assert-True -Name 'npm-library.json resolves successfully' -Condition $npmEffective.Success -Detail "$($npmEffective.Error)"
Assert-True -Name 'npm-library.json is reported Extended=true' -Condition $npmEffective.Extended
Assert-Equal -Name 'npm-library.json BaseProfileName is repository-baseline' -Expected 'repository-baseline' -Actual $npmEffective.BaseProfileName

$baselineEffective = Get-EffectiveCdaProfile -Path $baselinePath
Assert-True -Name 'repository-baseline.json resolves successfully (nothing to extend)' -Condition $baselineEffective.Success
Assert-True -Name 'repository-baseline.json is reported Extended=false (it has no `extends`)' -Condition (-not $baselineEffective.Extended)

$missingProfileResult = Get-EffectiveCdaProfile -Path (Join-Path $root 'profiles\does-not-exist.json')
Assert-True -Name 'a missing profile file reports Success=false, never throws' -Condition (-not $missingProfileResult.Success)

# A profile whose `extends` names something that is NOT a resolvable
# sibling file (e.g. the old documentation-only standard-name style) is
# returned as-is, never guessed at or treated as an error.
$docOnlyExtendsFixture = Join-Path $fixturesDir 'doc-only-extends-profile.json'
[System.IO.File]::WriteAllText($docOnlyExtendsFixture, '{"schemaVersion":"1.0","profileName":"fixture-profile","extends":"some-standard-name-not-a-file","repositorySettings":{"defaultBranch":"main"}}', (New-Object System.Text.UTF8Encoding $false))
$docOnlyResult = Get-EffectiveCdaProfile -Path $docOnlyExtendsFixture
Assert-True -Name 'a profile whose `extends` does not resolve to a sibling file is returned as-is (Extended=false), never an error' -Condition ($docOnlyResult.Success -and -not $docOnlyResult.Extended)
Remove-Item -LiteralPath $docOnlyExtendsFixture -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
Write-Host "34. Regression: npm-library effective desired state is unchanged after the baseline-extraction refactor" -ForegroundColor Cyan

# Hand-encoded from the ORIGINAL, monolithic profiles/npm-library.json
# (before this task split it into repository-baseline.json + a thin
# overlay) -- this is the exact set of values production tooling was
# already validated against; the refactor's whole point is that this
# regression stays green.
$npmEff = $npmEffective.Profile
Assert-Equal -Name 'REGRESSION: repositorySettings.defaultBranch' -Expected 'main' -Actual $npmEff.repositorySettings.defaultBranch
Assert-Equal -Name 'REGRESSION: repositorySettings.deleteBranchOnMerge' -Expected 'True' -Actual $npmEff.repositorySettings.deleteBranchOnMerge
Assert-Equal -Name 'REGRESSION: repositorySettings.allowSquashMerge' -Expected 'True' -Actual $npmEff.repositorySettings.allowSquashMerge
Assert-Equal -Name 'REGRESSION: repositorySettings.allowMergeCommit' -Expected 'False' -Actual $npmEff.repositorySettings.allowMergeCommit
Assert-Equal -Name 'REGRESSION: repositorySettings.allowRebaseMerge' -Expected 'False' -Actual $npmEff.repositorySettings.allowRebaseMerge
Assert-Equal -Name 'REGRESSION: repositorySettings.allowAutoMerge' -Expected 'False' -Actual $npmEff.repositorySettings.allowAutoMerge
Assert-Equal -Name 'REGRESSION: actions.enabled' -Expected 'True' -Actual $npmEff.actions.enabled
Assert-Equal -Name 'REGRESSION: actions.defaultWorkflowPermissions' -Expected 'read' -Actual $npmEff.actions.defaultWorkflowPermissions
Assert-Equal -Name 'REGRESSION: actions.allowedActionsPolicy' -Expected 'selected' -Actual $npmEff.actions.allowedActionsPolicy
Assert-Equal -Name 'REGRESSION: actions.selectedActions.githubOwnedAllowed' -Expected 'True' -Actual $npmEff.actions.selectedActions.githubOwnedAllowed
Assert-Equal -Name 'REGRESSION: actions.selectedActions.verifiedAllowed' -Expected 'False' -Actual $npmEff.actions.selectedActions.verifiedAllowed
Assert-Equal -Name 'REGRESSION: actions.shaPinningRequired' -Expected 'True' -Actual $npmEff.actions.shaPinningRequired
Assert-Equal -Name 'REGRESSION: actions.knownGitHubOwnedActionOwners' -Expected 'actions,github' -Actual (@($npmEff.actions.knownGitHubOwnedActionOwners) -join ',')
Assert-Equal -Name 'REGRESSION: security.vulnerabilityAlerts' -Expected 'True' -Actual $npmEff.security.vulnerabilityAlerts
Assert-Equal -Name 'REGRESSION: security.secretScanning' -Expected 'enabled' -Actual $npmEff.security.secretScanning
Assert-Equal -Name 'REGRESSION: security.secretScanningPushProtection' -Expected 'enabled' -Actual $npmEff.security.secretScanningPushProtection
Assert-Equal -Name 'REGRESSION: security.dependabotSecurityUpdates' -Expected 'enabled' -Actual $npmEff.security.dependabotSecurityUpdates
Assert-Equal -Name 'REGRESSION: security.codeQLDefaultSetup.applicableLanguages' -Expected 'JavaScript,TypeScript' -Actual (@($npmEff.security.codeQLDefaultSetup.applicableLanguages) -join ',')
Assert-Equal -Name 'REGRESSION: security.codeQLDefaultSetup.setupLanguages' -Expected 'javascript-typescript,actions' -Actual (@($npmEff.security.codeQLDefaultSetup.setupLanguages) -join ',')
Assert-Equal -Name 'REGRESSION: security.codeQLDefaultSetup.querySuite' -Expected 'default' -Actual $npmEff.security.codeQLDefaultSetup.querySuite
Assert-Equal -Name 'REGRESSION: ruleset.name' -Expected 'Protect main' -Actual $npmEff.ruleset.name
Assert-Equal -Name 'REGRESSION: ruleset.target' -Expected 'branch' -Actual $npmEff.ruleset.target
Assert-Equal -Name 'REGRESSION: ruleset.refInclude' -Expected '~DEFAULT_BRANCH' -Actual (@($npmEff.ruleset.refInclude) -join ',')
Assert-Equal -Name 'REGRESSION: ruleset.enforcement' -Expected 'active' -Actual $npmEff.ruleset.enforcement
Assert-Equal -Name 'REGRESSION: ruleset.bypassActors is empty' -Expected 0 -Actual (@($npmEff.ruleset.bypassActors).Count)
Assert-Equal -Name 'REGRESSION: ruleset.pullRequest.requiredApprovingReviewCount' -Expected 0 -Actual $npmEff.ruleset.pullRequest.requiredApprovingReviewCount
Assert-Equal -Name 'REGRESSION: ruleset.pullRequest.requireCodeOwnerReview' -Expected 'False' -Actual $npmEff.ruleset.pullRequest.requireCodeOwnerReview
Assert-Equal -Name 'REGRESSION: ruleset.pullRequest.requiredReviewThreadResolution' -Expected 'True' -Actual $npmEff.ruleset.pullRequest.requiredReviewThreadResolution
Assert-Equal -Name 'REGRESSION: ruleset.pullRequest.allowedMergeMethods' -Expected 'squash' -Actual (@($npmEff.ruleset.pullRequest.allowedMergeMethods) -join ',')
Assert-Equal -Name 'REGRESSION: ruleset.requiredStatusChecks.context' -Expected 'ci-required' -Actual $npmEff.ruleset.requiredStatusChecks.context
Assert-Equal -Name 'REGRESSION: ruleset.requiredStatusChecks.strict' -Expected 'True' -Actual $npmEff.ruleset.requiredStatusChecks.strict
Assert-Equal -Name 'REGRESSION: ruleset.nonFastForward' -Expected 'True' -Actual $npmEff.ruleset.nonFastForward
Assert-Equal -Name 'REGRESSION: ruleset.deletion' -Expected 'True' -Actual $npmEff.ruleset.deletion
Assert-Equal -Name 'REGRESSION: npm.trustedPublisher' -Expected 'EXTERNAL SETUP REQUIRED - not managed by this provisioner version' -Actual $npmEff.npm.trustedPublisher

# Also prove the two profiles' EFFECTIVE states genuinely differ where they
# should (profile-mismatch protection: composition must never silently
# cross-contaminate one profile's resolution with another's, e.g. via a
# stale cached object) -- baseline has no npm section and no JS/TS CodeQL;
# npm-library has both.
Assert-True -Name 'profile mismatch protection: repository-baseline''s effective profile has no npm section while npm-library''s does' -Condition (-not $baselineEffective.Profile.PSObject.Properties['npm'] -and $null -ne $npmEff.PSObject.Properties['npm'])
Assert-True -Name 'profile mismatch protection: repository-baseline''s effective CodeQL languages are empty while npm-library''s are not' -Condition (@($baselineEffective.Profile.security.codeQLDefaultSetup.applicableLanguages).Count -eq 0 -and @($npmEff.security.codeQLDefaultSetup.applicableLanguages).Count -gt 0)

# ---------------------------------------------------------------------------
Write-Host "35. Generic provision-repository.ps1 command" -ForegroundColor Cyan

$provisionRepoScript = Join-Path $commandsDir 'provision-repository.ps1'
try {
    & $provisionRepoScript -Repository 'Continuous-DrivenArchitecture/whatever' -Profile 'repository-baseline' -Mode 'NotARealMode' -DryRun 2>$null
    Assert-True -Name 'provision-repository.ps1: invalid -Mode value is rejected' -Condition $false -Detail '(script did not throw)'
}
catch {
    Assert-True -Name 'provision-repository.ps1: invalid -Mode value is rejected' -Condition ($_.Exception.Message -match 'NotARealMode' -or $_.CategoryInfo.Category -eq 'InvalidData' -or $_.FullyQualifiedErrorId -match 'ParameterArgumentValidationError')
}
try {
    & $provisionRepoScript -Repository 'Continuous-DrivenArchitecture/whatever' -Mode 'Verify' 2>$null
    Assert-True -Name 'provision-repository.ps1: -Profile is mandatory' -Condition $false -Detail '(script did not throw/prompt-fail)'
}
catch {
    Assert-True -Name 'provision-repository.ps1: -Profile is mandatory' -Condition $true
}
# Write-Error under this script's own $ErrorActionPreference='Stop'
# throws a terminating ActionPreferenceStopException rather than falling
# through to its own `exit 2` line -- same as every other BLOCKED-style
# early exit in this codebase (see assess-npm-library.ps1,
# provision-npm-library.ps1). Invoked via the call operator from a parent
# scope that ALSO sets $ErrorActionPreference='Stop', the error
# propagates up rather than being swallowed -- caught here, matching the
# established pattern for testing this class of failure elsewhere in this
# suite (see the -Mode/-Profile mandatory-parameter tests immediately
# above).
$missingProfileErrorText = $null
try {
    & $provisionRepoScript -Repository 'Continuous-DrivenArchitecture/whatever' -Profile 'this-profile-does-not-exist' -Mode 'Verify' 2>&1 | Out-Null
    Assert-True -Name 'provision-repository.ps1: an unknown -Profile name is rejected, never guessed at' -Condition $false -Detail '(script did not throw/exit non-zero)'
}
catch {
    $missingProfileErrorText = "$_"
    Assert-True -Name 'provision-repository.ps1: an unknown -Profile name is rejected, never guessed at' -Condition $true
}
Assert-True -Name 'provision-repository.ps1: the unknown-profile error names the profiles actually available' -Condition ($missingProfileErrorText -match 'repository-baseline' -and $missingProfileErrorText -match 'npm-library') -Detail "$missingProfileErrorText"

$provisionRepoSource = Get-Content -LiteralPath $provisionRepoScript -Raw
Assert-True -Name 'provision-repository.ps1 resolves its profile via Get-EffectiveCdaProfile (composition-aware), not the raw Get-CdaProfile' -Condition ($provisionRepoSource -match 'Get-EffectiveCdaProfile')
Assert-True -Name 'provision-npm-library.ps1 (compatibility wrapper) ALSO resolves via Get-EffectiveCdaProfile now' -Condition ((Get-Content -LiteralPath (Join-Path $commandsDir 'provision-npm-library.ps1') -Raw) -match 'Get-EffectiveCdaProfile')

# ---------------------------------------------------------------------------
Write-Host "36. Baseline-only Bootstrap / Finalize / Verify lifecycle (profile-agnosticism, source-pattern)" -ForegroundColor Cyan

# Mocking Invoke-Provisioning end-to-end was attempted and found not
# viable, empirically, not assumed: Test-RepositoryEligibility (defined
# in Validation.psm1, which nest-imports ReadOnlyGitHub.psm1 itself) and
# every Get-*Plan function in Orchestration.psm1 (which ALSO nest-imports
# ReadOnlyGitHub.psm1 directly in its own header) each call
# Invoke-ReadOnlyGitHub from WITHIN their own defining/nesting module --
# a global-scope test override cannot reach those calls, the same
# established limitation documented throughout this suite for Discovery
# .psm1's own API wrappers (see section 21's own comment). This is not a
# new gap: the ORIGINAL provisioner test suite this section descends from
# explicitly never attempted to mock a live gh api round-trip either --
# "those are exercised, read-only, via -Mode Verify / -Mode Bootstrap
# -DryRun against a real repository." The real, live Bootstrap -> Finalize
# -> Verify lifecycle for the baseline profile is exercised for real
# later in this same task, against the real published
# tool-repository-lifecycle repository (self-hosting) -- see the task's
# own Sections 16-19 and the resulting reports/ evidence.
#
# What CAN be proven offline, and is proven here: Orchestration.psm1's
# ruleset/actions/security-plan logic is profile-driven BY CONSTRUCTION --
# it reads every desired value from the $CdaProfile/$Desired parameter
# passed in, never a hardcoded npm-library-specific literal -- so running
# it against the baseline profile (no npm section, no JS/TS CodeQL) can
# never accidentally leak npm-specific behavior.
$orchestrationSource = Get-Content -LiteralPath (Join-Path $provisionerLib 'Orchestration.psm1') -Raw
Assert-True -Name 'Orchestration.psm1: Get-RulesetPlan reads the required-check context from the profile parameter, never a hardcoded literal' -Condition ($orchestrationSource -match 'New-DesiredRulesetBody -CdaProfile \$CdaProfile')
Assert-True -Name 'Orchestration.psm1: Get-SecurityPlan reads CodeQL applicable/setup languages from the profile parameter, never a hardcoded JavaScript/TypeScript literal' -Condition ($orchestrationSource -match '\$Desired\.codeQLDefaultSetup\.applicableLanguages' -and $orchestrationSource -notmatch "'JavaScript'|'TypeScript'")
Assert-True -Name 'Orchestration.psm1: Get-ActionsPlan reads the allowed-actions policy from the profile parameter, never hardcoded' -Condition ($orchestrationSource -match '\$Desired\.allowedActionsPolicy')
Assert-True -Name 'Invoke-Provisioning''s own Mode/DryRun/-CdaProfile signature accepts any profile object, not a specific one' -Condition ((Get-Command Invoke-Provisioning).Parameters.Keys -contains 'CdaProfile')

# Confirms Bootstrap's own fail-safe (never require a check with no
# execution evidence) and Finalize's own fail-safe (never touch the
# ruleset without evidence) are structurally present and unconditional on
# which profile is in use.
Assert-True -Name 'Orchestration.psm1: Get-RulesetPlan omits requiredStatusChecks from a newly-created ruleset when there is no execution evidence yet (profile-independent fail-safe)' -Condition ($orchestrationSource -match 'includeRsc = \$evidence\.Found')
Assert-True -Name 'Orchestration.psm1: Finalize mode fails safe (FAIL_SAFE, ruleset untouched) when ci-required has no evidence, regardless of profile' -Condition ($orchestrationSource -match 'Mode -eq ''Finalize'' -and -not \$evidence\.Found')

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "Results: $script:PassCount passed, $script:FailCount failed" -ForegroundColor $(if ($script:FailCount -eq 0) { 'Green' } else { 'Red' })
if ($script:FailCount -gt 0) { exit 1 }
exit 0
