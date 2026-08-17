<#
.SYNOPSIS
    Seed deterministic demo rows into a provisioned tenant schema and the
    kabipay_ops (operator) schema so every KabiPay subgraph has something
    to return for its list_* queries.

.DESCRIPTION
    Run this AFTER provision-tenant.ps1. The script is idempotent — every
    INSERT uses ON CONFLICT DO NOTHING, so re-running simply keeps the
    existing rows.

    Seeded coverage:

      If GraphQL returns **relation "attendance" does not exist**, tenant Liquibase is behind:
      run `kabipay-database/scripts/update-tenant-liquibase.ps1 -Schema <tenant_schema>` **before** (or after) seeding.

      Tenant plane ("$Schema"):
        0000 foundation   : department (Engineering + Accounting), designation, users/employees; demo + line manager + staff + **accountant@kabipay.local** (ACCOUNTING_APPROVER — second-line expense/travel step in seeded workflows)
        0010 shift/attend : shift (DAY/NIGHT), attendance for today
        0011 leave        : leave_type (CL/SL), leave_request (PENDING)
        0012 payroll      : salary_component (BASIC/HRA/ARREAR), payroll_cycle (current month), demo payslip + TDS
        0013 tax          : tax_configuration_version, tax_slab x 2
        0014 benefits     : benefit_type, benefit_plan
        0015 expense      : expense_category, expense (PENDING)
        0016 recruitment  : job_posting (OPEN), application (APPLIED)
        0017 onboarding   : onboarding_checklist (demo tasks for demo employee)
        0018 performance  : review_cycle (ACTIVE), goal (IN_PROGRESS)
        0019 lms          : skill, course
        0020 succession   : competency, talent_pool
        0021 compensation : salary_band, compensation_review_cycle
        0024 analytics     : report_definition, dashboard, dashboard_widget, report_schedule, workforce_snapshot
        0030 outbox         : outbox_event (sample rows for Insights event queue; HR-gated in API)
        0022 assets       : asset_category, asset
        0023 grievance    : grievance_category, grievance_case
        0033 travel       : travel_request (PENDING, demo employee)
        0025 workflow     : LEAVE + EXPENSE + TRAVEL_REQUEST + TIMESHEET definitions (multi-step approvals; expense/travel route to accounting role on step 2 in demo seeds)
        0027 comm/audit   : announcement, notification

      Ops plane (kabipay_ops):
        module           : 4 starter modules (EMPLOYEE, LEAVE, PAYROLL, RECRUIT)
        tenant_subscription : 2 active subscriptions for this tenant
        billing_cycle    : current-month cycle
        invoice          : 1 PENDING invoice for the above cycle
        payment          : 1 SUCCEEDED payment on that invoice
        operator_role    : 2 base roles (ADMIN, SUPPORT)
        operator_user    : 1 active admin operator

    Prints the seeded employee UUID at the end — use it as `-e EMPLOYEE_ID`
    when you query the subgraph directly.

.PARAMETER TenantId
    UUID of the tenant registered in kabipay_ops.tenant (produced by provision-tenant.ps1).

.PARAMETER Schema
    Target tenant schema, e.g. tenant_demo0001.

.PARAMETER DbName
    Postgres database name. Defaults to kabipay_dev.

.PARAMETER DbUser
    Postgres user. Defaults to kabipay.

.PARAMETER DbPassword
    Password for DbUser. Defaults to changeme.

.PARAMETER PostgresHost
    If set, connect to this host (e.g. Aiven). Uses `kabipay-database/run-sql.cjs` (Node + `pg`). Use with -PostgresPort, -PostgresSsl.

.PARAMETER PostgresPort
    Port when -PostgresHost is set.

.PARAMETER PostgresSsl
    When -PostgresHost is set, set PGSSLMODE=require (required for Aiven).

.EXAMPLE
    .\seed-demo-data.ps1 -TenantId 5a3b... -Schema tenant_demo0001
.EXAMPLE
    .\seed-demo-data.ps1 -TenantId ... -Schema tenant_... -PostgresHost "pg-....aivencloud.com" -PostgresPort 12507 -DbName defaultdb -DbUser avnadmin -DbPassword "..." -PostgresSsl
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TenantId,
    [Parameter(Mandatory = $true)][ValidatePattern('^tenant_[a-z0-9_]{1,50}$')][string]$Schema,
    [string]$DbName,
    [string]$DbUser,
    [string]$DbPassword,
    [string]$PostgresHost = '',
    [int]$PostgresPort = 5432,
    [switch]$PostgresSsl
)

$ErrorActionPreference = 'Stop'

$DatabaseDir = Split-Path -Parent $PSScriptRoot
$DbEnv = Join-Path $DatabaseDir '.env'
$RunSql = Join-Path $DatabaseDir 'run-sql.cjs'
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw "Node.js is required" }
if (-not (Test-Path $RunSql)) { throw "Missing run-sql.cjs. From kabipay-database: npm install" }
function Import-DotEnvFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return }
    Get-Content $Path | ForEach-Object {
        $line = $_.Trim()
        if ($line -match '^\s*#' -or $line -eq '') { return }
        $i = $line.IndexOf('=')
        if ($i -lt 1) { return }
        $k = $line.Substring(0, $i).Trim()
        $v = $line.Substring($i + 1).Trim()
        if ($v.StartsWith('"') -and $v.EndsWith('"')) { $v = $v.Substring(1, $v.Length - 2) }
        if ($k) { Set-Item -Path "Env:$k" -Value $v }
    }
}
Import-DotEnvFile -Path $DbEnv
$isRemoteInEnv = $env:POSTGRES_HOST -and $env:POSTGRES_HOST -notin @('localhost', '127.0.0.1', '')
if ($PostgresHost -or $isRemoteInEnv) {
    if ($PostgresHost) { $env:POSTGRES_HOST = $PostgresHost }
    if ($PostgresSsl) { $env:POSTGRES_SSLMODE = 'require' }
    if ($PSBoundParameters.ContainsKey('PostgresPort')) { $env:POSTGRES_PORT = "$PostgresPort" }
    if ($PSBoundParameters.ContainsKey('DbName') -and -not [string]::IsNullOrWhiteSpace($DbName)) { $env:POSTGRES_DB = $DbName }
    if ($PSBoundParameters.ContainsKey('DbUser') -and -not [string]::IsNullOrWhiteSpace($DbUser)) { $env:POSTGRES_USER = $DbUser }
    if ($PSBoundParameters.ContainsKey('DbPassword') -and -not [string]::IsNullOrWhiteSpace($DbPassword)) { $env:POSTGRES_PASSWORD = $DbPassword }
} else {
    $env:POSTGRES_HOST = 'localhost'
    if ($PSBoundParameters.ContainsKey('PostgresPort')) { $env:POSTGRES_PORT = "$PostgresPort" }
    elseif (-not $env:POSTGRES_PORT) { $env:POSTGRES_PORT = '5432' }
    if ($PSBoundParameters.ContainsKey('DbName') -and -not [string]::IsNullOrWhiteSpace($DbName)) { $env:POSTGRES_DB = $DbName }
    elseif (-not $env:POSTGRES_DB) { $env:POSTGRES_DB = 'kabipay_dev' }
    if ($PSBoundParameters.ContainsKey('DbUser') -and -not [string]::IsNullOrWhiteSpace($DbUser)) { $env:POSTGRES_USER = $DbUser }
    elseif (-not $env:POSTGRES_USER) { $env:POSTGRES_USER = 'kabipay' }
    if ($PSBoundParameters.ContainsKey('DbPassword') -and -not [string]::IsNullOrWhiteSpace($DbPassword)) { $env:POSTGRES_PASSWORD = $DbPassword }
    elseif (-not $env:POSTGRES_PASSWORD) { $env:POSTGRES_PASSWORD = 'changeme' }
    Remove-Item Env:POSTGRES_SSLMODE -ErrorAction SilentlyContinue
}
if ([string]::IsNullOrWhiteSpace($env:POSTGRES_HOST) -or [string]::IsNullOrWhiteSpace($env:POSTGRES_PORT) -or [string]::IsNullOrWhiteSpace($env:POSTGRES_DB) -or [string]::IsNullOrWhiteSpace($env:POSTGRES_USER) -or [string]::IsNullOrWhiteSpace($env:POSTGRES_PASSWORD)) {
    throw "Set POSTGRES_* in $DbEnv (or pass -Postgres* / -Db*)"
}

function New-DeterministicUuid {
    param([Parameter(Mandatory=$true)][string]$Seed)
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try {
        $bytes = $sha1.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("kabipay-seed:$Seed"))[0..15]
        $bytes[6] = ($bytes[6] -band 0x0F) -bor 0x50
        $bytes[8] = ($bytes[8] -band 0x3F) -bor 0x80
        $hex = ($bytes | ForEach-Object { $_.ToString('x2') }) -join ''
        return "$($hex.Substring(0,8))-$($hex.Substring(8,4))-$($hex.Substring(12,4))-$($hex.Substring(16,4))-$($hex.Substring(20,12))"
    } finally { $sha1.Dispose() }
}

# ---------- Deterministic UUIDs ----------
# Foundation
$DepartmentId        = New-DeterministicUuid -Seed "${Schema}:dept:engineering"
$DepartmentAccountingId = New-DeterministicUuid -Seed "${Schema}:dept:accounting"
$DesignationId       = New-DeterministicUuid -Seed "${Schema}:desig:software-engineer"
$DesignationAccountingId = New-DeterministicUuid -Seed "${Schema}:desig:accountant"
$UserId              = New-DeterministicUuid -Seed "${Schema}:user:demo"
$EmployeeId          = New-DeterministicUuid -Seed "${Schema}:employee:demo"
$ManagerUserId       = New-DeterministicUuid -Seed "${Schema}:user:line-manager"
$ManagerEmployeeId   = New-DeterministicUuid -Seed "${Schema}:employee:line-manager"
$TenantAdminUserId   = New-DeterministicUuid -Seed "${Schema}:user:tenant-admin"
$StaffUserId         = New-DeterministicUuid -Seed "${Schema}:user:staff"
$StaffEmployeeId     = New-DeterministicUuid -Seed "${Schema}:employee:staff"
$AccountingUserId    = New-DeterministicUuid -Seed "${Schema}:user:accounting"
$AccountingEmployeeId = New-DeterministicUuid -Seed "${Schema}:employee:accounting"
$TenantAdminEmployeeId = New-DeterministicUuid -Seed "${Schema}:employee:tenant-admin"
$RoleHrAdminId       = New-DeterministicUuid -Seed "${Schema}:role:HR_ADMIN"
$RoleTenantAdminId   = New-DeterministicUuid -Seed "${Schema}:role:TENANT_ADMIN"
$RoleLineManagerId   = New-DeterministicUuid -Seed "${Schema}:role:LINE_MANAGER"
$RoleDemoStaffId     = New-DeterministicUuid -Seed "${Schema}:role:DEMO_STAFF"
$RoleAccountingApproverId = New-DeterministicUuid -Seed "${Schema}:role:ACCOUNTING_APPROVER"
$PermEmployeeWriteId = New-DeterministicUuid -Seed "${Schema}:perm:employee:write"
$PermLeaveApproveId  = New-DeterministicUuid -Seed "${Schema}:perm:leave:approve"
$PermLeaveManageId   = New-DeterministicUuid -Seed "${Schema}:perm:leave:manage"
$PermExpenseApproveId = New-DeterministicUuid -Seed "${Schema}:perm:expense:approve"
$PermExpenseManageId   = New-DeterministicUuid -Seed "${Schema}:perm:expense:manage"
$PermExpensePayId = New-DeterministicUuid -Seed "${Schema}:perm:expense:pay"
$PermTaxProofApproveId = New-DeterministicUuid -Seed "${Schema}:perm:tax:approve"
$PermPayrollStatutoryId = New-DeterministicUuid -Seed "${Schema}:perm:payroll:statutory_export"
$PermAttendancePunchPolicyId = New-DeterministicUuid -Seed "${Schema}:perm:attendance:punch_policy"
$PermWorkflowManageId = New-DeterministicUuid -Seed "${Schema}:perm:workflow:manage"
$PermRoleManageId = New-DeterministicUuid -Seed "${Schema}:perm:role:manage"
$PermBenefitsManageId = New-DeterministicUuid -Seed "${Schema}:perm:benefits:manage"
$PermBenefitsSelfId = New-DeterministicUuid -Seed "${Schema}:perm:benefits:self"
$PermRecruitmentManageId = New-DeterministicUuid -Seed "${Schema}:perm:recruitment:manage"
$PermOnboardingManageId = New-DeterministicUuid -Seed "${Schema}:perm:onboarding:manage"
$PermOnboardingSelfId = New-DeterministicUuid -Seed "${Schema}:perm:onboarding:self"
$PermPerformanceManageId = New-DeterministicUuid -Seed "${Schema}:perm:performance:manage"
$PermLearningManageId = New-DeterministicUuid -Seed "${Schema}:perm:learning:manage"
$PermAssetsManageId = New-DeterministicUuid -Seed "${Schema}:perm:assets:manage"
$PermGrievanceManageId = New-DeterministicUuid -Seed "${Schema}:perm:grievance:manage"
$PermGrievanceSelfId = New-DeterministicUuid -Seed "${Schema}:perm:grievance:self"
$PermSuccessionManageId = New-DeterministicUuid -Seed "${Schema}:perm:succession:manage"
$PermCompensationManageId = New-DeterministicUuid -Seed "${Schema}:perm:compensation:manage"
$PermAnalyticsReadId = New-DeterministicUuid -Seed "${Schema}:perm:analytics:read"
$PermAttendancePunchSelfId = New-DeterministicUuid -Seed "${Schema}:perm:attendance:punch_self"
$PermAttendanceRegularizeId = New-DeterministicUuid -Seed "${Schema}:perm:attendance:regularize"
$PermTimesheetApproveId = New-DeterministicUuid -Seed "${Schema}:perm:timesheet:approve"
$PermTimesheetManageId = New-DeterministicUuid -Seed "${Schema}:perm:timesheet:manage"
$PermNotificationManageId = New-DeterministicUuid -Seed "${Schema}:perm:notification:manage"
$ScopeScopeEmployeeAllId  = New-DeterministicUuid -Seed "${Schema}:permission_scope:employee:write:ALL"
$ScopeScopeLeaveAllId   = New-DeterministicUuid -Seed "${Schema}:permission_scope:leave:approve:ALL"
$ScopeScopeLeaveTeamLmId = New-DeterministicUuid -Seed "${Schema}:permission_scope:leave:approve:TEAM:LM"
$ScopeScopeExpenseAllId = New-DeterministicUuid -Seed "${Schema}:permission_scope:expense:approve:ALL"
$ScopeScopeExpenseTeamLmId = New-DeterministicUuid -Seed "${Schema}:permission_scope:expense:approve:TEAM:LM"
$ScopeScopeExpenseAcctAllId = New-DeterministicUuid -Seed "${Schema}:permission_scope:expense:approve:ALL:ACCOUNTING"
$ScopeScopeAttendanceAllId = New-DeterministicUuid -Seed "${Schema}:permission_scope:attendance:read:ALL"
$ScopeAttendancePunchPolicyAllId = New-DeterministicUuid -Seed "${Schema}:permission_scope:attendance:punch_policy:ALL"
$ScopeWorkflowManageAllId = New-DeterministicUuid -Seed "${Schema}:permission_scope:workflow:manage:ALL"
$ScopeTimesheetApproveAllId = New-DeterministicUuid -Seed "${Schema}:permission_scope:timesheet:approve:ALL"
$ScopeTimesheetApproveTeamLmId = New-DeterministicUuid -Seed "${Schema}:permission_scope:timesheet:approve:TEAM:LM"

