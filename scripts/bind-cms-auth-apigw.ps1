Param(
  [Parameter(Mandatory = $true)]
  [string]$FunctionName,

  [Parameter(Mandatory = $true)]
  [string]$Region,

  [string]$Namespace = "default",
  [string]$ServiceName = "iq1-cms-auth",
  [string]$Environment = "release",
  [int]$ServiceTimeout = 30
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

function Invoke-Tccli {
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
    return @{ ok = $false; text = ($output -join "`n") }
  }

  return @{ ok = $true; text = ($output -join "`n") }
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
$paths = @("/auth", "/callback", "/health")

Write-Host "Binding API Gateway triggers to function $FunctionName ..." -ForegroundColor Yellow

foreach ($path in $paths) {
  $triggerDesc = New-TriggerDesc -Path $path -ServiceName $ServiceName -Environment $Environment -ServiceTimeout $ServiceTimeout

  Write-Host ("Ensuring route {0}" -f $path) -ForegroundColor Yellow

  $updateResult = Invoke-Tccli -Tccli $tccli -Args @(
    "scf", "UpdateTrigger",
    "--Region", $Region,
    "--Namespace", $Namespace,
    "--FunctionName", $FunctionName,
    "--TriggerName", "apigw",
    "--Type", "apigw",
    "--TriggerDesc", $triggerDesc
  ) -AllowFail

  if (-not $updateResult.ok) {
    $createResult = Invoke-Tccli -Tccli $tccli -Args @(
      "scf", "CreateTrigger",
      "--Region", $Region,
      "--Namespace", $Namespace,
      "--FunctionName", $FunctionName,
      "--TriggerName", "apigw",
      "--Type", "apigw",
      "--TriggerDesc", $triggerDesc
    ) -AllowFail

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