[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$Root)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'community-theme-test-support.ps1') -Root $Root

$bundle = Get-CommunityApplyBundle
foreach ($name in @(
  'Get-DreamSkinCommunityStartFailureMessage',
  'New-DreamSkinCommunityStartStateException',
  'Invoke-DreamSkinCommunityStartAndVerify',
  'New-DreamSkinCommunityApplyException',
  'Assert-DreamSkinCommunityActiveBaseline',
  'Ensure-DreamSkinCommunityActiveBaseline',
  'Get-DreamSkinCommunityActiveState',
  'Move-DreamSkinCommunityRollbackSnapshot',
  'Invoke-DreamSkinCommunityThemeTransaction'
)) {
  if ($null -eq (Find-CommunityApplyHelper -Bundle $bundle -Name $name)) {
    throw "A testable community apply helper is missing: $name"
  }
}
$startFailureMessageHelperAst = Find-CommunityApplyHelper -Bundle $bundle -Name 'Get-DreamSkinCommunityStartFailureMessage'
$startStateExceptionHelperAst = Find-CommunityApplyHelper -Bundle $bundle -Name 'New-DreamSkinCommunityStartStateException'
$startAndVerifyHelperAst = Find-CommunityApplyHelper -Bundle $bundle -Name 'Invoke-DreamSkinCommunityStartAndVerify'
$exceptionHelperAst = Find-CommunityApplyHelper -Bundle $bundle -Name 'New-DreamSkinCommunityApplyException'
$baselineHelperAst = Find-CommunityApplyHelper -Bundle $bundle -Name 'Assert-DreamSkinCommunityActiveBaseline'
$baselineStartHelperAst = Find-CommunityApplyHelper -Bundle $bundle -Name 'Ensure-DreamSkinCommunityActiveBaseline'
$activeStateHelperAst = Find-CommunityApplyHelper -Bundle $bundle -Name 'Get-DreamSkinCommunityActiveState'
$moveRollbackHelperAst = Find-CommunityApplyHelper -Bundle $bundle -Name 'Move-DreamSkinCommunityRollbackSnapshot'
$transactionAst = Find-CommunityApplyHelper -Bundle $bundle -Name 'Invoke-DreamSkinCommunityThemeTransaction'
# Exercise the real parent wait/result helper with a delayed child contract. Its
# completion budget is independent from lock acquisition, and a still-running
# child must never be force-killed out of its recovery finally block.
& {
  param($FailureMessageSource, $StateExceptionSource, $StartSource)
  . ([scriptblock]::Create($FailureMessageSource))
  . ([scriptblock]::Create($StateExceptionSource))
  . ([scriptblock]::Create($StartSource))

  $script:parentStartMode = 'complete'
  $script:parentWaitTimeout = 0
  $script:parentStopCalls = 0
  $script:parentReadCalls = 0
  $script:parentRemoveCalls = 0
  $script:parentResultPathProbes = 0
  $fakeProcess = [pscustomobject]@{ ExitCode = 1 }
  $fakeProcess | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
    param([int]$Milliseconds)
    $script:parentWaitTimeout = $Milliseconds
    return $script:parentStartMode -ceq 'complete'
  }

  function Get-DreamSkinCommunityText { param([string]$Key); return $Key }
  function Assert-DreamSkinNoReparseComponents { param([string]$Path) }
  function Join-Path {
    param([AllowEmptyString()][string]$Path, [string]$ChildPath)
    return 'fixture-' + $ChildPath
  }
  function Get-DreamSkinStartResultPath { param([string]$StateRoot, [string]$Token); return 'fixture-result' }
  function ConvertTo-DreamSkinProcessArgument { param([string]$Value); return $Value }
  function Get-Command { param([string]$Name, [object]$ErrorAction); return [pscustomobject]@{ Source = 'powershell.exe' } }
  function Start-Process {
    param([string]$FilePath, [object]$ArgumentList, [string]$WindowStyle, [switch]$PassThru)
    return $fakeProcess
  }
  function Stop-Process {
    param([object]$InputObject, [switch]$Force, [object]$ErrorAction)
    $script:parentStopCalls += 1
  }
  function Read-DreamSkinStartResult {
    param([string]$StateRoot, [string]$Token)
    $script:parentReadCalls += 1
    return [pscustomobject]@{
      outcome = 'failure'
      category = 'cdp-endpoint-unavailable'
      appearanceRecovery = 'restored'
    }
  }
  function Test-Path {
    param([string]$LiteralPath, [object]$PathType)
    if ($LiteralPath -ceq 'fixture-result') {
      $script:parentResultPathProbes += 1
      return $script:parentResultPathProbes -gt 1
    }
    return $true
  }
  function Remove-Item {
    param([string]$LiteralPath, [switch]$Force, [object]$ErrorAction)
    $script:parentRemoveCalls += 1
  }

  $completedFailure = $null
  try { Invoke-DreamSkinCommunityStartAndVerify } catch { $completedFailure = $_ }
  if ($null -eq $completedFailure -or
    "$($completedFailure.Exception.Data['DreamSkinAppearanceRecovery'])" -cne 'restored' -or
    $script:parentWaitTimeout -ne 480000 -or $script:parentStopCalls -ne 0 -or
    $script:parentReadCalls -ne 1 -or $script:parentRemoveCalls -ne 1) {
    throw ("The delayed child did not receive its independent completion grace and exact " +
      "restored result (message=$($completedFailure.Exception.Message); recovery=" +
      "$($completedFailure.Exception.Data['DreamSkinAppearanceRecovery']); wait=" +
      "$script:parentWaitTimeout; stops=$script:parentStopCalls; reads=" +
      "$script:parentReadCalls; removes=$script:parentRemoveCalls).")
  }

  $script:parentStartMode = 'timeout'
  $script:parentWaitTimeout = 0
  $script:parentReadCalls = 0
  $script:parentRemoveCalls = 0
  $script:parentResultPathProbes = 0
  $timeoutFailure = $null
  try { Invoke-DreamSkinCommunityStartAndVerify } catch { $timeoutFailure = $_ }
  if ($null -eq $timeoutFailure -or
    -not [bool]$timeoutFailure.Exception.Data['DreamSkinStartStateUnconfirmed'] -or
    -not [bool]$timeoutFailure.Exception.Data['DreamSkinStartStillRunning'] -or
    $script:parentWaitTimeout -ne 480000 -or $script:parentStopCalls -ne 0 -or
    $script:parentReadCalls -ne 0 -or $script:parentRemoveCalls -ne 0) {
    throw 'A still-running child was killed, consumed, or reported as safely rolled back.'
  }
} $startFailureMessageHelperAst.Extent.Text `
  $startStateExceptionHelperAst.Extent.Text $startAndVerifyHelperAst.Extent.Text

. ([scriptblock]::Create($exceptionHelperAst.Extent.Text))
. ([scriptblock]::Create($baselineHelperAst.Extent.Text))
. ([scriptblock]::Create($baselineStartHelperAst.Extent.Text))
. ([scriptblock]::Create($activeStateHelperAst.Extent.Text))
. ([scriptblock]::Create($moveRollbackHelperAst.Extent.Text))
. ([scriptblock]::Create($transactionAst.Extent.Text))

$script:communityExpectedFingerprint = '1' * 64
$script:communityRollbackFingerprint = '2' * 64
$script:communityOtherFingerprint = '3' * 64
$script:communityCurrentFingerprint = $script:communityRollbackFingerprint
$script:communityMode = 'success'
$script:communityStartCalls = 0
$script:communityStartTimeouts = @()
$script:communityRestoreCalls = 0
$script:communitySnapshotCalls = 0
$script:communityWriteCalls = 0
$script:communityPauseWriteCalls = 0
$script:communityBaselineVerifyCalls = 0
$script:communityBaselineVerifyArguments = @()
$script:communityPaused = $false
$script:communitySessionAvailable = $true
$script:communityLockDepth = 0
$script:communityMaxLockDepth = 0
$script:communityLockTimeouts = @()

function Enter-DreamSkinOperationLock {
  param([int]$TimeoutMilliseconds = 0)
  $script:communityLockTimeouts += $TimeoutMilliseconds
  if ($script:communityMode -ceq 'recovery-lock-timeout' -and
    $TimeoutMilliseconds -gt 0) {
    throw 'forced bounded recovery lock timeout'
  }
  $script:communityLockDepth += 1
  $script:communityMaxLockDepth = [Math]::Max(
    $script:communityMaxLockDepth,
    $script:communityLockDepth
  )
  return [pscustomobject]@{ TestLock = $true }
}

function Exit-DreamSkinOperationLock {
  param([Parameter(Mandatory = $true)][object]$Mutex)
  if (-not $Mutex.TestLock -or $script:communityLockDepth -ne 1) {
    throw 'The mocked operation lock was released out of order.'
  }
  $script:communityLockDepth -= 1
}

function Copy-DreamSkinImportedThemeSnapshot {
  param(
    [string]$SourceDirectory,
    [string]$Destination,
    [object]$Paths,
    [string]$ExpectedContentFingerprint
  )
  $fingerprint = if ($script:communityMode -ceq 'wrong-private-fingerprint') {
    '4' * 64
  } else {
    $ExpectedContentFingerprint
  }
  return [pscustomobject]@{ Directory = $Destination; ContentFingerprint = $fingerprint }
}

function Copy-DreamSkinActiveThemeSnapshot {
  param([object]$Paths, [string]$Destination)
  if ($script:communityLockDepth -ne 1) { throw 'Active snapshot occurred outside the operation lock.' }
  $script:communitySnapshotCalls += 1
  if ($script:communityMode -ceq 'baseline-snapshot-changed') {
    $script:communityCurrentFingerprint = $script:communityOtherFingerprint
  }
  return [pscustomobject]@{ Directory = $Destination }
}

function Get-DreamSkinThemeRuntimeContentFingerprint {
  param([string]$ThemeDirectory)
  if ($ThemeDirectory -like '*active-before') {
    if ($script:communityMode -in @(
        'baseline-snapshot-changed', 'rollback-snapshot-mismatch'
      )) {
      return $script:communityOtherFingerprint
    }
    return $script:communityRollbackFingerprint
  }
  if ($ThemeDirectory -like '*apply-candidate') { return $script:communityExpectedFingerprint }
  return $script:communityCurrentFingerprint
}

function Test-DreamSkinPaused {
  param([string]$StateRoot)
  return $script:communityPaused
}

function Test-DreamSkinPendingAppearanceTransaction {
  param([string]$BackupPath)
  return $script:communityMode -ceq 'baseline-pending-appearance'
}

function Set-DreamSkinPaused {
  param([bool]$Paused, [string]$StateRoot)
  $script:communityPauseWriteCalls += 1
  $script:communityPaused = $Paused
  return $Paused
}

function Get-DreamSkinLiveSessionContext {
  param([string]$StateRoot)
  if (-not $script:communitySessionAvailable) { return $null }
  $sessionActive = if ($script:communityMode -ceq 'baseline-session-mismatch') {
    'other-active'
  } else {
    'active'
  }
  return [pscustomobject]@{
    Paths = [pscustomobject]@{ Active = $sessionActive }
    NodePath = 'node.exe'
    Injector = 'injector.mjs'
    Port = 9335
    BrowserId = 'browser-1'
  }
}

function Invoke-DreamSkinNative {
  param(
    [string]$FilePath,
    [object[]]$ArgumentList,
    [switch]$DiscardStderr
  )
  $script:communityBaselineVerifyCalls += 1
  $script:communityBaselineVerifyArguments = @($ArgumentList)
  if ($script:communityMode -ceq 'baseline-selection-changed') {
    $script:communityCurrentFingerprint = $script:communityOtherFingerprint
  }
  if ($script:communityMode -ceq 'baseline-pause-during-verify') {
    $script:communityPaused = $true
  }
  $exitCode = if ($script:communityMode -in @('baseline-renderer-mismatch', 'baseline-bootstrap-no-session')) { 1 } else { 0 }
  return [pscustomobject]@{ ExitCode = $exitCode; Output = @('{}') }
}

function Set-DreamSkinActiveThemeFromSnapshot {
  param([string]$SnapshotDirectory, [string]$StateRoot, [string]$ExpectedContentFingerprint)
  if ($script:communityLockDepth -ne 1) { throw 'Active write occurred outside the operation lock.' }
  $script:communityWriteCalls += 1
  $script:communityCurrentFingerprint = $ExpectedContentFingerprint
  if ($script:communityMode -ceq 'partial-write-failure') {
    throw 'forced partial active-theme write failure'
  }
  return $ExpectedContentFingerprint
}

function Restore-DreamSkinActiveThemeSnapshot {
  param([string]$SnapshotDirectory, [string]$StateRoot, [string]$ExpectedContentFingerprint)
  if ($script:communityLockDepth -ne 1) { throw 'Rollback write occurred outside the operation lock.' }
  $script:communityRestoreCalls += 1
  if ($script:communityMode -ceq 'rollback-write-failure') {
    throw 'forced rollback file failure'
  }
  $script:communityCurrentFingerprint = $ExpectedContentFingerprint
  return $ExpectedContentFingerprint
}

function Invoke-DreamSkinCommunityStartAndVerify {
  param([int]$OperationLockTimeoutMilliseconds = 180000)
  if ($script:communityLockDepth -ne 0) {
    throw 'The child start script was called while the parent operation lock was held.'
  }
  $script:communityStartCalls += 1
  $script:communityStartTimeouts += $OperationLockTimeoutMilliseconds
  if ($script:communityMode -ceq 'baseline-off') {
    $script:communitySessionAvailable = $true
    return
  }
  if ($script:communityMode -ceq 'baseline-bootstrap-failure') {
    throw 'forced baseline start failure'
  }
  if ($script:communityMode -in @(
      'startup-failure', 'rollback-write-failure', 'recovery-lock-timeout', 'pause-superseded'
    ) -and
    $script:communityStartCalls -eq 1) {
    if ($script:communityMode -ceq 'pause-superseded') {
      $script:communityPaused = $true
    }
    throw 'forced imported renderer failure'
  }
  if ($script:communityMode -ceq 'preserved-rendered' -and
    $script:communityStartCalls -eq 1) {
    $exception = [System.InvalidOperationException]::new('forced preserved rendered result')
    $exception.Data['DreamSkinAppearanceRecovery'] = 'preserved-rendered'
    $exception.Data['DreamSkinStartStateUnconfirmed'] = $true
    throw $exception
  }
  if ($script:communityMode -ceq 'rollback-renderer-failure') {
    throw 'forced renderer failure'
  }
  if ($script:communityMode -ceq 'superseded' -and $script:communityStartCalls -eq 1) {
    $script:communityCurrentFingerprint = $script:communityOtherFingerprint
    throw 'forced concurrent user theme selection'
  }
}

$mockPaths = [pscustomobject]@{ Root = 'state'; Saved = 'saved'; Active = 'active' }
$mockImported = [pscustomobject]@{
  Path = 'saved\theme'
  ContentFingerprint = $script:communityExpectedFingerprint
}

function Reset-CommunityTransactionFixture {
  param([Parameter(Mandatory = $true)][string]$Mode)
  $script:communityMode = $Mode
  $script:communityCurrentFingerprint = $script:communityRollbackFingerprint
  $script:communityStartCalls = 0
  $script:communityStartTimeouts = @()
  $script:communityRestoreCalls = 0
  $script:communitySnapshotCalls = 0
  $script:communityWriteCalls = 0
  $script:communityPauseWriteCalls = 0
  $script:communityBaselineVerifyCalls = 0
  $script:communityBaselineVerifyArguments = @()
  $script:communityPaused = $Mode -ceq 'baseline-paused'
  $script:communitySessionAvailable = $Mode -notin @(
    'baseline-off', 'baseline-bootstrap-failure', 'baseline-bootstrap-no-session'
  )
  $script:communityLockDepth = 0
  $script:communityMaxLockDepth = 0
  $script:communityLockTimeouts = @()
}

function Assert-CommunityIntSequence {
  param(
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Actual,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Expected,
    [Parameter(Mandatory = $true)][string]$Label
  )
  if (($Actual -join ',') -cne ($Expected -join ',')) {
    throw "$Label sequence was '$($Actual -join ',')', expected '$($Expected -join ',')'."
  }
}

foreach ($baselineCase in @(
  @{ Mode = 'baseline-paused'; VerifyCalls = 0 },
  @{ Mode = 'baseline-session-mismatch'; VerifyCalls = 0 },
  @{ Mode = 'baseline-renderer-mismatch'; VerifyCalls = 1 },
  @{ Mode = 'baseline-selection-changed'; VerifyCalls = 1 },
  @{ Mode = 'baseline-pause-during-verify'; VerifyCalls = 1 },
  @{ Mode = 'baseline-pending-appearance'; VerifyCalls = 0 }
)) {
  Reset-CommunityTransactionFixture -Mode $baselineCase.Mode
  Assert-CommunityValueRejected -Label $baselineCase.Mode -Action {
    Invoke-DreamSkinCommunityThemeTransaction -Imported $mockImported `
      -Paths $mockPaths -WorkRoot 'work' -StateRoot 'state'
  }
  if ($script:communityBaselineVerifyCalls -ne $baselineCase.VerifyCalls -or
    $script:communitySnapshotCalls -ne 0 -or $script:communityWriteCalls -ne 0 -or
    $script:communityPauseWriteCalls -ne 0 -or $script:communityStartCalls -ne 0 -or
    $script:communityRestoreCalls -ne 0 -or $script:communityLockDepth -ne 0) {
    throw "Click-time baseline $($baselineCase.Mode) changed active state or started the client."
  }
  Assert-CommunityIntSequence -Actual $script:communityLockTimeouts -Expected @(0) `
    -Label "Click-time baseline $($baselineCase.Mode) lock"
}

Reset-CommunityTransactionFixture -Mode 'baseline-off'
$coldBaseline = Ensure-DreamSkinCommunityActiveBaseline -Paths $mockPaths `
  -StateRoot 'state'
