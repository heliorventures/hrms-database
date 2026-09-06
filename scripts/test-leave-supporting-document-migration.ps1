[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$DatabaseDir = Split-Path -Parent $PSScriptRoot
$MigrationRelativePath = 'migrations/0071_leave_supporting_document_file/leave_supporting_document_file.xml'
$MigrationPath = Join-Path (Join-Path $DatabaseDir 'changelog') $MigrationRelativePath
$MasterPath = Join-Path $DatabaseDir 'changelog/tenant.changelog-master.xml'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

Assert-True (Test-Path -LiteralPath $MigrationPath) '0071 leave supporting-document migration is missing'

[xml]$master = Get-Content -Raw -LiteralPath $MasterPath
$includes = @($master.databaseChangeLog.include | ForEach-Object { $_.file })
$previousIndex = [array]::IndexOf($includes, 'migrations/0070_workplace_configuration_rbac/workplace_configuration_rbac.xml')
$migrationIndex = [array]::IndexOf($includes, $MigrationRelativePath)
Assert-True ($migrationIndex -eq ($previousIndex + 1)) '0071 must immediately follow 0070 in the tenant changelog'

$migration = Get-Content -Raw -LiteralPath $MigrationPath
foreach ($requiredPattern in @(
    'supporting_document_file_storage_id',
    'baseColumnNames="tenant_id,supporting_document_file_storage_id"',
    'referencedColumnNames="tenant_id,id"',
    'referencedTableName="file_storage"',
    'onDelete="RESTRICT"',
    'idx_leave_request_supporting_document_file'
)) {
    Assert-True ($migration -match $requiredPattern) "Leave supporting-document migration is missing: $requiredPattern"
}

Write-Host 'Leave supporting-document migration contract passed.' -ForegroundColor Green
