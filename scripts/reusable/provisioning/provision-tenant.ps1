<#
.SYNOPSIS
  Retired colocated tenant entrypoint; fails before configuration or database access.
.DESCRIPTION
  For a fresh company use provisioning/company-databases/fresh-company.cjs.
  For an existing isolated company use deploy-company.cjs and company-bootstrap.cjs.
#>
[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments = $true)][object[]]$LegacyArguments)
throw 'LEGACY_COLOCATED_PROVISIONING_DISABLED: use provisioning/company-databases/fresh-company.cjs with explicit registry, cluster, empty staging database and company target; existing companies use deploy-company.cjs then company-bootstrap.cjs.'
