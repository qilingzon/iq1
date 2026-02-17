Param(
  [string]$AuthBaseUrl = "https://oauth.aniv.cn",
  [string]$SiteUrl = "https://iqii.cn",
  [string]$Provider = "github",
  [string]$Scope = "repo",
  [string]$SiteId = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Normalize-Url([string]$value) {
  if ([string]::IsNullOrWhiteSpace($value)) { return "" }
  return $value.Trim().TrimEnd('/')
}

$AuthBaseUrl = Normalize-Url $AuthBaseUrl
$SiteUrl = Normalize-Url $SiteUrl

if ([string]::IsNullOrWhiteSpace($AuthBaseUrl) -or [string]::IsNullOrWhiteSpace($SiteUrl)) {
  throw "AuthBaseUrl and SiteUrl are required."
}

if ([string]::IsNullOrWhiteSpace($SiteId)) {
  try {
    $uri = [System.Uri]$SiteUrl
    $SiteId = $uri.Host
  }
  catch {
    throw "Failed to parse SiteUrl to host. Please provide -SiteId explicitly."
  }
}

$script:checks = @()

function Add-Check {
  param(
    [string]$Name,
    [bool]$Ok,
    [string]$Detail
  )

  $script:checks += [PSCustomObject]@{
    Name = $Name
    Result = if ($Ok) { 'PASS' } else { 'FAIL' }
    Detail = $Detail
  }
}

$healthUrl = "{0}/health" -f $AuthBaseUrl
$authUrl = "{0}/auth?provider={1}&site_id={2}&scope={3}" -f $AuthBaseUrl, $Provider, $SiteId, $Scope
$callbackErrorUrl = "{0}/callback?error=access_denied" -f $AuthBaseUrl
$adminUrl = "{0}/admin" -f $SiteUrl

try {
  $health = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 20
  $ok = ($health.StatusCode -eq 200) -and ($health.Content -match '"ok"\s*:\s*true')
  Add-Check -Name 'oauth-health' -Ok $ok -Detail ("status={0}" -f $health.StatusCode)
}
catch {
  Add-Check -Name 'oauth-health' -Ok $false -Detail $_.Exception.Message
}

try {
  $auth = Invoke-WebRequest -Uri $authUrl -UseBasicParsing -TimeoutSec 20
  $hasHandshake = $auth.Content -match ("authorizing:{0}" -f [regex]::Escape($Provider))
  $hasGithubAuth = $auth.Content -match 'github.com/login/oauth/authorize\?'
  $hasScope = $auth.Content -match ("scope={0}" -f [regex]::Escape($Scope))
  Add-Check -Name 'oauth-auth-handshake' -Ok ($auth.StatusCode -eq 200 -and $hasHandshake -and $hasGithubAuth -and $hasScope) -Detail ("status={0}" -f $auth.StatusCode)
}
catch {
  Add-Check -Name 'oauth-auth-handshake' -Ok $false -Detail $_.Exception.Message
}

try {
  $cb = Invoke-WebRequest -Uri $callbackErrorUrl -UseBasicParsing -TimeoutSec 20
  $isFormat = ($cb.Content -match ("authorization:{0}:error:" -f [regex]::Escape($Provider))) -and ($cb.Content -match 'GitHub OAuth error: access_denied')
  Add-Check -Name 'oauth-callback-error-format' -Ok ($cb.StatusCode -eq 400 -and $isFormat) -Detail ("status={0}" -f $cb.StatusCode)
}
catch {
  if ($_.Exception.Response -and $_.Exception.Response.StatusCode.value__ -eq 400) {
    $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
    $body = $reader.ReadToEnd()
    $isFormat = ($body -match ("authorization:{0}:error:" -f [regex]::Escape($Provider))) -and ($body -match 'GitHub OAuth error: access_denied')
    Add-Check -Name 'oauth-callback-error-format' -Ok $isFormat -Detail 'status=400'
  }
  else {
    Add-Check -Name 'oauth-callback-error-format' -Ok $false -Detail $_.Exception.Message
  }
}

try {
  $admin = Invoke-WebRequest -Uri $adminUrl -UseBasicParsing -TimeoutSec 20
  $hasSelfHostAssets = ($admin.Content -match '/vendor/staticcms/main.css') -and ($admin.Content -match '/vendor/staticcms/static-cms-app.js')
  $oauthHost = ([System.Uri]$AuthBaseUrl).Host
  $hasOauthDomain = $admin.Content -match [regex]::Escape($oauthHost)
  Add-Check -Name 'admin-page-config' -Ok ($admin.StatusCode -eq 200 -and $hasSelfHostAssets -and $hasOauthDomain) -Detail ("status={0}" -f $admin.StatusCode)
}
catch {
  Add-Check -Name 'admin-page-config' -Ok $false -Detail $_.Exception.Message
}

$checks | Format-Table -AutoSize | Out-String | Write-Output

if ($checks.Result -contains 'FAIL') {
  exit 1
}
