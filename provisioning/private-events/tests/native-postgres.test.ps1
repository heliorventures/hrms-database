param([string]$PostgresBin='C:/Program Files/PostgreSQL/17/bin')
$ErrorActionPreference='Stop'
$workspace=(Resolve-Path (Join-Path $PSScriptRoot '../../../..')).Path
$suffix=[guid]::NewGuid().ToString('N');$container='private-bootstrap-'+$suffix;$containerId=$null;$checks=0
$fixture=Join-Path $workspace ('.codex-tmp/private-bootstrap-'+$suffix)
New-Item -ItemType Directory -Path $fixture -Force|Out-Null
$psql=Join-Path $PostgresBin 'psql.exe';if(!(Test-Path -LiteralPath $psql)){throw 'Native psql client required'}
$schema='Tenant_Bootstrap_'+$suffix.Substring(0,8);$role='private_runtime_'+$suffix.Substring(0,8);$opsRole='private_ops_'+$suffix.Substring(0,8)
$scope='11111111-1111-4111-8111-111111111111';$opsScope='22222222-2222-4222-8222-222222222222'
function Query([string]$Sql,[string]$File,[string[]]$Variables=@(),[string]$ExpectedError){
 if(!$File){$File=Join-Path $fixture ('query-'+[guid]::NewGuid().ToString('N')+'.sql');[IO.File]::WriteAllText($File,$Sql,[Text.UTF8Encoding]::new($false))}
 $arguments=@('-h','127.0.0.1','-p',"$script:port",'-U','private_bootstrap_dba','-d','private_bootstrap_fixture','-X','-q','-v','ON_ERROR_STOP=1','--single-transaction')
 foreach($variable in $Variables){$arguments+=@('-v',$variable)};$arguments+=@('-f',$File)
 $previous=$ErrorActionPreference;$ErrorActionPreference='Continue';$output=(& $psql @arguments 2>&1|ForEach-Object{$_.ToString()}|Out-String -Width 4096);$code=$LASTEXITCODE;$ErrorActionPreference=$previous
 if($ExpectedError){if($code-eq 0-or!$output.Contains($ExpectedError)){throw "Expected SQL rejection missing: $ExpectedError; $output"}}elseif($code-ne 0){throw "Isolated bootstrap SQL failed: $output"}
 $script:checks++;return $output
}
function Company([string]$Mode='empty',[long]$Generation=1,[string]$ExpectedError){
 Query -File (Join-Path $PSScriptRoot '../company.template.sql') -Variables @('database=private_bootstrap_fixture',"scope_id=$scope","source_schema=$schema","runtime_role=$role","bootstrap_mode=$Mode","producer_generation=$Generation") -ExpectedError $ExpectedError|Out-Null
}
function Operator([string]$Mode='empty',[string]$ExpectedError){Query -File (Join-Path $PSScriptRoot '../operator.template.sql') -Variables @('database=private_bootstrap_fixture',"scope_id=$opsScope",'source_schema=kabipay_ops',"runtime_role=$opsRole","bootstrap_mode=$Mode",'producer_generation=1') -ExpectedError $ExpectedError|Out-Null}
function TableDdl([string]$File,[string]$Prefix,[string]$Name){
 $document=[Xml.XmlDocument]::new();try{$document.LoadXml([IO.File]::ReadAllText($File))}catch{throw "Canonical migration XML is invalid: $($_.Exception.Message)"};$sql=$document.SelectSingleNode("//*[local-name()='sql']").InnerText
 $pattern=[regex]::Escape("CREATE TABLE $Prefix.$Name (")+'[\s\S]*?\n\);';$ddl=[regex]::Match($sql,$pattern).Value
 if(!$ddl){throw "Canonical DDL missing for $Name"};return $ddl
}
try {
 $containerId=(& docker run --pull=never --rm --detach --name $container --publish 127.0.0.1::5432 --env POSTGRES_USER=private_bootstrap_dba --env POSTGRES_DB=private_bootstrap_fixture --env POSTGRES_HOST_AUTH_METHOD=trust postgres:16-alpine|Out-String).Trim()
 if($LASTEXITCODE-ne 0-or$containerId-cnotmatch'^[a-f0-9]{64}$'){throw 'Owned PostgreSQL16 container startup failed'}
 $binding=(& docker port $containerId 5432/tcp|Out-String).Trim();if($binding-cnotmatch'^127\.0\.0\.1:(\d+)$'){throw 'Owned fixture must bind loopback only'};$script:port=[int]$Matches[1]
 $ready=$false;for($i=0;$i-lt 30;$i++){& docker exec $containerId pg_isready -U private_bootstrap_dba -d private_bootstrap_fixture *> $null;if($LASTEXITCODE-eq 0){$ready=$true;break};Start-Sleep -Milliseconds 200};if(!$ready){throw 'Owned PostgreSQL fixture did not become ready'}
 $source=Join-Path $workspace 'hrms-database/changelog/migrations/0125_private_event_source/private_event_source.xml'
 $control=Join-Path $workspace 'hrms-database/changelog/migrations/0124_private_event_control/private_event_control.xml'
 $ddl='';foreach($name in @('private_source_cutover','private_delivery_receipt','private_domain_receipt','private_survey_execution_state','private_legacy_export')){$ddl+=(TableDdl $source '"${schema}"' $name).Replace('${schema}',$schema)+"`n"}
 Query @"
REVOKE CONNECT ON DATABASE postgres,template1 FROM PUBLIC;
CREATE ROLE $role LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOREPLICATION;
CREATE ROLE $opsRole LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOREPLICATION;
CREATE ROLE private_bootstrap_extra;
CREATE SCHEMA "$schema";
CREATE TABLE "$schema"."user"(id uuid PRIMARY KEY,tenant_id uuid NOT NULL);
CREATE TABLE "$schema".employee(id uuid PRIMARY KEY,tenant_id uuid NOT NULL);
CREATE TABLE "$schema".organization_command_receipt(tenant_id uuid,source_tenant_id uuid);
INSERT INTO "$schema".organization_command_receipt VALUES('$scope','$opsScope');
CREATE TABLE "$schema".survey(id uuid NOT NULL,tenant_id uuid NOT NULL,UNIQUE(tenant_id,id));
CREATE TABLE "$schema".company_event_outbox(id uuid PRIMARY KEY,source_tenant_id uuid,organization_id uuid,event_type text,aggregate_type text,aggregate_id uuid,aggregate_version bigint,event_envelope jsonb,event_stream text,created_at timestamptz,source_position bigserial);
CREATE TABLE "$schema".audit_log(id uuid PRIMARY KEY,tenant_id uuid);
CREATE TABLE "$schema".outbox_event(id uuid PRIMARY KEY,tenant_id uuid);
CREATE TABLE "$schema".webhook_delivery_log(id uuid PRIMARY KEY,tenant_id uuid);
CREATE TABLE "$schema".employee_finance_outbox(id uuid PRIMARY KEY,tenant_id uuid);
CREATE TABLE "$schema".private_capture_evidence(id uuid PRIMARY KEY);
CREATE TABLE "$schema".business_grant_preserved(id integer);
GRANT SELECT ON "$schema".business_grant_preserved TO $role;
CREATE TABLE "$schema".private_file_cleanup_task(id integer,status text);
GRANT SELECT,UPDATE ON "$schema".private_file_cleanup_task TO $role;
CREATE FUNCTION "$schema".private_file_cleanup_business() RETURNS integer LANGUAGE SQL AS 'SELECT 1';
$ddl
"@|Out-Null
 Company existing 1 'Explicit legacy inventory classification'
 Company;Company # exact initial reapply
 Query @"
DO `$verify`$ BEGIN
 IF (SELECT count(*) FROM "$schema".private_source_cutover)<>1 OR NOT EXISTS(SELECT 1 FROM "$schema".private_source_cutover WHERE tenant_id='$scope' AND source_schema='$schema' AND producer_generation=1 AND state='PREPARED' AND NOT writers_fenced AND NOT reader_switch_complete AND NOT business_state_complete AND NOT pending_ownership_complete) THEN RAISE EXCEPTION 'Initial authority mismatch';END IF;
 IF NOT has_column_privilege('$role','"$schema".private_source_cutover','updated_at','UPDATE') OR has_column_privilege('$role','"$schema".private_source_cutover','producer_generation','UPDATE') OR NOT has_table_privilege('$role','"$schema".business_grant_preserved','SELECT') THEN RAISE EXCEPTION 'Least privilege or business grant mismatch';END IF;
 IF NOT has_table_privilege('$role','"$schema".private_file_cleanup_task','SELECT,UPDATE') OR NOT has_function_privilege('$role','"$schema".private_file_cleanup_business()','EXECUTE') THEN RAISE EXCEPTION 'Source private-file business grants changed';END IF;
END `$verify`$;
SET ROLE $role;SELECT producer_generation FROM "$schema".private_source_cutover FOR SHARE;RESET ROLE;
"@|Out-Null
 foreach($column in @('tenant_id','source_database','source_schema','producer_generation','state','writers_fenced','reader_switch_complete','business_state_complete','pending_ownership_complete','source_version')){
  Query "SET ROLE $role;UPDATE `"$schema`".private_source_cutover SET $column=$column;" -ExpectedError 'permission denied'|Out-Null
 }
 foreach($sql in @("DELETE FROM `"$schema`".audit_log","INSERT INTO `"$schema`".private_capture_evidence VALUES(gen_random_uuid())","DELETE FROM `"$schema`".private_delivery_receipt","UPDATE `"$schema`".private_delivery_receipt SET intent_hash=intent_hash","INSERT INTO `"$schema`".private_legacy_export(id) VALUES(gen_random_uuid())","SELECT setval(pg_get_serial_sequence('`"$schema`".company_event_outbox','source_position'),100)")){
  Query "SET ROLE $role;$sql;" -ExpectedError 'permission denied'|Out-Null
 }
 Query "GRANT UPDATE(producer_generation) ON `"$schema`".private_source_cutover TO $role;"|Out-Null;Company empty 1 'Unexpected private runtime effective column privileges';Query "REVOKE UPDATE(producer_generation) ON `"$schema`".private_source_cutover FROM $role;"|Out-Null
 Query "GRANT SELECT ON `"$schema`".private_capture_evidence TO PUBLIC;"|Out-Null;Company empty 1 'Unexpected private runtime effective column privileges';Query "REVOKE SELECT ON `"$schema`".private_capture_evidence FROM PUBLIC;"|Out-Null
 Query "GRANT private_bootstrap_extra TO $role;"|Out-Null;Company empty 1 'cannot inherit';Query "REVOKE private_bootstrap_extra FROM $role;"|Out-Null
 Company empty 2 'Existing source authority differs or advanced'
 Query "UPDATE `"$schema`".private_source_cutover SET reader_switch_complete=true;"|Out-Null;Company empty 1 'Existing source authority differs or advanced';Query "UPDATE `"$schema`".private_source_cutover SET reader_switch_complete=false;"|Out-Null
 Query "INSERT INTO `"$schema`".`"user`" VALUES(gen_random_uuid(),'$opsScope');"|Out-Null;Company empty 1 'another tenant identity';Query "DELETE FROM `"$schema`".`"user`";"|Out-Null
 Query "CREATE FUNCTION `"$schema`".private_capture_fake() RETURNS integer LANGUAGE SQL SECURITY DEFINER AS 'SELECT 1';"|Out-Null;Company empty 1 'operator evidence/capture/retirement functions';Query "REVOKE ALL ON FUNCTION `"$schema`".private_capture_fake() FROM PUBLIC;"|Out-Null
 Company
 $operatorDdl=(TableDdl $control 'kabipay_ops' 'private_source_cutover')+"`n"+(TableDdl $control 'kabipay_ops' 'private_legacy_export')
 Query @"
CREATE SCHEMA kabipay_ops;
CREATE TABLE kabipay_ops.organization_outbox(id uuid PRIMARY KEY,organization_id uuid,source_tenant_id uuid,actor_principal_id uuid,aggregate_id uuid,aggregate_version bigint,event_type text,schema_version integer,payload jsonb,event_stream text,created_at timestamptz,source_position bigserial);
CREATE TABLE kabipay_ops.operator_audit_log(id uuid PRIMARY KEY);
INSERT INTO kabipay_ops.operator_audit_log VALUES(gen_random_uuid());
CREATE TABLE kabipay_ops.tenant(id uuid PRIMARY KEY,is_deleted boolean NOT NULL);
CREATE TABLE kabipay_ops.tenant_database(tenant_id uuid,db_type text,db_host text,db_name text,schema_name text,is_active boolean);
INSERT INTO kabipay_ops.tenant VALUES('$scope',false);
INSERT INTO kabipay_ops.tenant_database VALUES('$scope','POSTGRES','source.example','private_bootstrap_fixture','$schema',true);
$operatorDdl
"@|Out-Null
 Operator empty 'Explicit legacy inventory classification';Operator existing;Operator existing
 Query -File (Join-Path $PSScriptRoot '../registration.template.sql') -Variables @('registry_database=private_bootstrap_fixture','database=private_bootstrap_fixture',"scope_id=$scope","source_schema=$schema",'runtime_host=source.example')|Out-Null
 Query -File (Join-Path $PSScriptRoot '../registration.template.sql') -Variables @('registry_database=private_bootstrap_fixture','database=private_bootstrap_fixture',"scope_id=$scope","source_schema=$schema",'runtime_host=wrong.example') -ExpectedError 'Exact registered company source binding required'|Out-Null
 Query "INSERT INTO kabipay_ops.tenant_database VALUES('$opsScope','POSTGRES','source.example','private_bootstrap_fixture','$schema',true);"|Out-Null
 Query -File (Join-Path $PSScriptRoot '../registration.template.sql') -Variables @('registry_database=private_bootstrap_fixture','database=private_bootstrap_fixture',"scope_id=$scope","source_schema=$schema",'runtime_host=source.example') -ExpectedError 'shared by another company'|Out-Null
 Write-Output "PASS: $checks native PostgreSQL16 bootstrap/role checks; owned loopback fixture artifacts $fixture. Native psql source-template tests use isolated trust transport, not production verify-full transport proof."
}finally{
 if($containerId){$actual=(& docker inspect --format '{{.Id}}' $container|Out-String).Trim();if($LASTEXITCODE-ne 0-or$actual-ne$containerId){throw 'Owned fixture identity changed; refusing cleanup'};& docker rm --force $containerId|Out-Null;if($LASTEXITCODE-ne 0){throw 'Owned fixture cleanup failed'}}
}