$coldStartSuccess = Invoke-DreamSkinCommunityThemeTransaction -Imported $mockImported `
  -Paths $mockPaths -WorkRoot 'work' -StateRoot 'state'
if ($coldBaseline.ContentFingerprint -cne $script:communityRollbackFingerprint -or
  $coldStartSuccess.ContentFingerprint -cne $script:communityExpectedFingerprint -or
  $script:communityStartCalls -ne 2 -or $script:communityBaselineVerifyCalls -ne 2 -or
  $script:communitySnapshotCalls -ne 1 -or $script:communityWriteCalls -ne 1 -or
  $script:communityRestoreCalls -ne 0 -or $script:communityLockDepth -ne 0 -or
  $script:communityMaxLockDepth -ne 1) {
  throw 'A missing live session did not establish and verify the old-theme baseline before applying.'
}
Assert-CommunityIntSequence -Actual $script:communityStartTimeouts `
  -Expected @(180000, 180000) -Label 'Cold-session baseline and candidate starts'
Assert-CommunityIntSequence -Actual $script:communityLockTimeouts `
  -Expected @(0, 180000, 0, 180000) -Label 'Cold-session baseline locks'

foreach ($coldFailureMode in @('baseline-bootstrap-failure', 'baseline-bootstrap-no-session')) {
  Reset-CommunityTransactionFixture -Mode $coldFailureMode
  Assert-CommunityValueRejected -Label $coldFailureMode -Action {
    Ensure-DreamSkinCommunityActiveBaseline -Paths $mockPaths -StateRoot 'state'
  }
  if ($script:communityStartCalls -ne 1 -or $script:communitySnapshotCalls -ne 0 -or
    $script:communityWriteCalls -ne 0 -or $script:communityRestoreCalls -ne 0 -or
    $script:communityPauseWriteCalls -ne 0 -or $script:communityLockDepth -ne 0) {
    throw "Cold-session failure $coldFailureMode changed active state or retried without a baseline."
  }
}

Reset-CommunityTransactionFixture -Mode 'baseline-snapshot-changed'
Assert-CommunityValueRejected -Label 'an active theme changed while its rollback snapshot was copied' -Action {
  Invoke-DreamSkinCommunityThemeTransaction -Imported $mockImported `
    -Paths $mockPaths -WorkRoot 'work' -StateRoot 'state'
}
if ($script:communityBaselineVerifyCalls -ne 1 -or
  $script:communitySnapshotCalls -ne 1 -or $script:communityWriteCalls -ne 0 -or
  $script:communityPauseWriteCalls -ne 0 -or $script:communityStartCalls -ne 0 -or
  $script:communityRestoreCalls -ne 0 -or $script:communityLockDepth -ne 0) {
  throw 'A post-verification active-theme change reached an active write or client start.'
}
Assert-CommunityIntSequence -Actual $script:communityLockTimeouts -Expected @(0) `
  -Label 'Post-verification active-theme change lock'

Reset-CommunityTransactionFixture -Mode 'success'
$success = Invoke-DreamSkinCommunityThemeTransaction -Imported $mockImported `
  -Paths $mockPaths -WorkRoot 'work' -StateRoot 'state'
