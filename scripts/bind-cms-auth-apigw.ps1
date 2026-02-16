Param(
  [string]$FunctionName = "",

  [string]$Region = "",

  [string]$Namespace = "default",
  [string]$ServiceName = "iq1-cms-auth",
  [string]$Environment = "release",
  [int]$ServiceTimeout = 30,
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
  $output = & $Tccli scf GetFunction help 2>&1
  $text = ($output -join "`n")
  $isScfReady = $text -match "AVAILABLE PARAMETERS" -and $text -match "GetFunction"
  $isBaseOnly = $text -match "usage:\s*tccli\s*\[-h\]\s*\[--profile PROFILE\]" -and -not $isScfReady
  if ($LASTEXITCODE -ne 0 -or $isBaseOnly) {
    throw "tccli is installed but SCF/APIGW commands are unavailable. Install full plugins, e.g.: pip install tccli tencentcloud-cli-plugin-scf tencentcloud-cli-plugin-apigateway"
  }
}

function Invoke-Tccli {
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
    return @{ ok = $false; text = ($output -join "`n") }
  }

  return @{ ok = $true; text = ($output -join "`n") }
}

function Invoke-TccliWithPayloadFile {
  Param(
    [string]$Tccli,
    [string]$Action,
    [string]$Region,
    [hashtable]$Payload,
    [switch]$AllowFail
  )

  $workDir = Join-Path $env:TEMP ("iq1-cms-auth-bind-" + [guid]::NewGuid().ToString("N"))
  New-Item -Path $workDir -ItemType Directory | Out-Null

  try {
    $payloadPath = Join-Path $workDir "payload.json"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($payloadPath, ($Payload | ConvertTo-Json -Depth 12), $utf8NoBom)

    return Invoke-Tccli -Tccli $Tccli -CmdArgs @(
      "scf", $Action,
      "--region", $Region,
      "--cli-input-json", ("file://{0}" -f $payloadPath)
    ) -AllowFail:$AllowFail
  }
  finally {
    if (Test-Path $workDir) {
      Remove-Item $workDir -Recurse -Force
    }
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

function New-TriggerDesc {
  Param(
    [string]$Path,
    [string]$ServiceName,
    [string]$Environment,
    [int]$ServiceTimeout
  )

  $payload = @{
    api = @{
      apiName = ("iq1-cms-auth-{0}" -f $Path.TrimStart('/').Replace('/', '-'))
      apiDesc = ("CMS OAuth route {0}" -f $Path)
      authRequired = "FALSE"
      isIntegratedResponse = "TRUE"
      isBase64Encoded = "FALSE"
      serviceTimeout = "{0}" -f $ServiceTimeout
      requestConfig = @{
        path = $Path
        method = "GET"
      }
      serviceType = "HTTP"
      serviceConfig = @{
        method = "ANY"
        path = "/"
      }
      apiType = "NORMAL"
    }
    service = @{
      serviceName = $ServiceName
      serviceDesc = "Static CMS GitHub OAuth routes"
      protocol = "http&https"
    }
    release = @{
      environmentName = $Environment
      releaseDesc = "auto bind cms oauth routes"
    }
  }

  return ($payload | ConvertTo-Json -Depth 10 -Compress)
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
}

if ([string]::IsNullOrWhiteSpace($FunctionName)) {
  $FunctionName = (Read-Host "Enter SCF Function Name").Trim()
}

if ([string]::IsNullOrWhiteSpace($Region)) {
  $Region = (Read-Host "Enter SCF Region (e.g. ap-guangzhou)").Trim()
}

if ([string]::IsNullOrWhiteSpace($FunctionName) -or [string]::IsNullOrWhiteSpace($Region)) {
  throw "FunctionName and Region are required."
}

$paths = @("/auth", "/callback", "/health")

Write-Host "Binding API Gateway triggers to function $FunctionName ..." -ForegroundColor Yellow

foreach ($path in $paths) {
  $triggerDesc = New-TriggerDesc -Path $path -ServiceName $ServiceName -Environment $Environment -ServiceTimeout $ServiceTimeout
  $payload = @{
    Namespace = $Namespace
    FunctionName = $FunctionName
    TriggerName = "apigw"
    Type = "apigw"
    TriggerDesc = $triggerDesc
  }

  Write-Host ("Ensuring route {0}" -f $path) -ForegroundColor Yellow

  $updateResult = Invoke-TccliWithPayloadFile -Tccli $tccli -Action "UpdateTrigger" -Region $Region -Payload $payload -AllowFail

  if (-not $updateResult.ok) {
    $createResult = Invoke-TccliWithPayloadFile -Tccli $tccli -Action "CreateTrigger" -Region $Region -Payload $payload -AllowFail

    if (-not $createResult.ok) {
      Write-Host ("Failed for {0}" -f $path) -ForegroundColor Red
      Write-Host "You can retry manually with this TriggerDesc:" -ForegroundColor Red
      Write-Host $triggerDesc
      throw "CreateTrigger and UpdateTrigger both failed for $path"
    }
  }
}

Write-Host ""
Write-Host "API Gateway routes are bound to SCF." -ForegroundColor Green
Write-Host "Routes: GET /auth, GET /callback, GET /health"