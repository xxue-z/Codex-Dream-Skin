[CmdletBinding(DefaultParameterSetName = 'Apply')]
param(
  [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'Apply')]
  [ValidateNotNullOrEmpty()]
  [string]$Uri,
  [Parameter(Mandatory = $true, ParameterSetName = 'Functions')]
  [switch]$FunctionsOnly
)


. (Join-Path $PSScriptRoot 'ds-cm-msg.ps1')
. (Join-Path $PSScriptRoot 'ds-cm-req.ps1')
. (Join-Path $PSScriptRoot 'ds-cm-data.ps1')
. (Join-Path $PSScriptRoot 'ds-cm-snap.ps1')

if (-not $FunctionsOnly) {
  $ErrorActionPreference = 'Stop'
  Set-StrictMode -Version 2.0
  . (Join-Path $PSScriptRoot 'common-windows.ps1')
  . (Join-Path $PSScriptRoot 'theme-windows.ps1')
  . (Join-Path $PSScriptRoot 'localization-windows.ps1')
  $dreamSkinLanguage = Resolve-DreamSkinLanguage `
    -StateRoot (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin')
}

function Invoke-DreamSkinCommunityApply {
  param([Parameter(Mandatory = $true)][string]$ApplyUri)
  $versionId = Resolve-DreamSkinCommunityApplyUri -Uri $ApplyUri
  $endpoints = Get-DreamSkinCommunityThemeEndpoints -VersionId $versionId
  $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $mutex = [System.Threading.Mutex]::new($false, "Local\CodexDreamSkin.$sid.CommunityApply")
  $acquired = $false
  $workRoot = $null
  $retainWorkRoot = $false
  $stateRoot = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'
  try {
    try { $acquired = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] {
      $acquired = $true
    }
    if (-not $acquired) {
      throw 'Another one-click theme apply is already running. Try again shortly.'
    }

    $metadataResponse = Get-DreamSkinCommunityHttpResponse `
      -RequestUri $endpoints.MetadataUri -Accept 'application/json'
    try {
      $metadata = Read-DreamSkinCommunityMetadataResponse -Response $metadataResponse `
        -ExpectedVersionId $versionId
    } finally {
      $metadataResponse.Dispose()
    }
    if (-not (Confirm-DreamSkinCommunityApply -Metadata $metadata)) {
      return [pscustomobject]@{ Canceled = $true; Name = $metadata.Name }
    }

    $paths = Get-DreamSkinThemePaths -StateRoot $stateRoot
    $null = Ensure-DreamSkinCommunityActiveBaseline -Paths $paths `
      -StateRoot $stateRoot -OperationLockTimeoutMilliseconds 180000
    Ensure-DreamSkinManagedDirectory -Path $paths.Root -Root $paths.Root
    $workRoot = Join-Path $paths.Root ('.community-apply-' + [guid]::NewGuid().ToString('N'))
    Ensure-DreamSkinManagedDirectory -Path $workRoot -Root $paths.Root
    $archivePath = Join-Path $workRoot 'theme.zip'
    Assert-DreamSkinNoReparseComponents -Path $archivePath

    $downloadResponse = Get-DreamSkinCommunityHttpResponse `
      -RequestUri $endpoints.DownloadUri -Accept 'application/zip'
    try {
      Save-DreamSkinCommunityDownload -Response $downloadResponse -Metadata $metadata `
        -ArchivePath $archivePath
    } finally {
      $downloadResponse.Dispose()
    }

    $imported = Import-DreamSkinThemeZip -ArchivePath $archivePath -StateRoot $stateRoot `
      -ExpectedArchiveBytes $metadata.PackageBytes `
      -ExpectedArchiveSha256 $metadata.PackageSha256
    if ($imported.SafeCssStatus -cne 'validated' -or
      $imported.Status -notin @('Imported', 'Duplicate') -or
      $imported.ContentFingerprint -isnot [string] -or
      $imported.ContentFingerprint -cnotmatch '\A[a-f0-9]{64}\z') {
      throw 'The downloaded theme did not complete the strict ZIP and Safe CSS import.'
    }
    $cleanupProperty = $imported.PSObject.Properties['CleanupWarning']
    $cleanupWarning = if ($null -ne $cleanupProperty) { "$($cleanupProperty.Value)" } else { '' }
    try {
      $null = Invoke-DreamSkinCommunityThemeTransaction -Imported $imported -Paths $paths `
        -WorkRoot $workRoot -StateRoot $stateRoot
    } catch {
      $transactionError = $_
      if ("$($transactionError.Exception.Data['DreamSkinRecovery'])" -ceq 'Failed') {
        $expectedSnapshot = [System.IO.Path]::GetFullPath((Join-Path $workRoot 'active-before'))
        $recordedSnapshot = "$($transactionError.Exception.Data['DreamSkinRollbackSnapshot'])"
        $rollbackFingerprint = "$($transactionError.Exception.Data['DreamSkinRollbackFingerprint'])"
        if ($recordedSnapshot -and
          [System.IO.Path]::GetFullPath($recordedSnapshot).Equals(
            $expectedSnapshot,
            [System.StringComparison]::OrdinalIgnoreCase
          ) -and (Test-Path -LiteralPath $expectedSnapshot -PathType Container)) {
          try {
            $retainedSnapshot = Move-DreamSkinCommunityRollbackSnapshot `
              -WorkRoot $workRoot -Paths $paths `
              -ExpectedContentFingerprint $rollbackFingerprint
            $transactionError.Exception.Data['DreamSkinRollbackPath'] = $retainedSnapshot
          } catch {
            $retainWorkRoot = $true
            $transactionError.Exception.Data['DreamSkinRollbackPath'] = $expectedSnapshot
            $transactionError.Exception.Data['DreamSkinWorkRootRetained'] = $true
            $transactionError.Exception.Data['DreamSkinRollbackPreservationError'] = `
              $_.Exception.Message
          }
        }
      }
      throw $transactionError
    }
    return [pscustomobject]@{
      Canceled = $false
      Name = $metadata.Name
      CleanupWarning = $cleanupWarning
    }
  } finally {
    if (-not $retainWorkRoot -and $workRoot -and (Test-Path -LiteralPath $workRoot)) {
      Assert-DreamSkinNoReparseComponents -Path $workRoot
      Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($acquired) { try { $mutex.ReleaseMutex() } catch {} }
    $mutex.Dispose()
  }
}