if ($success.ContentFingerprint -cne $script:communityExpectedFingerprint -or
  $script:communityCurrentFingerprint -cne $script:communityExpectedFingerprint -or
  $script:communityStartCalls -ne 1 -or $script:communityRestoreCalls -ne 0 -or
  $script:communityBaselineVerifyCalls -ne 1 -or
  $script:communitySnapshotCalls -ne 1 -or $script:communityWriteCalls -ne 1 -or
  $script:communityPauseWriteCalls -ne 0 -or
  $script:communityLockDepth -ne 0 -or $script:communityMaxLockDepth -ne 1) {
  throw 'The mocked community apply success transaction did not serialize and verify exactly once.'
}
foreach ($requiredBaselineArgument in @('--verify', '--theme-dir', 'active', '--timeout-ms', '30000')) {
  if ($script:communityBaselineVerifyArguments -cnotcontains $requiredBaselineArgument) {
    throw "The click-time renderer verification omitted argument: $requiredBaselineArgument"
  }
}
Assert-CommunityIntSequence -Actual $script:communityStartTimeouts -Expected @(180000) `
  -Label 'Successful child start timeout'
Assert-CommunityIntSequence -Actual $script:communityLockTimeouts -Expected @(0, 180000) `
  -Label 'Successful operation lock'

