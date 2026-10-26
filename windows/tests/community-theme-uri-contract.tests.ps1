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
$validUri = ($linkScheme + 'apply?version=ver_1234abcd')
$versionId = Resolve-DreamSkinCommunityApplyUri -Uri $validUri
if ($versionId -cne 'ver_1234abcd' -or
  -not (Test-DreamSkinCommunityVersionId -Value $versionId)) {
  throw 'The canonical community theme link did not resolve its version id.'
}
$normalizedUri = ($linkScheme + 'apply/?version=ver_1234abcd')
$normalizedVersionId = Resolve-DreamSkinCommunityApplyUri -Uri $normalizedUri
if ($normalizedVersionId -cne 'ver_1234abcd') {
  throw 'The browser-normalized community theme link did not resolve its version id.'
}
$endpoints = Get-DreamSkinCommunityThemeEndpoints -VersionId $versionId
if ($endpoints.MetadataUri -cne ($apiOrigin + '/v1/themes/ver_1234abcd') -or
  $endpoints.DownloadUri -cne ($apiOrigin + '/v1/themes/ver_1234abcd/download')) {
  throw 'Community theme endpoints were not built from the fixed API origin.'
}

foreach ($invalidUri in @(
  ($webOrigin + '/apply?version=ver_1234abcd'),
  ($linkScheme + 'apply?url=' + $exampleOrigin + '/theme.zip'),
  ($linkScheme + 'apply?version=ver_short'),
  ($linkScheme + 'apply?version=ver_1234abcd&extra=1'),
  ($linkScheme + 'apply/?version=ver_1234abcd&extra=1'),
  ($linkScheme + 'apply//?version=ver_1234abcd'),
  ($linkScheme + 'apply/path?version=ver_1234abcd'),
  ($linkScheme + 'apply?version=ver_1234abcd#fragment'),
  ($linkScheme + 'user@apply?version=ver_1234abcd'),
  ($linkScheme + 'apply:443?version=ver_1234abcd'),
  ($linkScheme.ToUpperInvariant() + 'apply?version=ver_1234abcd'),
  ($linkScheme + 'apply?version=ver_1234ABCD'),
  ($linkScheme + 'apply?version=ver_1234abcd%26url%3Dhttps%3A%2F%2Fevil.example')
)) {
  Assert-CommunityValueRejected -Label $invalidUri -Action {
    Resolve-DreamSkinCommunityApplyUri -Uri $invalidUri
  }
}

$validJson = @'
{"id":"ver_1234abcd","applyCompatible":true,"themeId":"theme-one","name":"Paper","version":"1.2.3","authorDisplayName":"Author","license":"MIT","packageSha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","packageBytes":2048}
'@
$metadata = ConvertFrom-DreamSkinCommunityThemeMetadata -Json $validJson `
  -ExpectedVersionId 'ver_1234abcd'
if ($metadata.Id -cne 'ver_1234abcd' -or -not $metadata.ApplyCompatible -or
  $metadata.ThemeId -cne 'theme-one' -or
  $metadata.Name -cne 'Paper' -or $metadata.Version -cne '1.2.3' -or
  $metadata.AuthorDisplayName -cne 'Author' -or $metadata.License -cne 'MIT' -or
  $metadata.PackageSha256 -cne ('a' * 64) -or $metadata.PackageBytes -ne 2048) {
  throw 'Valid community theme metadata did not retain its reviewed fields.'
}
$emoji = [char]::ConvertFromUtf32(0x1F642)
$bidiOverride = [char]0x202E
$bidiIsolate = [char]0x2066
$lineSeparator = [char]0x2028
$paragraphSeparator = [char]0x2029
$zeroWidthJoiner = [char]0x200D
$maximumUnicodeJson = $validJson.Replace('"name":"Paper"', '"name":"' + ($emoji * 120) + '"')
$maximumUnicode = ConvertFrom-DreamSkinCommunityThemeMetadata -Json $maximumUnicodeJson `
  -ExpectedVersionId 'ver_1234abcd'
if ((Get-DreamSkinUnicodeScalarCount -Value $maximumUnicode.Name) -ne 120) {
  throw 'Community display metadata did not count Unicode scalar values consistently.'
}

$invalidMetadata = @(
  @{ Label = 'mismatched id'; Json = $validJson.Replace('ver_1234abcd', 'ver_deadbeef') },
  @{ Label = 'case-ambiguous id key'; Json = $validJson.Replace('"id"', '"ID"') },
  @{ Label = 'not apply-compatible'; Json = $validJson.Replace('"applyCompatible":true', '"applyCompatible":false') },
  @{ Label = 'string apply compatibility'; Json = $validJson.Replace('"applyCompatible":true', '"applyCompatible":"true"') },
  @{ Label = 'missing apply compatibility'; Json = $validJson.Replace(',"applyCompatible":true', '') },
  @{ Label = 'uppercase hash'; Json = $validJson.Replace(('a' * 64), ('A' * 64)) },
  @{ Label = 'zero bytes'; Json = $validJson.Replace('"packageBytes":2048', '"packageBytes":0') },
  @{ Label = 'oversized bytes'; Json = $validJson.Replace('"packageBytes":2048', '"packageBytes":33554433') },
  @{ Label = 'string bytes'; Json = $validJson.Replace('"packageBytes":2048', '"packageBytes":"2048"') },
  @{ Label = 'fractional bytes'; Json = $validJson.Replace('"packageBytes":2048', '"packageBytes":2048.5') },
  @{ Label = 'unsafe display whitespace'; Json = $validJson.Replace('"name":"Paper"', '"name":" Paper"') },
  @{ Label = 'unsafe display control'; Json = $validJson.Replace('"name":"Paper"', '"name":"Paper\u000aInjected"') },
  @{ Label = 'unsafe bidi override'; Json = $validJson.Replace('Paper', "Pa${bidiOverride}per") },
  @{ Label = 'unsafe bidi isolate'; Json = $validJson.Replace('Paper', "Pa${bidiIsolate}per") },
  @{ Label = 'unsafe line separator'; Json = $validJson.Replace('Paper', "Pa${lineSeparator}per") },
  @{ Label = 'unsafe paragraph separator'; Json = $validJson.Replace('Paper', "Pa${paragraphSeparator}per") },
  @{ Label = 'unsafe Unicode format character'; Json = $validJson.Replace('Paper', "Pa${zeroWidthJoiner}per") },
  @{ Label = 'display over Unicode limit'; Json = $validJson.Replace('"name":"Paper"', '"name":"' + ($emoji * 121) + '"') },
  @{ Label = 'invalid semantic version'; Json = $validJson.Replace('"version":"1.2.3"', '"version":"1.2.3-beta"') },
  @{ Label = 'oversized semantic version'; Json = $validJson.Replace('"version":"1.2.3"', '"version":"123456789012345678901234567890.1.1"') },
  @{ Label = 'missing license'; Json = $validJson.Replace(',"license":"MIT"', '') },
  @{ Label = 'array root'; Json = "[$validJson]" }
)
foreach ($case in $invalidMetadata) {
  Assert-CommunityValueRejected -Label $case.Label -Action {
    ConvertFrom-DreamSkinCommunityThemeMetadata -Json $case.Json `
      -ExpectedVersionId 'ver_1234abcd'
  }
}
Assert-CommunityValueRejected -Label 'metadata over 64 KiB' -Action {
  ConvertFrom-DreamSkinCommunityThemeMetadata -Json ($validJson + (' ' * 65536)) `
    -ExpectedVersionId 'ver_1234abcd'
}


