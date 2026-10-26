function New-DreamSkinCommunityHttpRequest {
  param(
    [Parameter(Mandatory = $true)][string]$RequestUri,
    [Parameter(Mandatory = $true)][string]$Accept
  )
  if ($RequestUri -cnotmatch `
    '\Ahttps://api\.dreamskin\.cc/v1/themes/ver_[a-z0-9]{8,64}(?:/download)?\z') {
    throw 'Community theme network requests are restricted to the fixed DreamSkin.cc API.'
  }
  $request = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create(
    [System.Uri]::new($RequestUri, [System.UriKind]::Absolute)
  )
  if ($request.RequestUri.AbsoluteUri -cne $RequestUri) {
    throw 'The community theme API request URI was not canonical.'
  }
  $request.Method = 'GET'
  $request.Accept = $Accept
  $request.UserAgent = 'CodexDreamSkin/1 community-theme-apply'
  $request.AllowAutoRedirect = $false
  $request.AutomaticDecompression = [System.Net.DecompressionMethods]::None
  $request.CachePolicy = [System.Net.Cache.RequestCachePolicy]::new(
    [System.Net.Cache.RequestCacheLevel]::NoCacheNoStore
  )
  $request.KeepAlive = $false
  $request.Headers['Accept-Encoding'] = 'identity'
  $request.Timeout = 20000
  $request.ReadWriteTimeout = 60000
  return $request
}

function Get-DreamSkinCommunityHttpResponse {
  param(
    [Parameter(Mandatory = $true)][string]$RequestUri,
    [Parameter(Mandatory = $true)][string]$Accept
  )
  $request = New-DreamSkinCommunityHttpRequest -RequestUri $RequestUri -Accept $Accept
  $response = $null
  try {
    $response = [System.Net.HttpWebResponse]$request.GetResponse()
  } catch {
    if ($_.Exception -is [System.Net.WebException] -and $null -ne $_.Exception.Response) {
      $_.Exception.Response.Dispose()
    }
    throw 'DreamSkin.cc did not return the requested approved theme without a redirect.'
  }
  if ([int]$response.StatusCode -ne 200 -or
    $response.ResponseUri.AbsoluteUri -cne $RequestUri) {
    $response.Dispose()
    throw 'DreamSkin.cc returned an unexpected status or redirect.'
  }
  return $response
}

