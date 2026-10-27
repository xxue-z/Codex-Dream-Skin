[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$Root)

$ErrorActionPreference = 'Stop'
. (Join-Path $Root 'scripts\common-windows.ps1')
. (Join-Path $Root 'scripts\theme-windows.ps1')

$stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('dreamskin-video-settings-' + [guid]::NewGuid().ToString('N'))
$customFolder = Join-Path $stateRoot 'custom-videos'
try {
  [void][System.IO.Directory]::CreateDirectory($stateRoot)
  [void][System.IO.Directory]::CreateDirectory($customFolder)

  $defaults = Get-DreamSkinVideoSettings -StateRoot $stateRoot
  if ($defaults.AutoDiscover -ne $true -or $defaults.PollIntervalSeconds -ne 2 -or
      $null -ne $defaults.VideoDirectory -or $defaults.Veil -ne 100) {
    throw 'Video settings defaults are wrong.'
  }
  if ((Get-DreamSkinEffectiveVideoDirectory -StateRoot $stateRoot) -ne (Join-Path $stateRoot 'videos')) {
    throw 'Default effective video directory is wrong.'
  }

  # Legacy softVeil=false migrates to veil=0 while the settings file is absent.
  Write-DreamSkinUtf8FileAtomically -Path (Get-DreamSkinPlaylistStatePath -StateRoot $stateRoot) -Content (
    '{"schemaVersion":1,"index":0,"positionSeconds":0,"muted":true,"paused":false,"softVeil":false}' + "`r`n"
  )
  $legacy = Get-DreamSkinVideoSettings -StateRoot $stateRoot
  if ($legacy.Veil -ne 0) { throw 'Legacy softVeil=false did not migrate to veil=0.' }

  $saved = Set-DreamSkinVideoSettings -StateRoot $stateRoot -AutoDiscover $false `
    -PollIntervalSeconds 10 -Veil 33 -VideoDirectory $customFolder
  if ($saved.AutoDiscover -ne $false -or $saved.PollIntervalSeconds -ne 10 -or
      $saved.Veil -ne 33 -or $saved.VideoDirectory -ne $customFolder) {
    throw 'Video settings did not persist the requested values.'
  }
  $settingsPath = Get-DreamSkinVideoSettingsPath -StateRoot $stateRoot
  $bytes = [System.IO.File]::ReadAllBytes($settingsPath)
  if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    throw 'Video settings file must not include a BOM.'
  }
  if ((Get-DreamSkinEffectiveVideoDirectory -StateRoot $stateRoot) -ne $customFolder) {
    throw 'Custom effective video directory was not resolved.'
  }

  $null = Set-DreamSkinVideoSettings -StateRoot $stateRoot -PollIntervalSeconds 5
  $merged = Get-DreamSkinVideoSettings -StateRoot $stateRoot
  if ($merged.PollIntervalSeconds -ne 5 -or $merged.AutoDiscover -ne $false -or
      $merged.Veil -ne 33 -or $merged.VideoDirectory -ne $customFolder) {
    throw 'Partial video settings update lost existing values.'
  }

  $rejectedInterval = $false
  try { $null = Set-DreamSkinVideoSettings -StateRoot $stateRoot -PollIntervalSeconds 7 }
  catch { $rejectedInterval = $true }
  if (-not $rejectedInterval) { throw 'Unsupported interval was accepted.' }

  $networkRejected = $false
  try { $null = ConvertTo-DreamSkinVideoDirectory -Path '\\server\share' }
  catch { $networkRejected = $true }
  if (-not $networkRejected) { throw 'UNC video folder was accepted.' }

  $file = Join-Path $stateRoot 'not-a-folder.txt'
  [System.IO.File]::WriteAllText($file, 'x')
  $fileRejected = $false
  try { $null = ConvertTo-DreamSkinVideoDirectory -Path $file }
  catch { $fileRejected = $true }
  if (-not $fileRejected) { throw 'A file was accepted as a videos folder.' }

  $normalized = ConvertTo-DreamSkinVideoDirectory -Path $customFolder
  if ($normalized -ne $customFolder) { throw 'Valid videos folder was not normalized.' }

  # Restore default clears only the folder and keeps the other values.
  $null = Set-DreamSkinVideoSettings -StateRoot $stateRoot -ResetVideoDirectory
  $restored = Get-DreamSkinVideoSettings -StateRoot $stateRoot
  if ($null -ne $restored.VideoDirectory -or $restored.Veil -ne 33 -or
      $restored.PollIntervalSeconds -ne 5) {
    throw 'Restore default folder changed unrelated settings.'
  }

  # A corrupt existing file must be rejected by writers, not overwritten.
  [System.IO.File]::WriteAllText($settingsPath, '{')
  $writeRejected = $false
  try { $null = Set-DreamSkinVideoSettings -StateRoot $stateRoot -Veil 12 }
  catch { $writeRejected = $true }
  if (-not $writeRejected) { throw 'Corrupt video settings were overwritten.' }
  $fallback = Get-DreamSkinVideoSettings -StateRoot $stateRoot
  if ($fallback.Veil -ne 0 -or $fallback.PollIntervalSeconds -ne 2) {
    throw 'Corrupt video settings did not fall back to defaults.'
  }

  Write-Output 'PASS: video settings defaults, migration, validation, atomic persistence and corrupt-file protection.'
} finally {
  if (Test-Path -LiteralPath $stateRoot) {
    Remove-Item -LiteralPath $stateRoot -Recurse -Force
  }
}