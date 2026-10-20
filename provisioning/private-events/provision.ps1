[CmdletBinding()]
param(
 [Parameter(Mandatory)][ValidateSet('company','operator')][string]$Operation,
 [Parameter(Mandatory)][ValidatePattern('^[A-Za-z_][A-Za-z0-9_-]{0,62}$')][string]$Database,
 [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9_.-]{0,62}$')][string]$Service,
 [Parameter(Mandatory)][string]$ScopeId,
 [Parameter(Mandatory)][string]$RuntimeRole,
 [Parameter(Mandatory)][ValidateSet('empty','existing')][string]$BootstrapMode,
 [ValidateRange(1,9007199254740991)][long]$ProducerGeneration=1,
 [string]$SourceSchema,
 [string]$RegistryService,
 [string]$RegistryDatabase,
 [string]$RuntimeHost
)
$ErrorActionPreference='Stop'
if($ScopeId-cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'){throw 'Explicit canonical source ScopeId required'}
function ValidName([string]$value){return $value-cmatch '^[A-Za-z_][A-Za-z0-9_]{0,62}$' -and $value.ToLowerInvariant()-notin @('public','postgres','kabipay_ops','information_schema') -and !$value.ToLowerInvariant().StartsWith('pg_')}
if(!(ValidName $RuntimeRole)){throw 'Dedicated non-system RuntimeRole required'}
if($Operation-eq'company'){
 if(!(ValidName $SourceSchema)){throw 'Company requires a case-preserving non-system SourceSchema'}
 if($RegistryService-cnotmatch '^[a-z][a-z0-9_.-]{0,62}$' -or $RegistryDatabase-cnotmatch '^[A-Za-z_][A-Za-z0-9_-]{0,62}$' -or $RuntimeHost-cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,252}$'){throw 'Company requires fixed RegistryService, RegistryDatabase and reviewed RuntimeHost registration'}
}elseif($SourceSchema -or $RegistryService -or $RegistryDatabase -or $RuntimeHost){throw 'Operator source uses fixed kabipay_ops and cannot accept company binding arguments'}
else{$SourceSchema='kabipay_ops'}
function InvokeFixedPsql([string]$connection,[string]$file,[string[]]$variables){
 $parameters=@($connection,'-X','--set=ON_ERROR_STOP=1','--single-transaction')+$variables+@('--file='+(Join-Path $PSScriptRoot $file))
 & psql @parameters
 if($LASTEXITCODE-ne 0){throw 'Private source provisioning failed; transaction rolled back'}
}
# libpq service/passfiles are operator-owned. No password, arbitrary DSN or SQL input.
if($Operation-eq'company'){
 InvokeFixedPsql "service=$RegistryService dbname=$RegistryDatabase sslmode=verify-full" 'registration.template.sql' @("--set=registry_database=$RegistryDatabase","--set=database=$Database","--set=scope_id=$ScopeId","--set=source_schema=$SourceSchema","--set=runtime_host=$RuntimeHost")
}
InvokeFixedPsql "service=$Service dbname=$Database sslmode=verify-full" "$Operation.template.sql" @("--set=database=$Database","--set=scope_id=$ScopeId","--set=source_schema=$SourceSchema","--set=runtime_role=$RuntimeRole","--set=bootstrap_mode=$BootstrapMode","--set=producer_generation=$ProducerGeneration")
