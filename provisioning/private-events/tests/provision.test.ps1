$ErrorActionPreference='Stop'
$wrapper=Join-Path $PSScriptRoot '../provision.ps1'
$global:PrivateProvisionCalls=[Collections.Generic.List[object]]::new()
$global:PrivateProvisionExit=0
function global:psql {$global:PrivateProvisionCalls.Add(@($args));$global:LASTEXITCODE=$global:PrivateProvisionExit}
function Assert([bool]$value,[string]$message){if(!$value){throw $message}}
function Reject([scriptblock]$action){$before=$global:PrivateProvisionCalls.Count;$rejected=$false;try{&$action}catch{$rejected=$true};Assert $rejected 'Invalid input accepted';Assert ($before-eq$global:PrivateProvisionCalls.Count) 'Invalid input reached psql'}
try {
 $company=@{Operation='company';Database='Company_One';Service='source_dba';ScopeId='11111111-1111-4111-8111-111111111111';SourceSchema='Tenant_One';RuntimeRole='company_runtime';BootstrapMode='empty';RegistryService='metadata_dba';RegistryDatabase='Metadata';RuntimeHost='postgres-company'}
 & $wrapper @company
 Assert ($global:PrivateProvisionCalls.Count-eq 2) 'Company registration must precede source initialization'
 Assert ($global:PrivateProvisionCalls[0]-contains 'service=metadata_dba dbname=Metadata sslmode=verify-full') 'Fixed registry TLS connection missing'
 $args=$global:PrivateProvisionCalls[1]
 foreach($item in @('service=source_dba dbname=Company_One sslmode=verify-full','--single-transaction','--set=ON_ERROR_STOP=1','--set=source_schema=Tenant_One','--set=producer_generation=1','--set=runtime_role=company_runtime')){Assert ($args-contains$item) "Missing native argument $item"}
 foreach($field in @('ScopeId','SourceSchema','RuntimeRole','RegistryService','RegistryDatabase','RuntimeHost')){$bad=$company.Clone();$bad[$field]='x;SELECT 1';Reject {&$wrapper @bad}}
 foreach($schema in @('public','PUBLIC','kabipay_ops','information_schema','pg_catalog','PG_temp','a-b','')){$bad=$company.Clone();$bad.SourceSchema=$schema;Reject {&$wrapper @bad}}
 foreach($role in @('postgres','pg_read_all_data','PUBLIC','kabipay_ops','')){$bad=$company.Clone();$bad.RuntimeRole=$role;Reject {&$wrapper @bad}}
 $bad=$company.Clone();$bad.ProducerGeneration=0;Reject {&$wrapper @bad}
 $bad=$company.Clone();$bad.ProducerGeneration=9007199254740992;Reject {&$wrapper @bad}
 $bad=$company.Clone();$bad.Remove('RegistryService');Reject {&$wrapper @bad}
 & $wrapper -Operation operator -Database Metadata -Service metadata_dba -ScopeId '22222222-2222-4222-8222-222222222222' -RuntimeRole metadata_runtime -BootstrapMode existing -ProducerGeneration 7
 Assert ($global:PrivateProvisionCalls[-1]-contains '--set=source_schema=kabipay_ops') 'Operator schema must be fixed'
 Reject {&$wrapper -Operation operator -Database Metadata -Service metadata_dba -ScopeId '22222222-2222-4222-8222-222222222222' -RuntimeRole metadata_runtime -BootstrapMode empty -SourceSchema tenant_wrong}
 $before=$global:PrivateProvisionCalls.Count;$global:PrivateProvisionExit=1;$failed=$false;try{&$wrapper @company}catch{$failed=$true};Assert $failed 'psql failure ignored';Assert ($global:PrivateProvisionCalls.Count-eq$before+1) 'Registry failure still reached source database'
 Write-Output 'PASS: private source bootstrap argument/negative contracts; psql mocked, no database contacted'
} finally {Remove-Item Function:\psql -ErrorAction SilentlyContinue;$global:LASTEXITCODE=0}
