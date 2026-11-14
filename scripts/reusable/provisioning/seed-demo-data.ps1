<#
.SYNOPSIS
  Display current role defaults; the old mixed ops/company demo writer is retired.
.DESCRIPTION
  The former demo writer reset customized access and wrote retained colocated
  schemas. It cannot target isolated company databases safely. No demo rows are
  written here. Use the reviewed company bootstrap for access initialization.
#>
[CmdletBinding()]
param([switch]$ShowRoleDefaults)
$ErrorActionPreference = 'Stop'
if ($ShowRoleDefaults) {
  & node (Join-Path $PSScriptRoot '../rbac/canonical-role-defaults.cjs') --json
  if ($LASTEXITCODE -ne 0) { throw 'Canonical defaults could not be read.' }
  return
}
throw 'LEGACY_COLOCATED_DEMO_SEED_DISABLED: no demo data was seeded. Use provisioning/company-databases/company-bootstrap.cjs for explicit company access initialization; business demo fixtures need a separately reviewed isolated-company importer.'
