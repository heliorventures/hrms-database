param([string]$PostgresBin='C:/Program Files/PostgreSQL/17/bin')
$ErrorActionPreference='Stop'
$workspace=(Resolve-Path (Join-Path $PSScriptRoot '../../../..')).Path
if (!(Test-Path (Join-Path $workspace 'hrms-database/provisioning/organization/provision.ps1'))) {throw 'Workspace boundary could not be verified'}
$fixture=Join-Path $workspace ('.codex-tmp/native-cdc-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force|Out-Null
$data=Join-Path $fixture 'data';$started=$false;$checks=0
$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$listener.Start();$port=$listener.LocalEndpoint.Port;$listener.Stop()
$psql=Join-Path $PostgresBin 'psql.exe';$ctl=Join-Path $PostgresBin 'pg_ctl.exe'
function Query([string]$Database,[string]$Sql,[string]$File,[string[]]$Variables=@(),[string]$ExpectedError) {
 $arguments=@('-h','127.0.0.1','-p',"$port",'-U','infra_dba','-d',$Database,'-X','-q','-v','ON_ERROR_STOP=1','--single-transaction')
 foreach($variable in $Variables){$arguments+=@('-v',$variable)}
  if(!$File){$File=Join-Path $fixture ('query-'+[guid]::NewGuid().ToString('N')+'.sql');[IO.File]::WriteAllText($File,$Sql,[Text.UTF8Encoding]::new($false))}
 $arguments+=@('-f',$File)
 $previous=$ErrorActionPreference;$ErrorActionPreference='Continue'
 $output=(& $psql @arguments 2>&1|ForEach-Object {$_.ToString()}|Out-String -Width 4096);$status=$LASTEXITCODE;$ErrorActionPreference=$previous
 if($ExpectedError){if($status-eq 0 -or !$output.Contains($ExpectedError)){throw "Expected rejection missing: $ExpectedError; $output"}}elseif($status-ne 0){throw "Synthetic SQL failed: $output"}
 $script:checks++;return $output
}
function Company([string]$Database,[string]$Id,[string]$Schema,[string]$ExpectedError,[string]$Role) {
 if(!$Role){$Role='organization_cdc_'+$Id.Replace('-','')}
 Query $Database -File (Join-Path $PSScriptRoot '../cdc-source.template.sql') -Variables @("database=$Database","company_id=$Id","source_schema=$Schema","cdc_role=$Role") -ExpectedError $ExpectedError|Out-Null
}
function Setup([string]$Database,[string]$Sql) {Query $Database $Sql|Out-Null}
try {
 & (Join-Path $PostgresBin 'postgres.exe') --version
 & (Join-Path $PostgresBin 'initdb.exe') -D $data -U infra_dba -A trust --no-locale --encoding=UTF8 > (Join-Path $fixture 'initdb.log')
 if($LASTEXITCODE-ne 0){throw 'Isolated initdb failed'}
 & $ctl -D $data -l (Join-Path $fixture 'server.log') -o "-h 127.0.0.1 -p $port -c wal_level=logical -c max_replication_slots=8" -w start
 if($LASTEXITCODE-ne 0){throw 'Isolated PostgreSQL startup failed'};$started=$true
 # CREATE DATABASE cannot run inside our transaction helper.
 foreach($database in @('company_one','company_two','metadata')){& $psql -h 127.0.0.1 -p $port -U infra_dba -d postgres -X -q -v ON_ERROR_STOP=1 -c "CREATE DATABASE $database";if($LASTEXITCODE-ne 0){throw 'Synthetic database creation failed'}}
 $one='11111111-1111-4111-8111-111111111111';$two='22222222-2222-4222-8222-222222222222'
 $role1='organization_cdc_'+$one.Replace('-','');$role2='organization_cdc_'+$two.Replace('-','')
 Setup postgres "CREATE ROLE $role1 LOGIN REPLICATION NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE; CREATE ROLE $role2 LOGIN REPLICATION NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE; CREATE ROLE organization_control_cdc LOGIN REPLICATION NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE; CREATE ROLE cdc_extra;"
 $migrations=Join-Path $workspace 'hrms-database/changelog/migrations'
 $outbox=[regex]::Match((Get-Content (Join-Path $migrations '0115_organization_tenant_runtime/organization_tenant_runtime.xml') -Raw),'CREATE TABLE "\$\{schema\}"\.company_event_outbox \([\s\S]*?\);').Value
 $marker=[regex]::Match((Get-Content (Join-Path $migrations '0121_organization_source_history/organization_source_history.xml') -Raw),'CREATE TABLE "\$\{schema\}"\.organization_capture_marker \([\s\S]*?\);').Value
 if(!$outbox -or !$marker){throw 'Canonical source DDL extraction failed'}
 foreach($entry in @(@('company_one','tenant_one'),@('company_two','Tenant_Two'))){$schema=$entry[1];$ddl=($outbox+"`n"+$marker).Replace('${schema}',$schema);Setup $entry[0] "CREATE SCHEMA `"$schema`"; $ddl CREATE TABLE public.private_finance(id integer,secret text); ALTER TABLE public.private_finance ENABLE ROW LEVEL SECURITY;"}
 # Stock PUBLIC CONNECT must fail before any grants/publication provisioning.
 Company company_one $one tenant_one 'CDC identity can CONNECT to another database'
 Setup postgres 'REVOKE CONNECT ON DATABASE postgres,template1,company_one,company_two,metadata FROM PUBLIC;'
 Setup postgres "GRANT CONNECT ON DATABASE company_one TO $role1; GRANT CONNECT ON DATABASE company_two TO $role2; GRANT CONNECT ON DATABASE metadata TO organization_control_cdc;"
 Company company_one $one tenant_one
 Company company_one $one tenant_one # exact idempotent reapply
 Company company_two $two Tenant_Two
 Setup company_one "DO `$check`$ BEGIN IF has_database_privilege('$role1','company_two','CONNECT') OR has_database_privilege('$role2','company_one','CONNECT') THEN RAISE EXCEPTION 'Cross-company CONNECT leaked'; END IF; IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid='public.private_finance'::regclass) THEN RAISE EXCEPTION 'RLS changed'; END IF; END `$check`$;"
 Setup postgres "GRANT CONNECT ON DATABASE company_two TO $role1;"
 Company company_one $one tenant_one 'CDC identity can CONNECT to another database'
 Setup postgres "REVOKE CONNECT ON DATABASE company_two FROM $role1;"
 Setup company_one 'GRANT SELECT ON public.private_finance TO PUBLIC;'
 Company company_one $one tenant_one 'unexpected effective user-table privileges'
 Setup company_one 'REVOKE SELECT ON public.private_finance FROM PUBLIC;'
 Setup company_one "GRANT SELECT(secret) ON public.private_finance TO $role1;"
 Company company_one $one tenant_one 'unexpected effective user-table privileges'
 Setup company_one "REVOKE SELECT(secret) ON public.private_finance FROM $role1; GRANT UPDATE(aggregate_version) ON tenant_one.company_event_outbox TO $role1;"
 Company company_one $one tenant_one 'unexpected source-table mutation privileges'
 Setup company_one "REVOKE UPDATE(aggregate_version) ON tenant_one.company_event_outbox FROM $role1;"
 Setup postgres "GRANT cdc_extra TO $role1;"
 Company company_one $one tenant_one 'must not inherit or assume other roles'
 Setup postgres "REVOKE cdc_extra FROM $role1;"
 Setup company_one 'ALTER PUBLICATION organization_company_outbox SET TABLE tenant_one.company_event_outbox WHERE (aggregate_version>0),tenant_one.organization_capture_marker;'
 Company company_one $one tenant_one 'does not exactly match'
 Setup company_one 'ALTER PUBLICATION organization_company_outbox SET TABLE tenant_one.company_event_outbox(id),tenant_one.organization_capture_marker;'
 Company company_one $one tenant_one 'does not exactly match'
 Setup company_one 'ALTER PUBLICATION organization_company_outbox SET TABLE tenant_one.company_event_outbox;'
 Company company_one $one tenant_one 'does not exactly match'
 Setup company_one 'ALTER PUBLICATION organization_company_outbox SET TABLE tenant_one.company_event_outbox,tenant_one.organization_capture_marker; CREATE PUBLICATION leaked_private FOR TABLE public.private_finance;'
 Company company_one $one tenant_one 'Another publication exposes'
 Setup company_one 'DROP PUBLICATION leaked_private; CREATE PUBLICATION leaked_all FOR ALL TABLES;'
 Company company_one $one tenant_one 'Another publication exposes'
 Setup company_one 'DROP PUBLICATION leaked_all; CREATE PUBLICATION leaked_schema FOR TABLES IN SCHEMA public;'
 Company company_one $one tenant_one 'Another publication exposes'
 Setup company_one 'DROP PUBLICATION leaked_schema;'
 Company company_one $one public 'role/schema binding is invalid'
 Company company_one $one pg_catalog 'role/schema binding is invalid'
 Company company_one $one tenant_one 'role/schema binding is invalid' $role2
 Company company_one $one tenant_one
 Setup metadata 'CREATE SCHEMA kabipay_ops; CREATE TABLE kabipay_ops.organization_outbox(id uuid PRIMARY KEY);'
 foreach($iteration in 1..2){Query metadata -File (Join-Path $PSScriptRoot '../control-cdc-grants.template.sql') -Variables @('database=metadata')|Out-Null}
 Setup metadata 'ALTER PUBLICATION organization_control_outbox SET TABLE kabipay_ops.organization_outbox(id);'
 Query metadata -File (Join-Path $PSScriptRoot '../control-cdc-grants.template.sql') -Variables @('database=metadata') -ExpectedError 'differs from the exact metadata outbox'|Out-Null
 Write-Output "PASS: $checks native PostgreSQL17.6 checks; isolated fixture $fixture; loopback port $port. This is not pinned PostgreSQL16 or deployment proof."
} finally {
 if($started){& $ctl -D $data -m fast -w stop;if($LASTEXITCODE-ne 0){throw "Could not stop owned isolated PostgreSQL data directory $data"}}
}



