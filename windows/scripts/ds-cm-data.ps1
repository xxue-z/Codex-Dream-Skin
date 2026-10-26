function Read-DreamSkinCommunityMetadataResponse {
  param(
    [Parameter(Mandatory = $true)][System.Net.HttpWebResponse]$Response,
    [Parameter(Mandatory = $true)][string]$ExpectedVersionId
  )
  $contentType = ("$($Response.ContentType)" -split ';', 2)[0].Trim().ToLowerInvariant()
  if ($contentType -cne 'application/json') {
    throw 'DreamSkin.cc theme metadata did not use application/json.'
  }
  if ($Response.ContentLength -gt $script:DreamSkinMaxCommunityMetadataBytes) {
    throw 'DreamSkin.cc theme metadata exceeds the 64 KiB limit.'
  }
  $stream = $Response.GetResponseStream()
  $memory = [System.IO.MemoryStream]::new()
  try {
    $buffer = New-Object byte[] 8192
    while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
      if ($memory.Length + $read -gt $script:DreamSkinMaxCommunityMetadataBytes) {
        throw 'DreamSkin.cc theme metadata exceeds the 64 KiB limit.'
      }
      $memory.Write($buffer, 0, $read)
    }
    $strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
    try { $json = $strictUtf8.GetString($memory.ToArray()) } catch {
      throw 'DreamSkin.cc theme metadata is not valid UTF-8.'
    }
  } finally {
    $memory.Dispose()
    $stream.Dispose()
  }
  return ConvertFrom-DreamSkinCommunityThemeMetadata -Json $json `
    -ExpectedVersionId $ExpectedVersionId
}

function Save-DreamSkinCommunityDownload {
  param(
    [Parameter(Mandatory = $true)][System.Net.HttpWebResponse]$Response,
    [Parameter(Mandatory = $true)][object]$Metadata,
    [Parameter(Mandatory = $true)][string]$ArchivePath
  )
  $contentType = ("$($Response.ContentType)" -split ';', 2)[0].Trim().ToLowerInvariant()
  if ($contentType -cne 'application/zip') {
    throw 'DreamSkin.cc theme download did not use application/zip.'
  }
  if ($Response.ContentLength -ge 0 -and $Response.ContentLength -ne $Metadata.PackageBytes) {
    throw 'DreamSkin.cc theme download Content-Length does not match approved metadata.'
  }
  $input = $Response.GetResponseStream()
  $output = $null
  $written = [int64]0
  try {
    $output = [System.IO.File]::Open(
      $ArchivePath,
      [System.IO.FileMode]::CreateNew,
      [System.IO.FileAccess]::Write,
      [System.IO.FileShare]::None
    )
    $buffer = New-Object byte[] 65536
    while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
      $written += $read
      if ($written -gt $Metadata.PackageBytes -or
        $written -gt $script:DreamSkinMaxThemeArchiveBytes) {
        throw 'DreamSkin.cc theme download exceeded its approved size.'
      }
      $output.Write($buffer, 0, $read)
    }
  } finally {
    if ($null -ne $output) { $output.Dispose() }
    $input.Dispose()
  }
  if ($written -ne $Metadata.PackageBytes) {
    throw 'DreamSkin.cc theme download byte count does not match approved metadata.'
  }
  $actualHash = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actualHash -cne $Metadata.PackageSha256) {
    throw 'DreamSkin.cc theme download SHA-256 does not match approved metadata.'
  }
}