if ($FunctionsOnly) { return }

$previousProtocol = [System.Net.ServicePointManager]::SecurityProtocol
try {
  [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
  $result = Invoke-DreamSkinCommunityApply -ApplyUri $Uri
  if (-not $result.Canceled) {
    Show-DreamSkinCommunityMessage `
      -Message (Format-DreamSkinCommunitySuccessMessage -Name $result.Name `
        -CleanupWarning $result.CleanupWarning)
  }
  exit 0
} catch {
  $recovery = "$($_.Exception.Data['DreamSkinRecovery'])"
  $rollbackPath = "$($_.Exception.Data['DreamSkinRollbackPath'])"
  $workRootRetained = [bool]$_.Exception.Data['DreamSkinWorkRootRetained']
  $recoveryMessage = switch ($recovery) {
    'Verified' { Get-DreamSkinCommunityText -Key 'RecoveryVerified' }
    'Failed' { Get-DreamSkinCommunityText -Key 'RecoveryFailed' }
    'Superseded' { Get-DreamSkinCommunityText -Key 'RecoverySuperseded' }
    default { Get-DreamSkinCommunityText -Key 'RecoveryUnconfirmed' }
  }
  $cleanupMessage = if ($workRootRetained) {
    Get-DreamSkinCommunityText -Key 'RecoveryWorkRetained'
  } elseif ($null -ne $workRoot) {
    Get-DreamSkinCommunityText -Key 'DownloadCleaned'
  }
  $rollbackMessage = if ($rollbackPath) {
    Get-DreamSkinCommunityText -Key 'RollbackSnapshot' -FormatArguments @($rollbackPath)
  } else {
    ''
  }
  $summary = @(
    (Get-DreamSkinCommunityText -Key 'CommunityApplyFailed'),
    $recoveryMessage
  )
  if ($cleanupMessage) { $summary += $cleanupMessage }
  if ($rollbackMessage) { $summary += $rollbackMessage }
  Show-DreamSkinCommunityMessage -Kind Error -Message (
    (($summary -join [Environment]::NewLine) + [Environment]::NewLine +
      [Environment]::NewLine + $_.Exception.Message)
  )
  [Console]::Error.WriteLine($_.Exception.Message)
  if ($recovery -ceq 'Verified') { exit 20 }
  if ($recovery -ceq 'Failed') { exit 21 }
  if ($recovery -ceq 'Superseded') { exit 22 }
  exit 1
} finally {
  [System.Net.ServicePointManager]::SecurityProtocol = $previousProtocol
}