# Shift / attendance (0010)
$ShiftDayId          = New-DeterministicUuid -Seed "${Schema}:shift:day"
$ShiftNightId        = New-DeterministicUuid -Seed "${Schema}:shift:night"
$AttendanceTodayId   = New-DeterministicUuid -Seed "${Schema}:attendance:today"

# Leave (0011)
$LeaveTypeClId       = New-DeterministicUuid -Seed "${Schema}:leave_type:cl"
$LeaveTypeSlId       = New-DeterministicUuid -Seed "${Schema}:leave_type:sl"
$LeaveRequest1Id     = New-DeterministicUuid -Seed "${Schema}:leave_request:1"
$LeaveTypePtoId      = New-DeterministicUuid -Seed "${Schema}:leave_type:pto"
$LeavePolicyClId     = New-DeterministicUuid -Seed "${Schema}:leave_policy:cl"
$LeavePolicySlId     = New-DeterministicUuid -Seed "${Schema}:leave_policy:sl"
$LeavePolicyPtoId    = New-DeterministicUuid -Seed "${Schema}:leave_policy:pto"
$HolCalCoId          = New-DeterministicUuid -Seed "${Schema}:holiday_calendar:company"
$HolRepublicId       = New-DeterministicUuid -Seed "${Schema}:holiday:republic"
$HolIndependenceId   = New-DeterministicUuid -Seed "${Schema}:holiday:independence"
$LeaveApprovedMgrId  = New-DeterministicUuid -Seed "${Schema}:leave_request:approved_mgr"
$LbDemoClId          = New-DeterministicUuid -Seed "${Schema}:leave_balance:demo:cl"
$LbDemoSlId          = New-DeterministicUuid -Seed "${Schema}:leave_balance:demo:sl"
$LbDemoPtoId         = New-DeterministicUuid -Seed "${Schema}:leave_balance:demo:pto"
$LbMgrClId           = New-DeterministicUuid -Seed "${Schema}:leave_balance:mgr:cl"
$LbStaffClId         = New-DeterministicUuid -Seed "${Schema}:leave_balance:staff:cl"
$LbTenantAdminClId   = New-DeterministicUuid -Seed "${Schema}:leave_balance:tenant_admin:cl"
$LbTenantAdminSlId   = New-DeterministicUuid -Seed "${Schema}:leave_balance:tenant_admin:sl"
$LbTenantAdminPtoId  = New-DeterministicUuid -Seed "${Schema}:leave_balance:tenant_admin:pto"

# Payroll (0012)
$SalaryCompBasicId   = New-DeterministicUuid -Seed "${Schema}:salary_component:basic"
$SalaryCompHraId     = New-DeterministicUuid -Seed "${Schema}:salary_component:hra"
$SalaryCompArrearId  = New-DeterministicUuid -Seed "${Schema}:salary_component:arrear"
$PayrollCycleId      = New-DeterministicUuid -Seed "${Schema}:payroll_cycle:current"
$PayslipDemoId       = New-DeterministicUuid -Seed "${Schema}:payslip:demo"
$EmployeePanId       = New-DeterministicUuid -Seed "${Schema}:employee_pan:demo"
$EmploymentHistoryDemoId = New-DeterministicUuid -Seed "${Schema}:employment_history:demo"

# Tax (0013)
$TaxConfigId         = New-DeterministicUuid -Seed "${Schema}:tax_config:fy2026"
$TaxSlab1Id          = New-DeterministicUuid -Seed "${Schema}:tax_slab:1"
$TaxSlab2Id          = New-DeterministicUuid -Seed "${Schema}:tax_slab:2"

# Benefits (0014)
$BenefitTypeHealthId = New-DeterministicUuid -Seed "${Schema}:benefit_type:health"
$BenefitPlanId       = New-DeterministicUuid -Seed "${Schema}:benefit_plan:base"

# Expense (0015)
$ExpenseCategoryId   = New-DeterministicUuid -Seed "${Schema}:expense_category:travel"
$ExpensePolicyTravelAllId = New-DeterministicUuid -Seed "${Schema}:expense_policy:travel:all"
$ExpenseId           = New-DeterministicUuid -Seed "${Schema}:expense:1"

# Onboarding (0017)
$OnboardTask1Id      = New-DeterministicUuid -Seed "${Schema}:onboarding_checklist:1"
$OnboardTask2Id      = New-DeterministicUuid -Seed "${Schema}:onboarding_checklist:2"

# Travel request (0033)
$TravelRequestId     = New-DeterministicUuid -Seed "${Schema}:travel_request:1"

# Recruitment (0016)
$JobPostingId        = New-DeterministicUuid -Seed "${Schema}:job_posting:swe"
$ApplicationId       = New-DeterministicUuid -Seed "${Schema}:application:1"

# Performance (0018)
$ReviewCycleId       = New-DeterministicUuid -Seed "${Schema}:review_cycle:fy2026h1"
$GoalId              = New-DeterministicUuid -Seed "${Schema}:goal:1"

# LMS (0019)
$SkillId             = New-DeterministicUuid -Seed "${Schema}:skill:rust"
$CourseId            = New-DeterministicUuid -Seed "${Schema}:course:rust-basics"

# Succession (0020)
$CompetencyId        = New-DeterministicUuid -Seed "${Schema}:competency:leadership"
$TalentPoolId        = New-DeterministicUuid -Seed "${Schema}:talent_pool:hipo"

# Compensation (0021)
$SalaryBandId        = New-DeterministicUuid -Seed "${Schema}:salary_band:ic2"
$CompRevCycleId      = New-DeterministicUuid -Seed "${Schema}:comp_review_cycle:2026"

# Assets (0022)
$AssetCategoryId     = New-DeterministicUuid -Seed "${Schema}:asset_category:laptop"
$AssetId             = New-DeterministicUuid -Seed "${Schema}:asset:mbp-01"

# Grievance (0023)
$GrievCategoryId     = New-DeterministicUuid -Seed "${Schema}:grievance_category:hr"
$GrievCaseId         = New-DeterministicUuid -Seed "${Schema}:grievance_case:1"

# Analytics (0024)
$ReportDefId         = New-DeterministicUuid -Seed "${Schema}:report_def:headcount"
$ReportSchedId       = New-DeterministicUuid -Seed "${Schema}:report_schedule:monthly"
$DashId              = New-DeterministicUuid -Seed "${Schema}:dashboard:hr"
$DashWidgetId        = New-DeterministicUuid -Seed "${Schema}:dashboard_widget:1"
$WorkforceSnapId     = New-DeterministicUuid -Seed "${Schema}:workforce_snapshot:current"

# Outbox (0030) — demo rows for analytics subgraph list_outbox / Insights UI
$OutboxEventProcId   = New-DeterministicUuid -Seed "${Schema}:outbox:demo_processed"
$OutboxEventPendId   = New-DeterministicUuid -Seed "${Schema}:outbox:demo_pending"

# Workflow (0025)
$WorkflowId          = New-DeterministicUuid -Seed "${Schema}:workflow:leave-approval"
$WorkflowStep1Id     = New-DeterministicUuid -Seed "${Schema}:workflow_step:leave:1"
$WorkflowStep2Id     = New-DeterministicUuid -Seed "${Schema}:workflow_step:leave:2"
$WorkflowInstanceId  = New-DeterministicUuid -Seed "${Schema}:workflow_instance:1"
# Expense claim workflow (entity_type EXPENSE — M32), two-step demo on seeded `$ExpenseId`
$ExpenseWorkflowId          = New-DeterministicUuid -Seed "${Schema}:workflow:expense-approval"
$ExpenseWorkflowStep1Id     = New-DeterministicUuid -Seed "${Schema}:workflow_step:expense:1"
$ExpenseWorkflowStep2Id     = New-DeterministicUuid -Seed "${Schema}:workflow_step:expense:2"
$ExpenseWorkflowInstanceId  = New-DeterministicUuid -Seed "${Schema}:workflow_instance:expense:1"
$TravelWorkflowId          = New-DeterministicUuid -Seed "${Schema}:workflow:travel-approval"
$TravelWorkflowStep1Id     = New-DeterministicUuid -Seed "${Schema}:workflow_step:travel:1"
$TravelWorkflowStep2Id     = New-DeterministicUuid -Seed "${Schema}:workflow_step:travel:2"
$TravelWorkflowInstanceId  = New-DeterministicUuid -Seed "${Schema}:workflow_instance:travel:1"
$TimesheetWorkflowId          = New-DeterministicUuid -Seed "${Schema}:workflow:timesheet-approval"
$TimesheetWorkflowStep1Id     = New-DeterministicUuid -Seed "${Schema}:workflow_step:timesheet:1"
$TimesheetWorkflowStep2Id     = New-DeterministicUuid -Seed "${Schema}:workflow_step:timesheet:2"
$MdHrmsAttAdjId = New-DeterministicUuid -Seed "${Schema}:master_data:hrms_att_adj"
$MdHrmsTsLockId = New-DeterministicUuid -Seed "${Schema}:master_data:hrms_ts_lock"
$MdProjInternalId = New-DeterministicUuid -Seed "${Schema}:master_data:proj_internal"
$MdProjClientAId = New-DeterministicUuid -Seed "${Schema}:master_data:proj_client_a"
$MdTaskInternalId = New-DeterministicUuid -Seed "${Schema}:master_data:task_internal"

