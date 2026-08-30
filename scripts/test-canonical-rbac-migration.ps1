$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$migrationPath = Join-Path $root 'changelog\migrations\0067_canonical_rbac_authorization\canonical_rbac_authorization.xml'
$masterPath = Join-Path $root 'changelog\tenant.changelog-master.xml'
$migrationInclude = 'migrations/0067_canonical_rbac_authorization/canonical_rbac_authorization.xml'
$seedPath = Join-Path $PSScriptRoot 'seed-demo-data.ps1'
$bootstrapPath = Join-Path $PSScriptRoot 'bootstrap-tenant-admins.ps1'

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-ExactSet {
    param(
        [string[]]$Actual,
        [string[]]$Expected,
        [string]$Label
    )

    $actualSorted = @($Actual | Sort-Object -Unique)
    $expectedSorted = @($Expected | Sort-Object -Unique)
    Assert-True ($Actual.Count -eq $actualSorted.Count) "$Label must not contain duplicate values"
    Assert-True (
        $actualSorted.Count -eq $expectedSorted.Count -and
        [string]::Join(',', $actualSorted) -eq [string]::Join(',', $expectedSorted)
    ) "$Label must be exactly: $($expectedSorted -join ', ')"
}

function Get-NormalizedSqlStatements {
    param([xml]$Document)

    return @($Document.SelectNodes("//*[local-name()='sql']") | ForEach-Object {
        $_.InnerText `
        -replace '(?s)/\*.*?\*/', ' ' `
        -replace '(?m)--[^\r\n]*', ' ' `
        -replace '\s+', ' ' `
        -replace '\s*([(),;])\s*', '$1 '
    })
}

function Get-StatementIndexes {
    param(
        [string[]]$Statements,
        [string]$Pattern
    )

    $indexes = @()
    for ($index = 0; $index -lt $Statements.Count; $index++) {
        if ($Statements[$index] -match $Pattern) {
            $indexes += $index
        }
    }

    return $indexes
}

function Get-RoleDeletionStatements {
    param([string[]]$Statements)

    $deletions = @()
    $roleDeletionPattern = 'DELETE\s+FROM\s+"?\$\{schema\}"?\.role\b.*?(?:;|$)'
    for ($index = 0; $index -lt $Statements.Count; $index++) {
        $matches = [regex]::Matches(
            $Statements[$index],
            $roleDeletionPattern,
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline
        )
        foreach ($match in $matches) {
            $deletions += [pscustomobject]@{
                StatementIndex = $index
                Sql = $match.Value
            }
        }
    }

    return $deletions
}

function Get-PowerShellContract {
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Path')]
        [string]$Path,

        [Parameter(Mandatory = $true, ParameterSetName = 'Source')]
        [string]$SourceText,

        [Parameter(ParameterSetName = 'Source')]
        [string]$SourceName = 'PowerShell source'
    )

    $tokens = $null
    $parseErrors = $null
    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        $text = Get-Content -Raw -LiteralPath $Path
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $Path,
            [ref]$tokens,
            [ref]$parseErrors
        )
        $sourceLabel = $Path
    } else {
        $text = $SourceText
        $ast = [System.Management.Automation.Language.Parser]::ParseInput(
            $SourceText,
            [ref]$tokens,
            [ref]$parseErrors
        )
        $sourceLabel = $SourceName
    }
    Assert-True ($parseErrors.Count -eq 0) "$sourceLabel has PowerShell parse errors: $($parseErrors.Message -join '; ')"

    return [pscustomobject]@{
        Ast = $ast
        Text = $text
    }
}

function Get-VariableAssignments {
    param(
        [System.Management.Automation.Language.Ast]$Ast,
        [string]$VariableName
    )

    return @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $node.Left.VariablePath.UserPath -eq $VariableName
    }, $true))
}

function Get-CommandParameterArgument {
    param(
        [System.Management.Automation.Language.CommandAst]$Command,
        [string]$ParameterName
    )

    for ($index = 0; $index -lt $Command.CommandElements.Count; $index++) {
        $element = $Command.CommandElements[$index]
        if (
            $element -is [System.Management.Automation.Language.CommandParameterAst] -and
            $element.ParameterName -eq $ParameterName
        ) {
            if (($index + 1) -lt $Command.CommandElements.Count) {
                return $Command.CommandElements[$index + 1]
            }
            return $null
        }
    }

    return $null
}

function Test-CommandParameter {
    param(
        [System.Management.Automation.Language.CommandAst]$Command,
        [string]$ParameterName
    )

    return @($Command.CommandElements | Where-Object {
        $_ -is [System.Management.Automation.Language.CommandParameterAst] -and
        $_.ParameterName -eq $ParameterName
    }).Count -eq 1
}

function Resolve-HereStringAssignment {
    param(
        [System.Management.Automation.Language.Ast]$Ast,
        [string]$VariableName,
        [string]$WriterLabel,
        [System.Collections.Generic.List[string]]$Failures,
        [hashtable]$AssignmentIndex
    )

    $assignments = if ($null -ne $AssignmentIndex -and $AssignmentIndex.ContainsKey($VariableName)) {
        @($AssignmentIndex[$VariableName])
    } elseif ($null -ne $AssignmentIndex) {
        @()
    } else {
        @(Get-VariableAssignments -Ast $Ast -VariableName $VariableName)
    }
    if ($assignments.Count -ne 1) {
        $Failures.Add("$WriterLabel must assign exactly one here-string to `$$VariableName")
        return $null
    }
    $expression = $assignments[0].Right
    if ($expression -is [System.Management.Automation.Language.CommandExpressionAst]) {
        $expression = $expression.Expression
    }
    if ($expression -isnot [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
        $Failures.Add("$WriterLabel `$$VariableName must be an expandable SQL here-string")
        return $null
    }

    return $expression.Extent.Text
}

function Get-ContainingFunctionName {
    param([System.Management.Automation.Language.Ast]$Ast)

    $current = $Ast.Parent
    while ($null -ne $current) {
        if ($current -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
            return $current.Name
        }
        $current = $current.Parent
    }

    return $null
}

function Get-SeedExecutedSqlContracts {
    param(
        [System.Management.Automation.Language.ScriptBlockAst]$Ast,
        [string]$WriterLabel,
        [System.Collections.Generic.List[string]]$Failures
    )

    $tenantSqlCommands = @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -eq 'Invoke-TenantSql'
    }, $true))
    $expectedBatchVariables = @(
        'SqlFoundation', 'SqlShift', 'SqlLeave', 'SqlLeaveExtra', 'SqlPayroll', 'SqlTax',
        'SqlBenefits', 'SqlExpense', 'SqlOnboarding', 'SqlTravel', 'SqlRecruitment',
        'SqlPerformance', 'SqlLms', 'SqlSuccession', 'SqlCompensation', 'SqlAssets',
        'SqlGrievance', 'SqlAnalytics', 'SqlOutbox', 'SqlWorkflow', 'SqlHrmsMaster',
        'SqlComm', 'SqlOps', 'SqlSummary'
    )
    $assignmentIndex = @{}
    foreach ($assignment in @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [System.Management.Automation.Language.VariableExpressionAst]
    }, $true))) {
        $assignmentName = $assignment.Left.VariablePath.UserPath
        if (-not $assignmentIndex.ContainsKey($assignmentName)) {
            $assignmentIndex[$assignmentName] = [System.Collections.Generic.List[object]]::new()
        }
        $assignmentIndex[$assignmentName].Add($assignment)
    }
    $batchContracts = @()
    foreach ($tenantSqlCommand in $tenantSqlCommands) {
        $sqlArgument = Get-CommandParameterArgument -Command $tenantSqlCommand -ParameterName 'Sql'
        if ($sqlArgument -isnot [System.Management.Automation.Language.VariableExpressionAst]) {
            $Failures.Add("$WriterLabel every Invoke-TenantSql boundary must receive one SQL variable")
            continue
        }
        $sqlVariable = $sqlArgument.VariablePath.UserPath
        $sqlText = Resolve-HereStringAssignment -Ast $Ast -VariableName $sqlVariable -WriterLabel $WriterLabel -Failures $Failures -AssignmentIndex $assignmentIndex
        $batchContracts += [pscustomobject]@{
            Command = $tenantSqlCommand
            SqlVariable = $sqlVariable
            SqlText = $sqlText
            Raw = Test-CommandParameter -Command $tenantSqlCommand -ParameterName 'Raw'
        }
    }
    $actualBatchVariables = @($batchContracts | ForEach-Object { $_.SqlVariable })
    foreach ($expectedBatchVariable in $expectedBatchVariables) {
        if (@($actualBatchVariables | Where-Object { $_ -eq $expectedBatchVariable }).Count -ne 1) {
            $Failures.Add("$WriterLabel SQL batch `$$expectedBatchVariable must execute exactly once through Invoke-TenantSql")
        }
    }
    foreach ($unexpectedBatchVariable in @($actualBatchVariables | Where-Object { $expectedBatchVariables -notcontains $_ })) {
        $Failures.Add("$WriterLabel unexpected SQL batch `$$unexpectedBatchVariable executes through Invoke-TenantSql")
    }

    $writeHereStrings = @($Ast.FindAll({
        param($node)
        if (
            $node -isnot [System.Management.Automation.Language.AssignmentStatementAst] -or
            $node.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]
        ) {
            return $false
        }
        $expression = $node.Right
        if ($expression -is [System.Management.Automation.Language.CommandExpressionAst]) {
            $expression = $expression.Expression
        }
        return (
            $expression -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -and
            $expression.Extent.Text -match '\b(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM|CREATE\s+TEMP\s+TABLE)\b'
        )
    }, $true))
    foreach ($writeHereString in $writeHereStrings) {
        $writeVariable = $writeHereString.Left.VariablePath.UserPath
        if (@($actualBatchVariables | Where-Object { $_ -eq $writeVariable }).Count -ne 1) {
            $Failures.Add("$WriterLabel write SQL `$$writeVariable must not bypass Invoke-TenantSql")
        }
    }

    $nodeCommands = @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -eq 'node'
    }, $true))
    if ($nodeCommands.Count -ne 1 -or (Get-ContainingFunctionName -Ast $nodeCommands[0]) -ne 'Invoke-TenantSql') {
        $Failures.Add("$WriterLabel must have exactly one node SQL runner invocation and it must be inside Invoke-TenantSql")
    }

    $invokeFunctions = @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Invoke-TenantSql'
    }, $true))
    if ($invokeFunctions.Count -ne 1) {
        $Failures.Add("$WriterLabel must define exactly one Invoke-TenantSql execution boundary")
        return $null
    }
    $invokeFunction = $invokeFunctions[0]
    $guardSql = Resolve-HereStringAssignment -Ast $Ast -VariableName 'TenantDatabaseGuardSql' -WriterLabel $WriterLabel -Failures $Failures -AssignmentIndex $assignmentIndex
    $guardedSqlAssignments = @(Get-VariableAssignments -Ast $invokeFunction.Body -VariableName 'GuardedSql')
    if (
        $guardedSqlAssignments.Count -ne 1 -or
        $guardedSqlAssignments[0].Right.Extent.Text -notmatch '^\s*\$TenantDatabaseGuardSql\s*\.\s*TrimEnd\s*\(\s*\)\s*\+.*\+\s*\$Sql\s*$'
    ) {
        $Failures.Add("$WriterLabel Invoke-TenantSql must prepend `$TenantDatabaseGuardSql to every raw or ordinary `$Sql batch")
    }
    $writeCalls = @($invokeFunction.Body.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
        $node.Member.Value -eq 'WriteAllText'
    }, $true))
    if (
        $writeCalls.Count -ne 1 -or
        $writeCalls[0].Arguments.Count -lt 2 -or
        $writeCalls[0].Arguments[1] -isnot [System.Management.Automation.Language.VariableExpressionAst] -or
        $writeCalls[0].Arguments[1].VariablePath.UserPath -ne 'GuardedSql'
    ) {
        $Failures.Add("$WriterLabel Invoke-TenantSql must write only `$GuardedSql to the file passed to the selected runner")
    }

    $rawCommands = @($tenantSqlCommands | Where-Object { Test-CommandParameter -Command $_ -ParameterName 'Raw' })
    if ($rawCommands.Count -ne 1) {
        $Failures.Add("$WriterLabel must have exactly one Invoke-TenantSql -Raw invocation")
        return $null
    }

    $rawSqlArgument = Get-CommandParameterArgument -Command $rawCommands[0] -ParameterName 'Sql'
    if ($rawSqlArgument -isnot [System.Management.Automation.Language.VariableExpressionAst]) {
        $Failures.Add("$WriterLabel raw runner must receive SQL through one variable")
        return $null
    }
    $rbacSqlVariable = $rawSqlArgument.VariablePath.UserPath
    $rbacSql = Resolve-HereStringAssignment -Ast $Ast -VariableName $rbacSqlVariable -WriterLabel $WriterLabel -Failures $Failures -AssignmentIndex $assignmentIndex

    $workflowCommands = @($tenantSqlCommands | Where-Object {
        $sqlArgument = Get-CommandParameterArgument -Command $_ -ParameterName 'Sql'
        $labelArgument = Get-CommandParameterArgument -Command $_ -ParameterName 'Label'
        $sqlArgument -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $labelArgument -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
        $labelArgument.Value -match '\bworkflow\b'
    })
    if ($workflowCommands.Count -ne 1) {
        $Failures.Add("$WriterLabel must pass exactly one workflow SQL here-string to Invoke-TenantSql")
        return $null
    }
    $workflowArgument = Get-CommandParameterArgument -Command $workflowCommands[0] -ParameterName 'Sql'
    $workflowSqlVariable = $workflowArgument.VariablePath.UserPath
    $workflowSql = Resolve-HereStringAssignment -Ast $Ast -VariableName $workflowSqlVariable -WriterLabel $WriterLabel -Failures $Failures -AssignmentIndex $assignmentIndex

    return [pscustomobject]@{
        RbacSql = $rbacSql
        RbacSqlVariable = $rbacSqlVariable
        WorkflowSql = $workflowSql
        WorkflowSqlVariable = $workflowSqlVariable
        GuardSql = $guardSql
        Batches = $batchContracts
    }
}

