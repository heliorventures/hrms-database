param([string]$DatabaseRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
$migrationPath = Join-Path $DatabaseRoot 'changelog/migrations/0087_attendance_day_boundary/attendance_day_boundary.xml'
[xml]$migration = Get-Content -LiteralPath $migrationPath -Raw
[xml]$master = Get-Content -LiteralPath (Join-Path $DatabaseRoot 'changelog/tenant.changelog-master.xml') -Raw
$ns = New-Object System.Xml.XmlNamespaceManager($migration.NameTable)
$ns.AddNamespace('db', 'http://www.liquibase.org/xml/ns/dbchangelog')
$tables = @($migration.SelectNodes('//db:createTable', $ns))
foreach ($name in @('attendance_day_profile', 'attendance_day_policy_version', 'attendance_day_window')) {
    $table = @($tables | Where-Object { $_.tableName -eq $name })
    if ($table.Count -ne 1) { throw "Missing or duplicate table $name" }
    if ($table[0].schemaName -ne '${schema}') { throw "Table $name must use tenant schema" }
    if (-not $table[0].SelectSingleNode('db:column[@name="tenant_id"]/db:constraints[@nullable="false"]', $ns)) { throw "Tenant key absent from $name" }
}
$masterNs = New-Object System.Xml.XmlNamespaceManager($master.NameTable)
$masterNs.AddNamespace('db', 'http://www.liquibase.org/xml/ns/dbchangelog')
$included = @($master.SelectNodes('//db:include', $masterNs) | Where-Object { $_.file -eq 'migrations/0087_attendance_day_boundary/attendance_day_boundary.xml' })
if ($included.Count -ne 1) { throw 'Migration must be included exactly once' }
$constraints = @($migration.SelectNodes('//db:addUniqueConstraint | //db:addForeignKeyConstraint', $ns))
foreach ($name in @('uq_attendance_day_window_tenant_date', 'uq_attendance_day_version_tenant_id', 'fk_attendance_day_window_version')) {
    if (-not ($constraints | Where-Object { $_.constraintName -eq $name })) { throw "Missing constraint $name" }
}
$windowKey = $constraints | Where-Object { $_.constraintName -eq 'uq_attendance_day_window_tenant_date' }
if ($windowKey.tableName -ne 'attendance_day_window' -or $windowKey.columnNames -ne 'tenant_id,work_date') { throw 'Window uniqueness must use tenant and work date' }
$versionKey = $constraints | Where-Object { $_.constraintName -eq 'uq_attendance_day_version_tenant_id' }
if ($versionKey.tableName -ne 'attendance_day_policy_version' -or $versionKey.columnNames -ne 'tenant_id,id') { throw 'Version reference key must include tenant' }
$reference = $constraints | Where-Object { $_.constraintName -eq 'fk_attendance_day_window_version' }
if ($reference.baseTableName -ne 'attendance_day_window' -or $reference.baseColumnNames -ne 'tenant_id,policy_version_id' -or $reference.referencedTableName -ne 'attendance_day_policy_version' -or $reference.referencedColumnNames -ne 'tenant_id,id' -or $reference.onDelete -ne 'RESTRICT') { throw 'Window version reference must enforce tenant ownership and preserve history' }
$profileKey = $migration.SelectSingleNode('//db:addPrimaryKey[@tableName="attendance_day_profile"]', $ns)
if (-not $profileKey -or $profileKey.columnNames -ne 'tenant_id') { throw 'Activation profile must be unique per tenant' }
Write-Output 'PASS: attendance-day XML tables, required tenant keys, composite references and master inclusion'
