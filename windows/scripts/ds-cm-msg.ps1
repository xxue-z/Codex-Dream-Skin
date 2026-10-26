if (-not $FunctionsOnly) {
  $ErrorActionPreference = 'Stop'
  Set-StrictMode -Version 2.0
  . (Join-Path $PSScriptRoot 'common-windows.ps1')
  . (Join-Path $PSScriptRoot 'theme-windows.ps1')
  . (Join-Path $PSScriptRoot 'localization-windows.ps1')
  $dreamSkinLanguage = Resolve-DreamSkinLanguage `
    -StateRoot (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin')
}

function Get-DreamSkinCommunityText {
  param([Parameter(Mandatory = $true)][string]$Key, [object[]]$FormatArguments = @())
  Get-DreamSkinText -Key $Key -Language $dreamSkinLanguage -FormatArguments $FormatArguments
}

function Show-DreamSkinCommunityMessage {
  param(
    [Parameter(Mandatory = $true)][string]$Message,
    [ValidateSet('Info', 'Error')][string]$Kind = 'Info'
  )
  Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
  $icon = if ($Kind -eq 'Error') {
    [System.Windows.Forms.MessageBoxIcon]::Error
  } else {
    [System.Windows.Forms.MessageBoxIcon]::Information
  }
  [void][System.Windows.Forms.MessageBox]::Show(
    $Message,
    'Codex Dream Skin',
    [System.Windows.Forms.MessageBoxButtons]::OK,
    $icon
  )
}

function Format-DreamSkinCommunitySuccessMessage {
  param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Name,
    [string]$CleanupWarning = ''
  )
  $message = Get-DreamSkinCommunityText -Key 'CommunitySuccess' -FormatArguments @($Name)
  if (-not [string]::IsNullOrWhiteSpace($CleanupWarning)) {
    $message += [Environment]::NewLine + [Environment]::NewLine +
      (Get-DreamSkinCommunityText -Key 'CommunityCleanup')
  }
  return $message
}

function Confirm-DreamSkinCommunityApply {
  param([Parameter(Mandatory = $true)][object]$Metadata)
  Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
  $sizeMiB = [Math]::Round($Metadata.PackageBytes / 1MB, 2)
  $message = @(
    (Get-DreamSkinCommunityText -Key 'CommunityConfirm' -FormatArguments @($Metadata.Name)),
    '',
    (Get-DreamSkinCommunityText -Key 'CommunityAuthor' -FormatArguments @($Metadata.AuthorDisplayName)),
    (Get-DreamSkinCommunityText -Key 'CommunityVersion' -FormatArguments @($Metadata.Version, $sizeMiB)),
    (Get-DreamSkinCommunityText -Key 'CommunityHash' -FormatArguments @($Metadata.PackageSha256)),
    '',
    (Get-DreamSkinCommunityText -Key 'CommunitySafety')
  ) -join [Environment]::NewLine
  $choice = [System.Windows.Forms.MessageBox]::Show(
    $message.Trim(),
    (Get-DreamSkinCommunityText -Key 'CommunityConfirmTitle'),
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Question,
    [System.Windows.Forms.MessageBoxDefaultButton]::Button2
  )
  return $choice -eq [System.Windows.Forms.DialogResult]::Yes
}