function Get-BootstrapExecutedSqlContract {
    param(
        [System.Management.Automation.Language.ScriptBlockAst]$Ast,
        [string]$WriterLabel,
        [System.Collections.Generic.List[string]]$Failures
    )

    $runnerCommands = @($Ast.FindAll({
        param($node)
        if ($node -isnot [System.Management.Automation.Language.CommandAst] -or $node.GetCommandName() -ne 'node') {
            return $false
        }
        $variables = @($node.CommandElements | Where-Object {
            $_ -is [System.Management.Automation.Language.VariableExpressionAst]
        } | ForEach-Object { $_.VariablePath.UserPath })
        return $variables -contains 'RunSqlRaw'
    }, $true))
    if ($runnerCommands.Count -ne 1) {
        $Failures.Add("$WriterLabel must invoke node with `$RunSqlRaw exactly once")
        return $null
    }

    $fileArgument = Get-CommandParameterArgument -Command $runnerCommands[0] -ParameterName 'f'
    if ($fileArgument -isnot [System.Management.Automation.Language.VariableExpressionAst]) {
        $Failures.Add("$WriterLabel raw runner must receive one SQL file variable through -f")
        return $null
    }
    $tempVariable = $fileArgument.VariablePath.UserPath

    $writeCalls = @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
        $node.Member.Value -eq 'WriteAllText'
    }, $true) | Where-Object {
        $_.Arguments.Count -ge 2 -and
        $_.Arguments[0] -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $_.Arguments[0].VariablePath.UserPath -eq $tempVariable -and
        $_.Arguments[1] -is [System.Management.Automation.Language.VariableExpressionAst]
    })
    if ($writeCalls.Count -ne 1) {
        $Failures.Add("$WriterLabel must write one SQL variable to the exact file passed to `$RunSqlRaw")
        return $null
    }
    $sqlVariable = $writeCalls[0].Arguments[1].VariablePath.UserPath
    $sqlText = Resolve-HereStringAssignment -Ast $Ast -VariableName $sqlVariable -WriterLabel $WriterLabel -Failures $Failures

    $runnerAssignments = @(Get-VariableAssignments -Ast $Ast -VariableName 'RunSqlRaw')
    if ($runnerAssignments.Count -ne 1 -or $runnerAssignments[0].Right.Extent.Text -notmatch "'run-sql-raw\.cjs'") {
        $Failures.Add("$WriterLabel `$RunSqlRaw must resolve to run-sql-raw.cjs")
    }

    return [pscustomobject]@{
        RbacSql = $sqlText
        RbacSqlVariable = $sqlVariable
        WorkflowSql = $null
        WorkflowSqlVariable = $null
    }
}

function Test-ExactSet {
    param(
        [string[]]$Actual,
        [string[]]$Expected
    )

    $actualSorted = @($Actual | Sort-Object -Unique)
    $expectedSorted = @($Expected | Sort-Object -Unique)
    return (
        $Actual.Count -eq $actualSorted.Count -and
        $actualSorted.Count -eq $expectedSorted.Count -and
        [string]::Join(',', $actualSorted) -eq [string]::Join(',', $expectedSorted)
    )
}

function Get-CanonicalRbacConfig {
    param(
        [System.Management.Automation.Language.ScriptBlockAst]$Ast,
        [string]$WriterLabel,
        [System.Collections.Generic.List[string]]$Failures
    )

    $assignments = @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $node.Left.VariablePath.UserPath -eq 'CanonicalRbac'
    }, $true))
    if ($assignments.Count -ne 1) {
        $Failures.Add("$WriterLabel must define exactly one `$CanonicalRbac data structure")
        return $null
    }

    try {
        return & ([scriptblock]::Create($assignments[0].Right.Extent.Text))
    } catch {
        $Failures.Add("$WriterLabel `$CanonicalRbac must be a self-contained PowerShell data expression: $($_.Exception.Message)")
        return $null
    }
}