# Notification / Communication (0027)
$AnnouncementId      = New-DeterministicUuid -Seed "${Schema}:announcement:1"
$NotificationId      = New-DeterministicUuid -Seed "${Schema}:notification:1"

# ---- Ops plane UUIDs (tenant-independent constants) ----
$ModuleEmployeeId    = New-DeterministicUuid -Seed "ops:module:EMPLOYEE"
$ModuleLeaveId       = New-DeterministicUuid -Seed "ops:module:LEAVE"
$ModulePayrollId     = New-DeterministicUuid -Seed "ops:module:PAYROLL"
$ModuleRecruitId     = New-DeterministicUuid -Seed "ops:module:RECRUIT"
$ModuleExpenseId     = New-DeterministicUuid -Seed "ops:module:EXPENSE"
$ModuleTaxId         = New-DeterministicUuid -Seed "ops:module:TAX"
$ModuleAttendanceId  = New-DeterministicUuid -Seed "ops:module:ATTENDANCE"
$ModuleWorkflowId    = New-DeterministicUuid -Seed "ops:module:WORKFLOW"
$OpRoleAdminId       = New-DeterministicUuid -Seed "ops:operator_role:ADMIN"
$OpRoleSupportId     = New-DeterministicUuid -Seed "ops:operator_role:SUPPORT"
$OpUserId            = New-DeterministicUuid -Seed "ops:operator_user:admin"

# Tenant-scoped ops UUIDs
$BillingCycleId      = New-DeterministicUuid -Seed "ops:billing_cycle:${TenantId}:current"
$InvoiceId           = New-DeterministicUuid -Seed "ops:invoice:${TenantId}:1"
$PaymentId           = New-DeterministicUuid -Seed "ops:payment:${TenantId}:1"
$SubLeaveId          = New-DeterministicUuid -Seed "ops:subscription:${TenantId}:LEAVE"
$SubPayrollId        = New-DeterministicUuid -Seed "ops:subscription:${TenantId}:PAYROLL"
$SubAttendanceId     = New-DeterministicUuid -Seed "ops:subscription:${TenantId}:ATTENDANCE"
$SubWorkflowId       = New-DeterministicUuid -Seed "ops:subscription:${TenantId}:WORKFLOW"

Write-Host "=== Tenant plane UUIDs ==="
Write-Host "Department   : $DepartmentId"
Write-Host "Designation  : $DesignationId"
Write-Host "User         : $UserId"
Write-Host "Employee     : $EmployeeId"
Write-Host ""

# Argon2id hash for password "ChangeMe!123" (verified — generated by
# `cargo run -p kabipay-auth --bin kabipay-auth-hash --release -- "ChangeMe!123"`).
# Re-run that command if you rotate the demo password.
$PasswordHash = '$argon2id$v=19$m=19456,t=2,p=1$CDQNnKaKe519h5WXXU1DaA$IiZxOr7AvMrrMg0U2q2L1bD5CsBxDVWCHY42+CnLTXw'

function Invoke-TenantSql {
    param([Parameter(Mandatory=$true)][string]$Sql, [string]$Label)
    if ($Label) { Write-Host "==> $Label" -ForegroundColor Cyan }
    $tmp = [System.IO.Path]::GetTempFileName() + '.sql'
    try {
        [System.IO.File]::WriteAllText($tmp, $Sql, [System.Text.UTF8Encoding]::new($false))
        & node $RunSql -f $tmp
        if ($LASTEXITCODE -ne 0) { throw "Seed step '$Label' failed (exit $LASTEXITCODE)." }
    } finally {
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    }
}

# =====================================================================
# 1. FOUNDATION (unchanged)
# =====================================================================
$SqlFoundation = @"
INSERT INTO "$Schema".department (id, tenant_id, name, code)
VALUES ('$DepartmentId', '$TenantId', 'Engineering', 'ENG')
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".department (id, tenant_id, name, code)
VALUES ('$DepartmentAccountingId', '$TenantId', 'Accounting', 'ACC')
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".designation (id, tenant_id, department_id, title, level, grade)
VALUES ('$DesignationId', '$TenantId', '$DepartmentId', 'Software Engineer', 'IC2', 2)
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".designation (id, tenant_id, department_id, title, level, grade)
VALUES ('$DesignationAccountingId', '$TenantId', '$DepartmentAccountingId', 'Senior Accountant', 'IC2', 3)
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema"."user" (id, tenant_id, username, email, password_hash, is_active, mfa_enabled)
VALUES ('$UserId', '$TenantId', 'demo@kabipay.local', 'demo@kabipay.local', '$PasswordHash', true, false)
ON CONFLICT (id) DO UPDATE SET password_hash = EXCLUDED.password_hash, is_active = true;

INSERT INTO "$Schema".employee (
    id, tenant_id, user_id, department_id, designation_id,
    employee_code, first_name, last_name, employment_type, status,
    date_of_joining
) VALUES (
    '$EmployeeId', '$TenantId', '$UserId', '$DepartmentId', '$DesignationId',
    'EMP0001', 'Demo', 'Employee', 'PERMANENT', 'ACTIVE',
    CURRENT_DATE
) ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema"."user" (id, tenant_id, username, email, password_hash, is_active, mfa_enabled)
VALUES ('$ManagerUserId', '$TenantId', 'manager@kabipay.local', 'manager@kabipay.local', '$PasswordHash', true, false)
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".employee (
    id, tenant_id, user_id, department_id, designation_id,
    employee_code, first_name, last_name, employment_type, status,
    date_of_joining, reporting_manager_id
) VALUES (
    '$ManagerEmployeeId', '$TenantId', '$ManagerUserId', '$DepartmentId', '$DesignationId',
    'EMP0002', 'Line', 'Manager', 'PERMANENT', 'ACTIVE',
    CURRENT_DATE, NULL
) ON CONFLICT (id) DO NOTHING;

UPDATE "$Schema".employee
SET reporting_manager_id = '$ManagerEmployeeId', updated_at = NOW()
WHERE id = '$EmployeeId' AND tenant_id = '$TenantId';

INSERT INTO "$Schema".employee_pan (
    id, tenant_id, employee_id, pan_number, is_primary, is_verified
) VALUES (
    '$EmployeePanId', '$TenantId', '$EmployeeId', 'ABCDE1234F', true, false
) ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".employment_history (
    id, tenant_id, employee_id, salary, effective_from, is_deleted
) VALUES (
    '$EmploymentHistoryDemoId', '$TenantId', '$EmployeeId', 85000.0000, CURRENT_DATE - INTERVAL '1 year', false
) ON CONFLICT (id) DO NOTHING;

-- RBAC: demo user can create/update employees (JWT permissions loaded at login)
INSERT INTO "$Schema".role (id, tenant_id, name, description, is_system_role, is_deleted)
VALUES ('$RoleHrAdminId', '$TenantId', 'HR_ADMIN', 'Employee directory admin', true, false)
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".role (id, tenant_id, name, description, is_system_role, is_deleted)
VALUES ('$RoleLineManagerId', '$TenantId', 'LINE_MANAGER', 'People manager — hierarchical approvals (team-scoped lists)', true, false)
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".role (id, tenant_id, name, description, is_system_role, is_deleted)
VALUES ('$RoleDemoStaffId', '$TenantId', 'DEMO_STAFF', 'Demo IC — self-service benefits, onboarding, grievance only', true, false)
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".role (id, tenant_id, name, description, is_system_role, is_deleted)
VALUES ('$RoleTenantAdminId', '$TenantId', 'TENANT_ADMIN', 'Tenant administrator — admin shell + HR configuration', true, false)
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".role (id, tenant_id, name, description, is_system_role, is_deleted)
VALUES ('$RoleAccountingApproverId', '$TenantId', 'ACCOUNTING_APPROVER', 'Accounting / finance second-line approver for expense and travel workflows', true, false)
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema"."user" (id, tenant_id, username, email, password_hash, is_active, mfa_enabled)
VALUES ('$TenantAdminUserId', '$TenantId', 'tenant-admin@kabipay.local', 'tenant-admin@kabipay.local', '$PasswordHash', true, false)
ON CONFLICT (id) DO UPDATE SET password_hash = EXCLUDED.password_hash, is_active = true;

INSERT INTO "$Schema".employee (
    id, tenant_id, user_id, department_id, designation_id,
    employee_code, first_name, last_name, employment_type, status,
    date_of_joining, reporting_manager_id
) VALUES (
    '$TenantAdminEmployeeId', '$TenantId', '$TenantAdminUserId', '$DepartmentId', '$DesignationId',
    'EMP0998', 'Tenant', 'Administrator', 'PERMANENT', 'ACTIVE',
    CURRENT_DATE, '$ManagerEmployeeId'
) ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema"."user" (id, tenant_id, username, email, password_hash, is_active, mfa_enabled)
VALUES ('$AccountingUserId', '$TenantId', 'accountant@kabipay.local', 'accountant@kabipay.local', '$PasswordHash', true, false)
ON CONFLICT (id) DO UPDATE SET password_hash = EXCLUDED.password_hash, is_active = true;

INSERT INTO "$Schema".employee (
    id, tenant_id, user_id, department_id, designation_id,
    employee_code, first_name, last_name, employment_type, status,
    date_of_joining, reporting_manager_id
) VALUES (
    '$AccountingEmployeeId', '$TenantId', '$AccountingUserId', '$DepartmentAccountingId', '$DesignationAccountingId',
    'EMP0004', 'Finance', 'Reviewer', 'PERMANENT', 'ACTIVE',
    CURRENT_DATE, '$ManagerEmployeeId'
) ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema"."user" (id, tenant_id, username, email, password_hash, is_active, mfa_enabled)
VALUES ('$StaffUserId', '$TenantId', 'staff@kabipay.local', 'staff@kabipay.local', '$PasswordHash', true, false)
ON CONFLICT (id) DO UPDATE SET password_hash = EXCLUDED.password_hash, is_active = true;

