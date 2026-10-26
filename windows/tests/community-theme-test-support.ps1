[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$Root)

$ErrorActionPreference = 'Stop'
. (Join-Path $Root 'scripts\common-windows.ps1')
. (Join-Path $Root 'scripts\theme-windows.ps1')
. (Join-Path $Root 'scripts\localization-windows.ps1')
function Assert-CommunityValueRejected {
  param(
    [Parameter(Mandatory = $true)][scriptblock]$Action,
    [Parameter(Mandatory = $true)][string]$Label
  )
  $rejected = $false
  try { $null = & $Action } catch { $rejected = $true }
  if (-not $rejected) { throw "Community theme contract unexpectedly accepted $Label." }
}


function Invoke-CommunityOperationLockProbe {
  param(
    [Parameter(Mandatory = $true)][string]$PowerShellPath,
    [Parameter(Mandatory = $true)][string]$CommonPath,
    [Parameter(Mandatory = $true)][int]$TimeoutMilliseconds,
    [Parameter(Mandatory = $true)][bool]$ExpectSuccess
  )
  $escapedCommonPath = $CommonPath.Replace("'", "''")
  $lockCall = if ($TimeoutMilliseconds -lt 0) {
    '$lock = Enter-DreamSkinOperationLock'
  } else {
    '$lock = Enter-DreamSkinOperationLock -TimeoutMilliseconds ' + $TimeoutMilliseconds
  }
  $expectLiteral = if ($ExpectSuccess) { '$true' } else { '$false' }
  $childSource = @"
`$ErrorActionPreference = 'Stop'
. '$escapedCommonPath'
`$lock = `$null
`$exitCode = 0
try {
  $lockCall
  if (-not $expectLiteral) { `$exitCode = 81 }
} catch {
  if ($expectLiteral) { `$exitCode = 82 }
} finally {
  if (`$null -ne `$lock) { Exit-DreamSkinOperationLock -Mutex `$lock }
}
exit `$exitCode
"@
  # Launch the probe from a temporary script instead of an encoded command: the
  # encoded base64 pair matches endpoint-security "obfuscated command" heuristics
  # and got this test file quarantined.
  $childPath = Join-Path ([IO.Path]::GetTempPath()) ('ds-lock-probe-' + [guid]::NewGuid().ToString('N') + '.ps1')
  [IO.File]::WriteAllText($childPath, $childSource, (New-Object System.Text.UTF8Encoding($false)))
  $watch = [Diagnostics.Stopwatch]::StartNew()
  try {
    $child = Start-Process -FilePath $PowerShellPath -ArgumentList @(
      '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $childPath
    ) -Wait -PassThru
  } finally {
    Remove-Item -LiteralPath $childPath -Force -ErrorAction SilentlyContinue
  }
  $watch.Stop()
  return [pscustomobject]@{
    ExitCode = $child.ExitCode
    ElapsedMilliseconds = $watch.ElapsedMilliseconds
  }
}

$isWindowsHost = $PSVersionTable.PSEdition -eq 'Desktop' -or
  [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
$powerShellExecutable = $null
if ($isWindowsHost) {
  $powerShellExecutable = if ($PSVersionTable.PSEdition -eq 'Core') {
    Join-Path $PSHOME 'pwsh.exe'
  } else {
    Join-Path $PSHOME 'powershell.exe'
  }
  if (-not (Test-Path -LiteralPath $powerShellExecutable -PathType Leaf)) {
    $powerShellExecutable = (Get-Process -Id $PID -ErrorAction Stop).Path
  }
}
function Get-CommunityApplyModulePaths {
  param([Parameter(Mandatory = $true)][string]$Root)
  $scripts = Join-Path $Root 'scripts'
  $paths = @(Join-Path $scripts 'apply-community-theme.ps1')
  foreach ($name in @('ds-cm-msg.ps1', 'ds-cm-req.ps1', 'ds-cm-data.ps1', 'ds-cm-snap.ps1')) {
    $candidate = Join-Path $scripts $name
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { $paths += $candidate }
  }
  return $paths
}

function Get-CommunityApplyBundle {
  $texts = @()
  $asts = @()
  $paths = @(Get-CommunityApplyModulePaths -Root $Root)
  foreach ($path in $paths) {
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
      throw "Community theme source failed to parse: ${path}: $($parseErrors[0].Message)"
    }
    $texts += [System.IO.File]::ReadAllText($path)
    $asts += $ast
  }
  return [pscustomobject]@{ Text = ($texts -join "`r`n"); Asts = $asts; Paths = $paths }
}

function Find-CommunityApplyHelper {
  param(
    [Parameter(Mandatory = $true)][object]$Bundle,
    [Parameter(Mandatory = $true)][string]$Name
  )
  foreach ($ast in $Bundle.Asts) {
    $found = $ast.Find({
      param($node)
      $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $Name
    }, $true)
    if ($null -ne $found) { return $found }
  }
  return $null
}

function Import-CommunityApplyHelper {
  param(
    [Parameter(Mandatory = $true)][object]$Bundle,
    [Parameter(Mandatory = $true)][string]$Name
  )
  $helper = Find-CommunityApplyHelper -Bundle $Bundle -Name $Name
  if ($null -eq $helper) { throw "Community theme helper is missing: $Name" }
  . ([scriptblock]::Create($helper.Extent.Text))
}
