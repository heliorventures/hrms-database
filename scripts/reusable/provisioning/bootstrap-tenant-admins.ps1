<#
.SYNOPSIS
  Plan or execute the explicit registry-bound isolated company admin bootstrap.
.DESCRIPTION
  Existing accounts are never elevated or reset. AdminInput contains explicit
  CREATE_NEW_ADMIN intents and Argon2id hashes. No plaintext password is printed.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][guid]$TenantId,
  [Parameter(Mandatory)][string]$ExpectedDatabase,
  [Parameter(Mandatory)][string]$ExpectedMetadataDatabase,
  [Parameter(Mandatory)][string]$RuntimeHost,
  [Parameter(Mandatory)][ValidatePattern('^\d{1,20}$')][string]$ExpectedSystemIdentifier,
  [string]$AdminInput,
  [string]$Receipt,
  [switch]$Execute
)
$ErrorActionPreference = 'Stop'
$runner = Join-Path $PSScriptRoot '../../../provisioning/company-databases/company-bootstrap.cjs'
$arguments = @($runner, '--tenant-id', $TenantId.ToString(), '--expected-database', $ExpectedDatabase,
  '--expected-metadata-database', $ExpectedMetadataDatabase, '--runtime-host', $RuntimeHost,
  '--expected-system-identifier', $ExpectedSystemIdentifier)
if ($AdminInput) { $arguments += @('--admin-input', $AdminInput) }
if ($Execute) {
  if (-not $Receipt) { throw 'Execution requires a new receipt path.' }
  $arguments += @('--execute', '--receipt', $Receipt)
}
& node @arguments
if ($LASTEXITCODE -ne 0) { throw 'Company bootstrap failed. Review the receipt before retrying.' }