INSERT INTO "$Schema".employee (
    id, tenant_id, user_id, department_id, designation_id,
    employee_code, first_name, last_name, employment_type, status,
    date_of_joining, reporting_manager_id
) VALUES (
    '$StaffEmployeeId', '$TenantId', '$StaffUserId', '$DepartmentId', '$DesignationId',
    'EMP0003', 'Staff', 'Member', 'PERMANENT', 'ACTIVE',
    CURRENT_DATE, '$ManagerEmployeeId'
) ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".permission (id, resource, action, module_id, description)
VALUES ('$PermEmployeeWriteId', 'employee', 'write', '$ModuleEmployeeId', 'Create and update employee records')
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".permission (id, resource, action, module_id, description)
VALUES ('$PermLeaveApproveId', 'leave', 'approve', '$ModuleLeaveId', 'Approve or reject leave requests')
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".permission (id, resource, action, module_id, description)
VALUES ('$PermLeaveManageId', 'leave', 'manage', '$ModuleLeaveId', 'Configure leave types, policies, balances, and holiday calendars')
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".permission (id, resource, action, module_id, description)
VALUES ('$PermExpenseApproveId', 'expense', 'approve', '$ModuleExpenseId', 'Approve or reject expense claims')
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".permission (id, resource, action, module_id, description)
VALUES ('$PermExpenseManageId', 'expense', 'manage', '$ModuleExpenseId', 'Configure expense categories and caps')
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".permission (id, resource, action, module_id, description)
VALUES ('$PermExpensePayId', 'expense', 'pay', '$ModuleExpenseId', 'Mark expense reimbursements as paid or update payment lifecycle')
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".permission (id, resource, action, module_id, description)
VALUES ('$PermTaxProofApproveId', 'tax', 'approve', '$ModuleTaxId', 'Approve tax deduction proofs (declared vs actuals)')
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".permission (id, resource, action, module_id, description)
VALUES ('$PermPayrollStatutoryId', 'payroll', 'statutory_export', '$ModulePayrollId', 'Export statutory payroll reports (e.g. India TDS summary CSV)')
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".permission (id, resource, action, module_id, description)
VALUES ('$PermAttendancePunchPolicyId', 'attendance', 'punch_policy', '$ModuleAttendanceId', 'Configure geofence / IP punch policy for the tenant')
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".permission (id, resource, action, module_id, description)
VALUES ('$PermWorkflowManageId', 'workflow', 'manage', '$ModuleWorkflowId', 'Create or edit workflow definitions and steps')
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".permission (id, resource, action, module_id, description)
VALUES ('$PermRoleManageId', 'role', 'manage', '$ModuleEmployeeId', 'Assign tenant roles, permissions, and data scopes')
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".permission (id, resource, action, module_id, description)
VALUES ('$PermBenefitsManageId', 'benefits', 'manage', '$ModuleEmployeeId', 'Configure benefit types/plans (HR)')
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".permission (id, resource, action, module_id, description)
VALUES ('$PermBenefitsSelfId', 'benefits', 'self', '$ModuleEmployeeId', 'View offerings and enroll in benefits')
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".permission (id, resource, action, module_id, description)
VALUES ('$PermRecruitmentManageId', 'recruitment', 'manage', '$ModuleRecruitId', 'Manage job postings and applications')
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".permission (id, resource, action, module_id, description)
VALUES ('$PermOnboardingManageId', 'onboarding', 'manage', '$ModuleEmployeeId', 'Tenant-wide onboarding and offboarding console')
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".permission (id, resource, action, module_id, description)
VALUES ('$PermOnboardingSelfId', 'onboarding', 'self', '$ModuleEmployeeId', 'Own onboarding checklist and separation filing')
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".permission (id, resource, action, module_id, description)
VALUES ('$PermPerformanceManageId', 'performance', 'manage', '$ModuleEmployeeId', 'Performance cycles and goals administration')
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".permission (id, resource, action, module_id, description)
VALUES ('$PermLearningManageId', 'learning', 'manage', '$ModuleEmployeeId', 'LMS skills and courses administration')
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".permission (id, resource, action, module_id, description)
VALUES ('$PermAssetsManageId', 'assets', 'manage', '$ModuleEmployeeId', 'Asset categories and assignments')
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".permission (id, resource, action, module_id, description)
VALUES ('$PermGrievanceManageId', 'grievance', 'manage', '$ModuleEmployeeId', 'Tenant-wide grievance cases')
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".permission (id, resource, action, module_id, description)
VALUES ('$PermGrievanceSelfId', 'grievance', 'self', '$ModuleEmployeeId', 'File grievances and view own cases')
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".permission (id, resource, action, module_id, description)
VALUES ('$PermSuccessionManageId', 'succession', 'manage', '$ModuleEmployeeId', 'Succession competencies and talent pools')
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".permission (id, resource, action, module_id, description)
VALUES ('$PermCompensationManageId', 'compensation', 'manage', '$ModulePayrollId', 'Salary bands and compensation review cycles')
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".permission (id, resource, action, module_id, description)
VALUES ('$PermAnalyticsReadId', 'analytics', 'read', '$ModuleEmployeeId', 'Insights dashboards, workforce snapshots, report catalog')
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".permission (id, resource, action, module_id, description)
VALUES ('$PermAttendancePunchSelfId', 'attendance', 'punch_self', '$ModuleAttendanceId', 'Live punch in/out and own punch-day summary')
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".permission (id, resource, action, module_id, description)
VALUES ('$PermAttendanceRegularizeId', 'attendance', 'regularize', '$ModuleAttendanceId', 'Manual attendance corrections beyond employee self-service window')
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".permission (id, resource, action, module_id, description)
VALUES ('$PermTimesheetApproveId', 'timesheet', 'approve', '$ModuleAttendanceId', 'Approve or reject weekly timesheet submissions')
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".permission (id, resource, action, module_id, description)
VALUES ('$PermTimesheetManageId', 'timesheet', 'manage', '$ModuleAttendanceId', 'Configure timesheet projects, tasks, and lock policy')
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".permission (id, resource, action, module_id, description)
VALUES ('$PermNotificationManageId', 'notification', 'manage', '$ModuleEmployeeId', 'Announcements, direct in-app notifications, and deletes')
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".role_permission (role_id, permission_id)
VALUES ('$RoleHrAdminId', '$PermEmployeeWriteId')
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO "$Schema".role_permission (role_id, permission_id)
VALUES ('$RoleHrAdminId', '$PermLeaveApproveId')
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO "$Schema".role_permission (role_id, permission_id)
VALUES ('$RoleHrAdminId', '$PermExpenseApproveId')
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO "$Schema".role_permission (role_id, permission_id)
VALUES ('$RoleHrAdminId', '$PermExpenseManageId')
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO "$Schema".role_permission (role_id, permission_id)
VALUES ('$RoleHrAdminId', '$PermTaxProofApproveId')
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO "$Schema".role_permission (role_id, permission_id)
VALUES ('$RoleHrAdminId', '$PermPayrollStatutoryId')
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO "$Schema".role_permission (role_id, permission_id)
VALUES ('$RoleHrAdminId', '$PermAttendancePunchPolicyId')
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO "$Schema".role_permission (role_id, permission_id)
VALUES ('$RoleHrAdminId', '$PermAttendancePunchSelfId')
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO "$Schema".role_permission (role_id, permission_id)
VALUES ('$RoleHrAdminId', '$PermWorkflowManageId')
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO "$Schema".role_permission (role_id, permission_id)
VALUES ('$RoleHrAdminId', '$PermRoleManageId')
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO "$Schema".role_permission (role_id, permission_id)
VALUES ('$RoleHrAdminId', '$PermLeaveManageId')
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO "$Schema".role_permission (role_id, permission_id)
VALUES ('$RoleHrAdminId', '$PermBenefitsManageId')
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO "$Schema".role_permission (role_id, permission_id)
VALUES ('$RoleHrAdminId', '$PermRecruitmentManageId')
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO "$Schema".role_permission (role_id, permission_id)
VALUES ('$RoleHrAdminId', '$PermOnboardingManageId')
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO "$Schema".role_permission (role_id, permission_id)
VALUES ('$RoleHrAdminId', '$PermPerformanceManageId')
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO "$Schema".role_permission (role_id, permission_id)
VALUES ('$RoleHrAdminId', '$PermLearningManageId')
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO "$Schema".role_permission (role_id, permission_id)
VALUES ('$RoleHrAdminId', '$PermAssetsManageId')
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO "$Schema".role_permission (role_id, permission_id)
VALUES ('$RoleHrAdminId', '$PermGrievanceManageId')
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO "$Schema".role_permission (role_id, permission_id)
VALUES ('$RoleHrAdminId', '$PermSuccessionManageId')
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO "$Schema".role_permission (role_id, permission_id)
VALUES ('$RoleHrAdminId', '$PermCompensationManageId')
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO "$Schema".role_permission (role_id, permission_id)
VALUES ('$RoleHrAdminId', '$PermAnalyticsReadId')
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO "$Schema".role_permission (role_id, permission_id)
VALUES ('$RoleHrAdminId', '$PermTimesheetApproveId')
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO "$Schema".role_permission (role_id, permission_id)
VALUES ('$RoleHrAdminId', '$PermTimesheetManageId')
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO "$Schema".role_permission (role_id, permission_id)
VALUES ('$RoleHrAdminId', '$PermNotificationManageId')
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO "$Schema".role_permission (role_id, permission_id)
VALUES ('$RoleHrAdminId', '$PermAttendanceRegularizeId')
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO "$Schema".role_permission (role_id, permission_id)
VALUES ('$RoleLineManagerId', '$PermTimesheetApproveId')
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO "$Schema".role_permission (role_id, permission_id)
VALUES ('$RoleLineManagerId', '$PermAttendanceRegularizeId')
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO "$Schema".role_permission (role_id, permission_id)
VALUES ('$RoleLineManagerId', '$PermLeaveApproveId')
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO "$Schema".role_permission (role_id, permission_id)
VALUES ('$RoleLineManagerId', '$PermExpenseApproveId')
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO "$Schema".role_permission (role_id, permission_id)
VALUES ('$RoleAccountingApproverId', '$PermExpenseApproveId')
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO "$Schema".role_permission (role_id, permission_id)
VALUES ('$RoleAccountingApproverId', '$PermExpensePayId')
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO "$Schema".role_permission (role_id, permission_id)
VALUES ('$RoleAccountingApproverId', '$PermAttendancePunchSelfId')
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO "$Schema".role_permission (role_id, permission_id)
VALUES ('$RoleLineManagerId', '$PermBenefitsSelfId')
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO "$Schema".role_permission (role_id, permission_id)
VALUES ('$RoleLineManagerId', '$PermOnboardingSelfId')
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO "$Schema".role_permission (role_id, permission_id)
VALUES ('$RoleLineManagerId', '$PermGrievanceSelfId')
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO "$Schema".role_permission (role_id, permission_id)
VALUES ('$RoleLineManagerId', '$PermAnalyticsReadId')
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO "$Schema".role_permission (role_id, permission_id)
VALUES ('$RoleLineManagerId', '$PermAttendancePunchSelfId')
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO "$Schema".role_permission (role_id, permission_id)
VALUES ('$RoleDemoStaffId', '$PermBenefitsSelfId')
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO "$Schema".role_permission (role_id, permission_id)
VALUES ('$RoleDemoStaffId', '$PermOnboardingSelfId')
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO "$Schema".role_permission (role_id, permission_id)
VALUES ('$RoleDemoStaffId', '$PermGrievanceSelfId')
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO "$Schema".role_permission (role_id, permission_id)
VALUES ('$RoleDemoStaffId', '$PermAttendancePunchSelfId')
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO "$Schema".user_role (user_id, role_id)
VALUES ('$StaffUserId', '$RoleDemoStaffId')
ON CONFLICT (user_id, role_id) DO NOTHING;

INSERT INTO "$Schema".user_role (user_id, role_id)
VALUES ('$UserId', '$RoleHrAdminId')
ON CONFLICT (user_id, role_id) DO NOTHING;

INSERT INTO "$Schema".user_role (user_id, role_id)
VALUES ('$ManagerUserId', '$RoleLineManagerId')
ON CONFLICT (user_id, role_id) DO NOTHING;

INSERT INTO "$Schema".user_role (user_id, role_id)
VALUES ('$AccountingUserId', '$RoleAccountingApproverId')
ON CONFLICT (user_id, role_id) DO NOTHING;

INSERT INTO "$Schema".role_permission (role_id, permission_id)
SELECT '$RoleTenantAdminId', rp.permission_id
FROM "$Schema".role_permission rp
WHERE rp.role_id = '$RoleHrAdminId'
ON CONFLICT (role_id, permission_id) DO NOTHING;

DELETE FROM "$Schema".role_permission rp
USING "$Schema".role r
WHERE rp.role_id = r.id
  AND rp.permission_id = '$PermExpensePayId'
  AND r.tenant_id = '$TenantId'
  AND UPPER(TRIM(r.name)) IN ('HR_ADMIN', 'TENANT_ADMIN', 'ORG_ADMIN', 'LINE_MANAGER', 'MANAGER');

INSERT INTO "$Schema".user_role (user_id, role_id)
VALUES ('$TenantAdminUserId', '$RoleTenantAdminId')
ON CONFLICT (user_id, role_id) DO NOTHING;

-- Workflow steps use `assert_user_has_role(HR_ADMIN)`; assign HR_ADMIN explicitly (not implied by TENANT_ADMIN alone).
INSERT INTO "$Schema".user_role (user_id, role_id)
VALUES ('$TenantAdminUserId', '$RoleHrAdminId')
ON CONFLICT (user_id, role_id) DO NOTHING;

INSERT INTO "$Schema".permission_scope (id, tenant_id, role_id, resource, action, scope_type)
SELECT gen_random_uuid(), '$TenantId', '$RoleTenantAdminId', ps.resource, ps.action, ps.scope_type
FROM "$Schema".permission_scope ps
WHERE ps.tenant_id = '$TenantId' AND ps.role_id = '$RoleHrAdminId'
ON CONFLICT (role_id, resource, action) DO NOTHING;

-- Gap H: data scope for list filters (employee / leave) — ALL for admin role
INSERT INTO "$Schema".permission_scope (id, tenant_id, role_id, resource, action, scope_type)
VALUES
  ('$ScopeScopeEmployeeAllId', '$TenantId', '$RoleHrAdminId', 'employee', 'write', 'ALL'),
  ('$ScopeScopeLeaveAllId',    '$TenantId', '$RoleHrAdminId', 'leave',   'approve', 'ALL'),
  ('$ScopeScopeExpenseAllId',  '$TenantId', '$RoleHrAdminId', 'expense', 'approve', 'ALL'),
  ('$ScopeScopeAttendanceAllId', '$TenantId', '$RoleHrAdminId', 'attendance', 'read', 'ALL'),
  ('$ScopeAttendancePunchPolicyAllId', '$TenantId', '$RoleHrAdminId', 'attendance', 'punch_policy', 'ALL'),
  ('$ScopeWorkflowManageAllId', '$TenantId', '$RoleHrAdminId', 'workflow', 'manage', 'ALL'),
  ('$ScopeTimesheetApproveAllId', '$TenantId', '$RoleHrAdminId', 'timesheet', 'approve', 'ALL'),
  ('$ScopeTimesheetApproveTeamLmId', '$TenantId', '$RoleLineManagerId', 'timesheet', 'approve', 'TEAM'),
  ('$ScopeScopeLeaveTeamLmId', '$TenantId', '$RoleLineManagerId', 'leave', 'approve', 'TEAM'),
  ('$ScopeScopeExpenseTeamLmId', '$TenantId', '$RoleLineManagerId', 'expense', 'approve', 'TEAM'),
  ('$ScopeScopeExpenseAcctAllId', '$TenantId', '$RoleAccountingApproverId', 'expense', 'approve', 'ALL')