function Assert-CanonicalWriterContract {
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Path')]
        [string]$Path,

        [Parameter(Mandatory = $true, ParameterSetName = 'Source')]
        [string]$SourceText,

        [string]$WriterLabel,
        [switch]$Seed,
        [switch]$Bootstrap
    )

    $contract = if ($PSCmdlet.ParameterSetName -eq 'Path') {
        Get-PowerShellContract -Path $Path
    } else {
        Get-PowerShellContract -SourceText $SourceText -SourceName "$WriterLabel mutation"
    }
    $writerText = $contract.Text
    $writerFailures = [System.Collections.Generic.List[string]]::new()
    $config = Get-CanonicalRbacConfig -Ast $contract.Ast -WriterLabel $WriterLabel -Failures $writerFailures

    $executedSql = if ($Seed) {
        Get-SeedExecutedSqlContracts -Ast $contract.Ast -WriterLabel $WriterLabel -Failures $writerFailures
    } elseif ($Bootstrap) {
        Get-BootstrapExecutedSqlContract -Ast $contract.Ast -WriterLabel $WriterLabel -Failures $writerFailures
    } else {
        $null
    }
    $rbacSql = if ($null -ne $executedSql) { $executedSql.RbacSql } else { '' }
    $workflowSql = if ($null -ne $executedSql) { $executedSql.WorkflowSql } else { '' }
    $guardSql = if ($null -ne $executedSql -and $Seed) { $executedSql.GuardSql } else { '' }

    $writerBehaviorText = $writerText
    if ($Seed) {
        foreach ($leaveType in @('cl', 'sl', 'pto')) {
            $identityPattern = [regex]::Escape(":leave_balance:tenant_admin:$leaveType")
            if (([regex]::Matches($writerText, $identityPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)).Count -ne 1) {
                $writerFailures.Add("$WriterLabel must preserve the deterministic lowercase tenant_admin $leaveType leave-balance seed identity")
            }
        }
        if ($writerText -match ':leave_balance:admin:(?:cl|sl|pto)') {
            $writerFailures.Add("$WriterLabel must not replace stable tenant_admin leave-balance identity seeds with admin")
        }
        $writerBehaviorText = [regex]::Replace(
            $writerBehaviorText,
            ':leave_balance:tenant_admin:(?:cl|sl|pto)',
            ':leave_balance:preserved_internal_identity',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
    }
    foreach ($retiredRoleName in @('DEMO_STAFF', 'LINE_MANAGER', 'HR_ADMIN', 'ACCOUNTING_APPROVER', 'TENANT_ADMIN')) {
        if ($writerBehaviorText -match "\b$retiredRoleName\b") {
            $writerFailures.Add("$WriterLabel must not create, assign, or advertise retired role $retiredRoleName")
        }
    }

    if ($null -ne $config) {
        $actualRoles = @($config.Roles | ForEach-Object {
            "$($_.Name):$($_.Inherits):$($_.AllPermissions):$($_.BootstrapManaged)".ToUpperInvariant()
        })
        $expectedRoles = @(
            'EMPLOYEE::FALSE:FALSE',
            'MANAGER:EMPLOYEE:FALSE:FALSE',
            'HR:EMPLOYEE:FALSE:TRUE',
            'PAYROLL:EMPLOYEE:FALSE:FALSE',
            'ADMIN::TRUE:TRUE'
        )
        if (-not (Test-ExactSet -Actual $actualRoles -Expected $expectedRoles)) {
            $writerFailures.Add("$WriterLabel canonical role definitions must be exactly EMPLOYEE, MANAGER, HR, PAYROLL, and ADMIN with the approved inheritance/management flags")
        }
        if (@($config.Roles | Where-Object { [string]::IsNullOrWhiteSpace($_.Description) }).Count -ne 0) {
            $writerFailures.Add("$WriterLabel canonical role descriptions must all be non-empty")
        }

        $actualPermissions = @($config.Permissions | ForEach-Object {
            "$($_.Resource):$($_.Action):$($_.Module)".ToUpperInvariant()
        })
        $expectedPermissions = @(
            'EMPLOYEE:SELF:EMPLOYEE', 'EMPLOYEE:READ:EMPLOYEE', 'EMPLOYEE:WRITE:EMPLOYEE', 'EMPLOYEE:MANAGE:EMPLOYEE',
            'NOTIFICATION:READ:EMPLOYEE', 'NOTIFICATION:MANAGE:EMPLOYEE', 'ROLE:MANAGE:EMPLOYEE',
            'ATTENDANCE:READ:ATTENDANCE', 'ATTENDANCE:PUNCH_SELF:ATTENDANCE', 'ATTENDANCE:REGULARIZE:ATTENDANCE', 'ATTENDANCE:PUNCH_POLICY:ATTENDANCE',
            'TIMESHEET:READ:ATTENDANCE', 'TIMESHEET:WRITE:ATTENDANCE', 'TIMESHEET:APPROVE:ATTENDANCE', 'TIMESHEET:MANAGE:ATTENDANCE',
            'LEAVE:READ:LEAVE', 'LEAVE:SUBMIT:LEAVE', 'LEAVE:APPROVE:LEAVE', 'LEAVE:MANAGE:LEAVE',
            'EXPENSE:READ:EXPENSE', 'EXPENSE:SUBMIT:EXPENSE', 'EXPENSE:APPROVE:EXPENSE', 'EXPENSE:MANAGE:EXPENSE', 'EXPENSE:PAY:EXPENSE',
            'TRAVEL:READ:EXPENSE', 'TRAVEL:SUBMIT:EXPENSE', 'TRAVEL:APPROVE:EXPENSE', 'TRAVEL:MANAGE:EXPENSE',
            'PAYROLL:READ:PAYROLL', 'PAYROLL:MANAGE:PAYROLL', 'PAYROLL:STATUTORY_EXPORT:PAYROLL',
            'TAX:READ:TAX', 'TAX:SUBMIT:TAX', 'TAX:APPROVE:TAX', 'TAX:MANAGE:TAX',
            'WORKFLOW:MANAGE:WORKFLOW'
        )
        if (-not (Test-ExactSet -Actual $actualPermissions -Expected $expectedPermissions)) {
            $writerFailures.Add("$WriterLabel permission catalogue must match the exact 0067 resource/action/module ownership model")
        }
        if (@($config.Permissions | Where-Object { [string]::IsNullOrWhiteSpace($_.Description) }).Count -ne 0) {
            $writerFailures.Add("$WriterLabel permission catalogue descriptions must all be non-empty")
        }

        $actualGrants = @($config.Grants | ForEach-Object {
            "$($_.Role):$($_.Resource):$($_.Action):$($_.Scope)".ToUpperInvariant()
        })
        $expectedGrants = @(
            'EMPLOYEE:EMPLOYEE:SELF:SELF',
            'EMPLOYEE:ATTENDANCE:READ:SELF', 'EMPLOYEE:ATTENDANCE:PUNCH_SELF:SELF',
            'EMPLOYEE:TIMESHEET:READ:SELF', 'EMPLOYEE:TIMESHEET:WRITE:SELF',
            'EMPLOYEE:LEAVE:READ:SELF', 'EMPLOYEE:LEAVE:SUBMIT:SELF',
            'EMPLOYEE:EXPENSE:READ:SELF', 'EMPLOYEE:EXPENSE:SUBMIT:SELF',
            'EMPLOYEE:TRAVEL:READ:SELF', 'EMPLOYEE:TRAVEL:SUBMIT:SELF',
            'EMPLOYEE:PAYROLL:READ:SELF',
            'EMPLOYEE:TAX:READ:SELF', 'EMPLOYEE:TAX:SUBMIT:SELF',
            'EMPLOYEE:NOTIFICATION:READ:SELF',
            'EMPLOYEE:BENEFITS:SELF:SELF', 'EMPLOYEE:ONBOARDING:SELF:SELF', 'EMPLOYEE:GRIEVANCE:SELF:SELF', 'EMPLOYEE:ASSETS:SELF:SELF',
            'MANAGER:EMPLOYEE:READ:TEAM',
            'MANAGER:ATTENDANCE:READ:TEAM', 'MANAGER:ATTENDANCE:REGULARIZE:TEAM',
            'MANAGER:TIMESHEET:READ:TEAM', 'MANAGER:TIMESHEET:APPROVE:TEAM',
            'MANAGER:LEAVE:READ:TEAM', 'MANAGER:LEAVE:APPROVE:TEAM',
            'MANAGER:EXPENSE:READ:TEAM', 'MANAGER:EXPENSE:APPROVE:TEAM',
            'MANAGER:TRAVEL:READ:TEAM', 'MANAGER:TRAVEL:APPROVE:TEAM',
            'HR:EMPLOYEE:READ:ALL', 'HR:EMPLOYEE:WRITE:ALL', 'HR:EMPLOYEE:MANAGE:ALL',
            'HR:ATTENDANCE:READ:ALL', 'HR:ATTENDANCE:REGULARIZE:ALL', 'HR:ATTENDANCE:PUNCH_POLICY:ALL',
            'HR:TIMESHEET:READ:ALL', 'HR:TIMESHEET:APPROVE:ALL', 'HR:TIMESHEET:MANAGE:ALL',
            'HR:LEAVE:READ:ALL', 'HR:LEAVE:APPROVE:ALL', 'HR:LEAVE:MANAGE:ALL',
            'HR:EXPENSE:READ:ALL', 'HR:EXPENSE:APPROVE:ALL', 'HR:EXPENSE:MANAGE:ALL',
            'HR:TRAVEL:READ:ALL', 'HR:TRAVEL:APPROVE:ALL', 'HR:TRAVEL:MANAGE:ALL',
            'HR:WORKFLOW:MANAGE:ALL', 'HR:NOTIFICATION:MANAGE:ALL',
            'HR:BENEFITS:MANAGE:ALL', 'HR:RECRUITMENT:MANAGE:ALL', 'HR:ONBOARDING:MANAGE:ALL',
            'HR:PERFORMANCE:MANAGE:ALL', 'HR:LEARNING:MANAGE:ALL', 'HR:ASSETS:MANAGE:ALL',
            'HR:GRIEVANCE:MANAGE:ALL', 'HR:SUCCESSION:MANAGE:ALL', 'HR:COMPENSATION:MANAGE:ALL', 'HR:ANALYTICS:READ:ALL',
            'PAYROLL:PAYROLL:READ:ALL', 'PAYROLL:PAYROLL:MANAGE:ALL', 'PAYROLL:PAYROLL:STATUTORY_EXPORT:ALL',
            'PAYROLL:TAX:READ:ALL', 'PAYROLL:TAX:APPROVE:ALL', 'PAYROLL:TAX:MANAGE:ALL',
            'PAYROLL:EXPENSE:READ:ALL', 'PAYROLL:EXPENSE:APPROVE:ALL', 'PAYROLL:EXPENSE:PAY:ALL'
        )
        if (-not (Test-ExactSet -Actual $actualGrants -Expected $expectedGrants)) {
            $writerFailures.Add("$WriterLabel direct canonical grants/scopes must match 0067 exactly, including optional existing workplace permissions")
        }

        $actualAdminSelfScopes = @($config.AdminSelfScopes | ForEach-Object {
            "$($_.Resource):$($_.Action)".ToUpperInvariant()
        })
        $expectedAdminSelfScopes = @(
            '*:SELF', 'ATTENDANCE:PUNCH_SELF', 'TIMESHEET:WRITE', 'LEAVE:SUBMIT',
            'EXPENSE:SUBMIT', 'TRAVEL:SUBMIT', 'TAX:SUBMIT', 'NOTIFICATION:READ'
        )
        if (-not (Test-ExactSet -Actual $actualAdminSelfScopes -Expected $expectedAdminSelfScopes)) {
            $writerFailures.Add("$WriterLabel ADMIN intrinsic SELF-scope rules must match 0067 exactly")
        }
    }

    $canonicalJsonAssignments = @(Get-VariableAssignments -Ast $contract.Ast -VariableName 'CanonicalRbacJson')
    if (
        $canonicalJsonAssignments.Count -ne 1 -or
        $canonicalJsonAssignments[0].Right.Extent.Text -notmatch '^\s*\$CanonicalRbac\s*\|\s*ConvertTo-Json\b'
    ) {
        $writerFailures.Add("$WriterLabel must serialize `$CanonicalRbac exactly once into `$CanonicalRbacJson")
    }
    $canonicalJsonSqlAssignments = @(Get-VariableAssignments -Ast $contract.Ast -VariableName 'CanonicalRbacJsonSql')
    if (
        $canonicalJsonSqlAssignments.Count -ne 1 -or
        $canonicalJsonSqlAssignments[0].Right.Extent.Text -notmatch '\$CanonicalRbacJson\.Replace\('
    ) {
        $writerFailures.Add("$WriterLabel must SQL-escape only the serialized `$CanonicalRbacJson value")
    }
    if ($rbacSql -notmatch "INSERT\s+INTO\s+canonical_rbac_config\s*\(\s*payload\s*\)\s*VALUES\s*\(\s*'\`$CanonicalRbacJsonSql'::jsonb\s*\)") {
        $writerFailures.Add("$WriterLabel executed RBAC SQL must load `$CanonicalRbacJsonSql into canonical_rbac_config")
    }

    $configLinks = @(
        @{ JsonKey = 'Roles'; Target = 'canonical_role_definitions'; Label = 'role definitions' },
        @{ JsonKey = 'Permissions'; Target = 'canonical_permission_catalog'; Label = 'permission catalogue' },
        @{ JsonKey = 'Grants'; Target = 'canonical_direct_grants'; Label = 'direct grants' },
        @{ JsonKey = 'AdminSelfScopes'; Target = 'canonical_admin_self_scopes'; Label = 'ADMIN self scopes' }
    )
    foreach ($configLink in $configLinks) {
        $target = [regex]::Escape($configLink.Target)
        $jsonKey = [regex]::Escape($configLink.JsonKey)
        $pattern = "INSERT\s+INTO\s+$target\b(?s:.*?)FROM\s+canonical_rbac_config\s+CROSS\s+JOIN\s+LATERAL\s+jsonb_array_elements\s*\(\s*payload\s*->\s*'$jsonKey'\s*\)"
        if (([regex]::Matches($rbacSql, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)).Count -ne 1) {
            $writerFailures.Add("$WriterLabel executed RBAC SQL must derive $($configLink.Label) exactly once from canonical_rbac_config.$($configLink.JsonKey)")
        }
    }

    $permissionWriterPattern = 'INSERT\s+INTO\s+(?:%I|"\$Schema")\.permission\s*\([^;]+?FROM\s+canonical_permission_catalog\b'
    if (([regex]::Matches($rbacSql, $permissionWriterPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)).Count -ne 1) {
        $writerFailures.Add("$WriterLabel executed permission writer must consume canonical_permission_catalog exactly once")
    }

    $matrixRegion = [regex]::Match(
        $rbacSql,
        'CREATE\s+TEMP\s+TABLE\s+canonical_permission_matrix\b(?<body>.*?)DELETE\s+FROM\s+(?:%I|"\$Schema")\.role_permission\b',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline
    )
    if (-not $matrixRegion.Success) {
        $writerFailures.Add("$WriterLabel executed RBAC SQL must materialize one canonical_permission_matrix before managed grant deletion")
    } else {
        $matrixSql = $matrixRegion.Groups['body'].Value
        foreach ($matrixInput in @(
            @{ Pattern = '\bFROM\s+canonical_direct_grants\b'; Label = 'direct grants' },
            @{ Pattern = '\bFROM\s+canonical_role_definitions\b'; Label = 'role inheritance' },
            @{ Pattern = '\bFROM\s+canonical_admin_self_scopes\b'; Label = 'ADMIN self-scope rules' },
            @{ Pattern = '\bJOIN\s+canonical_managed_roles\b'; Label = 'managed-role filter' },
            @{ Pattern = 'INSERT\s+INTO\s+canonical_permission_matrix\b'; Label = 'matrix materialization' }
        )) {
            if ($matrixSql -notmatch $matrixInput.Pattern) {
                $writerFailures.Add("$WriterLabel canonical_permission_matrix must consume $($matrixInput.Label)")
            }
        }
    }

    $rolePermissionWriterPattern = 'INSERT\s+INTO\s+(?:%I|"\$Schema")\.role_permission\b[^;]*?FROM\s+canonical_permission_matrix\b'
    $permissionScopeWriterPattern = 'INSERT\s+INTO\s+(?:%I|"\$Schema")\.permission_scope\b[^;]*?FROM\s+canonical_permission_matrix\b'
    if (([regex]::Matches($rbacSql, $rolePermissionWriterPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)).Count -ne 1) {
        $writerFailures.Add("$WriterLabel executed role_permission writer must consume canonical_permission_matrix exactly once")
    }
    if (([regex]::Matches($rbacSql, $permissionScopeWriterPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)).Count -ne 1) {
        $writerFailures.Add("$WriterLabel executed permission_scope writer must consume canonical_permission_matrix exactly once")
    }
    if ($rbacSql -match 'DELETE\s+FROM\s+(?:%I|"\$Schema")\.role\b') {
        $writerFailures.Add("$WriterLabel executed RBAC SQL must never delete tenant roles, including custom roles")
    }

    $beginMatches = @([regex]::Matches($rbacSql, '(?m)^\s*BEGIN\s*;', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase))
    $commitMatches = @([regex]::Matches($rbacSql, '(?m)^\s*COMMIT\s*;', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase))
    if ($beginMatches.Count -ne 1 -or $commitMatches.Count -ne 1 -or $beginMatches[0].Index -ge $commitMatches[0].Index) {
        $writerFailures.Add("$WriterLabel executed RBAC SQL must have one ordered BEGIN/COMMIT transaction")
    }

    if ($Seed) {
        $tenantParameters = @($contract.Ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.ParameterAst] -and
            $node.Name.VariablePath.UserPath -eq 'TenantId'
        }, $true))
        if ($tenantParameters.Count -ne 1 -or $tenantParameters[0].StaticType -ne [Guid]) {
            $writerFailures.Add('demo seed TenantId parameter must be [Guid]')
        }
        $canonicalTenantAssignments = @(Get-VariableAssignments -Ast $contract.Ast -VariableName 'CanonicalTenantId')
        if (
            $canonicalTenantAssignments.Count -ne 1 -or
            $canonicalTenantAssignments[0].Right.Extent.Text -notmatch "^\s*\`$TenantId\.ToString\(\s*'D'\s*\)\.ToLowerInvariant\(\s*\)\s*$"
        ) {
            $writerFailures.Add('demo seed must serialize TenantId once as the canonical lowercase D-format UUID')
        }

        $tenantToken = [regex]::Escape("'`$CanonicalTenantId'::uuid")
        $schemaToken = [regex]::Escape("'`$Schema'")
        $mappingPattern = "SELECT\s+1\s*/\s*CASE\s+WHEN\s+COUNT\s*\(\s*\*\s*\)\s*=\s*1\s+THEN\s+1\s+ELSE\s+0\s+END\s+AS\s+seed_tenant_database_mapping_guard\s+FROM\s+kabipay_ops\.tenant_database\s+AS\s+tenant_database\s+WHERE\s+tenant_database\.tenant_id\s*=\s*$tenantToken\s+AND\s+tenant_database\.schema_name\s*=\s*$schemaToken"
        $mappingMatch = [regex]::Match(
            $guardSql,
            $mappingPattern,
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline
        )
        if (-not $mappingMatch.Success) {
            $writerFailures.Add('demo seed centralized execution guard must require exactly one matching tenant UUID plus schema row')
        }
        $batchGuardCopies = @($executedSql.Batches | Where-Object { $_.SqlText -match '\bkabipay_ops\.tenant_database\b' })
        if ($batchGuardCopies.Count -ne 0) {
            $writerFailures.Add('demo seed tenant_database guard must be centralized in Invoke-TenantSql, not copied into individual SQL batches')
        }

        $personaRoleMatch = [regex]::Match(
            $rbacSql,
            'seeded_persona_roles\s*\(\s*user_id\s*,\s*role_name\s*\)\s+AS\s*\(\s*VALUES\s*(?<values>(?:\(\s*''\$[A-Za-z][A-Za-z0-9]*''\s*,\s*''[A-Z]+''\s*\)\s*,?\s*)+)\)',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        if (-not $personaRoleMatch.Success) {
            $writerFailures.Add('demo seed must define seeded_persona_roles with explicit canonical assignments')
        } else {
            $actualPersonaRoles = @([regex]::Matches($personaRoleMatch.Groups['values'].Value, '''\$(?<user>[A-Za-z][A-Za-z0-9]*)''\s*,\s*''(?<role>[A-Z]+)''') | ForEach-Object {
                "$($_.Groups['user'].Value)->$($_.Groups['role'].Value)".ToUpperInvariant()
            })
            $expectedPersonaRoles = @(
                'STAFFUSERID->EMPLOYEE', 'MANAGERUSERID->MANAGER', 'USERID->HR',
                'ACCOUNTINGUSERID->PAYROLL', 'TENANTADMINUSERID->ADMIN'
            )
            if (-not (Test-ExactSet -Actual $actualPersonaRoles -Expected $expectedPersonaRoles)) {
                $writerFailures.Add('demo seed persona assignments must be staff EMPLOYEE, line manager MANAGER, HR demo HR, accounting PAYROLL, and tenant admin ADMIN')
            }
        }
        foreach ($workflowStage in @(
            @{ StepVariable = 'WorkflowStep1Id'; ApproverType = 'REPORTING_MANAGER_OR_ROLE'; Role = 'HR' },
            @{ StepVariable = 'ExpenseWorkflowStep1Id'; ApproverType = 'REPORTING_MANAGER_OR_ROLE'; Role = 'HR' },
            @{ StepVariable = 'ExpenseWorkflowStep2Id'; ApproverType = 'ROLE'; Role = 'PAYROLL' },
            @{ StepVariable = 'TravelWorkflowStep1Id'; ApproverType = 'REPORTING_MANAGER_OR_ROLE'; Role = 'HR' },
            @{ StepVariable = 'TravelWorkflowStep2Id'; ApproverType = 'ROLE'; Role = 'PAYROLL' },
            @{ StepVariable = 'TimesheetWorkflowStep1Id'; ApproverType = 'REPORTING_MANAGER_OR_ROLE'; Role = 'HR' }
        )) {
            $stepLiteral = "'" + '$' + $workflowStage.StepVariable + "'"
            $stepPattern = [regex]::Escape($stepLiteral) +
                ".{0,600}'$([regex]::Escape($workflowStage.ApproverType))'\s*,\s*\(\s*SELECT\s+canonical_role\.id.{0,400}UPPER\s*\(\s*TRIM\s*\(\s*canonical_role\.name\s*\)\s*\)\s*=\s*'$([regex]::Escape($workflowStage.Role))'"
            if (([regex]::Matches($workflowSql, $stepPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)).Count -ne 1) {
                $writerFailures.Add("demo seed workflow stage `$$($workflowStage.StepVariable) must use $($workflowStage.ApproverType) with canonical $($workflowStage.Role)")
            }
        }

        $seedRolePermissionDelete = 'DELETE\s+FROM\s+"\$Schema"\.role_permission\s+AS\s+role_permission\s+USING\s+"\$Schema"\.role\s+AS\s+canonical_role\s*,\s*canonical_managed_roles\s+WHERE\s+role_permission\.role_id\s*=\s*canonical_role\.id\s+AND\s+canonical_role\.tenant_id\s*=\s*''\$CanonicalTenantId''\s+AND\s+UPPER\s*\(\s*TRIM\s*\(\s*canonical_role\.name\s*\)\s*\)\s*=\s*canonical_managed_roles\.role_name'
        $seedScopeDelete = 'DELETE\s+FROM\s+"\$Schema"\.permission_scope\s+AS\s+permission_scope\s+USING\s+"\$Schema"\.role\s+AS\s+canonical_role\s*,\s*canonical_managed_roles\s+WHERE\s+permission_scope\.role_id\s*=\s*canonical_role\.id\s+AND\s+canonical_role\.tenant_id\s*=\s*''\$CanonicalTenantId''\s+AND\s+UPPER\s*\(\s*TRIM\s*\(\s*canonical_role\.name\s*\)\s*\)\s*=\s*canonical_managed_roles\.role_name'
        if (([regex]::Matches($rbacSql, $seedRolePermissionDelete, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)).Count -ne 1) {
            $writerFailures.Add('demo seed role_permission deletion must be limited to exact canonical managed role IDs for the canonical tenant')
        }
        if (([regex]::Matches($rbacSql, $seedScopeDelete, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)).Count -ne 1) {
            $writerFailures.Add('demo seed permission_scope deletion must be limited to exact canonical managed role IDs for the canonical tenant')
        }
    }

    if ($Bootstrap) {
        if ($rbacSql -notmatch "bootstrap_admin_role\s*\(\s*role_name\s*\)\s+AS\s*\(\s*VALUES\s*\(\s*'ADMIN'\s*\)\s*\)") {
            $writerFailures.Add('admin bootstrap must assign tenant administrators through the single canonical ADMIN role')
        }
        if ($rbacSql -notmatch 'INSERT\s+INTO\s+canonical_managed_roles\s*\(\s*role_name\s*\)\s+SELECT\s+role_name\s+FROM\s+canonical_role_definitions\s+WHERE\s+bootstrap_managed\s*=\s*true') {
            $writerFailures.Add('admin bootstrap executed SQL must derive exactly HR and ADMIN from BootstrapManaged role definitions')
        }
        foreach ($deleteContract in @(
            @{ Table = 'role_permission'; Alias = 'role_permission' },
            @{ Table = 'permission_scope'; Alias = 'permission_scope' }
        )) {
            $deletePattern = "DELETE\s+FROM\s+%I\.$($deleteContract.Table)\s+AS\s+$($deleteContract.Alias)\s+USING\s+canonical_managed_role_ids\s+WHERE\s+$($deleteContract.Alias)\.role_id\s*=\s*canonical_managed_role_ids\.role_id"
            if (([regex]::Matches($rbacSql, $deletePattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)).Count -ne 1) {
                $writerFailures.Add("admin bootstrap $($deleteContract.Table) deletion must be limited to canonical managed role IDs")
            }
        }
    }

    if ($writerFailures.Count -ne 0) {
        throw "$WriterLabel canonical provisioning contract failed:`n - $($writerFailures -join "`n - ")"
    }
}

function Assert-BootstrapAdminArraySerialization {
    param([string]$SourceText)

    $contract = Get-PowerShellContract -SourceText $SourceText -SourceName 'Tenant-admin bootstrap writer'
    $assignments = @(Get-VariableAssignments -Ast $contract.Ast -VariableName 'adminsJson')
    Assert-True ($assignments.Count -eq 1) 'admin bootstrap must assign $adminsJson exactly once'
    $serializationExpression = $assignments[0].Right.Extent.Text

    foreach ($adminCount in @(1, 2)) {
        $admins = New-Object 'System.Collections.Generic.List[object]'
        for ($index = 1; $index -le $adminCount; $index++) {
            $admins.Add([pscustomobject]@{
                username = "admin$index"
                first_name = 'Admin'
                last_name = "User$index"
                employee_code = "ADM-$index"
            })
        }

        $json = & ([scriptblock]::Create($serializationExpression))
        Assert-True ($json -match '^\s*\[') "admin bootstrap must serialize $adminCount administrator(s) as a JSON array"
        $decoded = ConvertFrom-Json -InputObject $json
        Assert-True ($decoded.Count -eq $adminCount) "admin bootstrap JSON array must preserve all $adminCount administrator(s)"
        for ($index = 1; $index -le $adminCount; $index++) {
            Assert-True ($decoded[$index - 1].username -eq "admin$index") "admin bootstrap JSON array must preserve administrator order and values"
        }
    }
}

function Assert-WriterMutationRejected {
    param(
        [string]$SourceText,
        [string]$Pattern,
        [string]$Replacement,
        [string]$MutationLabel,
        [string]$ExpectedFailure,
        [switch]$Seed,
        [switch]$Bootstrap
    )

    $regexOptions = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline
    $regex = [regex]::new($Pattern, $regexOptions)
    $matches = @($regex.Matches($SourceText))
    Assert-True ($matches.Count -eq 1) "mutation fixture '$MutationLabel' must match exactly one production location, found $($matches.Count)"
    $mutatedSource = $regex.Replace($SourceText, $Replacement, 1)

    $rejected = $false
    $failureMessage = ''
    try {
        $assertionParameters = @{
            SourceText = $mutatedSource
            WriterLabel = "$MutationLabel mutation"
        }
        if ($Seed) { $assertionParameters.Seed = $true }
        if ($Bootstrap) { $assertionParameters.Bootstrap = $true }
        Assert-CanonicalWriterContract @assertionParameters
    } catch {
        $rejected = $true
        $failureMessage = $_.Exception.Message
    }

    Assert-True $rejected "validator must reject mutation: $MutationLabel"
    Assert-True ($failureMessage -like "*$ExpectedFailure*") "mutation '$MutationLabel' was rejected for the wrong reason: $failureMessage"
}

function Assert-WriterMutationCoverage {
    param(
        [string]$SeedSource,
        [string]$BootstrapSource
    )

    foreach ($writerCase in @(
        @{ Source = $SeedSource; Label = 'seed'; Seed = $true; Bootstrap = $false },
        @{ Source = $BootstrapSource; Label = 'bootstrap'; Seed = $false; Bootstrap = $true }
    )) {
        $switches = @{}
        if ($writerCase.Seed) { $switches.Seed = $true }
        if ($writerCase.Bootstrap) { $switches.Bootstrap = $true }

        Assert-WriterMutationRejected @switches `
            -SourceText $writerCase.Source `
            -Pattern ([regex]::Escape("VALUES ('`$CanonicalRbacJsonSql'::jsonb);")) `
            -Replacement 'VALUES (''$DisconnectedCanonicalJsonSql''::jsonb);' `
            -MutationLabel "$($writerCase.Label) canonical JSON to config" `
            -ExpectedFailure 'must load $CanonicalRbacJsonSql into canonical_rbac_config'

        foreach ($configLink in @(
            @{ Key = 'Roles'; Label = 'role definitions' },
            @{ Key = 'Permissions'; Label = 'permission catalogue' },
            @{ Key = 'Grants'; Label = 'direct grants' },
            @{ Key = 'AdminSelfScopes'; Label = 'ADMIN self scopes' }
        )) {
            Assert-WriterMutationRejected @switches `
                -SourceText $writerCase.Source `
                -Pattern ("FROM\s+canonical_rbac_config(?=\s+CROSS\s+JOIN\s+LATERAL\s+jsonb_array_elements\s*\(\s*payload\s*->\s*'$([regex]::Escape($configLink.Key))'\s*\))") `
                -Replacement 'FROM disconnected_rbac_config' `
                -MutationLabel "$($writerCase.Label) config to $($configLink.Label)" `
                -ExpectedFailure "derive $($configLink.Label) exactly once"
        }

        Assert-WriterMutationRejected @switches `
            -SourceText $writerCase.Source `
            -Pattern '(?<prefix>INSERT\s+INTO\s+(?:%I|"\$Schema")\.permission\s*\([^;]+?)FROM\s+canonical_permission_catalog\b' `
            -Replacement '${prefix}FROM disconnected_permission_catalog' `
            -MutationLabel "$($writerCase.Label) catalogue to permission writer" `
            -ExpectedFailure 'permission writer must consume canonical_permission_catalog'

        Assert-WriterMutationRejected @switches `
            -SourceText $writerCase.Source `
            -Pattern 'FROM\s+canonical_direct_grants(?<suffix>\s+UNION\s+ALL)' `
            -Replacement 'FROM disconnected_direct_grants${suffix}' `
            -MutationLabel "$($writerCase.Label) direct grants to matrix" `
            -ExpectedFailure 'canonical_permission_matrix must consume direct grants'

        Assert-WriterMutationRejected @switches `
            -SourceText $writerCase.Source `
            -Pattern '(?<prefix>INSERT\s+INTO\s+(?:%I|"\$Schema")\.role_permission\b.*?)FROM\s+canonical_permission_matrix\b' `
            -Replacement '${prefix}FROM disconnected_permission_matrix' `
            -MutationLabel "$($writerCase.Label) matrix to role grants" `
            -ExpectedFailure 'role_permission writer must consume canonical_permission_matrix'

        Assert-WriterMutationRejected @switches `
            -SourceText $writerCase.Source `
            -Pattern '(?<prefix>INSERT\s+INTO\s+(?:%I|"\$Schema")\.permission_scope\b.*?)FROM\s+canonical_permission_matrix\b' `
            -Replacement '${prefix}FROM disconnected_permission_matrix' `
            -MutationLabel "$($writerCase.Label) matrix to scopes" `
            -ExpectedFailure 'permission_scope writer must consume canonical_permission_matrix'

        Assert-WriterMutationRejected @switches `
            -SourceText $writerCase.Source `
            -Pattern '(?m)^\s*BEGIN\s*;' `
            -Replacement 'SELECT 1;' `
            -MutationLabel "$($writerCase.Label) transaction begin" `
            -ExpectedFailure 'must have one ordered BEGIN/COMMIT transaction'

        Assert-WriterMutationRejected @switches `
            -SourceText $writerCase.Source `
            -Pattern '(?m)^\s*COMMIT\s*;' `
            -Replacement 'SELECT 1;' `
            -MutationLabel "$($writerCase.Label) transaction commit" `
            -ExpectedFailure 'must have one ordered BEGIN/COMMIT transaction'
    }

    Assert-WriterMutationRejected -Seed `
        -SourceText $SeedSource `
        -Pattern ([regex]::Escape('-Sql $SqlFoundation -Raw')) `
        -Replacement '-Sql $SqlShift -Raw' `
        -MutationLabel 'seed raw SQL binding' `
        -ExpectedFailure 'executed RBAC SQL must load $CanonicalRbacJsonSql'

    Assert-WriterMutationRejected -Seed `
        -SourceText $SeedSource `
        -Pattern 'tenant_database\.tenant_id\s*=\s*''\$CanonicalTenantId''::uuid' `
        -Replacement 'tenant_database.tenant_id = gen_random_uuid()' `
        -MutationLabel 'seed tenant mapping tenant ID' `
        -ExpectedFailure 'centralized execution guard must require exactly one matching tenant UUID plus schema row'

    Assert-WriterMutationRejected -Seed `
        -SourceText $SeedSource `
        -Pattern 'tenant_database\.schema_name\s*=\s*''\$Schema''' `
        -Replacement 'tenant_database.schema_name = ''tenant_other''' `
        -MutationLabel 'seed tenant mapping schema' `
        -ExpectedFailure 'centralized execution guard must require exactly one matching tenant UUID plus schema row'

    Assert-WriterMutationRejected -Seed `
        -SourceText $SeedSource `
        -Pattern 'COUNT\s*\(\s*\*\s*\)\s*=\s*1' `
        -Replacement 'COUNT(*) > 0' `
        -MutationLabel 'seed tenant mapping exact cardinality' `
        -ExpectedFailure 'centralized execution guard must require exactly one matching tenant UUID plus schema row'

    Assert-WriterMutationRejected -Seed `
        -SourceText $SeedSource `
        -Pattern '\$GuardedSql\s*=\s*\$TenantDatabaseGuardSql\.TrimEnd\(\)\s*\+\s*\[Environment\]::NewLine\s*\+\s*\$Sql' `
        -Replacement '$GuardedSql = $Sql + [Environment]::NewLine + $TenantDatabaseGuardSql.TrimEnd()' `
        -MutationLabel 'seed centralized guard pre-write order' `
        -ExpectedFailure 'must prepend $TenantDatabaseGuardSql to every raw or ordinary $Sql batch'

    Assert-WriterMutationRejected -Seed `
        -SourceText $SeedSource `
        -Pattern '(?<prefix>\[System\.IO\.File\]::WriteAllText\(\$tmp\s*,\s*)\$GuardedSql' `
        -Replacement '${prefix}$Sql' `
        -MutationLabel 'seed guarded wrapper file dataflow' `
        -ExpectedFailure 'must write only $GuardedSql to the file passed to the selected runner'

    Assert-WriterMutationRejected -Seed `
        -SourceText $SeedSource `
        -Pattern ([regex]::Escape('Invoke-TenantSql -Label "0025 workflow (workflow + instance)" -Sql $SqlWorkflow')) `
        -Replacement '& node $RunSql -f $SqlWorkflow' `
        -MutationLabel 'seed later workflow batch bypass' `
        -ExpectedFailure 'SQL batch $SqlWorkflow must execute exactly once through Invoke-TenantSql'

    Assert-WriterMutationRejected -Seed `
        -SourceText $SeedSource `
        -Pattern '(?<prefix>DELETE\s+FROM\s+"\$Schema"\.role_permission\s+AS\s+role_permission\s+)USING\s+"\$Schema"\.role\s+AS\s+canonical_role\s*,\s*canonical_managed_roles' `
        -Replacement '${prefix}USING "$Schema".role AS canonical_role, disconnected_managed_roles' `
        -MutationLabel 'seed custom-role-safe grant deletion' `
        -ExpectedFailure 'role_permission deletion must be limited to exact canonical managed role IDs'

    Assert-WriterMutationRejected -Seed `
        -SourceText $SeedSource `
        -Pattern '(?<prefix>DELETE\s+FROM\s+"\$Schema"\.permission_scope\s+AS\s+permission_scope\s+)USING\s+"\$Schema"\.role\s+AS\s+canonical_role\s*,\s*canonical_managed_roles' `
        -Replacement '${prefix}USING "$Schema".role AS canonical_role, disconnected_managed_roles' `
        -MutationLabel 'seed custom-role-safe scope deletion' `
        -ExpectedFailure 'permission_scope deletion must be limited to exact canonical managed role IDs'

    foreach ($workflowStage in @(
        @{ StepVariable = 'WorkflowStep1Id'; Role = 'HR' },
        @{ StepVariable = 'ExpenseWorkflowStep1Id'; Role = 'HR' },
        @{ StepVariable = 'ExpenseWorkflowStep2Id'; Role = 'PAYROLL' },
        @{ StepVariable = 'TravelWorkflowStep1Id'; Role = 'HR' },
        @{ StepVariable = 'TravelWorkflowStep2Id'; Role = 'PAYROLL' },
        @{ StepVariable = 'TimesheetWorkflowStep1Id'; Role = 'HR' }
    )) {
        $stepLiteral = "'" + '$' + $workflowStage.StepVariable + "'"
        $workflowPattern = '(?<prefix>' + [regex]::Escape($stepLiteral) +
            ".{0,900}UPPER\s*\(\s*TRIM\s*\(\s*canonical_role\.name\s*\)\s*\)\s*=\s*)'$([regex]::Escape($workflowStage.Role))'"
        Assert-WriterMutationRejected -Seed `
            -SourceText $SeedSource `
            -Pattern $workflowPattern `
            -Replacement '${prefix}''BROKEN_ROLE''' `
            -MutationLabel "seed workflow $($workflowStage.StepVariable)" `
            -ExpectedFailure "workflow stage `$$($workflowStage.StepVariable)"
    }

    Assert-WriterMutationRejected -Bootstrap `
        -SourceText $BootstrapSource `
        -Pattern ([regex]::Escape('& node $RunSqlRaw -f $tmp')) `
        -Replacement '& node $RunSql -f $tmp' `
        -MutationLabel 'bootstrap raw runner binding' `
        -ExpectedFailure 'must invoke node with $RunSqlRaw exactly once'

    Assert-WriterMutationRejected -Bootstrap `
        -SourceText $BootstrapSource `
        -Pattern '(?<prefix>DELETE\s+FROM\s+%I\.role_permission\s+AS\s+role_permission\s+)USING\s+canonical_managed_role_ids' `
        -Replacement '${prefix}USING disconnected_managed_role_ids' `
        -MutationLabel 'bootstrap custom-role-safe grant deletion' `
        -ExpectedFailure 'role_permission deletion must be limited to canonical managed role IDs'

    Assert-WriterMutationRejected -Bootstrap `
        -SourceText $BootstrapSource `
        -Pattern '(?<prefix>DELETE\s+FROM\s+%I\.permission_scope\s+AS\s+permission_scope\s+)USING\s+canonical_managed_role_ids' `
        -Replacement '${prefix}USING disconnected_managed_role_ids' `
        -MutationLabel 'bootstrap custom-role-safe scope deletion' `
        -ExpectedFailure 'permission_scope deletion must be limited to canonical managed role IDs'

    Assert-WriterMutationRejected -Bootstrap `
        -SourceText $BootstrapSource `
        -Pattern 'WHERE\s+bootstrap_managed\s*=\s*true\s*;' `
        -Replacement 'WHERE bootstrap_managed = false;' `
        -MutationLabel 'bootstrap exact HR ADMIN managed matrix' `
        -ExpectedFailure 'must derive exactly HR and ADMIN from BootstrapManaged role definitions'
}

Assert-True (Test-Path -LiteralPath $migrationPath) "Canonical RBAC migration 0067 is missing: $migrationPath"
Assert-True (Test-Path -LiteralPath $masterPath) "Tenant master changelog is missing: $masterPath"

[xml]$migration = Get-Content -Raw -LiteralPath $migrationPath
[xml]$master = Get-Content -Raw -LiteralPath $masterPath
$sqlStatements = Get-NormalizedSqlStatements -Document $migration
$sql = $sqlStatements -join "`n"

$includes = @($master.SelectNodes("//*[local-name()='include']") | ForEach-Object { $_.GetAttribute('file') })
Assert-True ($includes -contains $migrationInclude) 'Tenant master changelog must include canonical RBAC migration 0067'

$canonicalRoles = @('EMPLOYEE', 'MANAGER', 'HR', 'PAYROLL', 'ADMIN')
$canonicalRoleMatch = [regex]::Match(
    $sql,
    "canonical_roles\s*\(\s*name\s*\)\s+AS\s*\(\s*VALUES\s*(?<values>(?:\(\s*'[A-Z_]+'\s*\)\s*,?\s*)+)\)",
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
)
Assert-True $canonicalRoleMatch.Success 'Canonical RBAC migration must define canonical_roles(name) with explicit role names'
$actualCanonicalRoles = @([regex]::Matches($canonicalRoleMatch.Groups['values'].Value, "'(?<role>[A-Z_]+)'") | ForEach-Object {
    $_.Groups['role'].Value
})
Assert-ExactSet -Actual $actualCanonicalRoles -Expected $canonicalRoles -Label 'Canonical system-role names'
$canonicalRoleInsertIndexes = @(Get-StatementIndexes -Statements $sqlStatements -Pattern 'INSERT\s+INTO\s+"?\$\{schema\}"?\.role\s*\([^)]*name[^)]*\)\s*SELECT\b.*\bcanonical_roles\b')
Assert-True ($canonicalRoleInsertIndexes.Count -eq 1) 'Canonical RBAC migration must create canonical role rows from canonical_roles exactly once'
$canonicalRoleInsertIndex = $canonicalRoleInsertIndexes[0]

$legacyRoleMappings = [ordered]@{
    DEMO_STAFF = 'EMPLOYEE'
    LINE_MANAGER = 'MANAGER'
    HR_ADMIN = 'HR'
    ACCOUNTING_APPROVER = 'PAYROLL'
    TENANT_ADMIN = 'ADMIN'
}
$legacyRoleMappingMatch = [regex]::Match(
    $sql,
    "legacy_role_mapping\s*\(\s*legacy_name\s*,\s*canonical_name\s*\)\s+AS\s*\(\s*VALUES\s*(?<values>(?:\(\s*'[A-Z_]+'\s*,\s*'[A-Z_]+'\s*\)\s*,?\s*)+)\)",
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
)
Assert-True $legacyRoleMappingMatch.Success 'Canonical RBAC migration must define legacy_role_mapping(legacy_name, canonical_name) explicitly'
$actualLegacyRoleMappings = @([regex]::Matches($legacyRoleMappingMatch.Groups['values'].Value, "'(?<legacy>[A-Z_]+)'\s*,\s*'(?<canonical>[A-Z_]+)'") | ForEach-Object {
    "$($_.Groups['legacy'].Value)->$($_.Groups['canonical'].Value)"
})
$expectedLegacyRoleMappings = @($legacyRoleMappings.Keys | ForEach-Object {
    "$_->$($legacyRoleMappings[$_])"
})
Assert-ExactSet -Actual $actualLegacyRoleMappings -Expected $expectedLegacyRoleMappings -Label 'Legacy-to-canonical role mappings'

$requiredPermissionPairs = @(
    @{ Resource = 'employee'; Action = 'self' },
    @{ Resource = 'employee'; Action = 'read' },
    @{ Resource = 'employee'; Action = 'write' },
    @{ Resource = 'employee'; Action = 'manage' },
    @{ Resource = 'attendance'; Action = 'read' },
    @{ Resource = 'attendance'; Action = 'punch_self' },
    @{ Resource = 'attendance'; Action = 'regularize' },
    @{ Resource = 'attendance'; Action = 'punch_policy' },
    @{ Resource = 'timesheet'; Action = 'read' },
    @{ Resource = 'timesheet'; Action = 'write' },
    @{ Resource = 'timesheet'; Action = 'approve' },
    @{ Resource = 'timesheet'; Action = 'manage' },
    @{ Resource = 'leave'; Action = 'read' },
    @{ Resource = 'leave'; Action = 'submit' },
    @{ Resource = 'leave'; Action = 'approve' },
    @{ Resource = 'leave'; Action = 'manage' },
    @{ Resource = 'expense'; Action = 'read' },
    @{ Resource = 'expense'; Action = 'submit' },
    @{ Resource = 'expense'; Action = 'approve' },
    @{ Resource = 'expense'; Action = 'manage' },
    @{ Resource = 'expense'; Action = 'pay' },
    @{ Resource = 'travel'; Action = 'read' },
    @{ Resource = 'travel'; Action = 'submit' },
    @{ Resource = 'travel'; Action = 'approve' },
    @{ Resource = 'travel'; Action = 'manage' },
    @{ Resource = 'payroll'; Action = 'read' },
    @{ Resource = 'payroll'; Action = 'manage' },
    @{ Resource = 'payroll'; Action = 'statutory_export' },
    @{ Resource = 'tax'; Action = 'read' },
    @{ Resource = 'tax'; Action = 'submit' },
    @{ Resource = 'tax'; Action = 'approve' },
    @{ Resource = 'tax'; Action = 'manage' },
    @{ Resource = 'notification'; Action = 'read' },
    @{ Resource = 'notification'; Action = 'manage' },
    @{ Resource = 'role'; Action = 'manage' },
    @{ Resource = 'workflow'; Action = 'manage' }
)
foreach ($permissionPair in $requiredPermissionPairs) {
    $resource = [regex]::Escape($permissionPair.Resource)
    $action = [regex]::Escape($permissionPair.Action)
    Assert-True (
        $sql -match "\(\s*'$resource'\s*,\s*'$action'\s*\)"
    ) "Canonical RBAC migration must include permission $($permissionPair.Resource):$($permissionPair.Action)"
}

$roleForeignKeyConsumers = @(
    @{ Table = 'user_role'; Column = 'role_id' },
    @{ Table = 'workflow_step'; Column = 'approver_role_id' },
    @{ Table = 'approval_rule'; Column = 'approver_role_id' },
    @{ Table = 'expense_policy'; Column = 'role_id' }
)
$resolvedRoleMappingSource = 'resolved_role_mapping'
$resolvedRoleMappingIndexes = @(Get-StatementIndexes -Statements $sqlStatements -Pattern "\b$resolvedRoleMappingSource\s+AS\s*\(")
Assert-True ($resolvedRoleMappingIndexes.Count -eq 1) 'Canonical RBAC migration must define one resolved_role_mapping relation'
$resolvedRoleMappingIndex = $resolvedRoleMappingIndexes[0]
$resolvedRoleMappingStatement = $sqlStatements[$resolvedRoleMappingIndex]
Assert-True (
    $resolvedRoleMappingStatement -match 'SELECT\s+(?:DISTINCT\s+)?legacy_role\.id\s+AS\s+legacy_role_id\s*,\s*canonical_role\.id\s+AS\s+canonical_role_id'
) 'resolved_role_mapping must select legacy_role.id AS legacy_role_id and canonical_role.id AS canonical_role_id'
Assert-True (
    $resolvedRoleMappingStatement -match 'FROM\s+"?\$\{schema\}"?\.role\s+(?:AS\s+)?legacy_role\b'
) 'resolved_role_mapping must select legacy roles from the tenant role table'
Assert-True (
    $resolvedRoleMappingStatement -match 'JOIN\s+legacy_role_mapping\s+ON\s+UPPER\s*\(\s*TRIM\s*\(\s*legacy_role\.name\s*\)\s*\)\s*=\s*legacy_role_mapping\.legacy_name'
) 'resolved_role_mapping must join each legacy role name through legacy_role_mapping'
Assert-True (
    $resolvedRoleMappingStatement -match 'JOIN\s+"?\$\{schema\}"?\.role\s+(?:AS\s+)?canonical_role\s+ON\s+UPPER\s*\(\s*TRIM\s*\(\s*canonical_role\.name\s*\)\s*\)\s*=\s*legacy_role_mapping\.canonical_name'
) 'resolved_role_mapping must resolve canonical role IDs through legacy_role_mapping.canonical_name'

$remapStatementIndexes = @()
foreach ($consumer in $roleForeignKeyConsumers) {
    $remapPattern = "UPDATE\s+`"?\$\{schema\}`"?\.$($consumer.Table)\s+(?:AS\s+)?(?<target_alias>[A-Za-z_][A-Za-z0-9_]*)\s+SET\s+$($consumer.Column)\s*=\s*$resolvedRoleMappingSource\.canonical_role_id\s+FROM\s+$resolvedRoleMappingSource\s+WHERE\s+\k<target_alias>\.$($consumer.Column)\s*=\s*$resolvedRoleMappingSource\.legacy_role_id"
    $remapIndexes = @(Get-StatementIndexes -Statements $sqlStatements -Pattern $remapPattern)
    Assert-True ($remapIndexes.Count -eq 1) "Canonical RBAC migration must remap $($consumer.Table).$($consumer.Column) from resolved_role_mapping exactly once"
    Assert-True ($remapIndexes[0] -eq $resolvedRoleMappingIndex) "Canonical RBAC migration must use the one resolved_role_mapping relation when remapping $($consumer.Table).$($consumer.Column)"
    $remapStatementIndexes += $remapIndexes[0]
}

$canonicalMatrixSource = 'canonical_permission_matrix'
Assert-True ($sql -match "$canonicalMatrixSource\s*\([^)]*\)\s+AS\s*\(") 'Canonical RBAC migration must define the canonical permission matrix source'

$employeeGrantsMatch = [regex]::Match(
    $sql,
    "employee_grants\s*\(\s*resource\s*,\s*action\s*,\s*scope_type\s*\)\s+AS\s*\(\s*VALUES\s*(?<values>(?:\(\s*'[a-z_]+'\s*,\s*'[a-z_]+'\s*,\s*'(?:SELF|TEAM|ALL)'\s*\)\s*,?\s*)+)\)",
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
)
Assert-True $employeeGrantsMatch.Success 'Canonical RBAC migration must define explicit employee grant tuples with scopes'
$actualEmployeeGrants = @([regex]::Matches(
    $employeeGrantsMatch.Groups['values'].Value,
    "'(?<resource>[a-z_]+)'\s*,\s*'(?<action>[a-z_]+)'\s*,\s*'(?<scope>SELF|TEAM|ALL)'",
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
) | ForEach-Object {
    "$($_.Groups['resource'].Value):$($_.Groups['action'].Value):$($_.Groups['scope'].Value)".ToUpperInvariant()
})
$expectedEmployeeGrants = @(
    'EMPLOYEE:SELF:SELF',
    'ATTENDANCE:READ:SELF',
    'ATTENDANCE:PUNCH_SELF:SELF',
    'TIMESHEET:READ:SELF',
    'TIMESHEET:WRITE:SELF',
    'LEAVE:READ:SELF',
    'LEAVE:SUBMIT:SELF',
    'EXPENSE:READ:SELF',
    'EXPENSE:SUBMIT:SELF',
    'TRAVEL:READ:SELF',
    'TRAVEL:SUBMIT:SELF',
    'PAYROLL:READ:SELF',
    'TAX:READ:SELF',
    'TAX:SUBMIT:SELF',
    'NOTIFICATION:READ:SELF',
    'BENEFITS:SELF:SELF',
    'ONBOARDING:SELF:SELF',
    'GRIEVANCE:SELF:SELF',
    'ASSETS:SELF:SELF'
)
Assert-ExactSet -Actual $actualEmployeeGrants -Expected $expectedEmployeeGrants -Label 'Canonical EMPLOYEE resource/action/scope tuples'

$employeeDerivedRolesMatch = [regex]::Match(
    $sql,
    "employee_derived_roles\s*\(\s*role_name\s*\)\s+AS\s*\(\s*VALUES\s*(?<values>(?:\(\s*'[A-Z_]+'\s*\)\s*,?\s*)+)\)",
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
)
Assert-True $employeeDerivedRolesMatch.Success 'Canonical RBAC migration must explicitly identify roles that inherit EMPLOYEE grants'
$actualEmployeeDerivedRoles = @([regex]::Matches($employeeDerivedRolesMatch.Groups['values'].Value, "'(?<role>[A-Z_]+)'") | ForEach-Object {
    $_.Groups['role'].Value
})
Assert-ExactSet -Actual $actualEmployeeDerivedRoles -Expected @('EMPLOYEE', 'MANAGER', 'HR', 'PAYROLL') -Label 'Roles inheriting canonical EMPLOYEE grants'

$roleOverridesMatch = [regex]::Match(
    $sql,
    "role_overrides\s*\(\s*role_name\s*,\s*resource\s*,\s*action\s*,\s*scope_type\s*\)\s+AS\s*\(\s*VALUES\s*(?<values>(?:\(\s*'[A-Z_]+'\s*,\s*'[a-z_]+'\s*,\s*'[a-z_]+'\s*,\s*'(?:SELF|TEAM|ALL)'\s*\)\s*,?\s*)+)\)",
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
)
Assert-True $roleOverridesMatch.Success 'Canonical RBAC migration must define explicit MANAGER, HR, and PAYROLL override tuples with scopes'
$actualRoleOverrides = @([regex]::Matches(
    $roleOverridesMatch.Groups['values'].Value,
    "'(?<role>[A-Z_]+)'\s*,\s*'(?<resource>[a-z_]+)'\s*,\s*'(?<action>[a-z_]+)'\s*,\s*'(?<scope>SELF|TEAM|ALL)'",
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
) | ForEach-Object {
    "$($_.Groups['role'].Value):$($_.Groups['resource'].Value):$($_.Groups['action'].Value):$($_.Groups['scope'].Value)".ToUpperInvariant()
})
$expectedRoleOverrides = @(
    'MANAGER:EMPLOYEE:READ:TEAM',
    'MANAGER:ATTENDANCE:READ:TEAM',
    'MANAGER:ATTENDANCE:REGULARIZE:TEAM',
    'MANAGER:TIMESHEET:READ:TEAM',
    'MANAGER:TIMESHEET:APPROVE:TEAM',
    'MANAGER:LEAVE:READ:TEAM',
    'MANAGER:LEAVE:APPROVE:TEAM',
    'MANAGER:EXPENSE:READ:TEAM',
    'MANAGER:EXPENSE:APPROVE:TEAM',
    'MANAGER:TRAVEL:READ:TEAM',
    'MANAGER:TRAVEL:APPROVE:TEAM',
    'HR:EMPLOYEE:READ:ALL',
    'HR:EMPLOYEE:WRITE:ALL',
    'HR:EMPLOYEE:MANAGE:ALL',
    'HR:ATTENDANCE:READ:ALL',
    'HR:ATTENDANCE:REGULARIZE:ALL',
    'HR:ATTENDANCE:PUNCH_POLICY:ALL',
    'HR:TIMESHEET:READ:ALL',
    'HR:TIMESHEET:APPROVE:ALL',
    'HR:TIMESHEET:MANAGE:ALL',
    'HR:LEAVE:READ:ALL',
    'HR:LEAVE:APPROVE:ALL',
    'HR:LEAVE:MANAGE:ALL',
    'HR:EXPENSE:READ:ALL',
    'HR:EXPENSE:APPROVE:ALL',
    'HR:EXPENSE:MANAGE:ALL',
    'HR:TRAVEL:READ:ALL',
    'HR:TRAVEL:APPROVE:ALL',
    'HR:TRAVEL:MANAGE:ALL',
    'HR:WORKFLOW:MANAGE:ALL',
    'HR:NOTIFICATION:MANAGE:ALL',
    'HR:BENEFITS:MANAGE:ALL',
    'HR:RECRUITMENT:MANAGE:ALL',
    'HR:ONBOARDING:MANAGE:ALL',
    'HR:PERFORMANCE:MANAGE:ALL',
    'HR:LEARNING:MANAGE:ALL',
    'HR:ASSETS:MANAGE:ALL',
    'HR:GRIEVANCE:MANAGE:ALL',
    'HR:SUCCESSION:MANAGE:ALL',
    'HR:COMPENSATION:MANAGE:ALL',
    'HR:ANALYTICS:READ:ALL',
    'PAYROLL:PAYROLL:READ:ALL',
    'PAYROLL:PAYROLL:MANAGE:ALL',
    'PAYROLL:PAYROLL:STATUTORY_EXPORT:ALL',
    'PAYROLL:TAX:READ:ALL',
    'PAYROLL:TAX:APPROVE:ALL',
    'PAYROLL:TAX:MANAGE:ALL',
    'PAYROLL:EXPENSE:READ:ALL',
    'PAYROLL:EXPENSE:APPROVE:ALL',
    'PAYROLL:EXPENSE:PAY:ALL'
)
Assert-ExactSet -Actual $actualRoleOverrides -Expected $expectedRoleOverrides -Label 'Canonical MANAGER, HR, and PAYROLL resource/action/scope override tuples'

$roundTwoFailures = @()
$matrixConstructionIndexes = @(Get-StatementIndexes -Statements $sqlStatements -Pattern 'CREATE\s+TEMP\s+TABLE\s+canonical_permission_matrix\b')
if ($matrixConstructionIndexes.Count -ne 1) {
    $roundTwoFailures += 'Canonical RBAC migration must construct one materialized canonical_permission_matrix'
} else {
    $matrixConstructionSql = $sqlStatements[$matrixConstructionIndexes[0]]
    $grantCandidatesMatch = [regex]::Match(
        $matrixConstructionSql,
        'grant_candidates\s*\(\s*role_name\s*,\s*resource\s*,\s*action\s*,\s*scope_type\s*,\s*precedence\s*\)\s+AS\s*\((?<body>.*?)\)\s*,\s*canonical_permission_matrix\s*\(',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline
    )
    if (-not $grantCandidatesMatch.Success) {
        $roundTwoFailures += 'grant_candidates must be the single input relation for canonical_permission_matrix ranking'
    } else {
        $grantCandidatesSql = $grantCandidatesMatch.Groups['body'].Value
        if ($grantCandidatesSql -notmatch 'SELECT\s+employee_derived_roles\.role_name\s*,\s*employee_grants\.resource\s*,\s*employee_grants\.action\s*,\s*employee_grants\.scope_type\s*,\s*1\s+FROM\s+employee_derived_roles\s+CROSS\s+JOIN\s+employee_grants') {
            $roundTwoFailures += 'grant_candidates must consume inherited employee_grants with precedence 1'
        }
        if ($grantCandidatesSql -notmatch 'SELECT\s+role_overrides\.role_name\s*,\s*role_overrides\.resource\s*,\s*role_overrides\.action\s*,\s*role_overrides\.scope_type\s*,\s*2\s+FROM\s+role_overrides') {
            $roundTwoFailures += 'grant_candidates must consume role_overrides with precedence 2'
        }
    }

    $rankedMatrixMatch = [regex]::Match(
        $matrixConstructionSql,
        'canonical_permission_matrix\s*\(\s*role_name\s*,\s*resource\s*,\s*action\s*,\s*scope_type\s*\)\s+AS\s*\((?<body>.*?)\)\s*INSERT\s+INTO\s+canonical_permission_matrix',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline
    )
    if (-not $rankedMatrixMatch.Success) {
        $roundTwoFailures += 'canonical_permission_matrix must be materialized from a ranked CTE'
    } else {
        $rankedMatrixSql = $rankedMatrixMatch.Groups['body'].Value
        if ($rankedMatrixSql -notmatch 'SELECT\s+DISTINCT\s+ON\s*\(\s*grant_candidates\.role_name\s*,\s*grant_candidates\.resource\s*,\s*grant_candidates\.action\s*\)') {
            $roundTwoFailures += 'canonical_permission_matrix must rank one candidate per role, resource, and action'
        }
        if ($rankedMatrixSql -notmatch 'FROM\s+grant_candidates\s+ORDER\s+BY\s+grant_candidates\.role_name\s*,\s*grant_candidates\.resource\s*,\s*grant_candidates\.action\s*,\s*grant_candidates\.precedence\s+DESC') {
            $roundTwoFailures += 'canonical_permission_matrix must select the highest-precedence grant_candidate'
        }
    }
}

$adminGrantMatch = [regex]::Match(
    $sql,
    "SELECT\s*'ADMIN'\s*,(?<grant>.*?)FROM\s+`"?\$\{schema\}`"?\.permission\s+(?:AS\s+)?permission\b",
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline
)
Assert-True $adminGrantMatch.Success 'Canonical matrix must derive ADMIN grants from every tenant permission row'
$adminGrantSql = $adminGrantMatch.Groups['grant'].Value
Assert-True (([regex]::Matches($adminGrantSql, "THEN\s*'SELF'", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)).Count -eq 8) 'ADMIN must have exactly eight intrinsic SELF scope branches'
Assert-True ($adminGrantSql -match "LOWER\s*\(\s*TRIM\s*\(\s*permission\.action\s*\)\s*\)\s*=\s*'self'\s+THEN\s*'SELF'") 'ADMIN workplace and employee self actions must use SELF scope'
foreach ($adminSelfTuple in @(
    @{ Resource = 'attendance'; Action = 'punch_self' },
    @{ Resource = 'timesheet'; Action = 'write' },
    @{ Resource = 'leave'; Action = 'submit' },
    @{ Resource = 'expense'; Action = 'submit' },
    @{ Resource = 'travel'; Action = 'submit' },
    @{ Resource = 'tax'; Action = 'submit' },
    @{ Resource = 'notification'; Action = 'read' }
)) {
    $resource = [regex]::Escape($adminSelfTuple.Resource)
    $action = [regex]::Escape($adminSelfTuple.Action)
    Assert-True (
        $adminGrantSql -match "LOWER\s*\(\s*TRIM\s*\(\s*permission\.resource\s*\)\s*\)\s*=\s*'$resource'\s+AND\s+LOWER\s*\(\s*TRIM\s*\(\s*permission\.action\s*\)\s*\)\s*=\s*'$action'\s+THEN\s*'SELF'"
    ) "ADMIN $($adminSelfTuple.Resource):$($adminSelfTuple.Action) must use SELF scope"
}
Assert-True ($adminGrantSql -match "ELSE\s*'ALL'") 'ADMIN permissions not intrinsically self-bound must use ALL scope'

$canonicalMatrixIndexes = @(Get-StatementIndexes -Statements $sqlStatements -Pattern "INSERT\s+INTO\s+`"?\$\{schema\}`"?\.role_permission\s*\([^)]*\)\s*SELECT\b.*?FROM\s+$canonicalMatrixSource\b")
$canonicalScopeIndexes = @(Get-StatementIndexes -Statements $sqlStatements -Pattern "INSERT\s+INTO\s+`"?\$\{schema\}`"?\.permission_scope\s*\([^)]*\)\s*SELECT\b.*?FROM\s+$canonicalMatrixSource\b")
if ($canonicalMatrixIndexes.Count -ne 1) {
    $roundTwoFailures += 'role_permission must consume the materialized canonical_permission_matrix exactly once'
}
if ($canonicalScopeIndexes.Count -ne 1) {
    $roundTwoFailures += 'permission_scope must consume the same materialized canonical_permission_matrix directly exactly once'
}

$lockMatches = @([regex]::Matches(
    $sql,
    'LOCK\s+TABLE\s+(?<tables>.*?)\s+IN\s+(?<mode>ACCESS\s+EXCLUSIVE|SHARE\s+ROW\s+EXCLUSIVE|EXCLUSIVE|SHARE|ROW\s+EXCLUSIVE|SHARE\s+UPDATE\s+EXCLUSIVE|ROW\s+SHARE|ACCESS\s+SHARE)\s+MODE(?<nowait>\s+NOWAIT)?\s*;',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline
))
if ($lockMatches.Count -eq 0) {
    $roundTwoFailures += 'Canonical RBAC migration must define an explicit LOCK TABLE boundary'
} else {
    $blockingLockMatches = @($lockMatches | Where-Object { -not $_.Groups['nowait'].Success })
    if ($blockingLockMatches.Count -ne 0) {
        $roundTwoFailures += 'Every migration-boundary LOCK TABLE statement must use valid MODE NOWAIT syntax so contention fails fast'
    }

    $lockExpectations = @(
        @{ Table = '"\$\{schema\}"\."user"'; Mode = 'SHARE' },
        @{ Table = '"\$\{schema\}"\.employee'; Mode = 'SHARE' },
        @{ Table = '"\$\{schema\}"\.user_role'; Mode = 'SHARE ROW EXCLUSIVE' },
        @{ Table = '"\$\{schema\}"\.role'; Mode = 'SHARE ROW EXCLUSIVE' },
        @{ Table = '"\$\{schema\}"\.permission'; Mode = 'SHARE ROW EXCLUSIVE' },
        @{ Table = '"\$\{schema\}"\.role_permission'; Mode = 'SHARE ROW EXCLUSIVE' },
        @{ Table = '"\$\{schema\}"\.permission_scope'; Mode = 'SHARE ROW EXCLUSIVE' },
        @{ Table = '"\$\{schema\}"\.user_session'; Mode = 'SHARE ROW EXCLUSIVE' },
        @{ Table = '"\$\{schema\}"\.workflow_step'; Mode = 'SHARE ROW EXCLUSIVE' },
        @{ Table = '"\$\{schema\}"\.approval_rule'; Mode = 'SHARE ROW EXCLUSIVE' },
        @{ Table = '"\$\{schema\}"\.expense_policy'; Mode = 'SHARE ROW EXCLUSIVE' },
        @{ Table = '"\$\{schema\}"\.announcement'; Mode = 'SHARE ROW EXCLUSIVE' },
        @{ Table = 'kabipay_ops\.module'; Mode = 'SHARE' },
        @{ Table = 'kabipay_ops\.tenant_database'; Mode = 'SHARE' }
    )
    foreach ($lockExpectation in $lockExpectations) {
        $matchingLocks = @($lockMatches | Where-Object { $_.Groups['tables'].Value -match $lockExpectation.Table })
        if ($matchingLocks.Count -ne 1) {
            $roundTwoFailures += "Migration lock boundary must lock $($lockExpectation.Table) exactly once"
        } elseif (($matchingLocks[0].Groups['mode'].Value -replace '\s+', ' ').ToUpperInvariant() -ne $lockExpectation.Mode) {
            $roundTwoFailures += "Migration lock boundary must lock $($lockExpectation.Table) in $($lockExpectation.Mode) mode"
        }
    }
}

if ($roundTwoFailures.Count -ne 0) {
    throw "Canonical RBAC migration round-2 contract failed:`n - $($roundTwoFailures -join "`n - ")"
}

$rolePermissionIndex = $canonicalMatrixIndexes[0]
$permissionScopeIndex = $canonicalScopeIndexes[0]
$roleDeletions = @(Get-RoleDeletionStatements -Statements $sqlStatements)
Assert-True ($roleDeletions.Count -ge 1) 'Canonical RBAC migration must delete mapped legacy role rows'
$firstRoleDeletionIndex = ($roleDeletions | Measure-Object -Minimum -Property StatementIndex).Minimum
$lastRoleDeletionIndex = ($roleDeletions | Measure-Object -Maximum -Property StatementIndex).Maximum

$announcementRemapPattern = "UPDATE\s+`"?\$\{schema\}`"?\.announcement\s+(?:AS\s+)?(?<announcement_alias>[A-Za-z_][A-Za-z0-9_]*)\s+SET\s+target_audience\s*=\s*'ROLE:'\s*\|\|\s*legacy_role_mapping\.canonical_name\s+FROM\s+legacy_role_mapping\s+WHERE\s+UPPER\s*\(\s*TRIM\s*\(\s*\k<announcement_alias>\.target_audience\s*\)\s*\)\s*=\s*'ROLE:'\s*\|\|\s*legacy_role_mapping\.legacy_name"
$announcementRemapIndexes = @(Get-StatementIndexes -Statements $sqlStatements -Pattern $announcementRemapPattern)
Assert-True ($announcementRemapIndexes.Count -eq 1) 'Canonical RBAC migration must remap exact normalized ROLE:<legacy> announcement audiences from the logical legacy mapping'
Assert-True ($announcementRemapIndexes[0] -lt $firstRoleDeletionIndex) 'Announcement role audiences must be remapped before legacy roles are deleted'

$announcementLegacyAssertionPattern = "FROM\s+`"?\$\{schema\}`"?\.announcement\s+(?:AS\s+)?announcement\s+JOIN\s+legacy_role_mapping\s+ON\s+UPPER\s*\(\s*TRIM\s*\(\s*announcement\.target_audience\s*\)\s*\)\s*=\s*'ROLE:'\s*\|\|\s*legacy_role_mapping\.legacy_name"
$announcementLegacyAssertionIndexes = @(Get-StatementIndexes -Statements $sqlStatements -Pattern $announcementLegacyAssertionPattern)
Assert-True ($announcementLegacyAssertionIndexes.Count -eq 2) 'Canonical RBAC migration must verify mapped legacy announcement audiences both before and after legacy role deletion'
Assert-True (($announcementLegacyAssertionIndexes | Measure-Object -Minimum).Minimum -lt $firstRoleDeletionIndex) 'Pre-delete verification must reject mapped legacy announcement audiences'
Assert-True (($announcementLegacyAssertionIndexes | Measure-Object -Maximum).Maximum -gt $lastRoleDeletionIndex) 'Final verification must reject mapped legacy announcement audiences'

$loginActiveInvariantPattern = "UPPER\s*\(\s*TRIM\s*\(\s*employee\.status\s*\)\s*\)\s+IN\s*\(\s*'ACTIVE'\s*,\s*'PROBATION'\s*\)"
$loginActiveInvariantIndexes = @(Get-StatementIndexes -Statements $sqlStatements -Pattern $loginActiveInvariantPattern)
Assert-True ($loginActiveInvariantIndexes.Count -eq 2) 'Canonical RBAC migration must enforce canonical roles for ACTIVE and PROBATION employees before and after legacy deletion'
Assert-True (($loginActiveInvariantIndexes | Measure-Object -Minimum).Minimum -lt $firstRoleDeletionIndex) 'ACTIVE and PROBATION role invariant must run before legacy deletion'
Assert-True (($loginActiveInvariantIndexes | Measure-Object -Maximum).Maximum -gt $lastRoleDeletionIndex) 'ACTIVE and PROBATION role invariant must run in final verification'

foreach ($remapIndex in $remapStatementIndexes) {
    Assert-True ($canonicalRoleInsertIndex -lt $remapIndex) 'Canonical role rows must be created before dependent role foreign keys are remapped'
}
Assert-True (($remapStatementIndexes | Measure-Object -Maximum).Maximum -lt $rolePermissionIndex) 'Dependent role foreign keys must be remapped before the canonical role-permission matrix is populated'
Assert-True (($remapStatementIndexes | Measure-Object -Maximum).Maximum -lt $permissionScopeIndex) 'Dependent role foreign keys must be remapped before canonical permission scopes are populated'

$sessionRevocationIndexes = @(Get-StatementIndexes -Statements $sqlStatements -Pattern 'DELETE\s+FROM\s+"?\$\{schema\}"?\.user_session\s+AS\s+user_session\s+USING\s+"?\$\{schema\}"?\."user"\s+AS\s+tenant_user\s*,\s*tenant_context\s+WHERE\s+user_session\.user_id\s*=\s*tenant_user\.id\s+AND\s+tenant_user\.tenant_id\s*=\s*tenant_context\.tenant_id')
Assert-True ($sessionRevocationIndexes.Count -eq 1) 'Canonical RBAC migration must revoke tenant user sessions after rewriting role grants'
Assert-True ($permissionScopeIndex -lt $sessionRevocationIndexes[0]) 'Canonical RBAC migration must revoke sessions after canonical permission scopes are populated'

foreach ($roleDeletion in $roleDeletions) {
    Assert-True ($rolePermissionIndex -lt $roleDeletion.StatementIndex) 'Canonical role-permission matrix must be populated before legacy roles are deleted'
    Assert-True ($permissionScopeIndex -lt $roleDeletion.StatementIndex) 'Canonical permission scopes must be populated before legacy roles are deleted'

    $roleDeletionStatement = $roleDeletion.Sql
    Assert-True ($roleDeletionStatement -match '\blegacy_role_mapping\b') 'Every legacy role deletion must be limited to the explicit legacy role mapping'
    $deleteRolePredicate = [regex]::Match(
        $roleDeletionStatement,
        "UPPER\s*\(\s*TRIM\s*\(\s*(?:[A-Za-z_][A-Za-z0-9_]*\.)?name\s*\)\s*\)\s*IN\s*\(\s*(?<roles>[^)]*)\)",
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    Assert-True $deleteRolePredicate.Success 'Every legacy role deletion must use an explicit normalized role-name allowlist'
    $deletedRoleNames = @([regex]::Matches($deleteRolePredicate.Groups['roles'].Value, "'(?<role>[A-Z_]+)'") | ForEach-Object {
        $_.Groups['role'].Value
    })
    Assert-ExactSet -Actual $deletedRoleNames -Expected @($legacyRoleMappings.Keys) -Label 'Legacy role deletion allowlist'
}

Assert-True (Test-Path -LiteralPath $seedPath) 'Demo seed writer is missing'
Assert-True (Test-Path -LiteralPath $bootstrapPath) 'Tenant-admin bootstrap writer is missing'
$seedSource = Get-Content -Raw -LiteralPath $seedPath
$bootstrapSource = Get-Content -Raw -LiteralPath $bootstrapPath
$writerContractFailures = [System.Collections.Generic.List[string]]::new()
foreach ($writerCheck in @(
    { Assert-CanonicalWriterContract -Path $seedPath -WriterLabel 'Demo seed writer' -Seed },
    { Assert-CanonicalWriterContract -Path $bootstrapPath -WriterLabel 'Tenant-admin bootstrap writer' -Bootstrap },
    { Assert-BootstrapAdminArraySerialization -SourceText $bootstrapSource }
)) {
    try {
        & $writerCheck
    } catch {
        $writerContractFailures.Add($_.Exception.Message)
    }
}
if ($writerContractFailures.Count -ne 0) {
    throw "Canonical provisioning writer contract failed:`n - $($writerContractFailures -join "`n - ")"
}

Assert-WriterMutationCoverage -SeedSource $seedSource -BootstrapSource $bootstrapSource

Write-Host 'Canonical RBAC migration contract passed.'
