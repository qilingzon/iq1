Param(
  [string]$FunctionName = "",

  [string]$Region = "",

  [string]$GithubClientId = "",
  [string]$GithubClientSecret = "",
  [string]$PublicBaseUrl = "",
  [string]$AllowedOrigins = "",

  [string]$OauthStateSecret = "",
  [string]$Namespace = "default",
  [int]$MemorySize = 128,
  [int]$Timeout = 30,
  [string]$Runtime = "Nodejs18.15",
  [string]$Handler = "index.main_handler",
  [string]$SecretsFile = ".secrets/cms-auth.local.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Require-Tccli {
  $tccliExe = "$env:AppData\Python\Python312\Scripts\tccli.exe"
  if (Test-Path $tccliExe) { return $tccliExe }

  $cmd = Get-Command tccli -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }

  throw "tccli not found. Please install tccli first."
}

function Assert-TccliScfReady([string]$Tccli) {
  $output = & $Tccli scf --help 2>&1
  $text = ($output -join "`n")
  $isBaseOnly = $text -match "usage:\s*tccli\s*\[-h\]\s*\[--profile PROFILE\]"
  if ($LASTEXITCODE -ne 0 -or $isBaseOnly) {
    throw "tccli is installed but SCF command is unavailable. Install full plugins, e.g.: pip install tccli tencentcloud-cli-plugin-scf tencentcloud-cli-plugin-apigateway"
  }
}

function New-RandomSecret {
  return ([guid]::NewGuid().ToString("N") + [guid]::NewGuid().ToString("N"))
}

function Convert-SecureToPlain([SecureString]$secure) {
  if (-not $secure) { return "" }
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
  try {
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  }
  finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  }
}

function Resolve-SecretsPath([string]$rawPath, [string]$projectRoot) {
  if ([string]::IsNullOrWhiteSpace($rawPath)) { return "" }
  if ([IO.Path]::IsPathRooted($rawPath)) { return $rawPath }
  return Join-Path $projectRoot $rawPath
}

function Read-LocalSecretStore([string]$path) {
  if (-not (Test-Path $path)) { return $null }
  $text = Get-Content -Path $path -Raw -Encoding UTF8
  if ([string]::IsNullOrWhiteSpace($text)) { return $null }
  return ($text | ConvertFrom-Json)
}

function Invoke-TccliJson {
  Param(
    [string]$Tccli,
    [string[]]$Args,
    [switch]$AllowFail
  )

  $output = & $Tccli @Args 2>&1
  if ($LASTEXITCODE -ne 0 -and -not $AllowFail) {
    throw "tccli failed: $($output -join [Environment]::NewLine)"
  }

  if ($LASTEXITCODE -ne 0 -and $AllowFail) {
    return $null
  }

  $text = ($output -join "`n").Trim()
  if ([string]::IsNullOrWhiteSpace($text)) { return $null }
  return $text | ConvertFrom-Json
}

function Normalize-Url([string]$value) {
  return $value.Trim().TrimEnd('/')
}

$tccli = Require-Tccli
Assert-TccliScfReady -Tccli $tccli
$projectRoot = Split-Path -Parent $PSScriptRoot
$secretPath = Resolve-SecretsPath -rawPath $SecretsFile -projectRoot $projectRoot
$secretStore = Read-LocalSecretStore -path $secretPath

if ($secretStore) {
  if ([string]::IsNullOrWhiteSpace($FunctionName) -and $secretStore.functionName) {
    $FunctionName = [string]$secretStore.functionName
  }

  if ([string]::IsNullOrWhiteSpace($Region) -and $secretStore.region) {
    $Region = [string]$secretStore.region
  }

  if ([string]::IsNullOrWhiteSpace($GithubClientId) -and $secretStore.githubClientId) {
    $GithubClientId = [string]$secretStore.githubClientId
  }

  if ([string]::IsNullOrWhiteSpace($GithubClientSecret) -and $secretStore.githubClientSecretEncrypted) {
    try {
      $GithubClientSecret = Convert-SecureToPlain (ConvertTo-SecureString $secretStore.githubClientSecretEncrypted)
    }
    catch {
      Write-Warning "Unable to decrypt githubClientSecretEncrypted from local store."
    }
  }

  if ([string]::IsNullOrWhiteSpace($PublicBaseUrl) -and $secretStore.authBaseUrl) {
    $PublicBaseUrl = [string]$secretStore.authBaseUrl
  }

  if ([string]::IsNullOrWhiteSpace($AllowedOrigins) -and $secretStore.allowedOrigins) {
    $AllowedOrigins = [string]$secretStore.allowedOrigins
  }

  if ([string]::IsNullOrWhiteSpace($OauthStateSecret) -and $secretStore.oauthStateSecret) {
    $OauthStateSecret = [string]$secretStore.oauthStateSecret
  }
}

if ([string]::IsNullOrWhiteSpace($GithubClientId)) {
  $GithubClientId = (Read-Host "Enter GitHub Client ID").Trim()
}

if ([string]::IsNullOrWhiteSpace($FunctionName)) {
  $FunctionName = (Read-Host "Enter SCF Function Name").Trim()
}

