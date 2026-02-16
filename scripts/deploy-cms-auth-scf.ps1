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
  [string]$SecretsFile = ".secrets/cms-auth.local.json",
  [string]$Role = ""
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
  $output = & $Tccli scf GetFunction help 2>&1
  $text = ($output -join "`n")
  $isScfReady = $text -match "AVAILABLE PARAMETERS" -and $text -match "GetFunction"
  $isBaseOnly = $text -match "usage:\s*tccli\s*\[-h\]\s*\[--profile PROFILE\]" -and -not $isScfReady
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
    [string[]]$CmdArgs,
    [switch]$AllowFail
  )

  $previousEap = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = & $Tccli @CmdArgs 2>&1
  }
  finally {
    $ErrorActionPreference = $previousEap
  }
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

function Invoke-TccliText {
  Param(
    [string]$Tccli,
    [string[]]$CmdArgs,
    [switch]$AllowFail
  )

  $previousEap = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = & $Tccli @CmdArgs 2>&1
  }
  finally {
    $ErrorActionPreference = $previousEap
  }
  if ($LASTEXITCODE -ne 0 -and -not $AllowFail) {
    throw "tccli failed: $($output -join [Environment]::NewLine)"
  }

  if ($LASTEXITCODE -ne 0 -and $AllowFail) {
    return $null
  }

  return ($output -join "`n")
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
  $indexMjsPath = Join-Path $workDir "index.mjs"
  $indexJsPath = Join-Path $workDir "index.js"

  Copy-Item $sourceFile $indexMjsPath -Force
  @'
exports.main_handler = async function (event, context) {
  const mod = await import("./index.mjs");
  return mod.main_handler(event, context);
};
'@ | Set-Content -Path $indexJsPath -Encoding UTF8

  $zipPath = Join-Path $workDir "function.zip"
  Compress-Archive -Path @($indexMjsPath, $indexJsPath) -DestinationPath $zipPath -Force

  $zipBase64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($zipPath))

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
  $getRes = Invoke-TccliJson -Tccli $tccli -CmdArgs @(
    "scf", "GetFunction",
    "--region", $Region,
    "--Namespace", $Namespace,
    "--FunctionName", $FunctionName
  ) -AllowFail

  if (-not $getRes) {
    $exists = $false
  }

  if (-not $exists) {
    Write-Host "Creating function $FunctionName ..." -ForegroundColor Yellow
    $createPayload = @{
      Namespace = $Namespace
      FunctionName = $FunctionName
      Type = "Event"
      Runtime = $Runtime
      Handler = $Handler
      MemorySize = $MemorySize
      Timeout = $Timeout
      Code = @{ ZipFile = $zipBase64 }
      Environment = ($envJson | ConvertFrom-Json)
      AutoCreateClsTopic = "FALSE"
    }
    if (-not [string]::IsNullOrWhiteSpace($Role)) {
      $createPayload.Role = $Role
    }
    $createPayloadPath = Join-Path $workDir "create-function.json"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($createPayloadPath, ($createPayload | ConvertTo-Json -Depth 10), $utf8NoBom)

    Invoke-TccliText -Tccli $tccli -CmdArgs @(
      "scf", "CreateFunction",
      "--region", $Region,
      "--cli-input-json", ("file://{0}" -f $createPayloadPath)
    ) | Out-Null
  }
  else {
    Write-Host "Updating function code..." -ForegroundColor Yellow
    Invoke-TccliText -Tccli $tccli -CmdArgs @(
      "scf", "UpdateFunctionCode",
      "--region", $Region,
      "--Namespace", $Namespace,
      "--FunctionName", $FunctionName,
      "--Handler", $Handler,
      "--ZipFile", $zipBase64
    ) | Out-Null

    Write-Host "Updating function configuration..." -ForegroundColor Yellow
    $updatePayload = @{
      Namespace = $Namespace
      FunctionName = $FunctionName
      MemorySize = $MemorySize
      Timeout = $Timeout
      Environment = ($envJson | ConvertFrom-Json)
    }
    if (-not [string]::IsNullOrWhiteSpace($Role)) {
      $updatePayload.Role = $Role
    }
    $updatePayloadPath = Join-Path $workDir "update-config.json"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($updatePayloadPath, ($updatePayload | ConvertTo-Json -Depth 10), $utf8NoBom)

    Invoke-TccliText -Tccli $tccli -CmdArgs @(
      "scf", "UpdateFunctionConfiguration",
      "--region", $Region,
      "--cli-input-json", ("file://{0}" -f $updatePayloadPath)
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