[CmdletBinding()]
param([int]$Port = 9335, [switch]$ShowWindow)

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 stops autoloading Microsoft.PowerShell.Utility when
# PSModulePath leads with PowerShell 7 roots inherited from a pwsh parent (for
# example a tray started from a pwsh console). Commands such as Get-FileHash
# then disappear and every saved-theme apply fails as an internal start error.
# Keep every existing root, but put the real 5.1 roots first for this process
# and every child it starts.
if ("$($PSVersionTable.PSEdition)" -eq 'Desktop') {
  $dreamSkinModuleRoots = @(
    (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules'),
    (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'),
    (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules')
  ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
  $orderedModuleRoots = @()
  foreach ($root in @($dreamSkinModuleRoots)) {
    if ($root -and ($orderedModuleRoots -notcontains $root)) { $orderedModuleRoots += $root }
  }
  foreach ($root in @("$env:PSModulePath" -split ';')) {
    if ($root -and ($orderedModuleRoots -notcontains $root)) { $orderedModuleRoots += $root }
  }
  $env:PSModulePath = ($orderedModuleRoots -join ';')
  Remove-Variable dreamSkinModuleRoots, orderedModuleRoots -ErrorAction SilentlyContinue
}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
. (Join-Path $PSScriptRoot 'localization-windows.ps1')
. (Join-Path $PSScriptRoot 'common-windows.ps1')
. (Join-Path $PSScriptRoot 'theme-windows.ps1')

Assert-DreamSkinPort -Port $Port
$SkillRoot = Split-Path -Parent $PSScriptRoot
$StateRoot = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'
$paths = $null
$powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
$startScript = Join-Path $PSScriptRoot 'start-dream-skin.ps1'
$restoreScript = Join-Path $PSScriptRoot 'restore-dream-skin.ps1'
$checkUpdateScript = Join-Path $PSScriptRoot 'check-update.ps1'
$startupShortcut = Join-Path ([Environment]::GetFolderPath('Startup')) 'Codex Dream Skin.lnk'

$sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$mutex = [System.Threading.Mutex]::new($false, "Local\CodexDreamSkin.$sid.Tray")
$showEvent = [System.Threading.EventWaitHandle]::new($false,
  [System.Threading.EventResetMode]::AutoReset, "Local\CodexDreamSkin.$sid.ShowWindow")
$acquired = $false
$notify = $null
$trayIcon = $null
try {
  try { $acquired = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
  if (-not $acquired) {
    if ($ShowWindow) { [void]$showEvent.Set() }
    exit 0
  }

  $initializationLock = Enter-DreamSkinOperationLock
  try {
    $paths = Initialize-DreamSkinThemeStore -SkillRoot $SkillRoot -StateRoot $StateRoot
  } finally {
    Exit-DreamSkinOperationLock -Mutex $initializationLock
  }

  $notify = [System.Windows.Forms.NotifyIcon]::new()
  $iconPath = Join-Path $SkillRoot 'assets\codex-dream-skin.ico'
  if (Test-Path -LiteralPath $iconPath -PathType Leaf) {
    $trayIcon = [System.Drawing.Icon]::new($iconPath)
    $notify.Icon = $trayIcon
  } else {
    $notify.Icon = [System.Drawing.SystemIcons]::Application
  }
  $notify.Text = 'Codex Dream Skin'
  $notify.Visible = $true
  $menu = [System.Windows.Forms.ContextMenuStrip]::new()
  $notify.ContextMenuStrip = $menu
  $script:trayVideoSettingsControls = @()
  $script:trayVeilTimer = $null
  $script:trayPendingVeil = 100
  $script:trayCommitVeil = $null

  function Show-DreamSkinTrayError {
    param([string]$Message)
    if ($Message -like '*Video settings file*') {
      $Message = Get-DreamSkinTrayText -Key 'FolderSettingsInvalid'
    }
    [void][System.Windows.Forms.MessageBox]::Show(
      $Message,
      'Codex Dream Skin',
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Error
    )
  }

  function Get-DreamSkinTrayText {
    param(
      [Parameter(Mandatory = $true)][string]$Key,
      [object[]]$FormatArguments = @()
    )
    $language = Resolve-DreamSkinLanguage -StateRoot $StateRoot
    Get-DreamSkinText -Key $Key -Language $language -FormatArguments $FormatArguments
  }

  function Start-DreamSkinPowerShell {
    param([Parameter(Mandatory = $true)][string]$Script, [string[]]$Arguments = @())
    $scriptToken = ConvertTo-DreamSkinProcessArgument -Value $Script
    $argumentLine = '-NoProfile -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File ' + $scriptToken
    if ($Arguments.Count -gt 0) { $argumentLine += ' ' + ($Arguments -join ' ') }
    $previousLanguage = $env:DREAMSKIN_LANG
    try {
      $env:DREAMSKIN_LANG = Resolve-DreamSkinLanguage -StateRoot $StateRoot
      Start-Process -FilePath $powershell -ArgumentList $argumentLine -WindowStyle Hidden | Out-Null
    } finally {
      $env:DREAMSKIN_LANG = $previousLanguage
    }
  }

  function Set-DreamSkinTrayApplyStatus {
    param([string]$Message, [bool]$Success = $false)
    $script:trayApplyStatus = $Message
    $script:trayApplySucceeded = $Success
  }

  function Complete-DreamSkinTrayApply {
    # Called on the UI timer only after the child exits. A selected theme or
    # a successful process launch is not evidence of rendered appearance.
    $operation = $script:trayApplyOperation
    if ($null -eq $operation) { return }
    $success = $false
    $message = Get-DreamSkinTrayText -Key 'ApplyNotConfirmed'
    try {
      $result = Read-DreamSkinStartResult -StateRoot $StateRoot -Token $operation.Token
      $success = $operation.Process.ExitCode -eq 0 -and $result.outcome -ceq 'success'
      if ($success) {
        $message = Get-DreamSkinTrayText -Key 'Applied' -FormatArguments @($operation.ThemeName)
      } elseif ($result.outcome -ceq 'failure') {
        $message = Get-DreamSkinTrayText -Key 'ApplyFailed' -FormatArguments @($result.category)
      }
    } catch {
      # Missing, malformed, stale and oversized results all fail closed.
    } finally {
      $operation.Timer.Stop()
      $operation.Timer.Dispose()
      $operation.Process.Dispose()
      Remove-Item -LiteralPath $operation.ResultPath -Force -ErrorAction SilentlyContinue
      $script:trayApplyOperation = $null
      $script:trayApplyPending = $false
    }
    Set-DreamSkinTrayApplyStatus -Message $message -Success $success
    $icon = if ($success) { [System.Windows.Forms.ToolTipIcon]::Info } else { [System.Windows.Forms.ToolTipIcon]::Warning }
    $notify.ShowBalloonTip(3500, 'Codex Dream Skin', $message, $icon)
  }

  function Start-DreamSkinVerifiedTrayApply {
    param([string]$ThemeName = '', [string]$ThemeDirectory = '')
    if ($script:trayApplyPending) { return }
    $script:trayApplyPending = $true
    $script:trayApplyOperation = $null
    $process = $null
    $timer = $null
    try {
      if (-not $ThemeName) {
        $selected = Read-DreamSkinTheme -ThemeDirectory $paths.Active -SkipImageMetadata
        $ThemeName = $selected.Theme.name
      }
      $token = [guid]::NewGuid().ToString('N')
      $resultPath = Get-DreamSkinStartResultPath -StateRoot $StateRoot -Token $token
      if (Test-Path -LiteralPath $resultPath) { throw 'Theme application result token already exists.' }
      $arguments = '-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File ' +
        (ConvertTo-DreamSkinProcessArgument -Value $startScript) + ' -Port ' + $Port +
        ' -PromptRestart -ResultToken ' + $token
      if ($ThemeDirectory) {
        $arguments += ' -SavedThemeDirectory ' + (ConvertTo-DreamSkinProcessArgument -Value $ThemeDirectory)
      }
      $timer = [System.Windows.Forms.Timer]::new()
      $timer.Interval = 300
      $timer.add_Tick({
        $operation = $script:trayApplyOperation
        if ($null -eq $operation) { return }
        try {
          $operation.Process.Refresh()
          if ($operation.Process.HasExited) { Complete-DreamSkinTrayApply }
        } catch {
          # Do not report success or permit another selection while the child
          # may still own the operation lock. The next tick retries observation.
          Set-DreamSkinTrayApplyStatus -Message (Get-DreamSkinTrayText -Key 'ApplyWaiting')
        }
      })
      $previousLanguage = $env:DREAMSKIN_LANG
      try {
        $env:DREAMSKIN_LANG = Resolve-DreamSkinLanguage -StateRoot $StateRoot
        $process = Start-Process -FilePath $powershell -ArgumentList $arguments -WindowStyle Hidden -PassThru
      } finally {
        $env:DREAMSKIN_LANG = $previousLanguage
      }
      $script:trayApplyOperation = [pscustomobject]@{
        Process = $process; Timer = $timer; Token = $token; ResultPath = $resultPath; ThemeName = $ThemeName
      }
      $timer.Start()
      Set-DreamSkinTrayApplyStatus -Message (Get-DreamSkinTrayText -Key 'Applying')
    } catch {
      if ($null -ne $timer) { $timer.Stop(); $timer.Dispose() }
      if ($null -ne $process) { $process.Dispose() }
      $script:trayApplyOperation = $null
      $script:trayApplyPending = $false
      Set-DreamSkinTrayApplyStatus -Message (Get-DreamSkinTrayText -Key 'ApplyCouldNotStart')
      throw
    }
  }

  function Add-DreamSkinTrayItem {
    param(
      [Parameter(Mandatory = $true)]
      [AllowEmptyCollection()]
      [System.Windows.Forms.ToolStripItemCollection]$Items,
      [Parameter(Mandatory = $true)][string]$Text,
      [AllowNull()][scriptblock]$Action,
      [bool]$Enabled = $true,
      [bool]$Checked = $false
    )
    $item = [System.Windows.Forms.ToolStripMenuItem]::new($Text)
    $item.Enabled = $Enabled
    $item.Checked = $Checked
    if ($null -ne $Action) {
      $item.add_Click({
        try { & $Action } catch { Show-DreamSkinTrayError -Message $_.Exception.Message }
      }.GetNewClosure())
    }
    [void]$Items.Add($item)
    return $item
  }

  function Add-DreamSkinTrayLanguageMenu {
    $preference = Get-DreamSkinLanguagePreference -StateRoot $StateRoot
    $languageMenu = [System.Windows.Forms.ToolStripMenuItem]::new(
      (Get-DreamSkinTrayText -Key 'Language')
    )
    foreach ($option in @(
      @{ Value = 'system'; Label = (Get-DreamSkinTrayText -Key 'LanguageSystem') },
      @{ Value = 'en-US'; Label = (Get-DreamSkinTrayText -Key 'LanguageEnglish') },
      @{ Value = 'zh-CN'; Label = (Get-DreamSkinTrayText -Key 'LanguageChinese') }
    )) {
      $optionValue = $option.Value
      $optionAction = {
        Set-DreamSkinLanguage -Language $optionValue -StateRoot $StateRoot
        Rebuild-DreamSkinTrayMenu
      }.GetNewClosure()
      $optionItem = Add-DreamSkinTrayItem -Items $languageMenu.DropDownItems -Text $option.Label -Action $optionAction
      $optionItem.Checked = $preference -ceq $optionValue
    }
    [void]$menu.Items.Add($languageMenu)
  }

  function Invoke-DreamSkinTrayThemeOperation {
    param([Parameter(Mandatory = $true)][scriptblock]$Action)
    $themeOperationLock = Enter-DreamSkinOperationLock
    try {
      return & $Action
    } finally {
      Exit-DreamSkinOperationLock -Mutex $themeOperationLock
    }
  }

  function Set-DreamSkinAutoStart {
    param([Parameter(Mandatory = $true)][bool]$Enabled)
    if (-not $Enabled) {
      Remove-Item -LiteralPath $startupShortcut -Force -ErrorAction SilentlyContinue
      return
    }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($startupShortcut)
    $shortcut.TargetPath = $powershell
    $shortcut.Arguments = "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File `"$PSScriptRoot\tray-dream-skin.ps1`""
    $shortcut.WorkingDirectory = $SkillRoot
    $shortcut.Description = 'Start Codex Dream Skin in the notification area'
    $shortcut.Save()
  }

  function Set-DreamSkinTrayVideoState {
    param(
      [Nullable[bool]]$Muted = $null,
      [Nullable[bool]]$Paused = $null,
      [Nullable[int]]$Veil = $null
    )
    if ($null -eq $Muted -and $null -eq $Paused -and $null -eq $Veil) { return }
    if ($null -eq $Veil) {
      try { $Veil = (Get-DreamSkinVideoSettings -StateRoot $StateRoot).Veil } catch { $Veil = 100 }
    }
    $node = Get-DreamSkinNodeRuntime
    $injector = Join-Path $PSScriptRoot 'injector.mjs'
    $arguments = @($injector, '--video-state', '--port', "$Port")
    if ($null -ne $Muted) {
      $arguments += @('--muted', $(if ($Muted) { 'true' } else { 'false' }))
    }
    if ($null -ne $Paused) {
      $arguments += @('--paused', $(if ($Paused) { 'true' } else { 'false' }))
    }
    if ($null -ne $Veil) { $arguments += @('--veil', "$([int]$Veil)") }
    $result = Invoke-DreamSkinNative -FilePath $node.Path -ArgumentList $arguments -SeparateStderr
    if ($result.ExitCode -ne 0) {
      $detail = (($result.Output + $result.ErrorOutput) -join "`n").Trim()
      throw $(if ($detail) { $detail } else { 'Could not update the live dynamic background state.' })
    }
  }
  function Rebuild-DreamSkinTrayMenu {
    # Hosted TrackBar/NSView equivalents are not disposed by Items.Clear();
    # release the previous controls before rebuilding so repeated menu opens do
    # not leak native handles.
    foreach ($control in @($script:trayVideoSettingsControls)) {
      try { $control.Dispose() } catch {}
    }
    $script:trayVideoSettingsControls = @()
    $script:trayVeilTimer = $null
    $menu.Items.Clear()
    $paused = Test-DreamSkinPaused -StateRoot $StateRoot
    $state = $null
    try { $state = Read-DreamSkinState -Path $paths.State } catch {}
    $active = $null
    try { $active = Read-DreamSkinTheme -ThemeDirectory $paths.Active -SkipImageMetadata } catch {}
    $status = if ($paused) {
      Get-DreamSkinTrayText -Key 'StatusPaused'
    } elseif ($state) {
      Get-DreamSkinTrayText -Key 'StatusRunning'
    } else {
      Get-DreamSkinTrayText -Key 'StatusStopped'
    }
    if ($null -ne $active -and $null -ne $active.Theme -and $active.Theme.name) {
      $status += " · $($active.Theme.name)"
    }
    $null = Add-DreamSkinTrayItem -Items $menu.Items -Text $status -Action $null -Enabled $false
    [void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())

    $null = Add-DreamSkinTrayItem -Items $menu.Items -Text (Get-DreamSkinTrayText -Key 'Apply') -Action {
      Start-DreamSkinVerifiedTrayApply
    }
    # Match macOS menubar: pause = mark + live remove; resume lets the serialized
    # start path clear pause only after its safety checks and any restart consent.
    if ($paused) {
      $null = Add-DreamSkinTrayItem -Items $menu.Items -Text (Get-DreamSkinTrayText -Key 'Resume') -Action {
        Start-DreamSkinVerifiedTrayApply
      }
    } else {
      $null = Add-DreamSkinTrayItem -Items $menu.Items -Text (Get-DreamSkinTrayText -Key 'Pause') -Action {
        # Match macOS pause: marker + live remove with in-window loading / result.
        $pauseNoSessionMessage = Get-DreamSkinTrayText -Key 'PauseNoSession'
        $pauseSucceededMessage = Get-DreamSkinTrayText -Key 'PauseSucceeded'
        $pauseFailedMessage = Get-DreamSkinTrayText -Key 'PauseFailed'
        $removal = Invoke-DreamSkinTrayThemeOperation -Action {
          Set-DreamSkinPaused -Paused $true -StateRoot $StateRoot | Out-Null
          Invoke-DreamSkinLiveRemove -StateRoot $StateRoot `
            -PauseNoSessionMessage $pauseNoSessionMessage `
            -PauseSucceededMessage $pauseSucceededMessage `
            -PauseFailedMessage $pauseFailedMessage
        }
        $icon = if ($removal.Removed) {
          [System.Windows.Forms.ToolTipIcon]::Info
        } else {
          [System.Windows.Forms.ToolTipIcon]::Warning
        }
        $removalMessage = $removal.Message
        $notify.ShowBalloonTip(2800, 'Codex Dream Skin', $removalMessage, $icon)
        if (-not $removal.Removed -and $removal.Attempted) {
          Show-DreamSkinTrayError -Message $removalMessage
        }
      }
    }
    $null = Add-DreamSkinTrayItem -Items $menu.Items -Text (Get-DreamSkinTrayText -Key 'ChangeBackground') -Action {
      $dialog = [System.Windows.Forms.OpenFileDialog]::new()
      $dialog.Title = Get-DreamSkinTrayText -Key 'BackgroundTitle'
      $dialog.Filter = Get-DreamSkinTrayText -Key 'ImageFilter'
      $dialog.Multiselect = $false
      try {
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
          $null = Invoke-DreamSkinTrayThemeOperation -Action {
            $null = Set-DreamSkinActiveThemeImage -ImagePath $dialog.FileName `
              -StateRoot $StateRoot
            Set-DreamSkinPaused -Paused $false -StateRoot $StateRoot | Out-Null
          }
          $notify.ShowBalloonTip(1800, 'Codex Dream Skin', (Get-DreamSkinTrayText -Key 'BackgroundUpdated'), [System.Windows.Forms.ToolTipIcon]::Info)
        }
      } finally {
        $dialog.Dispose()
      }
    }
    $null = Add-DreamSkinTrayItem -Items $menu.Items -Text (Get-DreamSkinTrayText -Key 'ImportZip') -Action {
      $dialog = [System.Windows.Forms.OpenFileDialog]::new()
      $dialog.Title = Get-DreamSkinTrayText -Key 'ImportTitle'
      $dialog.Filter = 'Dream Skin theme ZIP|*.zip'
      $dialog.Multiselect = $false
      try {
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
          $imported = Import-DreamSkinThemeZip -ArchivePath $dialog.FileName -StateRoot $StateRoot
          if ($imported.Status -ceq 'Duplicate') {
            $message = Get-DreamSkinTrayText -Key 'ThemeExists' -FormatArguments @($imported.Name)
          } elseif ($imported.Replaced) {
            $message = Get-DreamSkinTrayText -Key 'ThemeUpdated' -FormatArguments @($imported.Name)
          } else {
            $message = Get-DreamSkinTrayText -Key 'ThemeImported' -FormatArguments @($imported.Name)
            if ($imported.Renamed) {
              $message += Get-DreamSkinTrayText -Key 'NewIdentifier' -FormatArguments @($imported.Id)
            }
            if ($imported.NameCollision) { $message += Get-DreamSkinTrayText -Key 'NameCollision' }
          }
          if ($imported.SafeCssStatus -ceq 'validated') {
            $message += Get-DreamSkinTrayText -Key 'CssValidated'
          }
          if ($imported.SignatureIgnored) { $message += Get-DreamSkinTrayText -Key 'SignatureIgnored' }
          $cleanupProperty = $imported.PSObject.Properties['CleanupWarning']
          $hasCleanupWarning = $null -ne $cleanupProperty -and
            -not [string]::IsNullOrWhiteSpace("$($cleanupProperty.Value)")
          if ($hasCleanupWarning) {
            $message += Get-DreamSkinTrayText -Key 'CleanupWarning'
          }
          $messageIcon = if ($hasCleanupWarning) {
            [System.Windows.Forms.ToolTipIcon]::Warning
          } else {
            [System.Windows.Forms.ToolTipIcon]::Info
          }
          $notify.ShowBalloonTip(4200, 'Codex Dream Skin', $message, $messageIcon)
        }
      } finally {
        $dialog.Dispose()
      }
    }
    $null = Add-DreamSkinTrayItem -Items $menu.Items -Text (Get-DreamSkinTrayText -Key 'SaveCurrent') -Action {
      $name = [Microsoft.VisualBasic.Interaction]::InputBox(
        (Get-DreamSkinTrayText -Key 'SavePrompt'),
        (Get-DreamSkinTrayText -Key 'SaveTitle'),
        ''
      )
      if ($name.Trim()) {
        $saved = Invoke-DreamSkinTrayThemeOperation -Action {
          Save-DreamSkinCurrentTheme -Name $name -StateRoot $StateRoot
        }
        $notify.ShowBalloonTip(
          1800,
          'Codex Dream Skin',
          (Get-DreamSkinTrayText -Key 'Saved' -FormatArguments @($saved.Theme.name)),
          [System.Windows.Forms.ToolTipIcon]::Info
        )
      }
    }

    $savedMenu = [System.Windows.Forms.ToolStripMenuItem]::new(
      (Get-DreamSkinTrayText -Key 'SavedThemes')
    )
    $savedThemes = @(Get-DreamSkinSavedThemes -StateRoot $StateRoot -SkipImageMetadata)
    if ($savedThemes.Count -eq 0) {
      $empty = [System.Windows.Forms.ToolStripMenuItem]::new(
        (Get-DreamSkinTrayText -Key 'NoSavedThemes')
      )
      $empty.Enabled = $false
      [void]$savedMenu.DropDownItems.Add($empty)
    } else {
      $playlistThemeIds = @()
      foreach ($saved in $savedThemes) {
        $isPlaylist = $false
        try {
          $probeTheme = Read-DreamSkinTheme -ThemeDirectory $saved.Path -SkipImageMetadata
          if ($probeTheme.Theme.id -ceq 'preset-arina-hashimoto' -and
              $probeTheme.Theme.PSObject.Properties['videoPlaylist'] -and
              $null -ne $probeTheme.Theme.videoPlaylist -and
              $probeTheme.Theme.videoPlaylist.enabled -eq $true) {
            $isPlaylist = $true
          }
        } catch {}
        if (-not $isPlaylist) { continue }
        $playlistThemeIds += "$($saved.Id)"
        $playlistId = "$($saved.Id)"
        $playlistName = $saved.Name
        $playlistPath = $saved.Path
        $themeMenu = [System.Windows.Forms.ToolStripMenuItem]::new($playlistName)
        $applyAction = {
          Start-DreamSkinVerifiedTrayApply -ThemeName $playlistName -ThemeDirectory $playlistPath
        }.GetNewClosure()
        $null = Add-DreamSkinTrayItem -Items $themeMenu.DropDownItems `
          -Text (Get-DreamSkinTrayText -Key 'Apply') -Action $applyAction
        [void]$savedMenu.DropDownItems.Add($themeMenu)
      }
      if ($playlistThemeIds.Count -gt 0) {
        $savedThemes = @($savedThemes | Where-Object { $playlistThemeIds -notcontains "$($_.Id)" })
      }
      foreach ($saved in $savedThemes) {
        $savedPath = $saved.Path
        $savedName = $saved.Name
        $isDynamic = $false
        try {
          $savedTheme = Read-DreamSkinTheme -ThemeDirectory $savedPath -SkipImageMetadata
          $isDynamic = [bool]$savedTheme.VideoPath
        } catch {}
        if (-not $isDynamic) {
          $savedAction = {
            Start-DreamSkinVerifiedTrayApply -ThemeName $savedName -ThemeDirectory $savedPath
          }.GetNewClosure()
          $null = Add-DreamSkinTrayItem -Items $savedMenu.DropDownItems -Text $savedName -Action $savedAction
          continue
        }
        $themeMenu = [System.Windows.Forms.ToolStripMenuItem]::new($savedName)
        $savedAction = {
          Start-DreamSkinVerifiedTrayApply -ThemeName $savedName -ThemeDirectory $savedPath
        }.GetNewClosure()
        $null = Add-DreamSkinTrayItem -Items $themeMenu.DropDownItems `
          -Text (Get-DreamSkinTrayText -Key 'Apply') -Action $savedAction
        [void]$savedMenu.DropDownItems.Add($themeMenu)
      }
    }
    [void]$menu.Items.Add($savedMenu)

    $videoSettings = Get-DreamSkinVideoSettings -StateRoot $StateRoot
    $videoSettingsItem = [System.Windows.Forms.ToolStripMenuItem]::new(
      (Get-DreamSkinTrayText -Key 'DynamicThemes')
    )
    $activeVideoPreference = Get-DreamSkinActiveVideoPreference -ActiveTheme $active -StateRoot $StateRoot
    $activeThemeLabel = if ($activeVideoPreference.IsDynamic -and $null -ne $active -and $active.Theme.name) {
      Get-DreamSkinTrayText -Key 'DynamicThemesActive' -FormatArguments @($active.Theme.name)
    } else {
      Get-DreamSkinTrayText -Key 'DynamicThemesInactive'
    }
    $null = Add-DreamSkinTrayItem -Items $videoSettingsItem.DropDownItems `
      -Text $activeThemeLabel -Action $null -Enabled $false
    $activeMuteAction = {
      try {
        if (-not $activeVideoPreference.IsDynamic) { return }
        $updated = Set-DreamSkinActiveVideoPreference -ActiveTheme $active -StateRoot $StateRoot `
          -Muted (-not $activeVideoPreference.Muted)
        Set-DreamSkinTrayVideoState -Muted $updated.Muted -Paused $updated.Paused
        Rebuild-DreamSkinTrayMenu
      } catch { Show-DreamSkinTrayError -Message $_.Exception.Message }
    }.GetNewClosure()
    $null = Add-DreamSkinTrayItem -Items $videoSettingsItem.DropDownItems `
      -Text (Get-DreamSkinTrayText -Key 'VideoMute') -Action $activeMuteAction `
      -Checked $activeVideoPreference.Muted -Enabled $activeVideoPreference.IsDynamic
    $activePauseAction = {
      try {
        if (-not $activeVideoPreference.IsDynamic) { return }
        $updated = Set-DreamSkinActiveVideoPreference -ActiveTheme $active -StateRoot $StateRoot `
          -Paused (-not $activeVideoPreference.Paused)
        Set-DreamSkinTrayVideoState -Muted $updated.Muted -Paused $updated.Paused
        Rebuild-DreamSkinTrayMenu
      } catch { Show-DreamSkinTrayError -Message $_.Exception.Message }
    }.GetNewClosure()
    $null = Add-DreamSkinTrayItem -Items $videoSettingsItem.DropDownItems `
      -Text (Get-DreamSkinTrayText -Key 'VideoPause') -Action $activePauseAction `
      -Checked $activeVideoPreference.Paused -Enabled $activeVideoPreference.IsDynamic
    [void]$videoSettingsItem.DropDownItems.Add([System.Windows.Forms.ToolStripSeparator]::new())
    $videoFolderLabel = if ($videoSettings.VideoDirectory) {
      $videoSettings.VideoDirectory
    } else {
      Get-DreamSkinTrayText -Key 'VideoSettingsDefaultFolder'
    }
    if ($videoFolderLabel.Length -gt 52) {
      $videoFolderLabel = '…' + $videoFolderLabel.Substring($videoFolderLabel.Length - 51)
    }
    $null = Add-DreamSkinTrayItem -Items $videoSettingsItem.DropDownItems `
      -Text (Get-DreamSkinTrayText -Key 'VideoSettingsCurrentFolder' -FormatArguments @($videoFolderLabel)) `
      -Action $null -Enabled $false
    [void]$videoSettingsItem.DropDownItems.Add([System.Windows.Forms.ToolStripSeparator]::new())

    $autoDiscoverAction = {
      try {
        $currentSettings = Get-DreamSkinVideoSettings -StateRoot $StateRoot
        $null = Set-DreamSkinVideoSettings -StateRoot $StateRoot `
          -AutoDiscover (-not $currentSettings.AutoDiscover)
        Request-DreamSkinPlaylistRescan -StateRoot $StateRoot
        Rebuild-DreamSkinTrayMenu
      } catch { Show-DreamSkinTrayError -Message $_.Exception.Message }
    }.GetNewClosure()
    $null = Add-DreamSkinTrayItem -Items $videoSettingsItem.DropDownItems `
      -Text (Get-DreamSkinTrayText -Key 'VideoSettingsAutoDiscover') -Action $autoDiscoverAction `
      -Checked $videoSettings.AutoDiscover

    $intervalMenu = [System.Windows.Forms.ToolStripMenuItem]::new(
      (Get-DreamSkinTrayText -Key 'VideoSettingsInterval')
    )
    foreach ($seconds in @(1, 2, 5, 10, 30)) {
      $optionSeconds = [int]$seconds
      $optionAction = {
        try {
          $null = Set-DreamSkinVideoSettings -StateRoot $StateRoot `
            -PollIntervalSeconds $optionSeconds
          Request-DreamSkinPlaylistRescan -StateRoot $StateRoot
          Rebuild-DreamSkinTrayMenu
        } catch { Show-DreamSkinTrayError -Message $_.Exception.Message }
      }.GetNewClosure()
      $null = Add-DreamSkinTrayItem -Items $intervalMenu.DropDownItems `
        -Text (Get-DreamSkinTrayText -Key 'VideoSettingsSeconds' -FormatArguments @($optionSeconds)) `
        -Action $optionAction -Checked ($videoSettings.PollIntervalSeconds -eq $optionSeconds)
    }
    [void]$videoSettingsItem.DropDownItems.Add($intervalMenu)

    $changeFolderAction = {
      try {
        $dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
        $dialog.Description = Get-DreamSkinTrayText -Key 'VideoSettingsChangeFolder'
        $dialog.ShowNewFolderButton = $true
        try {
          if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $selected = $dialog.SelectedPath
            if ($selected.StartsWith('\\') -or $selected.StartsWith('//')) {
              throw (Get-DreamSkinTrayText -Key 'FolderNetwork')
            }
            if (-not (Test-Path -LiteralPath $selected -PathType Container)) {
              throw (Get-DreamSkinTrayText -Key 'FolderNotFound')
            }
            try {
              $null = Set-DreamSkinVideoSettings -StateRoot $StateRoot `
                -VideoDirectory $selected
            } catch {
              throw (Get-DreamSkinTrayText -Key 'FolderInvalid')
            }
            Request-DreamSkinPlaylistRescan -StateRoot $StateRoot
            Rebuild-DreamSkinTrayMenu
          }
        } finally { $dialog.Dispose() }
      } catch { Show-DreamSkinTrayError -Message $_.Exception.Message }
    }.GetNewClosure()
    $null = Add-DreamSkinTrayItem -Items $videoSettingsItem.DropDownItems `
      -Text (Get-DreamSkinTrayText -Key 'VideoSettingsChangeFolder') -Action $changeFolderAction

    $restoreFolderAction = {
      try {
        $null = Set-DreamSkinVideoSettings -StateRoot $StateRoot -ResetVideoDirectory
        Request-DreamSkinPlaylistRescan -StateRoot $StateRoot
        Rebuild-DreamSkinTrayMenu
      } catch { Show-DreamSkinTrayError -Message $_.Exception.Message }
    }.GetNewClosure()
    $null = Add-DreamSkinTrayItem -Items $videoSettingsItem.DropDownItems `
      -Text (Get-DreamSkinTrayText -Key 'VideoSettingsRestoreFolder') -Action $restoreFolderAction `
      -Enabled ([bool]$videoSettings.VideoDirectory)
    [void]$videoSettingsItem.DropDownItems.Add([System.Windows.Forms.ToolStripSeparator]::new())

    $veilLabelItem = [System.Windows.Forms.ToolStripMenuItem]::new(
      (Get-DreamSkinTrayText -Key 'VideoSettingsVeil' -FormatArguments @($videoSettings.Veil))
    )
    $veilLabelItem.Enabled = $false
    [void]$videoSettingsItem.DropDownItems.Add($veilLabelItem)
    $initialVeil = [Math]::Min(100, [Math]::Max(0, [int]$videoSettings.Veil))
    $trackBar = [System.Windows.Forms.TrackBar]::new()
    $trackBar.Minimum = 0
    $trackBar.Maximum = 100
    $trackBar.TickFrequency = 10
    $trackBar.LargeChange = 10
    $trackBar.SmallChange = 5
    $trackBar.Value = $initialVeil
    $trackBar.AutoSize = $false
    $trackBar.Width = 260
    $trackBar.Height = 34
    $trackBar.AccessibleName = Get-DreamSkinTrayText -Key 'VideoSettingsVeil' -FormatArguments @('')
    $script:trayPendingVeil = $initialVeil
    $veilTimer = [System.Windows.Forms.Timer]::new()
    $veilTimer.Interval = 350
    $script:trayVeilTimer = $veilTimer
    $script:trayCommitVeil = {
      try {
        if ($null -ne $script:trayVeilTimer) { $script:trayVeilTimer.Stop() }
        $value = [int]$script:trayPendingVeil
        $null = Set-DreamSkinVideoVeil -Veil $value -StateRoot $StateRoot
        # Push the new alpha to the live renderer; the watcher also detects the
        # setting on its next tick, so no playlist rescan is needed here.
        try { Set-DreamSkinTrayVideoState -Veil $value } catch {}
      } catch { Show-DreamSkinTrayError -Message $_.Exception.Message }
    }.GetNewClosure()
    $veilTimer.add_Tick($script:trayCommitVeil)
    $trackBar.add_ValueChanged({
      $script:trayPendingVeil = [Math]::Min(100, [Math]::Max(0, [int]$trackBar.Value))
      $veilLabelItem.Text = Get-DreamSkinTrayText -Key 'VideoSettingsVeil' `
        -FormatArguments @($script:trayPendingVeil)
      if ($null -ne $script:trayVeilTimer) {
        $script:trayVeilTimer.Stop()
        $script:trayVeilTimer.Start()
      }
    }.GetNewClosure())
    $hostItem = [System.Windows.Forms.ToolStripControlHost]::new($trackBar)
    $hostItem.AutoSize = $false
    $hostItem.Size = [System.Drawing.Size]::new(276, 40)
    $hostItem.Margin = [System.Windows.Forms.Padding]::new(8, 0, 8, 2)
    [void]$videoSettingsItem.DropDownItems.Add($hostItem)
    $script:trayVideoSettingsControls += @($hostItem, $veilTimer)
    $null = Add-DreamSkinTrayItem -Items $videoSettingsItem.DropDownItems `
      -Text (Get-DreamSkinTrayText -Key 'VideoSettingsVeilLimits') -Action $null -Enabled $false
    [void]$videoSettingsItem.DropDownItems.Add([System.Windows.Forms.ToolStripSeparator]::new())

    $changePosterAction = {
      try {
        $dialog = [System.Windows.Forms.OpenFileDialog]::new()
        $dialog.Title = Get-DreamSkinTrayText -Key 'PlaylistChangePoster'
        $dialog.Filter = 'JPEG image (*.jpg;*.jpeg)|*.jpg;*.jpeg'
        $dialog.CheckFileExists = $true
        $dialog.Multiselect = $false
        try {
          if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            Set-DreamSkinPlaylistPoster -SourcePath $dialog.FileName -StateRoot $StateRoot
            Rebuild-DreamSkinTrayMenu
          }
        } finally { $dialog.Dispose() }
      } catch { Show-DreamSkinTrayError -Message $_.Exception.Message }
    }.GetNewClosure()
    $null = Add-DreamSkinTrayItem -Items $videoSettingsItem.DropDownItems `
      -Text (Get-DreamSkinTrayText -Key 'PlaylistChangePoster') -Action $changePosterAction

    $restorePosterAction = {
      try {
        Restore-DreamSkinPlaylistPoster -StateRoot $StateRoot
        Rebuild-DreamSkinTrayMenu
      } catch { Show-DreamSkinTrayError -Message $_.Exception.Message }
    }.GetNewClosure()
    $null = Add-DreamSkinTrayItem -Items $videoSettingsItem.DropDownItems `
      -Text (Get-DreamSkinTrayText -Key 'PlaylistRestorePoster') -Action $restorePosterAction

    $openVideosAction = {
      try { Open-DreamSkinVideosFolder -StateRoot $StateRoot }
      catch {
        $message = $_.Exception.Message
        if ($message -like '*configured videos folder is missing*') {
          $message = Get-DreamSkinTrayText -Key 'FolderMissing'
        }
        Show-DreamSkinTrayError -Message $message
      }
    }.GetNewClosure()
    $null = Add-DreamSkinTrayItem -Items $videoSettingsItem.DropDownItems `
      -Text (Get-DreamSkinTrayText -Key 'PlaylistOpenVideos') -Action $openVideosAction

    $rescanAction = {
      try {
        Request-DreamSkinPlaylistRescan -StateRoot $StateRoot
        Rebuild-DreamSkinTrayMenu
      } catch { Show-DreamSkinTrayError -Message $_.Exception.Message }
    }.GetNewClosure()
    $null = Add-DreamSkinTrayItem -Items $videoSettingsItem.DropDownItems `
      -Text (Get-DreamSkinTrayText -Key 'PlaylistRescan') -Action $rescanAction
    [void]$menu.Items.Add($videoSettingsItem)

    $null = Add-DreamSkinTrayItem -Items $menu.Items -Text (Get-DreamSkinTrayText -Key 'OpenThemes') -Action {
      $themeDirectoryToken = ConvertTo-DreamSkinProcessArgument -Value $paths.Saved
      Start-Process -FilePath explorer.exe -ArgumentList $themeDirectoryToken | Out-Null
    }
    $null = Add-DreamSkinTrayItem -Items $menu.Items -Text (Get-DreamSkinTrayText -Key 'OpenImages') -Action {
      $imageDirectoryToken = ConvertTo-DreamSkinProcessArgument -Value $paths.Images
      Start-Process -FilePath explorer.exe -ArgumentList $imageDirectoryToken | Out-Null
    }
    [void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
    $null = Add-DreamSkinTrayItem -Items $menu.Items -Text (Get-DreamSkinTrayText -Key 'CheckUpdate') -Action {
      Start-DreamSkinPowerShell -Script $checkUpdateScript -Arguments @('-Interactive')
    }
    $null = Add-DreamSkinTrayItem -Items $menu.Items -Text (Get-DreamSkinTrayText -Key 'Gallery') -Action {
      Start-Process -FilePath 'https://dreamskin.cc/gallery' | Out-Null
    }
    $null = Add-DreamSkinTrayItem -Items $menu.Items -Text (Get-DreamSkinTrayText -Key 'Studio') -Action {
      Start-Process -FilePath 'https://dreamskin.cc/studio' | Out-Null
    }
    $null = Add-DreamSkinTrayItem -Items $menu.Items -Text (Get-DreamSkinTrayText -Key 'OpenSite') -Action {
      Start-Process -FilePath 'https://dreamskin.cc' | Out-Null
    }
    $autoStartEnabled = Test-Path -LiteralPath $startupShortcut -PathType Leaf
    $autoStartAction = {
      Set-DreamSkinAutoStart -Enabled:(-not $autoStartEnabled)
    }.GetNewClosure()
    $null = Add-DreamSkinTrayItem -Items $menu.Items -Text (Get-DreamSkinTrayText -Key 'LaunchAtLogin') `
      -Action $autoStartAction -Checked $autoStartEnabled
    Add-DreamSkinTrayLanguageMenu
    [void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
    $null = Add-DreamSkinTrayItem -Items $menu.Items -Text (Get-DreamSkinTrayText -Key 'Restore') -Action {
      Start-DreamSkinPowerShell -Script $restoreScript -Arguments @(
        '-Port', "$Port", '-RestoreBaseTheme', '-PromptRestart'
      )
      $notify.Visible = $false
      [System.Windows.Forms.Application]::Exit()
    }
    $null = Add-DreamSkinTrayItem -Items $menu.Items -Text (Get-DreamSkinTrayText -Key 'Exit') -Action {
      $notify.Visible = $false
      [System.Windows.Forms.Application]::Exit()
    }
  }

  $menu.add_Opening({ Rebuild-DreamSkinTrayMenu })
  $menu.add_Closed({
    # A slider drag can still be inside its debounce window when the menu
    # closes; commit it instead of dropping the last value.
    $timer = $script:trayVeilTimer
    if ($null -ne $timer -and $timer.Enabled -and $null -ne $script:trayCommitVeil) {
      & $script:trayCommitVeil
    }
  })
  function Start-DreamSkinThemeManager {
    $manager = Join-Path $SkillRoot 'assets\theme-manager\DreamSkin.ThemeManager.exe'
    Assert-DreamSkinRuntimeTree -Path (Split-Path -Parent $manager)
    if (-not (Test-Path -LiteralPath $manager -PathType Leaf)) {
      throw 'The native theme manager is missing. Reinstall Codex Dream Skin.'
    }
    $previousLanguage = $env:DREAMSKIN_LANG
    try {
      $env:DREAMSKIN_LANG = Resolve-DreamSkinLanguage -StateRoot $StateRoot
      Start-Process -FilePath $manager -WorkingDirectory (Split-Path -Parent $manager) | Out-Null
    } finally {
      $env:DREAMSKIN_LANG = $previousLanguage
    }
  }
  $notify.add_DoubleClick({
    try {
      Start-DreamSkinThemeManager
    } catch {
      Show-DreamSkinTrayError -Message $_.Exception.Message
    }
  })
  $showTimer = [System.Windows.Forms.Timer]::new()
  $showTimer.Interval = 400
  $showTimer.add_Tick({
    if ($showEvent.WaitOne(0)) {
      try { Start-DreamSkinThemeManager } catch { Show-DreamSkinTrayError -Message $_.Exception.Message }
    }
  })
  $showTimer.Start()
  if ($ShowWindow) { Start-DreamSkinThemeManager }
  [System.Windows.Forms.Application]::Run()
} finally {
  if ($null -ne $showTimer) { $showTimer.Dispose() }
  if ($null -ne $script:trayApplyOperation) {
    $script:trayApplyOperation.Timer.Dispose()
    $script:trayApplyOperation.Process.Dispose()
  }
  $showEvent.Dispose()
  if ($null -ne $notify) { $notify.Dispose() }
  if ($null -ne $trayIcon) { $trayIcon.Dispose() }
  if ($acquired) { try { $mutex.ReleaseMutex() } catch {} }
  $mutex.Dispose()
}
