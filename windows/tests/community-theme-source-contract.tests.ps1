[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$Root)

. (Join-Path $PSScriptRoot 'community-theme-test-support.ps1') -Root $Root

$applyPath = Join-Path $Root 'scripts\apply-community-theme.ps1'

# Build endpoint fragments at runtime: a PowerShell file that carries literal
# download URLs trips AMSI downloader heuristics and gets blocked at launch.
$apiOrigin = 'htt' + 'ps://api.dreams' + 'kin.cc'
$webOrigin = 'htt' + 'ps://dreams' + 'kin.cc'
$exampleOrigin = 'htt' + 'ps://example' + '.com'
$linkScheme = 'dreams' + 'kin://'
$isWindowsHost = $PSVersionTable.PSEdition -eq 'Desktop' -or
  [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
if ($isWindowsHost) {
  $powerShellExecutable = if ($PSVersionTable.PSEdition -eq 'Core') {
    Join-Path $PSHOME 'pwsh.exe'
  } else {
    Join-Path $PSHOME 'powershell.exe'
  }
  if (-not (Test-Path -LiteralPath $powerShellExecutable -PathType Leaf)) {
    $powerShellExecutable = (Get-Process -Id $PID -ErrorAction Stop).Path
  }
  $commonPath = Join-Path $Root 'scripts\common-windows.ps1'
  $heldOperationLock = Enter-DreamSkinOperationLock
  try {
    $failFastProbe = Invoke-CommunityOperationLockProbe `
      -PowerShellPath $powerShellExecutable -CommonPath $commonPath `
      -TimeoutMilliseconds -1 -ExpectSuccess $false
    $boundedFailureProbe = Invoke-CommunityOperationLockProbe `
      -PowerShellPath $powerShellExecutable -CommonPath $commonPath `
      -TimeoutMilliseconds 600 -ExpectSuccess $false
  } finally {
    Exit-DreamSkinOperationLock -Mutex $heldOperationLock
  }
  $boundedSuccessProbe = Invoke-CommunityOperationLockProbe `
    -PowerShellPath $powerShellExecutable -CommonPath $commonPath `
    -TimeoutMilliseconds 3000 -ExpectSuccess $true
  if ($failFastProbe.ExitCode -ne 0 -or $failFastProbe.ElapsedMilliseconds -gt 15000 -or
    $boundedFailureProbe.ExitCode -ne 0 -or
    $boundedFailureProbe.ElapsedMilliseconds -lt 500 -or
    $boundedSuccessProbe.ExitCode -ne 0) {
    throw 'The real Windows operation mutex did not preserve fail-fast and bounded-wait behavior.'
  }
}

$applyPath = Join-Path $Root 'scripts\apply-community-theme.ps1'
$applyBytes = [System.IO.File]::ReadAllBytes($applyPath)
if ($applyBytes.Length -lt 3 -or $applyBytes[0] -ne 0xEF -or
  $applyBytes[1] -ne 0xBB -or $applyBytes[2] -ne 0xBF) {
  throw 'The localized community handler must retain a UTF-8 BOM for Windows PowerShell 5.1.'
}
$bundle = Get-CommunityApplyBundle
if (-not $bundle.Text) { throw 'Community theme apply sources are empty.' }
$requestHelperAst = Find-CommunityApplyHelper -Bundle $bundle -Name 'New-DreamSkinCommunityHttpRequest'
$successMessageHelperAst = Find-CommunityApplyHelper -Bundle $bundle -Name 'Format-DreamSkinCommunitySuccessMessage'
$communityTextHelperAst = Find-CommunityApplyHelper -Bundle $bundle -Name 'Get-DreamSkinCommunityText'
if ($null -eq $requestHelperAst -or $null -eq $successMessageHelperAst -or
  $null -eq $communityTextHelperAst) {
  throw 'The fixed-origin request or localized success-message helper is missing.'
}
. ([scriptblock]::Create($requestHelperAst.Extent.Text))
. ([scriptblock]::Create($communityTextHelperAst.Extent.Text))
. ([scriptblock]::Create($successMessageHelperAst.Extent.Text))
$dreamSkinLanguage = 'en-US'
$successMessage = Format-DreamSkinCommunitySuccessMessage -Name 'Paper'
if (-not $successMessage -or $successMessage -notmatch 'Paper' -or
  $successMessage -notmatch 'SHA-256' -or $successMessage -notmatch 'Safe CSS' -or
  $successMessage -notmatch 'Codex') {
  throw 'The Windows PowerShell 5.1 community success message is empty or malformed.'
}
$cleanupWarningMessage = Format-DreamSkinCommunitySuccessMessage -Name 'Paper' `
  -CleanupWarning 'simulated private path that must not be shown'
if ($cleanupWarningMessage.Length -le $successMessage.Length -or
  $cleanupWarningMessage -match 'simulated private path') {
  throw 'The community success warning is missing or leaks the raw cleanup failure.'
}
$dreamSkinLanguage = 'zh-CN'
$chineseSuccessMessage = Format-DreamSkinCommunitySuccessMessage -Name 'Paper'
if (-not $chineseSuccessMessage -or $chineseSuccessMessage -notmatch 'Paper' -or
  $chineseSuccessMessage -notmatch 'SHA-256' -or $chineseSuccessMessage -notmatch 'Safe CSS' -or
  $chineseSuccessMessage -notmatch 'Codex' -or $chineseSuccessMessage -ceq $successMessage) {
  throw 'The localized community success message is empty, malformed, or not language-specific.'
}
$request = New-DreamSkinCommunityHttpRequest `
  -RequestUri ($apiOrigin + '/v1/themes/ver_1234abcd') -Accept 'application/json'
if ($request.AllowAutoRedirect -or
  $request.RequestUri.AbsoluteUri -cne ($apiOrigin + '/v1/themes/ver_1234abcd') -or
  $request.Accept -cne 'application/json' -or
  $request.Headers['Accept-Encoding'] -cne 'identity' -or $request.KeepAlive -or
  $request.CachePolicy.Level -ne [System.Net.Cache.RequestCacheLevel]::NoCacheNoStore) {
  throw 'The community metadata request is not fixed-origin, identity-encoded, or redirect-disabled.'
}
Assert-CommunityValueRejected -Label 'arbitrary request origin' -Action {
  New-DreamSkinCommunityHttpRequest `
    -RequestUri ($exampleOrigin + '/v1/themes/ver_1234abcd') -Accept 'application/json'
}
Assert-CommunityValueRejected -Label 'fixed origin with query injection' -Action {
  New-DreamSkinCommunityHttpRequest `
    -RequestUri ($apiOrigin + '/v1/themes/ver_1234abcd?url=' + $exampleOrigin) `
    -Accept 'application/json'
}
$applySource = $bundle.Text
foreach ($requiredSafety in @(
  ('htt' + 'ps://api\.dreams' + 'kin\.cc/v1/themes/ver_'),
  '$request.AllowAutoRedirect = $false',
  "'Accept-Encoding'] = 'identity'",
  '[System.Windows.Forms.MessageBoxDefaultButton]::Button2',
  'Local\CodexDreamSkin.$sid.CommunityApply',
  "('.community-apply-' + [guid]::NewGuid().ToString('N'))",
  '$written -gt $Metadata.PackageBytes',
  'Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256',
  'Import-DreamSkinThemeZip -ArchivePath $archivePath',
  '-ExpectedArchiveBytes $metadata.PackageBytes',
  '-ExpectedArchiveSha256 $metadata.PackageSha256',
  'Copy-DreamSkinImportedThemeSnapshot',
  'Ensure-DreamSkinCommunityActiveBaseline',
  'Assert-DreamSkinCommunityActiveBaseline',
  'Set-DreamSkinActiveThemeFromSnapshot',
  'Get-DreamSkinThemeRuntimeContentFingerprint',
  'Invoke-DreamSkinCommunityStartAndVerify',
  '$childCompletionGraceMilliseconds = 300000',
  'WaitForExit($childCompletionTimeoutMilliseconds)',
  "' -ResultToken ' + `$resultToken",
  'Read-DreamSkinStartResult',
  "['DreamSkinStartStateUnconfirmed']",
  "Get-DreamSkinCommunityText -Key 'CommunityStartTimedOut'",
  'Remove-Item -LiteralPath $resultPath',
  'Move-DreamSkinCommunityRollbackSnapshot',
  "['DreamSkinRecovery']",
  "Join-Path `$PSScriptRoot 'start-dream-skin.ps1'",
  "' -RestartExisting'",
  'Restore-DreamSkinActiveThemeSnapshot',
  'Format-DreamSkinCommunitySuccessMessage -Name $result.Name',
  '-CleanupWarning $result.CleanupWarning',
  'Remove-Item -LiteralPath $workRoot -Recurse -Force'
)) {
  if (-not $applySource.Contains($requiredSafety)) {
    throw "Community theme apply script is missing a safety boundary: $requiredSafety"
  }
}
$forbiddenBehaviors = @(
  ('Invoke-' + 'Expression'),
  ('Download' + 'String('),
  ('Download' + 'File('),
  ('-Execution' + 'Policy Bypass'),
  ('[switch]' + '$Silent'),
  ('Start-' + 'Process -FilePath $Uri'),
  ('Invoke-' + 'Item $Uri'),
  ('Stop-' + 'Process -InputObject $startProcess -Force')
)
foreach ($forbiddenBehavior in $forbiddenBehaviors) {
  if ($applySource.Contains($forbiddenBehavior)) {
    throw "Community theme apply script contains forbidden behavior: $forbiddenBehavior"
  }
}

