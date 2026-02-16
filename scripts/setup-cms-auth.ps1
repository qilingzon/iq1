Param(
  [string]$SiteUrl = "",
  [string]$AuthBaseUrl = "",
  [string]$Repo = "qilingzon/iq1",
  [string]$Branch = "main",
  [string]$Region = "ap-guangzhou"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Normalize-Url([string]$value) {
  if ([string]::IsNullOrWhiteSpace($value)) { return "" }
  return $value.Trim().TrimEnd('/')
}

function New-RandomSecret() {
  return ([guid]::NewGuid().ToString("N") + [guid]::NewGuid().ToString("N"))
}

$SiteUrl = Normalize-Url $SiteUrl
$AuthBaseUrl = Normalize-Url $AuthBaseUrl

if ([string]::IsNullOrWhiteSpace($SiteUrl)) {
  $SiteUrl = Normalize-Url (Read-Host "Enter site URL (e.g. https://example.com)")
}

if ([string]::IsNullOrWhiteSpace($AuthBaseUrl)) {
  $AuthBaseUrl = Normalize-Url (Read-Host "Enter auth service URL (e.g. https://auth.example.com)")
}

if ([string]::IsNullOrWhiteSpace($SiteUrl) -or [string]::IsNullOrWhiteSpace($AuthBaseUrl)) {
  throw "Site URL and auth service URL are required."
}

$stateSecret = New-RandomSecret
$callbackUrl = "{0}/callback" -f $AuthBaseUrl
$healthUrl = "{0}/health" -f $AuthBaseUrl

$outputDir = Join-Path $PSScriptRoot "..\docs"
$outputFile = Join-Path $outputDir "cms-auth.generated.txt"

$report = @"
================= Static CMS GitHub Auth Parameters =================

[GitHub OAuth App]
Homepage URL: $SiteUrl
Authorization callback URL: $callbackUrl

[SCF Environment Variables]
GITHUB_CLIENT_ID=<your GitHub Client ID>
GITHUB_CLIENT_SECRET=<your GitHub Client Secret>
PUBLIC_BASE_URL=$AuthBaseUrl
OAUTH_STATE_SECRET=$stateSecret
ALLOWED_ORIGINS=$SiteUrl

[Website Environment Variables (EO)]
CMS_BASE_URL=$AuthBaseUrl
CMS_AUTH_ENDPOINT=/auth
CMS_GITHUB_REPO=$Repo
CMS_GITHUB_BRANCH=$Branch

[Tencent Cloud Suggested Settings]
Region=$Region
FunctionEntry=index.main_handler
FunctionRuntime=Nodejs18.15

[Validation URLs]
Health Check: $healthUrl
Admin URL: $SiteUrl/admin

=====================================================================
"@

if (-not (Test-Path $outputDir)) {
  New-Item -Path $outputDir -ItemType Directory | Out-Null
}

$report | Set-Content -Path $outputFile -Encoding UTF8

Write-Host ""
Write-Host "Generated deployment parameters:" -ForegroundColor Green
Write-Host "   $outputFile" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "1) Create GitHub OAuth App using the generated values"
Write-Host "2) Copy [SCF Environment Variables] into Tencent SCF"
Write-Host "3) Copy [Website Environment Variables] into EO"
Write-Host ""