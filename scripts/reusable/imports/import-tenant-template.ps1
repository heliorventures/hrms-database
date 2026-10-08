[CmdletBinding()]
param(
    [ValidateSet('Validate', 'Preview', 'Apply', 'Reconcile')]
    [string]$Action = 'Preview',
    [Parameter(Mandatory = $true)][string]$PackagePath,
    [Parameter(Mandatory = $true)][string]$OptionsPath,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [string]$ImporterPath,
    [string]$EnvironmentFile,
    [string]$PlanPath,
    [string]$ConfirmDigest,
    [switch]$Replace,
    [switch]$WritesPaused,
    [string]$PostgresBin,
    [string]$RunId
)
$ErrorActionPreference = 'Stop'
$databaseRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../..')).Path
if (-not $ImporterPath) {
    $ImporterPath = Join-Path (Split-Path $databaseRoot -Parent) 'hrms-svc/target/debug/kabipay-tenant-import.exe'
}
function ExistingFile([string]$Path) {
    $item = Get-Item -LiteralPath $Path
    if ($item.PSIsContainer) { throw 'Expected a file path.' }
    return $item.FullName
}
$program = ExistingFile $ImporterPath
$packageFile = ExistingFile $PackagePath
$optionsFile = ExistingFile $OptionsPath
$outputPath = [System.IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $outputPath) { throw 'OutputDirectory must be a new private directory.' }
if ($Action -ne 'Apply' -and ($PlanPath -or $ConfirmDigest -or $WritesPaused)) {
    throw 'PlanPath, ConfirmDigest and WritesPaused require Action Apply.'
}
if ($Action -eq 'Apply' -and (-not $PlanPath -or -not $ConfirmDigest)) {
    throw 'Apply requires the reviewed PlanPath and its exact ConfirmDigest.'
}
if ($Action -eq 'Apply' -and $Replace) {
    $operatorOptions = Get-Content -LiteralPath $optionsFile -Raw | ConvertFrom-Json
    $skipBackup = $operatorOptions.replacement_backup.mode -eq 'SKIP'
    if (-not $WritesPaused -or (-not $skipBackup -and -not $PostgresBin)) {
        throw 'Replacement requires a write pause and PostgresBin unless the reviewed options explicitly skip backup.'
    }
}
$nativeArguments = @($Action.ToLowerInvariant(), '--package', $packageFile, '--options', $optionsFile, '--output', $outputPath)
if ($EnvironmentFile) { $nativeArguments += @('--env-file', (ExistingFile $EnvironmentFile)) }
if ($Replace) { $nativeArguments += '--replace' }
if ($WritesPaused) { $nativeArguments += '--writes-paused' }
if ($PlanPath) { $nativeArguments += @('--plan', (ExistingFile $PlanPath)) }
if ($ConfirmDigest) { $nativeArguments += @('--confirm', $ConfirmDigest) }
if ($PostgresBin) { $nativeArguments += @('--pg-bin', (Resolve-Path -LiteralPath $PostgresBin).Path) }
if ($Action -eq 'Reconcile') {
    if (-not $RunId) { throw 'Reconcile requires RunId from the staged run-state file.' }
    $nativeArguments += @('--run-id', $RunId)
}
& $program @nativeArguments
if ($LASTEXITCODE -ne 0) { throw 'Native tenant import did not complete. Review its safe error code and private output.' }
