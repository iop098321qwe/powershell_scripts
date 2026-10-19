<#
.SYNOPSIS
Runs isolated disable-user regressions without AD, Pester, or elevation.
.EXAMPLE
pwsh -NoProfile -File ./tests/disable_ad_user.Tests.ps1
#>
[CmdletBinding()]
param ()

$ErrorActionPreference = 'Stop'
$sourcePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'disable_ad_user.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $sourcePath, [ref]$tokens, [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
    throw ($parseErrors.Message -join '; ')
}

# Load only definitions and AD configuration, never the administrative entry point.
$ast.FindAll({
    param ($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $false) | ForEach-Object { . ([scriptblock]::Create($_.Extent.Text)) }
$ast.EndBlock.Statements | Where-Object {
    $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $_.Left.Extent.Text -in @('$script:AdUserProperties', '$script:AdGroupProperties')
} | ForEach-Object { . ([scriptblock]::Create($_.Extent.Text)) }
$script:AdServer = 'dc1.example.test'
$script:readCalls = [System.Collections.Generic.List[object]]::new()
$script:sleepCalls = 0
$script:passed = 0

function Assert-True {
    param ([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param ([scriptblock]$Action, [string]$Pattern)
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_ }
    Assert-True ($null -ne $caught) 'Expected an exception, but execution succeeded.'
    Assert-True ($caught.Exception.Message -like $Pattern) "Unexpected error: $($caught.Exception.Message)"
}

function Test-Case {
    param ([string]$Name, [scriptblock]$Action)
    & $Action
    $script:passed++
    Write-Host "PASS: $Name"
}

function New-TestUser {
    [pscustomobject]@{
        ObjectGUID = [guid]'00112233-4455-6677-8899-aabbccddeeff'
        SamAccountName = 'ann.user'
        GivenName = 'Ann'
        Surname = 'User'
        DisplayName = 'Ann User'
        UserPrincipalName = 'ann.user@example.test'
        DistinguishedName = 'CN=User\, Ann,OU=Active,DC=example,DC=test'
        CanonicalName = 'example.test/Active/User, Ann'
        Description = 'Original description'
        Enabled = $true
        userAccountControl = 512
        PasswordNeverExpires = $false
        PrimaryGroupID = 513
        MemberOf = @()
        msExchHideFromAddressLists = $false
    }
}

function Get-ADUser {
    [CmdletBinding()]
    param ($Identity, $LDAPFilter, $Properties, $Server)
    Assert-True ($Server -eq $script:AdServer) 'AD read used a different controller.'
    [void]$script:readCalls.Add([pscustomobject]@{
        Identity = $Identity; LDAPFilter = $LDAPFilter; Server = $Server
    })
    if ($Identity -eq 'Ann') { throw 'Identity not found' }
    if ($LDAPFilter -like '*(sAMAccountName=*') { return }
    return $script:directoryUser.PSObject.Copy()
}

function Start-Sleep {
    param ($Seconds)
    $script:sleepCalls++
    if ($null -ne $script:onSleep) { & $script:onSleep }
}

function Read-Host {
    param ($Prompt)
    if ($script:answers.Count -eq 0) { throw "Unexpected prompt: $Prompt" }
    return $script:answers.Dequeue()
}

function Set-TestAnswers {
    param ([string[]]$Answers)
    $script:answers = [System.Collections.Generic.Queue[string]]::new()
    foreach ($answer in $Answers) { $script:answers.Enqueue($answer) }
}

$script:directoryUser = New-TestUser

Test-Case 'confirmation returns only one Boolean and honors both answers' {
    foreach ($answer in @('n', 'y')) {
        Set-TestAnswers @($answer)
        $result = @(Confirm-TargetAdUser -User $script:directoryUser)
        Assert-True ($result.Count -eq 1 -and $result[0] -is [bool]) 'Confirmation leaked presentation output.'
        Assert-True ($result[0] -eq ($answer -eq 'y')) 'Confirmation ignored the supplied answer.'
    }
    Assert-True (@(Write-Section 'Test section').Count -eq 0) 'Section output contaminated a return value.'
}

Test-Case 'exact and partial-name selection return only the chosen user' {
    foreach ($identity in @('ann.user', 'Ann')) {
        Set-TestAnswers @($identity, '1')
        $selected = @(Select-TargetAdUser)
        Assert-True ($selected.Count -eq 1) 'Selection leaked display strings.'
        Assert-True ($selected[0].ObjectGUID -eq $script:directoryUser.ObjectGUID) 'Wrong user selected.'
        $refreshed = Get-RefreshedAdUser -User $selected[0]
        Assert-True ($refreshed.ObjectGUID -eq $selected[0].ObjectGUID) 'Selected user could not be refreshed.'
    }
}

Test-Case 'refresh follows GUID after a move and reports current state on rerun' {
    $oldUser = $script:directoryUser.PSObject.Copy()
    $script:directoryUser.Enabled = $false
    $script:directoryUser.userAccountControl = 514
    $script:directoryUser.Description = 'Disabled 2026-10-19'
    $script:directoryUser.DistinguishedName = 'CN=User\, Ann,OU=Disabled,DC=example,DC=test'
    $result = Get-RefreshedAdUser -User $oldUser -ExpectedEnabled $false
    Assert-True ($result.DistinguishedName -ne $oldUser.DistinguishedName) 'Refresh retained the old OU.'
    Assert-True ($script:readCalls[-1].LDAPFilter -eq '(objectGUID=\33\22\11\00\55\44\77\66\88\99\aa\bb\cc\dd\ee\ff)') 'GUID lookup used an incorrect LDAP encoding.'
    Set-TestAnswers @('ann.user')
    $rerun = Get-RefreshedAdUser -User (Select-TargetAdUser)
    Set-TestAnswers @('n')
    $display = @(Confirm-TargetAdUser -User $rerun 6>&1)
    $displayText = ($display | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { $_.ToString() }) -join "`n"
    Assert-True ($displayText -like '*Disabled (cannot sign in)*') 'Rerun displayed old enabled state.'
    Assert-True ($displayText -like '*Disabled 2026-10-19*') 'Rerun displayed the old description.'
    Assert-True ($displayText -match 'Current location:\s+Disabled') 'Rerun displayed the old OU.'
}

Test-Case 'refresh retries until all expected properties are visible' {
    $script:directoryUser.PasswordNeverExpires = $false
    $script:sleepCalls = 0
    $script:onSleep = { $script:directoryUser.PasswordNeverExpires = $true }
    try {
        $result = Get-RefreshedAdUser -User $script:directoryUser -ExpectedEnabled $false -ExpectedProperties @{
            PasswordNeverExpires = $true
            Description = 'Disabled 2026-10-19'
        } -MaxAttempts 3
        Assert-True ($script:sleepCalls -eq 1 -and $result.PasswordNeverExpires) 'Refresh did not wait for all expected properties.'
    }
    finally { $script:onSleep = $null }
}

Test-Case 'verification failure throws with actionable diagnostics' {
    $script:sleepCalls = 0
    Assert-Throws {
        Get-RefreshedAdUser -User $script:directoryUser -ExpectedEnabled $true -MaxAttempts 2
    } '*dc1.example.test*Enabled: expected*True*observed*False*'
    Assert-True ($script:sleepCalls -eq 1) 'Retry count was incorrect.'
    foreach ($properties in @(
        @{ Description = 'Unexpected description' },
        @{ PasswordNeverExpires = $false },
        @{ PrimaryGroupID = 999 },
        @{ DistinguishedName = 'CN=Wrong,DC=example,DC=test' }
    )) {
        Assert-Throws {
            Get-RefreshedAdUser -User $script:directoryUser -ExpectedProperties $properties
        } '*Could not verify*expected*observed*'
    }
    Assert-Throws { Get-RefreshedAdUser -User ([pscustomobject]@{ SamAccountName = 'missing' }) } '*object GUID was not available*'
}

Test-Case 'optional attributes use the selected controller and immutable identity' {
    $result = Get-OptionalAdUserPropertyState -User $script:directoryUser -PropertyName 'msExchHideFromAddressLists'
    Assert-True ($result.IsAvailable -and $result.Value -eq $false) 'Optional attribute read failed.'
    Assert-True ($script:readCalls[-1].Identity -eq $script:directoryUser.ObjectGUID) 'Optional attribute read used a mutable DN.'
}

Test-Case 'every operational AD command explicitly targets the selected controller' {
    $discoveryFunction = $ast.Find({
        param ($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Resolve-ActiveDirectoryServer'
    }, $false)
    $commands = $ast.FindAll({
        param ($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -match '^(Get|Set|Disable|Add|Remove|Move)-AD'
    }, $true)
    foreach ($command in $commands) {
        # These two discovery calls select the controller before operational work.
        if ($command.Extent.StartOffset -gt $discoveryFunction.Extent.StartOffset -and
            $command.Extent.EndOffset -lt $discoveryFunction.Extent.EndOffset) { continue }
        $serverParameters = @($command.CommandElements | Where-Object {
            $_ -is [System.Management.Automation.Language.CommandParameterAst] -and
            $_.ParameterName -eq 'Server'
        })
        Assert-True ($serverParameters.Count -eq 1) "Unpinned AD command: $($command.Extent.Text)"
        $parameterIndex = [array]::IndexOf([object[]]$command.CommandElements, $serverParameters[0])
        Assert-True ($command.CommandElements[$parameterIndex + 1].Extent.Text -eq '$script:AdServer') 'AD command targets a different server variable.'
    }
}

Test-Case 'workflow rejects No, verifies two iterations, and cannot summarize a failed disable' {
    function Test-IsAdministrator { return $true }
    function Import-ActiveDirectoryModule {}
    function Resolve-ActiveDirectoryServer { return 'dc1.example.test' }
    function Get-DisableSummaryExportPath {
        $script:pathCount++
        # Unique in-memory paths isolate refresh from the existing-file guard.
        return "mock-summary-$script:pathCount.txt"
    }
    function Assert-ExportFileDoesNotExist {}
    function Export-DisableAdUserSummary {
        param ($Lines, $Path)
        [void]$script:exports.Add(($Lines -join "`n"))
    }
    function Get-ADGroup {
        [CmdletBinding()]
        param ($Identity, $Properties, $Server)
        Assert-True ($Server -eq $script:AdServer) 'Group read used a different controller.'
        return [pscustomobject]@{
            Name = 'Domain Users'
            DistinguishedName = 'CN=Domain Users,CN=Users,DC=example,DC=test'
            primaryGroupToken = 513
        }
    }
    function Get-ADDomain {
        [CmdletBinding()]
        param ($Server)
        Assert-True ($Server -eq $script:AdServer) 'Domain read used a different controller.'
        return [pscustomobject]@{ DomainSID = [pscustomobject]@{ Value = 'S-1-5-21-1-2-3' } }
    }
    function Set-ADUser {
        [CmdletBinding()]
        param ($Identity, $Description, $Replace, [bool]$PasswordNeverExpires, $Server)
        Assert-True ($Server -eq $script:AdServer) 'User write used a different controller.'
        $script:mutations++
        if ($PSBoundParameters.ContainsKey('Description')) { $script:directoryUser.Description = $Description }
        if ($PSBoundParameters.ContainsKey('PasswordNeverExpires')) { $script:directoryUser.PasswordNeverExpires = $PasswordNeverExpires }
        if ($null -ne $Replace) {
            foreach ($name in $Replace.Keys) { $script:directoryUser.$name = $Replace[$name] }
        }
    }
    function Disable-ADAccount {
        [CmdletBinding()]
        param ($Identity, $Server)
        Assert-True ($Server -eq $script:AdServer) 'Disable used a different controller.'
        $script:mutations++
        if (-not $script:failDisable) {
            $script:directoryUser.Enabled = $false
            $script:directoryUser.userAccountControl = 514
        }
    }
    function Set-ADAccountPassword {
        [CmdletBinding()]
        param ($Identity, [switch]$Reset, $NewPassword, $Server)
        Assert-True ($Server -eq $script:AdServer) 'Password reset used a different controller.'
        $script:mutations++
    }
    function Select-TargetOrganizationalUnit {
        return [pscustomobject]@{ DistinguishedName = 'OU=Disabled,DC=example,DC=test' }
    }
    function Move-ADObject {
        [CmdletBinding()]
        param ($Identity, $TargetPath, $Server)
        Assert-True ($Server -eq $script:AdServer) 'Move used a different controller.'
        Assert-True ($TargetPath -eq 'OU=Disabled,DC=example,DC=test') 'Unexpected destination.'
        $script:mutations++
        $script:directoryUser.DistinguishedName = 'CN=User\, Ann,OU=Disabled,DC=example,DC=test'
    }
    function Read-RerunOrExitPrompt {
        $script:iterations++
        return ($script:iterations -lt 2)
    }

    # Run the real top-level workflow body with mocked external dependencies.
    # Omit only its exit/error UI so failures can be asserted in this process.
    $entryPoint = $ast.EndBlock.Statements | Where-Object {
        $_ -is [System.Management.Automation.Language.TryStatementAst]
    }
    $bodyText = $entryPoint.Body.Extent.Text
    $workflow = [scriptblock]::Create($bodyText.Substring(1, $bodyText.Length - 2))
    $script:directoryUser = New-TestUser
    $script:mutations = 0
    $script:pathCount = 0
    $script:iterations = 0
    $script:failDisable = $false
    $script:exports = [System.Collections.Generic.List[string]]::new()

    Set-TestAnswers @('ann.user', 'n')
    Assert-Throws { & $workflow } '*Unexpected prompt*'
    Assert-True ($script:mutations -eq 0 -and $script:exports.Count -eq 0) 'Rejected confirmation performed changes.'

    Set-TestAnswers @('ann.user', 'y', 'y', 'ann.user', 'y', 'n')
    & $workflow | Out-Null
    Assert-True ($script:iterations -eq 2 -and $script:exports.Count -eq 2) 'Workflow did not finish both iterations.'
    Assert-True ($script:exports[1] -match 'Organizational Unit:\s+Disabled') 'Rerun summary used the old OU.'
    Assert-True (-not $script:directoryUser.Enabled -and $script:directoryUser.PasswordNeverExpires) 'Final account state was incorrect.'
    Assert-True ($script:directoryUser.msExchHideFromAddressLists) 'Address-list visibility was not updated.'

    $script:directoryUser = New-TestUser
    $script:failDisable = $true
    Set-TestAnswers @('ann.user', 'y')
    Assert-Throws { & $workflow } '*Could not verify*Enabled: expected*False*observed*True*'
    Assert-True ($script:exports.Count -eq 2) 'Failed disable produced a success export.'
}

Write-Host "All $script:passed regression checks passed. No live AD operations were executed."