ON CONFLICT (role_id, resource, action) DO NOTHING;
"@
Invoke-TenantSql -Label "0000 foundation (department, designation, user, employee)" -Sql $SqlFoundation

# =====================================================================
# 2. SHIFT / ATTENDANCE (0010)
# =====================================================================
$SqlShift = @"
INSERT INTO "$Schema".shift (id, tenant_id, name, start_time, end_time, work_hours, is_night_shift)
VALUES ('$ShiftDayId', '$TenantId', 'General Day', '09:00', '18:00', 9, false)
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".shift (id, tenant_id, name, start_time, end_time, work_hours, is_night_shift)
VALUES ('$ShiftNightId', '$TenantId', 'Night Ops', '22:00', '07:00', 9, true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".attendance (
    id, tenant_id, employee_id, shift_id, work_date,
    check_in_time, check_out_time, status, source
) VALUES (
    '$AttendanceTodayId', '$TenantId', '$EmployeeId', '$ShiftDayId', CURRENT_DATE,
    '09:15', '18:10', 'PRESENT', 'WEB'
) ON CONFLICT (id) DO NOTHING;
"@
Invoke-TenantSql -Label "0010 shift + attendance" -Sql $SqlShift

# =====================================================================
# 3. LEAVE (0011)
# =====================================================================
$SqlLeave = @"
INSERT INTO "$Schema".leave_type (
    id, tenant_id, name, code,
    is_paid, carry_forward, max_carry_forward_days,
    sandwich_rule, half_day_allowed, requires_document
) VALUES
    ('$LeaveTypeClId', '$TenantId', 'Casual Leave', 'CL', true,  true,  5, false, true,  false),
    ('$LeaveTypeSlId', '$TenantId', 'Sick Leave',   'SL', true,  false, 0, false, true,  true),
    ('$LeaveTypePtoId', '$TenantId', 'Paid Time Off', 'PTO', true, false, 0, false, true, false)
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".leave_request (
    id, tenant_id, employee_id, leave_type_id,
    from_date, to_date, days_requested,
    is_half_day, status, reason, applied_at
) VALUES (
    '$LeaveRequest1Id', '$TenantId', '$EmployeeId', '$LeaveTypeClId',
    CURRENT_DATE + INTERVAL '7 days', CURRENT_DATE + INTERVAL '8 days', 2,
    false, 'PENDING', 'Family function', NOW()
) ON CONFLICT (id) DO NOTHING;
"@
Invoke-TenantSql -Label "0011 leave (types + request)" -Sql $SqlLeave

$SqlLeaveExtra = @"
INSERT INTO "$Schema".leave_policy (
    id, tenant_id, leave_type_id, applicable_to,
    annual_entitlement, accrual_frequency, accrual_days,
    max_consecutive_days, min_notice_days, created_at, updated_at
) VALUES
    ('$LeavePolicyClId', '$TenantId', '$LeaveTypeClId', 'ALL', 12, NULL, NULL, 10, 1, NOW(), NOW()),
    ('$LeavePolicySlId', '$TenantId', '$LeaveTypeSlId', 'ALL', 10, NULL, NULL, 7, 0, NOW(), NOW()),
    ('$LeavePolicyPtoId', '$TenantId', '$LeaveTypePtoId', 'ALL', NULL, 'MONTHLY', 1.2500, 5, 2, NOW(), NOW())
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".holiday_calendar (
    id, tenant_id, location_id, name, year, created_at, updated_at
) VALUES (
    '$HolCalCoId', '$TenantId', NULL, 'Company — India', EXTRACT(YEAR FROM CURRENT_DATE)::int, NOW(), NOW()
) ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".holiday (
    id, calendar_id, holiday_date, name, "type", created_at, updated_at
) VALUES
    ('$HolRepublicId', '$HolCalCoId',
        (EXTRACT(YEAR FROM CURRENT_DATE)::text || '-01-26')::date,
        'Republic Day', 'PUBLIC', NOW(), NOW()),
    ('$HolIndependenceId', '$HolCalCoId',
        (EXTRACT(YEAR FROM CURRENT_DATE)::text || '-08-15')::date,
        'Independence Day', 'PUBLIC', NOW(), NOW())
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".leave_balance (
    id, tenant_id, employee_id, leave_type_id, year,
    entitled_days, used_days, pending_days, carried_forward_days, balance_days,
    created_at, updated_at
) VALUES
    ('$LbDemoClId', '$TenantId', '$EmployeeId', '$LeaveTypeClId', EXTRACT(YEAR FROM CURRENT_DATE)::int,
        12, 0, 2, 0, 10, NOW(), NOW()),
    ('$LbDemoSlId', '$TenantId', '$EmployeeId', '$LeaveTypeSlId', EXTRACT(YEAR FROM CURRENT_DATE)::int,
        10, 0, 0, 0, 10, NOW(), NOW()),
    ('$LbDemoPtoId', '$TenantId', '$EmployeeId', '$LeaveTypePtoId', EXTRACT(YEAR FROM CURRENT_DATE)::int,
        0, 0, 0, 0, 0, NOW(), NOW()),
    ('$LbMgrClId', '$TenantId', '$ManagerEmployeeId', '$LeaveTypeClId', EXTRACT(YEAR FROM CURRENT_DATE)::int,
        12, 0, 0, 0, 12, NOW(), NOW()),
    ('$LbStaffClId', '$TenantId', '$StaffEmployeeId', '$LeaveTypeClId', EXTRACT(YEAR FROM CURRENT_DATE)::int,
        12, 0, 0, 0, 12, NOW(), NOW()),
    ('$LbTenantAdminClId', '$TenantId', '$TenantAdminEmployeeId', '$LeaveTypeClId', EXTRACT(YEAR FROM CURRENT_DATE)::int,
        12, 0, 0, 0, 12, NOW(), NOW()),
    ('$LbTenantAdminSlId', '$TenantId', '$TenantAdminEmployeeId', '$LeaveTypeSlId', EXTRACT(YEAR FROM CURRENT_DATE)::int,
        10, 0, 0, 0, 10, NOW(), NOW()),
    ('$LbTenantAdminPtoId', '$TenantId', '$TenantAdminEmployeeId', '$LeaveTypePtoId', EXTRACT(YEAR FROM CURRENT_DATE)::int,
        0, 0, 0, 0, 0, NOW(), NOW())
ON CONFLICT (employee_id, leave_type_id, year) DO NOTHING;

WITH monthly_policy AS (
    SELECT
        policy.tenant_id,
        policy.leave_type_id,
        COALESCE(policy.accrual_days, 0)::numeric AS accrual_days
    FROM "$Schema".leave_policy policy
    JOIN "$Schema".leave_type leave_type
      ON leave_type.id = policy.leave_type_id
     AND leave_type.tenant_id = policy.tenant_id
    WHERE UPPER(TRIM(COALESCE(policy.accrual_frequency, ''))) = 'MONTHLY'
      AND leave_type.is_deleted = false
),
eligible_balance AS (
    SELECT
        balance.id,
        balance.year,
        balance.used_days,
        balance.pending_days,
        balance.carried_forward_days,
        monthly_policy.accrual_days,
        COALESCE(employee.date_of_joining, make_date(balance.year, 1, 1)) AS joining_date,
        make_date(balance.year, 1, 1) AS year_start,
        make_date(balance.year, 12, 31) AS year_end
    FROM "$Schema".leave_balance balance
    JOIN monthly_policy
      ON monthly_policy.tenant_id = balance.tenant_id
     AND monthly_policy.leave_type_id = balance.leave_type_id
    JOIN "$Schema".employee employee
      ON employee.id = balance.employee_id
     AND employee.tenant_id = balance.tenant_id
    WHERE balance.year = EXTRACT(YEAR FROM CURRENT_DATE)::int
      AND employee.is_deleted = false
),
month_window AS (
    SELECT
        id,
        used_days,
        pending_days,
        carried_forward_days,
        accrual_days,
        GREATEST(
            CASE
                WHEN EXTRACT(DAY FROM joining_date)::int = 1
                    THEN date_trunc('month', joining_date)::date
                ELSE (date_trunc('month', joining_date)::date + INTERVAL '1 month')::date
            END,
            year_start
        ) AS accrual_start,
        LEAST(CURRENT_DATE, year_end) AS accrual_as_of
    FROM eligible_balance
),
earned_balance AS (
    SELECT
        id,
        CASE
            WHEN accrual_start > accrual_as_of THEN 0::numeric
            ELSE (
                accrual_days
                * (
                    ((EXTRACT(YEAR FROM accrual_as_of)::int - EXTRACT(YEAR FROM accrual_start)::int) * 12)
                    + EXTRACT(MONTH FROM accrual_as_of)::int
                    - EXTRACT(MONTH FROM accrual_start)::int
                    + 1
                )
            )::numeric(15, 4)
        END AS target_entitled_days
    FROM month_window
)
UPDATE "$Schema".leave_balance balance
SET entitled_days = earned_balance.target_entitled_days,
    balance_days = (
        earned_balance.target_entitled_days
        + balance.carried_forward_days
        - balance.used_days
        - balance.pending_days
    )::numeric(15, 4),
    updated_at = NOW()
FROM earned_balance
WHERE balance.id = earned_balance.id;

INSERT INTO "$Schema".leave_request (
    id, tenant_id, employee_id, leave_type_id,
    from_date, to_date, days_requested,
    is_half_day, status, reason, applied_at, workflow_instance_id
) VALUES (
    '$LeaveApprovedMgrId', '$TenantId', '$ManagerEmployeeId', '$LeaveTypeClId',
    CURRENT_DATE - INTERVAL '12 days', CURRENT_DATE - INTERVAL '10 days', 3,
    false, 'APPROVED', 'Seeded approved leave (team calendar demo)', NOW(), NULL
) ON CONFLICT (id) DO NOTHING;
"@
Invoke-TenantSql -Label "0011b leave (policies, holidays, balances, approved sample)" -Sql $SqlLeaveExtra

# =====================================================================
# 4. PAYROLL (0012)
# =====================================================================
$SqlPayroll = @"
INSERT INTO "$Schema".salary_component (
    id, tenant_id, name, code, type, is_taxable, is_fixed, is_active
) VALUES
    ('$SalaryCompBasicId',  '$TenantId', 'Basic',                'BASIC',  'EARNING', true, true, true),
    ('$SalaryCompHraId',    '$TenantId', 'House Rent Allow.',    'HRA',    'EARNING', true, true, true),
    ('$SalaryCompArrearId', '$TenantId', 'Arrear & adjustments', 'ARREAR', 'EARNING', true, true, true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".payroll_cycle (
    id, tenant_id, name, month, year, status, payment_date
) VALUES (
    '$PayrollCycleId', '$TenantId',
    TO_CHAR(CURRENT_DATE, 'FMMonth YYYY'),
    EXTRACT(MONTH FROM CURRENT_DATE)::int,
    EXTRACT(YEAR FROM CURRENT_DATE)::int,
    'DRAFT',
    (DATE_TRUNC('month', CURRENT_DATE) + INTERVAL '1 month - 1 day')::date
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".payslip (
    id, tenant_id, employee_id, payroll_cycle_id,
    gross_salary, total_deductions, net_salary,
    pf_employee, tds_amount, professional_tax,
    status
) VALUES (
    '$PayslipDemoId', '$TenantId', '$EmployeeId', '$PayrollCycleId',
    85000.0000, 12500.0000, 72500.0000,
    1800.0000, 4200.0000, 200.0000,
    'GENERATED'
)
ON CONFLICT (id) DO NOTHING;
"@
Invoke-TenantSql -Label "0012 payroll (components + cycle + demo payslip)" -Sql $SqlPayroll