Reset-CommunityTransactionFixture -Mode 'wrong-private-fingerprint'
Assert-CommunityValueRejected -Label 'a wrong private imported-content fingerprint' -Action {
  Invoke-DreamSkinCommunityThemeTransaction -Imported $mockImported `
    -Paths $mockPaths -WorkRoot 'work' -StateRoot 'state'
}
if ($script:communityStartCalls -ne 0 -or
  $script:communityCurrentFingerprint -cne $script:communityRollbackFingerprint -or
  $script:communitySnapshotCalls -ne 0 -or $script:communityWriteCalls -ne 0) {
  throw 'A wrong imported-content fingerprint reached the active theme or renderer.'
}
Assert-CommunityIntSequence -Actual $script:communityLockTimeouts -Expected @() `
  -Label 'Wrong private fingerprint lock'

Reset-CommunityTransactionFixture -Mode 'partial-write-failure'
$partialWriteError = $null
try {
  $null = Invoke-DreamSkinCommunityThemeTransaction -Imported $mockImported `
    -Paths $mockPaths -WorkRoot 'work' -StateRoot 'state'
} catch {
  $partialWriteError = $_
}
if ($null -eq $partialWriteError -or
  "$($partialWriteError.Exception.Data['DreamSkinRecovery'])" -cne 'Verified' -or
  $script:communityCurrentFingerprint -cne $script:communityRollbackFingerprint -or
  $script:communityRestoreCalls -ne 1 -or $script:communityStartCalls -ne 1) {
  throw 'A partial active-theme write did not restore and visibly verify the exact prior theme.'
}
Assert-CommunityIntSequence -Actual $script:communityStartTimeouts -Expected @(180000) `
  -Label 'Partial-write recovery start timeout'
Assert-CommunityIntSequence -Actual $script:communityLockTimeouts -Expected @(0, 180000) `
  -Label 'Partial-write recovery lock'

Reset-CommunityTransactionFixture -Mode 'startup-failure'
$startupError = $null
try {
  $null = Invoke-DreamSkinCommunityThemeTransaction -Imported $mockImported `
    -Paths $mockPaths -WorkRoot 'work' -StateRoot 'state'
} catch {
  $startupError = $_
}
if ($null -eq $startupError -or
  "$($startupError.Exception.Data['DreamSkinRecovery'])" -cne 'Verified' -or
  $script:communityCurrentFingerprint -cne $script:communityRollbackFingerprint -or
  $script:communityRestoreCalls -ne 1 -or $script:communityStartCalls -ne 2) {
  throw 'A failed imported renderer did not restart and visibly verify the exact rollback theme.'
}
Assert-CommunityIntSequence -Actual $script:communityStartTimeouts `
  -Expected @(180000, 180000) -Label 'Renderer rollback start timeout'
Assert-CommunityIntSequence -Actual $script:communityLockTimeouts `
  -Expected @(0, 180000, 180000) -Label 'Renderer rollback lock'

Reset-CommunityTransactionFixture -Mode 'preserved-rendered'
$preservedRenderedError = $null
try {
  $null = Invoke-DreamSkinCommunityThemeTransaction -Imported $mockImported `
    -Paths $mockPaths -WorkRoot 'work' -StateRoot 'state'
} catch {
  $preservedRenderedError = $_
}
if ($null -eq $preservedRenderedError -or
  "$($preservedRenderedError.Exception.Data['DreamSkinRecovery'])" -cne 'Failed' -or
  $script:communityCurrentFingerprint -cne $script:communityExpectedFingerprint -or
  $script:communityRestoreCalls -ne 0 -or $script:communityStartCalls -ne 1) {
  throw 'A preserved rendered child result rewrote active-theme files into mixed state.'
}

Reset-CommunityTransactionFixture -Mode 'rollback-write-failure'
$rollbackWriteError = $null
try {
  $null = Invoke-DreamSkinCommunityThemeTransaction -Imported $mockImported `
    -Paths $mockPaths -WorkRoot 'work' -StateRoot 'state'
} catch {
  $rollbackWriteError = $_
}
if ($null -eq $rollbackWriteError -or
  "$($rollbackWriteError.Exception.Data['DreamSkinRecovery'])" -cne 'Failed' -or
  "$($rollbackWriteError.Exception.Data['DreamSkinRollbackSnapshot'])" -notlike '*active-before' -or
  "$($rollbackWriteError.Exception.Data['DreamSkinRollbackFingerprint'])" -cne
    $script:communityRollbackFingerprint -or
  $script:communityRestoreCalls -ne 1 -or $script:communityStartCalls -ne 1) {
  throw 'A rollback file failure was not reported as an unverified recovery.'
}
Assert-CommunityIntSequence -Actual $script:communityStartTimeouts -Expected @(180000) `
  -Label 'Rollback-write failure start timeout'
Assert-CommunityIntSequence -Actual $script:communityLockTimeouts -Expected @(0, 180000) `
  -Label 'Rollback-write failure lock'

Reset-CommunityTransactionFixture -Mode 'rollback-renderer-failure'
$rollbackRendererError = $null
try {
  $null = Invoke-DreamSkinCommunityThemeTransaction -Imported $mockImported `
    -Paths $mockPaths -WorkRoot 'work' -StateRoot 'state'
} catch {
  $rollbackRendererError = $_
}
if ($null -eq $rollbackRendererError -or
  "$($rollbackRendererError.Exception.Data['DreamSkinRecovery'])" -cne 'Failed' -or
  $script:communityCurrentFingerprint -cne $script:communityRollbackFingerprint -or
  $script:communityRestoreCalls -ne 1 -or $script:communityStartCalls -ne 2) {
  throw 'A rollback renderer failure was incorrectly reported as verified recovery.'
}
Assert-CommunityIntSequence -Actual $script:communityStartTimeouts `
  -Expected @(180000, 180000) -Label 'Rollback-renderer start timeout'
Assert-CommunityIntSequence -Actual $script:communityLockTimeouts `
  -Expected @(0, 180000, 180000) -Label 'Rollback-renderer lock'

Reset-CommunityTransactionFixture -Mode 'superseded'
$supersededError = $null
try {
  $null = Invoke-DreamSkinCommunityThemeTransaction -Imported $mockImported `
    -Paths $mockPaths -WorkRoot 'work' -StateRoot 'state'
} catch {
  $supersededError = $_
}
if ($null -eq $supersededError -or
  "$($supersededError.Exception.Data['DreamSkinRecovery'])" -cne 'Superseded' -or
  $script:communityCurrentFingerprint -cne $script:communityOtherFingerprint -or
  $script:communityRestoreCalls -ne 0) {
  throw 'A concurrent user theme selection was overwritten by stale rollback.'
}
Assert-CommunityIntSequence -Actual $script:communityStartTimeouts -Expected @(180000) `
  -Label 'Superseded selection start timeout'
Assert-CommunityIntSequence -Actual $script:communityLockTimeouts -Expected @(0, 180000) `
  -Label 'Superseded selection lock'

Reset-CommunityTransactionFixture -Mode 'pause-superseded'
$pauseSupersededError = $null
try {
  $null = Invoke-DreamSkinCommunityThemeTransaction -Imported $mockImported `
    -Paths $mockPaths -WorkRoot 'work' -StateRoot 'state'
} catch {
  $pauseSupersededError = $_
}
if ($null -eq $pauseSupersededError -or
  "$($pauseSupersededError.Exception.Data['DreamSkinRecovery'])" -cne 'Superseded' -or
  -not $script:communityPaused -or $script:communityPauseWriteCalls -ne 0 -or
  $script:communityRestoreCalls -ne 0) {
  throw 'A newer pause choice was cleared or overwritten by stale one-click recovery.'
}
Assert-CommunityIntSequence -Actual $script:communityStartTimeouts -Expected @(180000) `
  -Label 'Pause supersession start timeout'
Assert-CommunityIntSequence -Actual $script:communityLockTimeouts -Expected @(0, 180000) `
  -Label 'Pause supersession lock'

Reset-CommunityTransactionFixture -Mode 'recovery-lock-timeout'
$recoveryLockError = $null
try {
  $null = Invoke-DreamSkinCommunityThemeTransaction -Imported $mockImported `
    -Paths $mockPaths -WorkRoot 'work' -StateRoot 'state'
} catch {
  $recoveryLockError = $_
}
if ($null -eq $recoveryLockError -or
  "$($recoveryLockError.Exception.Data['DreamSkinRecovery'])" -cne 'Failed' -or
  "$($recoveryLockError.Exception.Data['DreamSkinRollbackSnapshot'])" -notlike '*active-before' -or
  "$($recoveryLockError.Exception.Data['DreamSkinRollbackFingerprint'])" -cne
    $script:communityRollbackFingerprint -or
  $script:communityRestoreCalls -ne 0 -or $script:communityStartCalls -ne 1) {
  throw 'A bounded recovery lock timeout did not retain exact rollback evidence.'
}
Assert-CommunityIntSequence -Actual $script:communityStartTimeouts -Expected @(180000) `
  -Label 'Recovery lock-timeout start timeout'
Assert-CommunityIntSequence -Actual $script:communityLockTimeouts -Expected @(0, 180000) `
  -Label 'Recovery lock-timeout lock'

if ($isWindowsHost) {
  $retentionRoot = Join-Path ([System.IO.Path]::GetTempPath()) `
    ('dreamskin-community-retention-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $retentionRoot -Force | Out-Null
  try {
    $retentionPaths = [pscustomobject]@{ Root = $retentionRoot }
    $retainedPaths = @()
    foreach ($index in 1..2) {
      Reset-CommunityTransactionFixture -Mode 'success'
      $retentionWork = Join-Path $retentionRoot ('.community-apply-test-' + $index)
      $retentionSnapshot = Join-Path $retentionWork 'active-before'
      New-Item -ItemType Directory -Path $retentionSnapshot -Force | Out-Null
      $retainedPaths += Move-DreamSkinCommunityRollbackSnapshot `
        -WorkRoot $retentionWork -Paths $retentionPaths `
        -ExpectedContentFingerprint $script:communityRollbackFingerprint
    }
    $missingRetained = @($retainedPaths | Where-Object {
        -not (Test-Path -LiteralPath $_ -PathType Container)
      })
    if ($retainedPaths.Count -ne 2 -or $retainedPaths[0] -ceq $retainedPaths[1] -or
      $missingRetained.Count -ne 0) {
      throw 'Rollback snapshots were not atomically retained under unique managed paths.'
    }

    Reset-CommunityTransactionFixture -Mode 'rollback-snapshot-mismatch'
    $mismatchWork = Join-Path $retentionRoot '.community-apply-mismatch'
    $mismatchSnapshot = Join-Path $mismatchWork 'active-before'
    New-Item -ItemType Directory -Path $mismatchSnapshot -Force | Out-Null
    Assert-CommunityValueRejected -Label 'a changed rollback snapshot' -Action {
      Move-DreamSkinCommunityRollbackSnapshot -WorkRoot $mismatchWork `
        -Paths $retentionPaths `
        -ExpectedContentFingerprint $script:communityRollbackFingerprint
    }
    if (-not (Test-Path -LiteralPath $mismatchSnapshot -PathType Container)) {
      throw 'A changed rollback snapshot was removed instead of being preserved in place.'
    }
  } finally {
    Remove-Item -LiteralPath $retentionRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Write-Host 'PASS: Windows community links, metadata, identity, serialized apply, and verified rollback are fail-closed.'
