# Focused argument/negative checks: psql is mocked; no database is contacted.
$ErrorActionPreference='Stop'
$wrapper=Join-Path $PSScriptRoot '../provision.ps1'
$global:ProvisioningTestCalls=0
function global:psql {
 $global:ProvisioningTestCalls++
 $global:ProvisioningTestArguments=@($args)
 $global:LASTEXITCODE=$global:ProvisioningTestExit
}
function Assert([bool]$Condition,[string]$Message) {if(-not $Condition){throw $Message}}
function Reject([scriptblock]$Action) {
 $before=$global:ProvisioningTestCalls;$rejected=$false
 try {& $Action} catch {$rejected=$true}
 Assert $rejected 'Invalid input was accepted'
 Assert ($before -eq $global:ProvisioningTestCalls) 'Invalid input reached psql'
}
try {
 $global:ProvisioningTestExit=0
 $id='11111111-1111-4111-8111-111111111111'
 & $wrapper -Operation company -Database company_one -Service source_dba -CompanyId $id -SourceSchema Tenant_One
 Assert ($global:ProvisioningTestArguments -contains '--set=company_id=11111111-1111-4111-8111-111111111111') 'Company ID missing'
 Assert ($global:ProvisioningTestArguments -contains '--set=cdc_role=organization_cdc_11111111111141118111111111111111') 'Derived role incorrect'
 Assert ($global:ProvisioningTestArguments -contains '--set=source_schema=Tenant_One') 'Quoted-case source binding lost'
 Assert ($global:ProvisioningTestArguments -contains '--single-transaction') 'Transaction missing'
 Assert ($global:ProvisioningTestArguments -contains '--set=ON_ERROR_STOP=1') 'Stop-on-error missing'
 Assert ($global:ProvisioningTestArguments -contains 'service=source_dba dbname=company_one sslmode=verify-full') 'Fixed service/TLS binding missing'
 & $wrapper -Operation company -Database company_two -Service source_dba -CompanyId '22222222-2222-4222-8222-222222222222' -SourceSchema tenant_two
 Assert ($global:ProvisioningTestArguments -contains '--set=cdc_role=organization_cdc_22222222222242228222222222222222') 'Second company role collided'
 foreach($schema in @('public','PUBLIC','kabipay_ops','information_schema','pg_catalog','PG_temp','x.*','x;SELECT','a-b','')) {
  Reject {& $wrapper -Operation company -Database company_one -Service source_dba -CompanyId $id -SourceSchema $schema}
 }
 Reject {& $wrapper -Operation company -Database company_one -Service source_dba -SourceSchema tenant_one}
 Reject {& $wrapper -Operation company -Database company_one -Service source_dba -CompanyId $id}
 Reject {& $wrapper -Operation company -Database company_one -Service source_dba -CompanyId '*' -SourceSchema tenant_one}
 Reject {& $wrapper -Operation control -Database metadata -Service metadata_dba -CompanyId $id}
 & $wrapper -Operation control -Database metadata -Service metadata_dba
 Assert (-not ($global:ProvisioningTestArguments -match '^--set=source_schema=')) 'Metadata source accepted company schema'
 $global:ProvisioningTestExit=1;$rejected=$false
 try {& $wrapper -Operation workers -Database metadata -Service metadata_dba} catch {$rejected=$true}
 Assert $rejected 'psql failure was ignored'
 $company=Get-Content (Join-Path $PSScriptRoot '../cdc-source.template.sql') -Raw
 $boundary=Get-Content (Join-Path $PSScriptRoot '../cdc-boundary-guard.sql') -Raw
 Assert ($company.Contains(':"source_schema".company_event_outbox')) 'Source schema identifier is not quoted'
 Assert ($company.Contains(':"cdc_role"')) 'Role identifier is not quoted'
 Assert ($company.Contains('count(*) FROM pg_publication_rel WHERE prpubid=publication_id)<>2')) 'Exact publication cardinality guard missing'
 foreach($contract in @('pg_auth_members','has_database_privilege(role_id,oid,''CONNECT'')','pg_publication_namespace','puballtables','pg_publication_rel','has_table_privilege','has_any_column_privilege','rolbypassrls')) {Assert ($boundary.Contains($contract)) "Boundary SQL contract missing: $contract"}
 Assert ($company.Contains('prqual IS NOT NULL OR prattrs IS NOT NULL')) 'Full-table publication qualifier guard missing'
 Write-Output 'PASS: native psql wrapper argument/negative checks and static SQL boundary contracts; no DB contacted'
} finally {
 Remove-Item Function:\psql -ErrorAction SilentlyContinue
 $global:LASTEXITCODE=0
}

