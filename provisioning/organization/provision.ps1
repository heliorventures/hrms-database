param(
  [Parameter(Mandatory)][ValidateSet('company','control','workers')][string]$Operation,
  [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9_]{0,62}$')][string]$Database,
  [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9_.-]*$')][string]$Service,
  [string]$CompanyId,
  [string]$SourceSchema
)
$ErrorActionPreference = 'Stop'
$files = @{company='cdc-source.template.sql';control='control-cdc-grants.template.sql';workers='grants.sql'}
$parameters = @("service=$Service dbname=$Database sslmode=verify-full",'-X','--set=ON_ERROR_STOP=1',"--set=database=$Database",'--single-transaction')
if ($Operation -eq 'company') {
  if ($CompanyId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$') { throw 'Company operation requires canonical CompanyId' }
  if ($SourceSchema -cnotmatch '^[A-Za-z_][A-Za-z0-9_]{0,62}$' -or $SourceSchema.ToLowerInvariant() -in @('public','kabipay_ops','information_schema') -or $SourceSchema.ToLowerInvariant().StartsWith('pg_')) { throw 'Company operation requires a valid non-system SourceSchema' }
  $cdcRole = 'organization_cdc_' + $CompanyId.Replace('-','')
  $parameters += @("--set=company_id=$CompanyId","--set=cdc_role=$cdcRole","--set=source_schema=$SourceSchema")
} elseif ($CompanyId -or $SourceSchema) { throw 'CompanyId/SourceSchema are only valid for company provisioning' }
$parameters += '--file=' + (Join-Path $PSScriptRoot $files[$Operation])
# libpq service and passfiles are operator-owned; never generated or displayed.
& psql @parameters
if ($LASTEXITCODE -ne 0) { throw "PostgreSQL $Operation provisioning failed" }