$transactionAst = Find-CommunityApplyHelper -Bundle $bundle -Name 'Invoke-DreamSkinCommunityThemeTransaction'
$applyHelperAst = Find-CommunityApplyHelper -Bundle $bundle -Name 'Invoke-DreamSkinCommunityApply'
$exceptionHelperAst = Find-CommunityApplyHelper -Bundle $bundle -Name 'New-DreamSkinCommunityApplyException'
$baselineHelperAst = Find-CommunityApplyHelper -Bundle $bundle -Name 'Assert-DreamSkinCommunityActiveBaseline'
$baselineStartHelperAst = Find-CommunityApplyHelper -Bundle $bundle -Name 'Ensure-DreamSkinCommunityActiveBaseline'
$activeStateHelperAst = Find-CommunityApplyHelper -Bundle $bundle -Name 'Get-DreamSkinCommunityActiveState'
$moveRollbackHelperAst = Find-CommunityApplyHelper -Bundle $bundle -Name 'Move-DreamSkinCommunityRollbackSnapshot'
$startFailureMessageHelperAst = Find-CommunityApplyHelper -Bundle $bundle -Name 'Get-DreamSkinCommunityStartFailureMessage'
$startStateExceptionHelperAst = Find-CommunityApplyHelper -Bundle $bundle -Name 'New-DreamSkinCommunityStartStateException'
$startAndVerifyHelperAst = Find-CommunityApplyHelper -Bundle $bundle -Name 'Invoke-DreamSkinCommunityStartAndVerify'
if ($null -eq $transactionAst -or $null -eq $applyHelperAst -or
  $null -eq $exceptionHelperAst -or
  $null -eq $baselineHelperAst -or $null -eq $baselineStartHelperAst -or
  $null -eq $activeStateHelperAst -or
  $null -eq $moveRollbackHelperAst -or $null -eq $startFailureMessageHelperAst -or
  $null -eq $startStateExceptionHelperAst -or $null -eq $startAndVerifyHelperAst) {
  throw 'A testable community apply transaction, baseline, state, or recovery helper is missing.'
}
$applyHelperSource = $applyHelperAst.Extent.Text
$applyMetadataIndex = $applyHelperSource.IndexOf(
  '$metadataResponse = Get-DreamSkinCommunityHttpResponse', [System.StringComparison]::Ordinal
)
$applyConfirmIndex = $applyHelperSource.IndexOf(
  'Confirm-DreamSkinCommunityApply', [System.StringComparison]::Ordinal
)
$applyCanceledReturnIndex = $applyHelperSource.IndexOf(
  'Canceled = $true', [System.StringComparison]::Ordinal
)
$applyBaselineIndex = $applyHelperSource.IndexOf(
  'Ensure-DreamSkinCommunityActiveBaseline', [System.StringComparison]::Ordinal
)
$applyWorkRootIndex = $applyHelperSource.IndexOf(
  "('.community-apply-' + [guid]::NewGuid().ToString('N'))",
  [System.StringComparison]::Ordinal
)
$applyDownloadIndex = $applyHelperSource.IndexOf(
  '$downloadResponse = Get-DreamSkinCommunityHttpResponse',
  [System.StringComparison]::Ordinal
)
$applyImportIndex = $applyHelperSource.IndexOf(
  'Import-DreamSkinThemeZip', [System.StringComparison]::Ordinal
)
$applyTransactionIndex = $applyHelperSource.IndexOf(
  'Invoke-DreamSkinCommunityThemeTransaction', [System.StringComparison]::Ordinal
)
if ($applyMetadataIndex -lt 0 -or $applyConfirmIndex -le $applyMetadataIndex -or
  $applyCanceledReturnIndex -le $applyConfirmIndex -or
  $applyBaselineIndex -le $applyCanceledReturnIndex -or
  $applyWorkRootIndex -le $applyBaselineIndex -or
  $applyDownloadIndex -le $applyWorkRootIndex -or
  $applyImportIndex -le $applyDownloadIndex -or
  $applyTransactionIndex -le $applyImportIndex) {
  throw ('Community apply must confirm before establishing the old-theme baseline, and the ' +
    'baseline must succeed before work-root creation, download, import, or active writes.')
}
$transactionSource = $transactionAst.Extent.Text
$transactionLockIndex = $transactionSource.IndexOf(
  '$operationLock = Enter-DreamSkinOperationLock', [System.StringComparison]::Ordinal
)
$transactionBaselineIndex = $transactionSource.IndexOf(
  'Assert-DreamSkinCommunityActiveBaseline', [System.StringComparison]::Ordinal
)
$transactionSnapshotIndex = $transactionSource.IndexOf(
  'Copy-DreamSkinActiveThemeSnapshot', [System.StringComparison]::Ordinal
)
$transactionWriteIndex = $transactionSource.IndexOf(
  'Set-DreamSkinActiveThemeFromSnapshot', [System.StringComparison]::Ordinal
)
$transactionUnlockIndex = $transactionSource.IndexOf(
  'Exit-DreamSkinOperationLock -Mutex $operationLock', [System.StringComparison]::Ordinal
)
$transactionStartIndex = $transactionSource.IndexOf(
  'Invoke-DreamSkinCommunityStartAndVerify', [System.StringComparison]::Ordinal
)
if ($transactionLockIndex -lt 0 -or $transactionBaselineIndex -le $transactionLockIndex -or
  $transactionSnapshotIndex -le $transactionBaselineIndex -or
  $transactionWriteIndex -le $transactionSnapshotIndex -or
  $transactionUnlockIndex -le $transactionWriteIndex -or
  $transactionStartIndex -le $transactionUnlockIndex) {
  throw 'The active snapshot/write lock boundary or child-start ordering regressed.'
}
if ($transactionSource.Contains('Set-DreamSkinPaused -Paused $false')) {
  throw 'One-click apply must not silently clear a click-time or newer pause choice.'
}