# =====================================================================
# 5. TAX (0013)
# =====================================================================
$SqlTax = @"
INSERT INTO "$Schema".tax_configuration_version (
    id, tenant_id, fiscal_year, regime, country_code, is_active
) VALUES (
    '$TaxConfigId', '$TenantId', 2026, 'NEW', 'IN', true
) ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".tax_slab (
    id, tenant_id, tax_config_version_id,
    income_from, income_to, tax_rate, surcharge_rate, cess_rate
) VALUES
    ('$TaxSlab1Id', '$TenantId', '$TaxConfigId',        0,  300000, 0,  0, 4),
    ('$TaxSlab2Id', '$TenantId', '$TaxConfigId',   300000,  600000, 5,  0, 4)
ON CONFLICT (id) DO NOTHING;
"@
Invoke-TenantSql -Label "0013 tax (configuration + slabs)" -Sql $SqlTax

# =====================================================================
# 6. BENEFITS (0014)
# =====================================================================
$SqlBenefits = @"
INSERT INTO "$Schema".benefit_type (id, tenant_id, name, code, category)
VALUES ('$BenefitTypeHealthId', '$TenantId', 'Group Health Insurance', 'GHI', 'INSURANCE')
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".benefit_plan (
    id, tenant_id, benefit_type_id, name,
    employer_contribution, employee_contribution, contribution_type,
    is_mandatory, is_active
) VALUES (
    '$BenefitPlanId', '$TenantId', '$BenefitTypeHealthId', 'GHI Base Plan',
    8000, 2000, 'FLAT', false, true
) ON CONFLICT (id) DO NOTHING;
"@
Invoke-TenantSql -Label "0014 benefits (type + plan)" -Sql $SqlBenefits

# =====================================================================
# 7. EXPENSE (0015)
# =====================================================================
$SqlExpense = @"
INSERT INTO "$Schema".expense_category (id, tenant_id, name, code, max_amount_per_claim)
VALUES ('$ExpenseCategoryId', '$TenantId', 'Travel', 'TRAVEL', 50000)
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".expense_policy (
    id, tenant_id, expense_category_id,
    limit_per_day, limit_per_month, receipt_required, approval_required,
    applicable_to, department_id, designation_id, role_id, max_amount_per_claim
) VALUES (
    '$ExpensePolicyTravelAllId', '$TenantId', '$ExpenseCategoryId',
    NULL, NULL, false, true,
    'ALL', NULL, NULL, NULL, NULL
) ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".expense (
    id, tenant_id, employee_id, expense_category_id,
    amount, currency, expense_date, title, status, submitted_at
) VALUES (
    '$ExpenseId', '$TenantId', '$EmployeeId', '$ExpenseCategoryId',
    4500, 'INR', CURRENT_DATE - INTERVAL '3 days', 'Client Visit - Cab & Meals', 'PENDING', NOW()
) ON CONFLICT (id) DO NOTHING;
"@
Invoke-TenantSql -Label "0015 expense (category + pending expense for approver demo)" -Sql $SqlExpense

# =====================================================================
# 7b. ONBOARDING (0017) — checklist tasks for demo employee
# =====================================================================
$SqlOnboarding = @"
INSERT INTO "$Schema".onboarding_checklist (
    id, tenant_id, employee_id, task_name, task_category,
    assigned_to, is_completed, due_date
) VALUES
    ('$OnboardTask1Id', '$TenantId', '$EmployeeId', 'Complete profile & emergency contacts', 'HR', NULL, false, CURRENT_DATE + 7),
    ('$OnboardTask2Id', '$TenantId', '$EmployeeId', 'Read employee handbook', 'Policy', NULL, false, CURRENT_DATE + 14)
ON CONFLICT (id) DO NOTHING;
"@
Invoke-TenantSql -Label "0017 onboarding (checklist tasks)" -Sql $SqlOnboarding

# =====================================================================
# 7c. TRAVEL REQUEST (0033) — pending trip for approver demo
#     Requires tenant Liquibase through 0033_travel_request on this schema.
# =====================================================================
$SqlTravel = @"
INSERT INTO "$Schema".travel_request (
    id, tenant_id, employee_id,
    origin_location, destination_location, from_date, to_date,
    purpose, estimated_amount, currency, status, submitted_at
) VALUES (
    '$TravelRequestId', '$TenantId', '$EmployeeId',
    'Bengaluru', 'Mumbai', CURRENT_DATE + 10, CURRENT_DATE + 12,
    'Bengaluru → Mumbai — QBR with customer team', 18500, 'INR', 'PENDING', NOW()
) ON CONFLICT (id) DO NOTHING;
"@
Invoke-TenantSql -Label "0033 travel_request (pending demo)" -Sql $SqlTravel

# =====================================================================
# 8. RECRUITMENT (0016)
# =====================================================================
$SqlRecruitment = @"
INSERT INTO "$Schema".job_posting (
    id, tenant_id, department_id, designation_id,
    title, description, employment_type, vacancies, status,
    open_date, close_date
) VALUES (
    '$JobPostingId', '$TenantId', '$DepartmentId', '$DesignationId',
    'Senior Software Engineer', 'Rust + TypeScript, remote friendly.', 'PERMANENT', 2, 'OPEN',
    CURRENT_DATE, CURRENT_DATE + INTERVAL '30 days'
) ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".application (
    id, tenant_id, job_id, candidate_name, candidate_email, candidate_phone,
    source, status, applied_at
) VALUES (
    '$ApplicationId', '$TenantId', '$JobPostingId',
    'Asha Rao', 'asha.rao@example.com', '+91-9999999999',
    'LINKEDIN', 'APPLIED', NOW()
) ON CONFLICT (id) DO NOTHING;
"@
Invoke-TenantSql -Label "0016 recruitment (job posting + application)" -Sql $SqlRecruitment

# =====================================================================
# 9. PERFORMANCE (0018)
# =====================================================================
$SqlPerformance = @"
INSERT INTO "$Schema".review_cycle (
    id, tenant_id, name, start_date, end_date, status, review_type
) VALUES (
    '$ReviewCycleId', '$TenantId', 'FY26 H1',
    DATE_TRUNC('year', CURRENT_DATE)::date,
    (DATE_TRUNC('year', CURRENT_DATE) + INTERVAL '6 months - 1 day')::date,
    'ACTIVE', 'HALF_YEARLY'
) ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".goal (
    id, tenant_id, employee_id, review_cycle_id,
    title, description, weightage, status, visibility
) VALUES (
    '$GoalId', '$TenantId', '$EmployeeId', '$ReviewCycleId',
    'Ship federated gateway', 'Unblock module delivery via graphql-yoga stitching.',
    40, 'IN_PROGRESS', 'MANAGER'
) ON CONFLICT (id) DO NOTHING;
"@
Invoke-TenantSql -Label "0018 performance (review cycle + goal)" -Sql $SqlPerformance

# =====================================================================
# 10. LMS (0019)
# =====================================================================
$SqlLms = @"
INSERT INTO "$Schema".skill (id, tenant_id, name, category, level)
VALUES ('$SkillId', '$TenantId', 'Rust', 'PROGRAMMING', 'INTERMEDIATE')
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".course (
    id, tenant_id, title, description, category, delivery_mode,
    duration_minutes, is_mandatory, is_active
) VALUES (
    '$CourseId', '$TenantId', 'Rust Basics',
    'Ownership, borrowing, lifetimes and async essentials.',
    'ENGINEERING', 'SELF_PACED',
    240, false, true
) ON CONFLICT (id) DO NOTHING;
"@
Invoke-TenantSql -Label "0019 lms (skill + course)" -Sql $SqlLms

# =====================================================================
# 11. SUCCESSION (0020)
# =====================================================================
$SqlSuccession = @"
INSERT INTO "$Schema".competency (id, tenant_id, name, category, description)
VALUES ('$CompetencyId', '$TenantId', 'Leadership', 'CORE', 'Guides teams, sets direction, coaches.')
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".talent_pool (id, tenant_id, name, description)
VALUES ('$TalentPoolId', '$TenantId', 'High Potential 2026', 'Top 10% identified in FY26 H1 review.')
ON CONFLICT (id) DO NOTHING;
"@
Invoke-TenantSql -Label "0020 succession (competency + talent pool)" -Sql $SqlSuccession

# =====================================================================
# 12. COMPENSATION (0021)
# =====================================================================
$SqlCompensation = @"
INSERT INTO "$Schema".salary_band (
    id, tenant_id, designation_id, grade,
    min_salary, mid_salary, max_salary, currency, effective_year
) VALUES (
    '$SalaryBandId', '$TenantId', '$DesignationId', 2,
    1200000, 1600000, 2000000, 'INR', 2026
) ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".compensation_review_cycle (
    id, tenant_id, name, year, start_date, end_date, status, budget_percentage
) VALUES (
    '$CompRevCycleId', '$TenantId', 'Annual Comp 2026', 2026,
    DATE_TRUNC('year', CURRENT_DATE)::date,
    (DATE_TRUNC('year', CURRENT_DATE) + INTERVAL '1 year - 1 day')::date,
    'PLANNING', 8
) ON CONFLICT (id) DO NOTHING;
"@
Invoke-TenantSql -Label "0021 compensation (salary band + review cycle)" -Sql $SqlCompensation

# =====================================================================
# 13. ASSETS (0022)
# =====================================================================
$SqlAssets = @"
INSERT INTO "$Schema".asset_category (id, tenant_id, name, code)
VALUES ('$AssetCategoryId', '$TenantId', 'Laptops', 'LAPTOP')
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".asset (
    id, tenant_id, asset_category_id, name,
    serial_number, asset_tag, purchase_value, purchase_date, status
) VALUES (
    '$AssetId', '$TenantId', '$AssetCategoryId', 'MacBook Pro 14 inch',
    'MBP14-2026-0001', 'KPA-MBP-0001', 210000, CURRENT_DATE - INTERVAL '30 days', 'AVAILABLE'
) ON CONFLICT (id) DO NOTHING;
"@
Invoke-TenantSql -Label "0022 assets (category + asset)" -Sql $SqlAssets

# =====================================================================
# 14. GRIEVANCE (0023)
# =====================================================================
$SqlGrievance = @"
INSERT INTO "$Schema".grievance_category (id, tenant_id, name, code, is_posh, resolution_sla_days)
VALUES ('$GrievCategoryId', '$TenantId', 'HR Policy', 'HR_POLICY', false, 14)
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".grievance_case (
    id, tenant_id, employee_id, grievance_category_id,
    subject, description, status, priority, confidentiality_level, filed_at
) VALUES (
    '$GrievCaseId', '$TenantId', '$EmployeeId', '$GrievCategoryId',
    'Request for remote work policy clarification',
    'Need clarification on multi-state remote work policy.',
    'OPEN', 'MEDIUM', 'STANDARD', NOW()
) ON CONFLICT (id) DO NOTHING;
"@
Invoke-TenantSql -Label "0023 grievance (category + case)" -Sql $SqlGrievance

# =====================================================================
# 14b. ANALYTICS (0024) — report, dashboard, snapshot
# =====================================================================
$SqlAnalytics = @"
INSERT INTO "$Schema".report_definition (
    id, tenant_id, name, entity_type, filters_json, columns_json, chart_type, is_public, created_by
) VALUES (
    '$ReportDefId', '$TenantId', 'Active headcount by department', 'EMPLOYEE',
    '{}'::jsonb, '[]'::jsonb, 'BAR', true, NULL
) ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".dashboard (
    id, tenant_id, name, description, is_default, created_by
) VALUES (
    '$DashId', '$TenantId', 'HR overview', 'Workforce and hiring snapshot', true, NULL
) ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".dashboard_widget (
    id, tenant_id, dashboard_id, report_definition_id, widget_type, title, grid_col, grid_row, col_span, row_span
) VALUES (
    '$DashWidgetId', '$TenantId', '$DashId', '$ReportDefId', 'CHART', 'Headcount', 0, 0, 2, 1
) ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".report_schedule (
    id, tenant_id, report_definition_id, frequency, is_active, recipients_json, delivery_format
) VALUES (
    '$ReportSchedId', '$TenantId', '$ReportDefId', 'MONTHLY', true, '[]'::jsonb, 'CSV'
) ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".workforce_snapshot (
    id, tenant_id, snapshot_date,
    total_headcount, active_employees, new_joiners, separations, open_positions,
    average_tenure_months, attrition_rate
) VALUES (
    '$WorkforceSnapId', '$TenantId', CURRENT_DATE,
    1, 1, 0, 0, 1, 24.0000, 0.0000
) ON CONFLICT (id) DO NOTHING;
"@
Invoke-TenantSql -Label "0024 analytics (report, dashboard, schedule, snapshot)" -Sql $SqlAnalytics