if ([string]::IsNullOrWhiteSpace($Region)) {
  $Region = (Read-Host "Enter SCF Region (e.g. ap-guangzhou)").Trim()
}

if ([string]::IsNullOrWhiteSpace($GithubClientSecret)) {
  $secureGithubSecret = Read-Host "Enter GitHub Client Secret" -AsSecureString
  $GithubClientSecret = Convert-SecureToPlain $secureGithubSecret
}

$PublicBaseUrl = Normalize-Url $PublicBaseUrl
$AllowedOrigins = Normalize-Url $AllowedOrigins

if ([string]::IsNullOrWhiteSpace($PublicBaseUrl) -or [string]::IsNullOrWhiteSpace($AllowedOrigins)) {
  throw "PublicBaseUrl and AllowedOrigins are required (or provide them in local secret store)."
}

if ([string]::IsNullOrWhiteSpace($OauthStateSecret)) {
  $OauthStateSecret = New-RandomSecret
}

if ([string]::IsNullOrWhiteSpace($GithubClientId) -or [string]::IsNullOrWhiteSpace($GithubClientSecret)) {
  throw "GithubClientId and GithubClientSecret are required."
}

if ([string]::IsNullOrWhiteSpace($FunctionName) -or [string]::IsNullOrWhiteSpace($Region)) {
  throw "FunctionName and Region are required."
}

$sourceFile = Join-Path $projectRoot "oauth/tencent-scf/github-oauth-broker.mjs"
if (-not (Test-Path $sourceFile)) {
  throw "Source file not found: $sourceFile"
}

$workDir = Join-Path $env:TEMP ("iq1-cms-auth-" + [guid]::NewGuid().ToString("N"))
New-Item -Path $workDir -ItemType Directory | Out-Null

try {
  Copy-Item $sourceFile (Join-Path $workDir "index.mjs") -Force

  $zipPath = Join-Path $workDir "function.zip"
  Compress-Archive -Path (Join-Path $workDir "index.mjs") -DestinationPath $zipPath -Force

  $zipBase64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($zipPath))
  $codeJson = @{ ZipFile = $zipBase64 } | ConvertTo-Json -Compress

  $envJson = @{
    Variables = @(
      @{ Key = "GITHUB_CLIENT_ID"; Value = $GithubClientId },
      @{ Key = "GITHUB_CLIENT_SECRET"; Value = $GithubClientSecret },
      @{ Key = "PUBLIC_BASE_URL"; Value = $PublicBaseUrl },
      @{ Key = "OAUTH_STATE_SECRET"; Value = $OauthStateSecret },
      @{ Key = "ALLOWED_ORIGINS"; Value = $AllowedOrigins }
    )
  } | ConvertTo-Json -Compress

  Write-Host "Checking function existence..." -ForegroundColor Yellow
  $exists = $true
  $getRes = Invoke-TccliJson -Tccli $tccli -Args @(
    "scf", "GetFunction",
    "--Region", $Region,
    "--Namespace", $Namespace,
    "--FunctionName", $FunctionName
  ) -AllowFail

  if (-not $getRes) {
    $exists = $false
  }

  if (-not $exists) {
    Write-Host "Creating function $FunctionName ..." -ForegroundColor Yellow
    Invoke-TccliJson -Tccli $tccli -Args @(
      "scf", "CreateFunction",
      "--Region", $Region,
      "--Namespace", $Namespace,
      "--FunctionName", $FunctionName,
      "--Type", "Event",
      "--Runtime", $Runtime,
      "--Handler", $Handler,
      "--MemorySize", "$MemorySize",
      "--Timeout", "$Timeout",
      "--Code", $codeJson,
      "--Environment", $envJson
    ) | Out-Null
  }
  else {
    Write-Host "Updating function code..." -ForegroundColor Yellow
    Invoke-TccliJson -Tccli $tccli -Args @(
      "scf", "UpdateFunctionCode",
      "--Region", $Region,
      "--Namespace", $Namespace,
      "--FunctionName", $FunctionName,
      "--Handler", $Handler,
      "--Code", $codeJson
    ) | Out-Null

    Write-Host "Updating function configuration..." -ForegroundColor Yellow
    Invoke-TccliJson -Tccli $tccli -Args @(
      "scf", "UpdateFunctionConfiguration",
      "--Region", $Region,
      "--Namespace", $Namespace,
      "--FunctionName", $FunctionName,
      "--MemorySize", "$MemorySize",
      "--Timeout", "$Timeout",
      "--Environment", $envJson
    ) | Out-Null
  }

  Write-Host "" 
  Write-Host "SCF deployment completed." -ForegroundColor Green
  Write-Host "FunctionName: $FunctionName"
  Write-Host "Region: $Region"
  Write-Host "Namespace: $Namespace"
  Write-Host "" 
  Write-Host "Next: bind API Gateway routes to this function:" -ForegroundColor Cyan
  Write-Host "  GET /auth"
  Write-Host "  GET /callback"
  Write-Host "  GET /health"
  Write-Host ""
  Write-Host "Then set site env var: CMS_BASE_URL=https://your-auth-domain" -ForegroundColor Cyan
}
finally {
  if (Test-Path $workDir) {
    Remove-Item $workDir -Recurse -Force
  }
}