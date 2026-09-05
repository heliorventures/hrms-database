$ErrorActionPreference = 'Stop'
$Script = Join-Path $PSScriptRoot 'update-indian-tenant-timezones.ps1'
$Preview = & $Script -AllIndianTenants -GenerateSqlOnly
if ($Preview -notmatch 'BEGIN READ ONLY' -or $Preview -match '\bUPDATE\b') { throw 'Preview must remain read-only.' }
if ($Preview -notmatch "'IN', 'INDIA'" -or $Preview -notmatch 'is_deleted = FALSE') { throw 'Tenant scope is missing.' }
$Sql = & $Script -TenantSlug solvianconsultancy -Execute -ExpectedCount 1 -GenerateSqlOnly
if ($Sql -notmatch "subdomain = 'solvianconsultancy'" -or $Sql -notmatch 'target_count <> 1' -or $Sql -notmatch 'FOR UPDATE') { throw 'Execution guards are missing.' }
if ($Sql -match "UPPER\(TRIM\(COALESCE\(country") { throw 'An explicitly selected legacy tenant must not depend on country metadata.' }
if ($Sql -match 'UPDATE.*attendance') { throw 'Historical attendance must not be rewritten.' }
$Rejected = $false
try { & $Script -AllIndianTenants -Execute -GenerateSqlOnly } catch { $Rejected = $true }
if (-not $Rejected) { throw 'Execution must require an expected change count.' }
Write-Host 'Timezone script static safeguards passed; no database connection was made.'