# =====================================================================
# 14c. OUTBOX (0030) — sample events for Insights "Event queue" (requires HR to view in API)
# =====================================================================
$SqlOutbox = @"
INSERT INTO "$Schema".outbox_event (
    id, tenant_id, aggregate_type, aggregate_id, event_type, payload, status, retry_count, last_error, created_at, processed_at, claimed_at
) VALUES (
    '$OutboxEventProcId', '$TenantId', 'LEAVE_REQUEST', '$LeaveRequest1Id', 'LEAVE_STATUS_CHANGED',
    '{"demo":true,"note":"Seeded for UI"}'::jsonb, 'PROCESSED', 0, NULL, NOW() - interval '2 hours', NOW() - interval '1 hour', NULL
) ON CONFLICT (id) DO NOTHING;
INSERT INTO "$Schema".outbox_event (
    id, tenant_id, aggregate_type, aggregate_id, event_type, payload, status, retry_count, last_error, created_at, processed_at, claimed_at
) VALUES (
    '$OutboxEventPendId', '$TenantId', 'EMPLOYEE', '$EmployeeId', 'DEMO_PING',
    '{}'::jsonb, 'PENDING', 0, NULL, NOW(), NULL, NULL
) ON CONFLICT (id) DO NOTHING;
"@
Invoke-TenantSql -Label "0030 outbox (demo events for event queue tab)" -Sql $SqlOutbox

# =====================================================================
# 15. WORKFLOW (0025)
# =====================================================================
$SqlWorkflow = @"
INSERT INTO "$Schema".workflow (id, tenant_id, name, entity_type, is_active)
VALUES ('$WorkflowId', '$TenantId', 'Leave Approval', 'LEAVE_REQUEST', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".workflow_step (
    id, tenant_id, workflow_id, sequence_order, step_name,
    approver_type, approver_role_id, can_skip, sla_hours
) VALUES (
    '$WorkflowStep1Id', '$TenantId', '$WorkflowId', 1, 'Manager or HR approval',
    'REPORTING_MANAGER_OR_ROLE', '$RoleHrAdminId', false, NULL
) ON CONFLICT (id) DO UPDATE SET
    sequence_order = EXCLUDED.sequence_order,
    step_name = EXCLUDED.step_name,
    approver_type = EXCLUDED.approver_type,
    approver_role_id = EXCLUDED.approver_role_id,
    can_skip = EXCLUDED.can_skip,
    sla_hours = EXCLUDED.sla_hours,
    updated_at = NOW();

DELETE FROM "$Schema".workflow_step WHERE id = '$WorkflowStep2Id';

UPDATE "$Schema".workflow_instance
SET current_step_id = '$WorkflowStep1Id', updated_at = NOW()
WHERE workflow_id = '$WorkflowId'
  AND entity_type = 'LEAVE_REQUEST'
  AND status = 'IN_PROGRESS'
  AND current_step_id = '$WorkflowStep2Id';

INSERT INTO "$Schema".workflow_instance (
    id, tenant_id, workflow_id, entity_type, entity_id, status, current_step_id
) VALUES (
    '$WorkflowInstanceId', '$TenantId', '$WorkflowId',
    'LEAVE_REQUEST', '$LeaveRequest1Id', 'IN_PROGRESS', '$WorkflowStep1Id'
) ON CONFLICT (id) DO UPDATE SET
    current_step_id = EXCLUDED.current_step_id,
    status = EXCLUDED.status,
    updated_at = NOW();

UPDATE "$Schema".leave_request
SET workflow_instance_id = '$WorkflowInstanceId', updated_at = NOW()
WHERE id = '$LeaveRequest1Id' AND (workflow_instance_id IS DISTINCT FROM '$WorkflowInstanceId');

INSERT INTO "$Schema".workflow (id, tenant_id, name, entity_type, is_active)
VALUES ('$ExpenseWorkflowId', '$TenantId', 'Expense Approval', 'EXPENSE', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".workflow_step (
    id, tenant_id, workflow_id, sequence_order, step_name,
    approver_type, approver_role_id, can_skip, sla_hours
) VALUES (
    '$ExpenseWorkflowStep1Id', '$TenantId', '$ExpenseWorkflowId', 1, 'Manager or HR approval',
    'REPORTING_MANAGER_OR_ROLE', '$RoleHrAdminId', false, NULL
) ON CONFLICT (id) DO UPDATE SET
    sequence_order = EXCLUDED.sequence_order,
    step_name = EXCLUDED.step_name,
    approver_type = EXCLUDED.approver_type,
    approver_role_id = EXCLUDED.approver_role_id,
    can_skip = EXCLUDED.can_skip,
    sla_hours = EXCLUDED.sla_hours,
    updated_at = NOW();

INSERT INTO "$Schema".workflow_step (
    id, tenant_id, workflow_id, sequence_order, step_name,
    approver_type, approver_role_id, can_skip, sla_hours
) VALUES (
    '$ExpenseWorkflowStep2Id', '$TenantId', '$ExpenseWorkflowId', 2, 'Accounting verification',
    'ROLE', '$RoleAccountingApproverId', false, NULL
) ON CONFLICT (id) DO UPDATE SET
    sequence_order = EXCLUDED.sequence_order,
    step_name = EXCLUDED.step_name,
    approver_type = EXCLUDED.approver_type,
    approver_role_id = EXCLUDED.approver_role_id,
    can_skip = EXCLUDED.can_skip,
    sla_hours = EXCLUDED.sla_hours,
    updated_at = NOW();

INSERT INTO "$Schema".workflow_instance (
    id, tenant_id, workflow_id, entity_type, entity_id, status, current_step_id
) VALUES (
    '$ExpenseWorkflowInstanceId', '$TenantId', '$ExpenseWorkflowId',
    'EXPENSE', '$ExpenseId', 'IN_PROGRESS', '$ExpenseWorkflowStep1Id'
) ON CONFLICT (id) DO UPDATE SET
    current_step_id = EXCLUDED.current_step_id,
    status = EXCLUDED.status,
    updated_at = NOW();

UPDATE "$Schema".expense
SET workflow_instance_id = '$ExpenseWorkflowInstanceId', updated_at = NOW()
WHERE id = '$ExpenseId' AND (workflow_instance_id IS DISTINCT FROM '$ExpenseWorkflowInstanceId');

INSERT INTO "$Schema".workflow (id, tenant_id, name, entity_type, is_active)
VALUES ('$TravelWorkflowId', '$TenantId', 'Travel pre-approval', 'TRAVEL_REQUEST', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".workflow_step (
    id, tenant_id, workflow_id, sequence_order, step_name,
    approver_type, approver_role_id, can_skip, sla_hours
) VALUES (
    '$TravelWorkflowStep1Id', '$TenantId', '$TravelWorkflowId', 1, 'Reporting manager or HR',
    'REPORTING_MANAGER_OR_ROLE', '$RoleHrAdminId', false, NULL
) ON CONFLICT (id) DO UPDATE SET
    sequence_order = EXCLUDED.sequence_order,
    step_name = EXCLUDED.step_name,
    approver_type = EXCLUDED.approver_type,
    approver_role_id = EXCLUDED.approver_role_id,
    can_skip = EXCLUDED.can_skip,
    sla_hours = EXCLUDED.sla_hours,
    updated_at = NOW();

INSERT INTO "$Schema".workflow_step (
    id, tenant_id, workflow_id, sequence_order, step_name,
    approver_type, approver_role_id, can_skip, sla_hours
) VALUES (
    '$TravelWorkflowStep2Id', '$TenantId', '$TravelWorkflowId', 2, 'Accounting clearance',
    'ROLE', '$RoleAccountingApproverId', false, NULL
) ON CONFLICT (id) DO UPDATE SET
    sequence_order = EXCLUDED.sequence_order,
    step_name = EXCLUDED.step_name,
    approver_type = EXCLUDED.approver_type,
    approver_role_id = EXCLUDED.approver_role_id,
    can_skip = EXCLUDED.can_skip,
    sla_hours = EXCLUDED.sla_hours,
    updated_at = NOW();

INSERT INTO "$Schema".workflow_instance (
    id, tenant_id, workflow_id, entity_type, entity_id, status, current_step_id
) VALUES (
    '$TravelWorkflowInstanceId', '$TenantId', '$TravelWorkflowId',
    'TRAVEL_REQUEST', '$TravelRequestId', 'IN_PROGRESS', '$TravelWorkflowStep1Id'
) ON CONFLICT (id) DO UPDATE SET
    current_step_id = EXCLUDED.current_step_id,
    status = EXCLUDED.status,
    updated_at = NOW();

UPDATE "$Schema".travel_request
SET workflow_instance_id = '$TravelWorkflowInstanceId', updated_at = NOW()
WHERE id = '$TravelRequestId' AND tenant_id = '$TenantId'
  AND (workflow_instance_id IS DISTINCT FROM '$TravelWorkflowInstanceId');

INSERT INTO "$Schema".workflow (id, tenant_id, name, entity_type, is_active)
VALUES ('$TimesheetWorkflowId', '$TenantId', 'Timesheet week approval', 'TIMESHEET_WEEK_BATCH', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".workflow_step (
    id, tenant_id, workflow_id, sequence_order, step_name,
    approver_type, approver_role_id, can_skip, sla_hours
) VALUES (
    '$TimesheetWorkflowStep1Id', '$TenantId', '$TimesheetWorkflowId', 1,
    'Reporting manager or HR',
    'REPORTING_MANAGER_OR_ROLE', '$RoleHrAdminId', false, NULL
) ON CONFLICT (id) DO UPDATE SET
    sequence_order = EXCLUDED.sequence_order,
    step_name = EXCLUDED.step_name,
    approver_type = EXCLUDED.approver_type,
    approver_role_id = EXCLUDED.approver_role_id,
    can_skip = EXCLUDED.can_skip,
    sla_hours = EXCLUDED.sla_hours,
    updated_at = NOW();

-- Single-step timesheet approval: remove legacy HR-only second step (avoid RESTRICT FK failures).
DELETE FROM "$Schema".workflow_action
WHERE tenant_id = '$TenantId' AND workflow_step_id = '$TimesheetWorkflowStep2Id';

DELETE FROM "$Schema".workflow_step
WHERE tenant_id = '$TenantId' AND id = '$TimesheetWorkflowStep2Id';
"@
Invoke-TenantSql -Label "0025 workflow (workflow + instance)" -Sql $SqlWorkflow

# =====================================================================
# 15b. HRMS timesheet / attendance defaults (master_data)
# =====================================================================
$SqlHrmsMaster = @"
INSERT INTO "$Schema".master_data (
    id, tenant_id, category, data_key, value, description, display_order, is_system, is_active, created_at, updated_at
) VALUES (
    '$MdHrmsAttAdjId', '$TenantId', 'HRMS_ATTENDANCE_ADJUSTMENT', 'POLICY',
    '{"maxSelfAdjustDays":5}', 'Manual punch self-service window (days)', 0, false, true, NOW(), NOW()
) ON CONFLICT (tenant_id, category, data_key) DO NOTHING;

INSERT INTO "$Schema".master_data (
    id, tenant_id, category, data_key, value, description, display_order, is_system, is_active, created_at, updated_at
) VALUES (
    '$MdHrmsTsLockId', '$TenantId', 'HRMS_TIMESHEET_LOCK', 'POLICY',
    '{"editableWeekSpan":2,"lockApprovedEntries":true}', 'Timesheet draft horizon + approved lock', 0, false, true, NOW(), NOW()
) ON CONFLICT (tenant_id, category, data_key) DO NOTHING;

INSERT INTO "$Schema".master_data (
    id, tenant_id, category, data_key, value, description, display_order, is_system, is_active, created_at, updated_at
) VALUES (
    '$MdProjInternalId', '$TenantId', 'TIMESHEET_PROJECT', 'INTERNAL',
    'Internal / overhead', NULL, 0, false, true, NOW(), NOW()
) ON CONFLICT (tenant_id, category, data_key) DO NOTHING;

INSERT INTO "$Schema".master_data (
    id, tenant_id, category, data_key, value, description, display_order, is_system, is_active, created_at, updated_at
) VALUES (
    '$MdProjClientAId', '$TenantId', 'TIMESHEET_PROJECT', 'CLIENT-A',
    'Client Alpha implementation', NULL, 1, false, true, NOW(), NOW()
) ON CONFLICT (tenant_id, category, data_key) DO NOTHING;

