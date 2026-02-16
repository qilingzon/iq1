Param(
  [Parameter(Mandatory = $true)]
  [string]$FunctionName,

  [Parameter(Mandatory = $true)]
  [string]$Region,

  [Parameter(Mandatory = $true)]
  [string]$GithubClientId,

  [Parameter(Mandatory = $true)]
  [string]$GithubClientSecret,

  [Parameter(Mandatory = $true)]
  [string]$PublicBaseUrl,

  [Parameter(Mandatory = $true)]
  [string]$AllowedOrigins,

  [string]$OauthStateSecret = "",
  [string]$Namespace = "default",
  [int]$MemorySize = 128,
  [int]$Timeout = 30,
  [string]$Runtime = "Nodejs18.15",
  [string]$Handler = "index.main_handler"
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

function New-RandomSecret {
  return ([guid]::NewGuid().ToString("N") + [guid]::NewGuid().ToString("N"))
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
$PublicBaseUrl = Normalize-Url $PublicBaseUrl
if ([string]::IsNullOrWhiteSpace($OauthStateSecret)) {
  $OauthStateSecret = New-RandomSecret
}

$projectRoot = Split-Path -Parent $PSScriptRoot
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