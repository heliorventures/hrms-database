<#
.SYNOPSIS
    Provision a tenant and bootstrap admin users in one command.

.DESCRIPTION
    Wraps:
      1. scripts/provision-tenant.ps1
      2. scripts/bootstrap-tenant-admins.ps1

    This is the preferred onboarding entrypoint for a new HRMS tenant.

.EXAMPLE
    .\scripts\setup-tenant.ps1 -Name "Solvian Consultancy" -Code solvianconsultancy -AdminUsernames @('aniket.dobhada','ritesh.jain') -TemporaryPassword 'ChangeMe!123' -RuntimePostgresHost postgres
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Name,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^(?=.{2,63}$)[a-z0-9](?:[a-z0-9-]*[a-z0-9])$')]
    [string]$Code,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string[]]$AdminUsernames,

    [string]$TemporaryPassword = 'ChangeMe!123',
    [string]$PasswordHash = '',
    [string]$Country = 'IN',
    [string]$Currency = 'INR',
    [string]$RuntimePostgresHost = 'postgres',
    [string]$RuntimeDbName = '',

    [string]$PostgresHost = '',
    [int]$PostgresPort = 5432,
    [string]$DbName = '',
    [string]$DbUser = '',
    [string]$DbPassword = '',
    [switch]$PostgresSsl
)

$ErrorActionPreference = 'Stop'

$ProvisionScript = Join-Path $PSScriptRoot 'provision-tenant.ps1'
$BootstrapScript = Join-Path $PSScriptRoot 'bootstrap-tenant-admins.ps1'

if (-not (Test-Path $ProvisionScript)) {
    throw "Missing provisioning script: $ProvisionScript"
}
if (-not (Test-Path $BootstrapScript)) {
    throw "Missing admin bootstrap script: $BootstrapScript"
}

$provisionArgs = @{
    Name = $Name
    Code = $Code
    Country = $Country
    Currency = $Currency
    RuntimePostgresHost = $RuntimePostgresHost
}
if (-not [string]::IsNullOrWhiteSpace($RuntimeDbName)) { $provisionArgs.RuntimeDbName = $RuntimeDbName }
if (-not [string]::IsNullOrWhiteSpace($PostgresHost)) { $provisionArgs.PostgresHost = $PostgresHost }
if ($PSBoundParameters.ContainsKey('PostgresPort')) { $provisionArgs.PostgresPort = $PostgresPort }
if (-not [string]::IsNullOrWhiteSpace($DbName)) { $provisionArgs.DbName = $DbName }
if (-not [string]::IsNullOrWhiteSpace($DbUser)) { $provisionArgs.DbUser = $DbUser }
if (-not [string]::IsNullOrWhiteSpace($DbPassword)) { $provisionArgs.DbPassword = $DbPassword }
if ($PostgresSsl) { $provisionArgs.PostgresSsl = $true }

Write-Host "==> Provisioning tenant '$Name' ($Code)" -ForegroundColor Cyan
& $ProvisionScript @provisionArgs
if ($LASTEXITCODE -ne 0) {
    throw "Tenant provisioning failed with exit code $LASTEXITCODE"
}

$bootstrapArgs = @{
    TenantCode = $Code
    AdminUsernames = $AdminUsernames
    TemporaryPassword = $TemporaryPassword
}
if (-not [string]::IsNullOrWhiteSpace($PasswordHash)) { $bootstrapArgs.PasswordHash = $PasswordHash }
if (-not [string]::IsNullOrWhiteSpace($PostgresHost)) { $bootstrapArgs.PostgresHost = $PostgresHost }
if ($PSBoundParameters.ContainsKey('PostgresPort')) { $bootstrapArgs.PostgresPort = $PostgresPort }
if (-not [string]::IsNullOrWhiteSpace($DbName)) { $bootstrapArgs.DbName = $DbName }
if (-not [string]::IsNullOrWhiteSpace($DbUser)) { $bootstrapArgs.DbUser = $DbUser }
if (-not [string]::IsNullOrWhiteSpace($DbPassword)) { $bootstrapArgs.DbPassword = $DbPassword }
if ($PostgresSsl) { $bootstrapArgs.PostgresSsl = $true }

Write-Host "==> Bootstrapping tenant admins" -ForegroundColor Cyan
& $BootstrapScript @bootstrapArgs
if ($LASTEXITCODE -ne 0) {
    throw "Tenant admin bootstrap failed with exit code $LASTEXITCODE"
}

Write-Host ""
Write-Host "Tenant setup complete." -ForegroundColor Green
Write-Host "Tenant URL: https://$Code.heliorsoft.com"
Write-Host "Admins:"
$AdminUsernames | ForEach-Object { Write-Host "  - $($_.Trim().ToLowerInvariant())" }
