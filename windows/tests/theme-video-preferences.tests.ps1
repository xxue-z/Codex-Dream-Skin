[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$Root)

$ErrorActionPreference = 'Stop'
. (Join-Path $Root 'scripts\common-windows.ps1')
. (Join-Path $Root 'scripts\theme-windows.ps1')

$stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('dreamskin-video-prefs-' + [guid]::NewGuid().ToString('N'))
try {
  [void][System.IO.Directory]::CreateDirectory($stateRoot)
  $themePrefsPath = Join-Path $stateRoot 'theme-preferences.json'
  $videoPrefsPath = Join-Path $stateRoot 'theme-video-preferences.json'
  Write-DreamSkinUtf8FileAtomically -Path $themePrefsPath -Content (
    '{"schemaVersion":1,"themes":{"video-theme":{"transparency":42}}}' + "`r`n"
  )
  $null = Set-DreamSkinThemeVideoPreference -ThemeId 'video-theme' `
    -Paused $true -Muted $false -StateRoot $stateRoot
  $videoPrefs = (Read-DreamSkinUtf8File -Path $videoPrefsPath) | ConvertFrom-Json -ErrorAction Stop
  if ($videoPrefs.videoBackground -ne $true) {
    throw 'New video preferences must default videoBackground to true.'
  }
  if ($videoPrefs.themes.'video-theme'.paused -ne $true -or
    $videoPrefs.themes.'video-theme'.muted -ne $false) {
    throw 'Video preference update did not persist paused/muted values.'
  }
  $themePrefs = (Read-DreamSkinUtf8File -Path $themePrefsPath) | ConvertFrom-Json -ErrorAction Stop
  if ($themePrefs.themes.'video-theme'.transparency -ne 42) {
    throw 'Video preferences must not rewrite the existing transparency file.'
  }
  $null = Set-DreamSkinThemeVideoPreference -ThemeId 'video-theme' -Paused $false -StateRoot $stateRoot
  $current = Get-DreamSkinThemeVideoPreference -ThemeId 'video-theme' -StateRoot $stateRoot
  if ($current.Paused -ne $false -or $current.Muted -ne $false) {
    throw 'Video preference partial update did not preserve the muted value.'
  }
  Write-DreamSkinUtf8FileAtomically -Path $videoPrefsPath -Content ('{' + "`r`n")
  $rejected = $false
  try {
    $null = Set-DreamSkinThemeVideoPreference -ThemeId 'video-theme' -Muted $true -StateRoot $stateRoot
  } catch { $rejected = $true }
  if (-not $rejected) { throw 'Invalid video preferences were overwritten instead of being rejected.' }
  Write-Output 'PASS: local video mute/pause preferences are isolated, atomic and preserve unrelated files.'
} finally {
  if (Test-Path -LiteralPath $stateRoot) {
    Remove-Item -LiteralPath $stateRoot -Recurse -Force
  }
}