INSERT INTO "$Schema".master_data (
    id, tenant_id, category, data_key, value, description, display_order, is_system, is_active, created_at, updated_at
) VALUES (
    '$MdTaskInternalId', '$TenantId', 'TIMESHEET_TASK', 'INTERNAL',
    '["ADMIN","MEETING","DEV"]', NULL, 0, false, true, NOW(), NOW()
) ON CONFLICT (tenant_id, category, data_key) DO NOTHING;
"@
Invoke-TenantSql -Label "HRMS master_data (timesheet + attendance policy)" -Sql $SqlHrmsMaster

# =====================================================================
# 16. NOTIFICATION / COMMUNICATION (0027)
# =====================================================================
$SqlComm = @"
INSERT INTO "$Schema".announcement (
    id, tenant_id, created_by, title, body, target_audience, publish_at
) VALUES (
    '$AnnouncementId', '$TenantId', '$UserId',
    'Welcome to KabiPay!',
    'Thanks for provisioning your tenant. Explore the modules via /admin/module-health.',
    'ALL', NOW()
) ON CONFLICT (id) DO NOTHING;

INSERT INTO "$Schema".notification (
    id, tenant_id, user_id, type, title, message, action_url, is_read
) VALUES (
    '$NotificationId', '$TenantId', '$UserId',
    'SYSTEM', 'Demo data seeded',
    'Your tenant now has sample rows across all modules.',
    '/admin/module-health', false
) ON CONFLICT (id) DO NOTHING;
"@
Invoke-TenantSql -Label "0027 communication (announcement + notification)" -Sql $SqlComm

# =====================================================================
# 17. OPS PLANE (kabipay_ops)
#     modules, subscriptions, billing_cycle, invoice, payment, operator_*
# =====================================================================
$SqlOps = @"
-- Module catalogue (starter modules, idempotent)
INSERT INTO kabipay_ops.module (id, code, name, category, description, is_active, display_order, is_core) VALUES
    ('$ModuleEmployeeId', 'EMPLOYEE',    'Employee Core',       'CORE', 'Master employee records.',        true, 10, true),
    ('$ModuleLeaveId',    'LEAVE',       'Leave Management',    'HR',   'Policies, balances, requests.',   true, 20, false),
    ('$ModulePayrollId',  'PAYROLL',     'Payroll Processing',  'HR',   'Cycles, payslips, compliance.',   true, 30, false),
    ('$ModuleRecruitId',  'RECRUITMENT', 'Talent Acquisition',  'HR',   'Job postings and applications.',  true, 40, false),
    ('$ModuleExpenseId',  'EXPENSE',     'Expense Management',  'HR',   'Claims, policies, reimbursements.', true, 25, false),
    ('$ModuleTaxId',      'TAX',         'Tax & Statutory',     'HR',   'Regimes, proofs, TDS, filings.',    true, 22, false),
    ('$ModuleAttendanceId', 'ATTENDANCE', 'Attendance & Time',   'HR',   'Shifts, punches, attendance.',       true, 18, false),
    ('$ModuleWorkflowId', 'WORKFLOW',    'Workflows',           'CORE', 'Approval routing and definitions.',  true, 15, false)
ON CONFLICT (id) DO NOTHING;

-- Two active subscriptions for this tenant
INSERT INTO kabipay_ops.tenant_subscription (
    id, tenant_id, module_id, status,
    activated_at, expires_at,
    contracted_seats, current_seat_usage, overage_policy
) VALUES
    ('$SubLeaveId',   '$TenantId', '$ModuleLeaveId',   'ACTIVE',
        CURRENT_DATE, CURRENT_DATE + INTERVAL '1 year', 100, 1, 'BLOCK'),
    ('$SubPayrollId', '$TenantId', '$ModulePayrollId', 'ACTIVE',
        CURRENT_DATE, CURRENT_DATE + INTERVAL '1 year', 100, 1, 'BLOCK'),
    ('$SubAttendanceId', '$TenantId', '$ModuleAttendanceId', 'ACTIVE',
        CURRENT_DATE, CURRENT_DATE + INTERVAL '1 year', 100, 1, 'BLOCK'),
    ('$SubWorkflowId', '$TenantId', '$ModuleWorkflowId', 'ACTIVE',
        CURRENT_DATE, CURRENT_DATE + INTERVAL '1 year', 100, 1, 'BLOCK')
ON CONFLICT (id) DO NOTHING;

-- Current-month billing cycle
INSERT INTO kabipay_ops.billing_cycle (
    id, tenant_id, period_start, period_end, frequency, status
) VALUES (
    '$BillingCycleId', '$TenantId',
    DATE_TRUNC('month', CURRENT_DATE)::date,
    (DATE_TRUNC('month', CURRENT_DATE) + INTERVAL '1 month - 1 day')::date,
    'MONTHLY', 'INVOICED'
) ON CONFLICT (id) DO NOTHING;

-- One pending invoice for that cycle
INSERT INTO kabipay_ops.invoice (
    id, tenant_id, billing_cycle_id, invoice_number,
    subtotal, discount_total, tax_amount, total_amount, currency,
    status, due_date
) VALUES (
    '$InvoiceId', '$TenantId', '$BillingCycleId',
    CONCAT('INV-', TO_CHAR(CURRENT_DATE, 'YYYYMM'), '-', SUBSTRING('$TenantId', 1, 8)),
    20000, 0, 3600, 23600, 'INR',
    'PENDING', CURRENT_DATE + INTERVAL '15 days'
) ON CONFLICT (id) DO NOTHING;

-- Successful payment for that invoice
INSERT INTO kabipay_ops.payment (
    id, invoice_id, amount, payment_method, status, paid_at, gateway_ref
) VALUES (
    '$PaymentId', '$InvoiceId', 23600, 'CARD', 'SUCCEEDED', NOW(), 'demo_pay_0001'
) ON CONFLICT (id) DO NOTHING;

-- Operator RBAC seed
INSERT INTO kabipay_ops.operator_role (id, code, name, description) VALUES
    ('$OpRoleAdminId',   'ADMIN',   'Platform Admin',   'Full access to all tenants and operator tools.'),
    ('$OpRoleSupportId', 'SUPPORT', 'Support Engineer', 'Read-only tenant inspection for support.')
ON CONFLICT (id) DO NOTHING;

INSERT INTO kabipay_ops.operator_user (
    id, email, password_hash, full_name, phone, is_active
) VALUES (
    '$OpUserId',
    'ops-admin@kabipay.local',
    '$PasswordHash',
    'Ops Admin',
    '+91-9000000001',
    true
) ON CONFLICT (id) DO UPDATE SET password_hash = EXCLUDED.password_hash, is_active = true;
"@
Invoke-TenantSql -Label "ops plane (modules, subscriptions, billing, operators)" -Sql $SqlOps

# =====================================================================
# 18. SUMMARY — counts across seeded tables
# =====================================================================
$SqlSummary = @"
SELECT 'tenant.employee'       AS table, COUNT(*) AS rows FROM "$Schema".employee
UNION ALL SELECT 'tenant.shift',              COUNT(*) FROM "$Schema".shift
UNION ALL SELECT 'tenant.attendance',         COUNT(*) FROM "$Schema".attendance
UNION ALL SELECT 'tenant.leave_type',         COUNT(*) FROM "$Schema".leave_type
UNION ALL SELECT 'tenant.leave_request',      COUNT(*) FROM "$Schema".leave_request
UNION ALL SELECT 'tenant.salary_component',   COUNT(*) FROM "$Schema".salary_component
UNION ALL SELECT 'tenant.payroll_cycle',      COUNT(*) FROM "$Schema".payroll_cycle
UNION ALL SELECT 'tenant.payslip',            COUNT(*) FROM "$Schema".payslip
UNION ALL SELECT 'tenant.employee_pan',       COUNT(*) FROM "$Schema".employee_pan
UNION ALL SELECT 'tenant.tax_config_ver',     COUNT(*) FROM "$Schema".tax_configuration_version
UNION ALL SELECT 'tenant.tax_slab',           COUNT(*) FROM "$Schema".tax_slab
UNION ALL SELECT 'tenant.benefit_plan',       COUNT(*) FROM "$Schema".benefit_plan
UNION ALL SELECT 'tenant.expense',            COUNT(*) FROM "$Schema".expense
UNION ALL SELECT 'tenant.job_posting',        COUNT(*) FROM "$Schema".job_posting
UNION ALL SELECT 'tenant.application',        COUNT(*) FROM "$Schema".application
UNION ALL SELECT 'tenant.review_cycle',       COUNT(*) FROM "$Schema".review_cycle
UNION ALL SELECT 'tenant.goal',               COUNT(*) FROM "$Schema".goal
UNION ALL SELECT 'tenant.skill',              COUNT(*) FROM "$Schema".skill
UNION ALL SELECT 'tenant.course',             COUNT(*) FROM "$Schema".course
UNION ALL SELECT 'tenant.competency',         COUNT(*) FROM "$Schema".competency
UNION ALL SELECT 'tenant.talent_pool',        COUNT(*) FROM "$Schema".talent_pool
UNION ALL SELECT 'tenant.report_definition',  COUNT(*) FROM "$Schema".report_definition
UNION ALL SELECT 'tenant.workforce_snapshot',  COUNT(*) FROM "$Schema".workforce_snapshot
UNION ALL SELECT 'tenant.outbox_event',         COUNT(*) FROM "$Schema".outbox_event
UNION ALL SELECT 'tenant.salary_band',        COUNT(*) FROM "$Schema".salary_band
UNION ALL SELECT 'tenant.comp_review_cycle',  COUNT(*) FROM "$Schema".compensation_review_cycle
UNION ALL SELECT 'tenant.asset',              COUNT(*) FROM "$Schema".asset
UNION ALL SELECT 'tenant.grievance_case',     COUNT(*) FROM "$Schema".grievance_case
UNION ALL SELECT 'tenant.workflow_instance',  COUNT(*) FROM "$Schema".workflow_instance
UNION ALL SELECT 'tenant.announcement',       COUNT(*) FROM "$Schema".announcement
UNION ALL SELECT 'tenant.notification',       COUNT(*) FROM "$Schema".notification
UNION ALL SELECT 'ops.module',                COUNT(*) FROM kabipay_ops.module
UNION ALL SELECT 'ops.tenant_subscription',   COUNT(*) FROM kabipay_ops.tenant_subscription WHERE tenant_id = '$TenantId'
UNION ALL SELECT 'ops.invoice',               COUNT(*) FROM kabipay_ops.invoice WHERE tenant_id = '$TenantId'
UNION ALL SELECT 'ops.payment',               COUNT(*) FROM kabipay_ops.payment p
    JOIN kabipay_ops.invoice i ON i.id = p.invoice_id WHERE i.tenant_id = '$TenantId'
UNION ALL SELECT 'ops.operator_user',         COUNT(*) FROM kabipay_ops.operator_user
ORDER BY 1;
"@
Invoke-TenantSql -Label "counts" -Sql $SqlSummary

Write-Host ""
Write-Host "Seed complete." -ForegroundColor Green
Write-Host ""
Write-Host "Demo tenant logins (password ChangeMe!123):" -ForegroundColor Yellow
Write-Host '  demo@kabipay.local          - HR_ADMIN + employee (full HR + self-service + attendance:punch_self)'
Write-Host '  tenant-admin@kabipay.local  - TENANT_ADMIN + HR_ADMIN row (workflow fallbacks + admin shell)'
Write-Host '  manager@kabipay.local       - LINE_MANAGER (approvals + analytics:read + attendance:punch_self)'
Write-Host '  staff@kabipay.local         - DEMO_STAFF (benefits:self, onboarding:self, grievance:self, attendance:punch_self)'
Write-Host ""
Write-Host "Try the employee query once kabipay-employee is running:" -ForegroundColor Yellow
Write-Host '  PowerShell:'
Write-Host ('    Invoke-RestMethod -Method Post -Uri http://127.0.0.1:4013/graphql ' +
            '-Headers @{"content-type"="application/json"; "x-tenant-id"="' + $TenantId + '"} ' +
            '-Body (''{"query":"{ employee(id: \"' + $EmployeeId + '\") { id employeeCode firstName lastName fullName } }"}'')')
Write-Host ''
Write-Host '  curl (single-line):'
$Query = '{ employee(id: \"' + $EmployeeId + '\") { id employeeCode firstName lastName fullName } }'
$JsonBody = '{"query":"' + $Query + '"}'
Write-Host ('    curl -s -X POST http://127.0.0.1:4013/graphql -H "content-type: application/json" ' +
            '-H "x-tenant-id: ' + $TenantId + '" -d ''' + $JsonBody + '''')
Write-Host ''
Write-Host "Or point the UI at /admin/module-health for a green-light matrix across all subgraphs." -ForegroundColor Yellow
