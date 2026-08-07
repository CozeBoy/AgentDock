param(
  [switch]$Check,
  [switch]$Yes,
  [string]$Proxy,
  [switch]$NoProxy,
  [string]$WhisperModel
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ProxyEnvNames = @(
  "HTTP_PROXY",
  "HTTPS_PROXY",
  "ALL_PROXY",
  "http_proxy",
  "https_proxy",
  "all_proxy",
  "PIP_PROXY",
  "PIP_INDEX_URL",
  "PIP_EXTRA_INDEX_URL",
  "UV_DEFAULT_INDEX",
  "UV_INDEX",
  "UV_INDEX_URL"
)

function Save-EnvironmentVariables([string[]]$Names) {
  foreach ($name in $Names) {
    [pscustomobject]@{
      Name = $name
      Value = [Environment]::GetEnvironmentVariable($name, "Process")
    }
  }
}

function Restore-EnvironmentVariables($SavedItems) {
  foreach ($item in $SavedItems) {
    if ([string]::IsNullOrEmpty($item.Value)) {
      Remove-Item "Env:$($item.Name)" -ErrorAction SilentlyContinue
    } else {
      Set-Item "Env:$($item.Name)" $item.Value
    }
  }
}

$OriginalProxyEnv = @(Save-EnvironmentVariables $ProxyEnvNames)
$ProxyEnvApplied = $false
$PackageMirrorsApplied = $false
$NpmProxyChanged = $false
$OriginalNpmProxy = $null
$OriginalNpmHttpsProxy = $null
$NpmRegistryChanged = $false
$OriginalNpmRegistry = $null
$GitHttpsRewriteApplied = $false
$OriginalGitInsteadOf = $null
$OriginalGitHttpProxy = $null
$OriginalGitHttpsProxy = $null
$OriginalNoColor = $env:NO_COLOR
$NoColorApplied = $false
$YtDlpModulesRequested = $false
$WhisperModulesRequested = $false

function Say($Text) { Write-Host $Text }
function Ok($Text) { Write-Host "OK $Text" -ForegroundColor Green }
function Warn($Text) { Write-Host "WARN $Text" -ForegroundColor Yellow }
function Fail($Text) { Write-Host "ERR $Text" -ForegroundColor Red }
function Step($Text) { Write-Host ""; Write-Host "==> $Text" -ForegroundColor Cyan }
function HasCommand($Name) { [bool](Get-Command $Name -ErrorAction SilentlyContinue) }
function Get-CommandSource($Name) {
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}
function Test-TransientToolPath([string]$Path) {
  if (-not $Path) { return $false }
  $lower = $Path.ToLowerInvariant()
  return ($lower -like "*\hermes\*" -or $lower -like "*\.hermes\*" -or $lower -like "*\uv\cache\*" -or $lower -like "*\.cache\uv\*")
}
function HasGlobalTool($Name) {
  $source = Get-CommandSource $Name
  if (-not $source) { return $false }
  return (-not (Test-TransientToolPath $source))
}
function Get-NpmCommand {
  $cmd = Get-Command "npm.cmd" -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $cmd = Get-Command "npm.exe" -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $cmd = Get-Command "npm" -CommandType Application -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}
function HasNpm { return [bool](Get-NpmCommand) }
function Invoke-Npm([string[]]$Arguments) {
  $npm = Get-NpmCommand
  if (-not $npm) { throw "npm 不可用" }
  & $npm @Arguments
}
function Get-LarkCliCommand {
  $cmd = Get-Command "lark-cli.cmd" -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $cmd = Get-Command "lark-cli.exe" -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $cmd = Get-Command "lark-cli" -CommandType Application -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}
function HasLarkCli { return [bool](Get-LarkCliCommand) }
function Invoke-LarkCli([string[]]$Arguments) {
  $lark = Get-LarkCliCommand
  if (-not $lark) { throw "lark-cli 不可用" }
  & $lark @Arguments
}
$LastLarkAuthStatusRaw = $null
function Convert-LarkJsonOutput([string]$Text) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  $clean = $Text -replace "`e\[[0-9;?]*[ -/]*[@-~]", ""
  $start = $clean.IndexOf("{")
  $end = $clean.LastIndexOf("}")
  if ($start -lt 0 -or $end -le $start) { return $null }
  $json = $clean.Substring($start, $end - $start + 1)
  try { return ($json | ConvertFrom-Json) } catch { return $null }
}
function Get-LarkAuthStatus {
  $script:LastLarkAuthStatusRaw = $null
  if (-not (HasLarkCli)) { return $null }
  try {
    $raw = Invoke-LarkCli @("auth", "status") 2>&1 | Out-String
    $script:LastLarkAuthStatusRaw = $raw
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return (Convert-LarkJsonOutput $raw)
  } catch {
    return $null
  }
}
function Test-LarkCliNeedsBind($Status) {
  if (-not $Status) {
    return ("$script:LastLarkAuthStatusRaw" -match "not bound to it|not bound|not_configured")
  }
  return (($Status.ok -eq $false) -and ($Status.error.subtype -eq "not_configured") -and ("$($Status.error.message)" -match "not bound|not configured|not_configured"))
}
function Show-LarkAuthStatus {
  $status = Get-LarkAuthStatus
  if (Test-LarkCliNeedsBind $status) {
    Warn "lark-cli 授权：检测到 Hermes 上下文，但还没有绑定到 lark-cli"
    return $false
  }
  if (-not $status) {
    Warn "lark-cli 授权：未检测到有效配置"
    return $false
  }
  $botReady = $status.identities.bot.available -eq $true
  $userReady = $status.identities.user.available -eq $true
  if ($userReady) {
    Ok "lark-cli 授权：用户身份已登录"
    return $true
  }
  if ($botReady) {
    Warn "lark-cli 授权：Bot 身份可用，但用户身份未登录"
    return $false
  }
  Warn "lark-cli 授权：未登录"
  return $false
}
function Ensure-LarkCliBinding {
  $status = Get-LarkAuthStatus
  if (-not (Test-LarkCliNeedsBind $status)) { return $true }
  Say "需要先把 Hermes 的飞书应用配置绑定到 lark-cli，然后才能发起用户授权。"
  Say "身份策略说明："
  Say "  1) bot-only：只使用机器人身份，更安全；不能访问个人日历、邮箱、云文档等用户资源。"
  Say "  2) user-default：允许用户身份，适合需要访问个人资源的课程/工作流。"
  if (-not (Confirm-Step "绑定 Hermes 飞书配置到 lark-cli")) { return $false }
  $choice = Read-Host "选择身份策略 [1=bot-only / 2=user-default，默认 2]"
  $identity = if ($choice -eq "1") { "bot-only" } else { "user-default" }
  try {
    Invoke-LarkCli @("config", "bind", "--source", "hermes", "--identity", $identity)
    Ok "已绑定 lark-cli：$identity"
    return $true
  } catch {
    Warn "lark-cli 配置绑定失败：$($_.Exception.Message)"
    return $false
  }
}
function Get-HermesCommand {
  $cmd = Get-Command "hermes.cmd" -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $cmd = Get-Command "hermes.exe" -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $cmd = Get-Command "hermes" -CommandType Application -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $cmd = Get-Command "hermes" -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}
function HasHermes { return [bool](Get-HermesCommand) }
function Invoke-Hermes([string[]]$Arguments) {
  $hermes = Get-HermesCommand
  if (-not $hermes) { throw "hermes 不可用" }
  & $hermes @Arguments
}
function EffectsEnabled { return (-not $env:NO_COLOR) }

function Enable-AnsiConsole {
  if ($env:NO_COLOR) { return $false }
  try {
    $consoleKey = "HKCU:\Console"
    if (-not (Test-Path $consoleKey)) { New-Item -Path $consoleKey -Force | Out-Null }
    New-ItemProperty -Path $consoleKey -Name "VirtualTerminalLevel" -Value 1 -PropertyType DWord -Force | Out-Null
  } catch {
    return $false
  }
  return $false
}

function Prepare-ConsoleOutput {
  if (Enable-AnsiConsole) {
    Ok "已启用 Windows ANSI/VT 终端显示"
    return
  }
  if (-not $env:NO_COLOR) {
    $env:NO_COLOR = "1"
    $script:NoColorApplied = $true
    Warn "当前终端不支持 ANSI/VT 显示，已为子安装器临时关闭颜色输出"
  }
}

function Show-Intro {
  if (-not (EffectsEnabled)) { return }
  Write-Host ""
  Write-Host "    ___                    __  ____             __  " -ForegroundColor Cyan
  Write-Host "   /   |  ____ ____  ____ / /_/ __ \____  _____/ /__" -ForegroundColor Cyan
  Write-Host "  / /| | / __ `/ _ \/ __ `/ __/ / / / __ \/ ___/ //_/" -ForegroundColor Cyan
  Write-Host " / ___ |/ /_/ /  __/ /_/ / /_/ /_/ / /_/ / /__/ ,<   " -ForegroundColor Cyan
  Write-Host "/_/  |_|\__, /\___/\__,_/\__/_____/\____/\___/_/|_|  " -ForegroundColor Cyan
  Write-Host "       /____/                                         " -ForegroundColor Cyan
  $title = "AgentDock"
  foreach ($ch in $title.ToCharArray()) {
    Write-Host -NoNewline $ch -ForegroundColor White
    Start-Sleep -Milliseconds 25
  }
  Write-Host " Agent environment bootstrap" -ForegroundColor DarkGray
  Write-Host -NoNewline "[" -ForegroundColor DarkGray
  for ($i = 0; $i -lt 28; $i++) {
    Write-Host -NoNewline "#" -ForegroundColor DarkGray
    Start-Sleep -Milliseconds 15
  }
  Write-Host "] ready" -ForegroundColor DarkGray
  Write-Host ""
}

function Invoke-WithSpinner([string]$Label, [scriptblock]$Action) {
  if (-not (EffectsEnabled)) {
    try {
      & $Action
      return 0
    } catch {
      Write-Error $_
      return 1
    }
  }
  $job = Start-Job -ScriptBlock $Action
  $spin = @("|", "/", "-", "\")
  $i = 0
  while ($job.State -eq "Running") {
    Write-Host -NoNewline "`r$($spin[$i % $spin.Count]) $Label..." -ForegroundColor Cyan
    $i++
    Start-Sleep -Milliseconds 120
  }
  Receive-Job $job | Out-Host
  $state = $job.State
  $hadError = $job.ChildJobs[0].Error.Count -gt 0
  Remove-Job $job -Force
  if ($state -eq "Completed" -and -not $hadError) {
    Write-Host "`rOK $Label    " -ForegroundColor Green
    return 0
  }
  Write-Host "`rERR $Label    " -ForegroundColor Red
  return 1
}

$GithubAccelerators = @(
  "https://ghfast.top/",
  "https://gh-proxy.com/",
  "https://gh.llkk.cc/"
)

function Normalize-ProxyValue([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
  $Value = $Value.Trim()
  if ($Value -match '^\d+$') { return "http://127.0.0.1:$Value" }
  if ($Value -match '^[^/:]+:\d+$') { return "http://$Value" }
  return $Value
}

function Choose-Proxy {
  if ($NoProxy) { return "" }
  if ($Proxy) { return Normalize-ProxyValue $Proxy }
  if ($Yes) { return "http://127.0.0.1:7890" }

  Step "网络代理设置"
  Say "请选择下载代理："
  Say "  1) http://127.0.0.1:7890"
  Say "  2) http://127.0.0.1:7897"
  Say "  3) http://127.0.0.1:1080"
  Say "  4) http://127.0.0.1:10808"
  Say "  5) 自定义"
  Say "  6) 不使用代理"
  $choice = Read-Host "输入序号、自定义代理，或只输入端口 [默认 1]"
  if ([string]::IsNullOrWhiteSpace($choice)) { $choice = "1" }
  switch ($choice) {
    "1" { "http://127.0.0.1:7890" }
    "2" { "http://127.0.0.1:7897" }
    "3" { "http://127.0.0.1:1080" }
    "4" { "http://127.0.0.1:10808" }
    "5" {
      $custom = Read-Host "请输入代理地址或端口"
      Normalize-ProxyValue $custom
    }
    "6" { "" }
    default { Normalize-ProxyValue $choice }
  }
}

$ProxyUrl = Choose-Proxy
if ($ProxyUrl) {
  $env:HTTP_PROXY = $ProxyUrl
  $env:HTTPS_PROXY = $ProxyUrl
  $env:ALL_PROXY = $ProxyUrl
  $env:http_proxy = $ProxyUrl
  $env:https_proxy = $ProxyUrl
  $env:all_proxy = $ProxyUrl
  $env:PIP_PROXY = $ProxyUrl
  $script:ProxyEnvApplied = $true
  Ok "已启用代理：$ProxyUrl"
  Say "子安装器将继承代理环境变量：HTTP_PROXY / HTTPS_PROXY / ALL_PROXY / PIP_PROXY"
} else {
  Warn "未启用代理"
}

function Restore-ProxyEnvironment {
  if ($script:NoColorApplied) {
    if ([string]::IsNullOrEmpty($script:OriginalNoColor)) {
      Remove-Item "Env:NO_COLOR" -ErrorAction SilentlyContinue
    } else {
      Set-Item "Env:NO_COLOR" $script:OriginalNoColor
    }
  }
  if ($script:ProxyEnvApplied) {
    Restore-EnvironmentVariables $script:OriginalProxyEnv
  }
  if ($script:NpmProxyChanged -and (HasNpm)) {
    if ($script:OriginalNpmProxy) { Invoke-Npm @("config", "set", "proxy", $script:OriginalNpmProxy) | Out-Null } else { Invoke-Npm @("config", "delete", "proxy") | Out-Null }
    if ($script:OriginalNpmHttpsProxy) { Invoke-Npm @("config", "set", "https-proxy", $script:OriginalNpmHttpsProxy) | Out-Null } else { Invoke-Npm @("config", "delete", "https-proxy") | Out-Null }
  }
  if ($script:NpmRegistryChanged -and (HasNpm)) {
    if ($script:OriginalNpmRegistry) { Invoke-Npm @("config", "set", "registry", $script:OriginalNpmRegistry) | Out-Null } else { Invoke-Npm @("config", "delete", "registry") | Out-Null }
  }
  Restore-GitHttpsRewrite
  if ($script:ProxyEnvApplied -or $script:PackageMirrorsApplied -or $script:NpmProxyChanged -or $script:NpmRegistryChanged -or $script:GitHttpsRewriteApplied) {
    Ok "已恢复安装前的代理 / 镜像 / npm / Git 配置"
  }
  $script:ProxyEnvApplied = $false
  $script:PackageMirrorsApplied = $false
  $script:NpmProxyChanged = $false
  $script:NpmRegistryChanged = $false
  $script:NoColorApplied = $false
}

function Apply-NpmProxy {
  if (-not $ProxyUrl) { return }
  if (-not (HasNpm)) { return }
  if (-not $script:NpmProxyChanged) {
    $script:OriginalNpmProxy = (Invoke-Npm @("config", "get", "proxy") 2>$null)
    if ($script:OriginalNpmProxy -eq "null") { $script:OriginalNpmProxy = $null }
    $script:OriginalNpmHttpsProxy = (Invoke-Npm @("config", "get", "https-proxy") 2>$null)
    if ($script:OriginalNpmHttpsProxy -eq "null") { $script:OriginalNpmHttpsProxy = $null }
  }
  Invoke-Npm @("config", "set", "proxy", $ProxyUrl) | Out-Null
  Invoke-Npm @("config", "set", "https-proxy", $ProxyUrl) | Out-Null
  Invoke-Npm @("config", "set", "fetch-timeout", "600000") | Out-Null
  Invoke-Npm @("config", "set", "fetch-retries", "5") | Out-Null
  $script:NpmProxyChanged = $true
  Ok "已临时设置 npm 代理：$ProxyUrl"
}

function Set-NpmRegistryTemporary([string]$Registry) {
  if (-not (HasNpm)) { return }
  if (-not $script:NpmRegistryChanged) {
    $script:OriginalNpmRegistry = (Invoke-Npm @("config", "get", "registry") 2>$null)
    if ($script:OriginalNpmRegistry -eq "undefined") { $script:OriginalNpmRegistry = $null }
  }
  Invoke-Npm @("config", "set", "registry", $Registry) | Out-Null
  $script:NpmRegistryChanged = $true
}

function Apply-PackageMirrors {
  if ($script:PackageMirrorsApplied) {
    if (HasNpm) {
      if ($ProxyUrl) {
        Set-NpmRegistryTemporary "https://registry.npmjs.org/"
      } else {
        Set-NpmRegistryTemporary "https://registry.npmmirror.com"
      }
    }
    return
  }
  if ($ProxyUrl) {
    $env:PIP_INDEX_URL = "https://pypi.org/simple"
    Remove-Item Env:PIP_EXTRA_INDEX_URL -ErrorAction SilentlyContinue
    $env:UV_DEFAULT_INDEX = "https://pypi.org/simple"
    Remove-Item Env:UV_INDEX -ErrorAction SilentlyContinue
    Remove-Item Env:UV_INDEX_URL -ErrorAction SilentlyContinue
    $script:PackageMirrorsApplied = $true
    Ok "已临时设置 pip / uv 使用官方源，网络全部走代理"
    if (HasNpm) {
      Set-NpmRegistryTemporary "https://registry.npmjs.org/"
      Ok "已临时设置 npm registry：https://registry.npmjs.org/"
    }
    return
  }
  $env:PIP_INDEX_URL = "https://pypi.tuna.tsinghua.edu.cn/simple"
  $env:PIP_EXTRA_INDEX_URL = "https://mirrors.aliyun.com/pypi/simple https://pypi.org/simple"
  $env:UV_INDEX = "https://pypi.tuna.tsinghua.edu.cn/simple https://mirrors.aliyun.com/pypi/simple"
  $env:UV_DEFAULT_INDEX = "https://pypi.org/simple"
  $env:UV_INDEX_URL = $env:PIP_INDEX_URL
  $script:PackageMirrorsApplied = $true
  Ok "已临时设置 pip / uv 国内镜像，官方源作为兜底"
  if (HasNpm) {
    Set-NpmRegistryTemporary "https://registry.npmmirror.com"
    Ok "已临时设置 npm registry：https://registry.npmmirror.com"
  }
}

function Invoke-WithoutProxy([scriptblock]$Action) {
  $names = @("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy", "PIP_PROXY")
  $saved = @(Save-EnvironmentVariables $names)
  foreach ($key in $names) { Remove-Item "Env:$key" -ErrorAction SilentlyContinue }
  try { & $Action } finally {
    Restore-EnvironmentVariables $saved
  }
}

function Install-NpmGlobal([string]$PackageName) {
  if ($ProxyUrl) {
    Apply-NpmProxy
    Set-NpmRegistryTemporary "https://registry.npmjs.org/"
    Say "执行：npm install -g $PackageName（走代理访问官方 npm registry）"
    Invoke-Npm @("install", "-g", $PackageName)
    return
  }
  Set-NpmRegistryTemporary "https://registry.npmmirror.com"
  Say "执行：npm install -g $PackageName（优先 npm 国内镜像）"
  Invoke-WithoutProxy { Invoke-Npm @("install", "-g", $PackageName) }
  if ($LASTEXITCODE -ne 0) {
    Warn "npm 国内镜像安装失败，切换官方源直连重试：$PackageName"
    Set-NpmRegistryTemporary "https://registry.npmjs.org/"
    Invoke-Npm @("install", "-g", $PackageName)
  }
}

function Install-PipUser([string]$PythonCommand, [string[]]$PipArgs) {
  if ($ProxyUrl) {
    Say "执行：$PythonCommand -m pip install --user $($PipArgs -join ' ')（走代理访问官方 PyPI）"
    $args = @("-m", "pip", "install", "--user", "--index-url", "https://pypi.org/simple") + $PipArgs
    Invoke-PythonCommand $PythonCommand $args
    if ($LASTEXITCODE -ne 0) {
      Warn "官方 PyPI 代理安装失败，切换国内镜像重试"
      $mirrorArgs = @("-m", "pip", "install", "--user", "--index-url", "https://pypi.tuna.tsinghua.edu.cn/simple", "--extra-index-url", "https://mirrors.aliyun.com/pypi/simple", "--extra-index-url", "https://pypi.org/simple") + $PipArgs
      Invoke-PythonCommand $PythonCommand $mirrorArgs
    }
    return
  }
  Say "执行：$PythonCommand -m pip install --user $($PipArgs -join ' ')（优先 pip 国内镜像）"
  $mirrorArgs = @("-m", "pip", "install", "--user", "--index-url", "https://pypi.tuna.tsinghua.edu.cn/simple", "--extra-index-url", "https://mirrors.aliyun.com/pypi/simple", "--extra-index-url", "https://pypi.org/simple") + $PipArgs
  Invoke-WithoutProxy { Invoke-PythonCommand $PythonCommand $mirrorArgs }
  if ($LASTEXITCODE -ne 0) {
    Warn "pip 国内镜像安装失败，切换官方源直连重试"
    $officialArgs = @("-m", "pip", "install", "--user", "--index-url", "https://pypi.org/simple") + $PipArgs
    Invoke-PythonCommand $PythonCommand $officialArgs
  }
}

function Install-UvTool([string]$PackageName, [string]$CommandName) {
  if (-not (HasCommand "uv")) { return $false }
  $userBin = Join-Path $env:USERPROFILE ".local\bin"
  New-Item -ItemType Directory -Force -Path $userBin | Out-Null
  Add-UserPath $userBin
  if ($ProxyUrl) {
    Say "执行：uv tool install $PackageName（走代理访问官方 PyPI，创建用户级命令入口）"
    & uv tool install $PackageName
  } else {
    Say "执行：uv tool install $PackageName（优先 uv / pip 镜像，创建用户级命令入口）"
    Invoke-WithoutProxy { & uv tool install $PackageName }
    if ($LASTEXITCODE -ne 0) { & uv tool install $PackageName }
  }
  Refresh-ProcessPath
  return (HasGlobalTool $CommandName)
}

function Get-PythonIdentity([string]$PythonCommand) {
  try {
    $code = "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}:{sys.executable}')"
    $result = Invoke-PythonCommand $PythonCommand @("-c", $code) 2>$null
    if ($LASTEXITCODE -eq 0 -and $result) { return ($result | Select-Object -First 1) }
  } catch {}
  return $null
}

function Get-PythonExecutablePath([string]$PythonCommand) {
  try {
    $result = Invoke-PythonCommand $PythonCommand @("-c", "import sys; print(sys.executable)") 2>$null
    if ($LASTEXITCODE -eq 0 -and $result) { return ($result | Select-Object -First 1) }
  } catch {}
  return $null
}

function Test-PythonCommand([string]$PythonCommand) {
  try {
    Invoke-PythonCommand $PythonCommand @("--version") *> $null
    return ($LASTEXITCODE -eq 0)
  } catch {
    return $false
  }
}

function Test-StandalonePython([string]$PythonCommand) {
  $exe = Get-PythonExecutablePath $PythonCommand
  if (-not $exe) { return $false }
  $lower = $exe.ToLowerInvariant()
  if ($lower -like "*\hermes\*" -or $lower -like "*\.hermes\*" -or $lower -like "*\uv\python\*" -or $lower -like "*\uv\cache\*") {
    return $false
  }
  if (Test-PythonVirtualEnv $PythonCommand) { return $false }
  if (Test-PythonExternallyManaged $PythonCommand) { return $false }
  return $true
}

function Test-PythonHasPip([string]$PythonCommand) {
  try {
    Invoke-PythonCommand $PythonCommand @("-m", "pip", "--version") *> $null
    return ($LASTEXITCODE -eq 0)
  } catch {
    return $false
  }
}

function Test-PythonExternallyManaged([string]$PythonCommand) {
  try {
    $code = "import sysconfig, pathlib; print(pathlib.Path(sysconfig.get_path('stdlib'), 'EXTERNALLY-MANAGED').exists())"
    $value = Invoke-PythonCommand $PythonCommand @("-c", $code) 2>$null | Select-Object -First 1
    return ($value -eq "True")
  } catch {
    return $false
  }
}

function Test-PythonVirtualEnv([string]$PythonCommand) {
  try {
    $code = "import sys; print(sys.prefix != sys.base_prefix)"
    $value = Invoke-PythonCommand $PythonCommand @("-c", $code) 2>$null | Select-Object -First 1
    return ($value -eq "True")
  } catch {
    return $false
  }
}

function Get-PythonTargets {
  $raw = New-Object System.Collections.Generic.List[string]
  $python3 = Get-Python3Command
  if ($python3) { $raw.Add($python3) }
  if (HasCommand "py") {
    $raw.Add("py -3")
    $raw.Add("py -3.11")
    try {
      py -0p 2>$null | ForEach-Object {
        $line = "$_".Trim()
        if ($line -match '([A-Za-z]:\\.*python\.exe)$') {
          $raw.Add($matches[1])
        }
      }
    } catch {}
  }
  if (HasCommand "python") { $raw.Add("python") }
  if (HasCommand "python3") { $raw.Add("python3") }

  foreach ($pattern in @("$env:ProgramFiles\Python*", "$env:LOCALAPPDATA\Programs\Python\Python*", "$env:APPDATA\Python\Python*")) {
    try {
      Get-ChildItem -Path $pattern -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $exe = Join-Path $_.FullName "python.exe"
        if (Test-Path $exe) { $raw.Add($exe) }
      }
    } catch {}
  }

  $seen = @{}
  foreach ($candidate in $raw) {
    if (-not $candidate) { continue }
    if (-not (Test-PythonCommand $candidate)) { continue }
    if (-not (Test-StandalonePython $candidate)) {
      Warn "跳过 Hermes/uv/venv 托管 Python：$candidate"
      continue
    }
    if (-not (Test-PythonHasPip $candidate)) {
      Warn "跳过 Python（未安装 pip）：$candidate"
      continue
    }
    $identity = Get-PythonIdentity $candidate
    if (-not $identity -or $seen.ContainsKey($identity)) { continue }
    $seen[$identity] = $true
    $candidate
  }
}

function Get-MainPythonCommand {
  $python3 = Get-Python3Command
  if ($python3) { return $python3 }
  if (HasCommand "py") { return "py -3" }
  if (HasCommand "python") { return "python" }
  return $null
}

function Get-PythonUserScripts([string]$PythonCommand) {
  try {
    $base = Invoke-PythonCommand $PythonCommand @("-m", "site", "--user-base") 2>$null | Select-Object -First 1
    if ($base) { return (Join-Path $base "Scripts") }
  } catch {}
  return $null
}

function Install-PythonModuleAll([string]$PackageName, [string]$Label) {
  $installed = $false
  $mainPython = Get-MainPythonCommand
  if ($mainPython) { Say "主 Python 优先：$(Get-PythonCommandDisplay $mainPython)" }
  foreach ($python in (Get-PythonTargets)) {
    Say "为 Python 安装 $Label 模块：$python"
    Install-PipUser $python @("--upgrade", $PackageName)
    if ($LASTEXITCODE -eq 0) { $installed = $true }
  }
  if ($mainPython) {
    $scripts = Get-PythonUserScripts $mainPython
    if ($scripts -and (Test-Path $scripts)) { Add-UserPath $scripts }
  }
  return $installed
}

function Install-YtDlpModules {
  $installed = Install-PythonModuleAll "yt-dlp" "yt-dlp"
  if (-not (HasGlobalTool "yt-dlp")) {
    Warn "pip 安装后仍未检测到全局 yt-dlp 命令，尝试 uv tool install 兜底"
    $installed = (Install-UvTool "yt-dlp" "yt-dlp") -or $installed
  }
  return $installed
}

function Install-WhisperModules {
  $installed = Install-PythonModuleAll "openai-whisper" "Whisper"
  if (-not (HasGlobalTool "whisper")) {
    Warn "pip 安装后仍未检测到全局 whisper 命令，尝试 uv tool install 兜底"
    $installed = (Install-UvTool "openai-whisper" "whisper") -or $installed
  }
  return $installed
}

function Enable-GitHttpsRewrite {
  if ($script:GitHttpsRewriteApplied) { return }
  if (-not (HasCommand "git")) { return }
  $script:OriginalGitInsteadOf = (git config --global --get url.https://github.com/.insteadOf 2>$null)
  $script:OriginalGitHttpProxy = (git config --global --get http.proxy 2>$null)
  $script:OriginalGitHttpsProxy = (git config --global --get https.proxy 2>$null)
  git config --global url.https://github.com/.insteadOf git@github.com: | Out-Null
  if ($ProxyUrl) {
    git config --global http.proxy $ProxyUrl | Out-Null
    git config --global https.proxy $ProxyUrl | Out-Null
  }
  $script:GitHttpsRewriteApplied = $true
  Ok "已临时设置 Git：SSH 地址改走 HTTPS，HTTPS clone 使用代理"
}

function Restore-GitHttpsRewrite {
  if (-not $script:GitHttpsRewriteApplied -or -not (HasCommand "git")) { return }
  if ($script:OriginalGitInsteadOf) {
    git config --global url.https://github.com/.insteadOf $script:OriginalGitInsteadOf | Out-Null
  } else {
    git config --global --unset url.https://github.com/.insteadOf 2>$null
  }
  if ($script:OriginalGitHttpProxy) {
    git config --global http.proxy $script:OriginalGitHttpProxy | Out-Null
  } else {
    git config --global --unset http.proxy 2>$null
  }
  if ($script:OriginalGitHttpsProxy) {
    git config --global https.proxy $script:OriginalGitHttpsProxy | Out-Null
  } else {
    git config --global --unset https.proxy 2>$null
  }
  $script:GitHttpsRewriteApplied = $false
  Ok "已恢复安装前的 Git 配置"
}

function Confirm-Step([string]$Prompt) {
  if ($Yes) { return $true }
  Write-Host "等待确认：$Prompt" -ForegroundColor Yellow
  $ans = Read-Host "请按回车继续；如果你确认已安装但未检测到，输入 s 跳过；输入 q 退出"
  if ($ans -match '^[qQ]$') { Graceful-Exit }
  if ($ans -match '^[sS]$') { return $false }
  Write-Host "已确认，开始处理：$Prompt" -ForegroundColor Green
  return $true
}

function Keep-TerminalOpen {
  if ($Yes) { return }
  if ($env:AGENTDOCK_ELEVATED_WINDOW -eq "1") {
    Write-Host "脚本已结束，管理员窗口将保持打开。输入 exit 后再退出。" -ForegroundColor DarkGray
    return
  }
  Write-Host "脚本已结束，终端将保持打开。输入 exit 后再退出。" -ForegroundColor DarkGray
  if (Get-Command pwsh -ErrorAction SilentlyContinue) {
    pwsh -NoExit
  } else {
    powershell -NoExit
  }
}

function Graceful-Exit {
  Restore-ProxyEnvironment
  Keep-TerminalOpen
  exit 0
}

function Ensure-Utf8Bom([string]$Path) {
  if (-not (Test-Path $Path)) { return }
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    return
  }
  $bom = [byte[]](0xEF, 0xBB, 0xBF)
  $combined = New-Object -TypeName "System.Byte[]" -ArgumentList ($bom.Length + $bytes.Length)
  [Array]::Copy($bom, 0, $combined, 0, $bom.Length)
  [Array]::Copy($bytes, 0, $combined, $bom.Length, $bytes.Length)
  [System.IO.File]::WriteAllBytes($Path, $combined)
}

function Copy-ScriptForElevation([string]$SourcePath, [string]$TargetPath) {
  Copy-Item -Path $SourcePath -Destination $TargetPath -Force
  Ensure-Utf8Bom $TargetPath
}

function Get-CurrentScriptPathForElevation {
  $tmpScript = Join-Path $env:TEMP "AgentDock-install-elevated.ps1"
  if ($PSCommandPath -and (Test-Path $PSCommandPath)) {
    Say "将当前脚本复制为 UTF-8 BOM 临时文件用于管理员运行：$tmpScript"
    Copy-ScriptForElevation $PSCommandPath $tmpScript
    return $tmpScript
  }
  if ($MyInvocation.MyCommand.Path -and (Test-Path $MyInvocation.MyCommand.Path)) {
    Say "将当前脚本复制为 UTF-8 BOM 临时文件用于管理员运行：$tmpScript"
    Copy-ScriptForElevation $MyInvocation.MyCommand.Path $tmpScript
    return $tmpScript
  }
  Say "当前脚本来自远程管道，将保存为 UTF-8 BOM 临时文件用于管理员运行：$tmpScript"
  Invoke-WebDownload "https://raw.githubusercontent.com/CozeBoy/AgentDock/main/install.ps1?ts=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())" $tmpScript
  Ensure-Utf8Bom $tmpScript
  return $tmpScript
}

function Build-ElevationArguments([string]$ScriptPath) {
  $scriptArgs = @()
  if ($Check) { $scriptArgs += "-Check" }
  if ($Yes) { $scriptArgs += "-Yes" }
  if ($NoProxy) { $scriptArgs += "-NoProxy" }
  if ($ProxyUrl) { $scriptArgs += @("-Proxy", "'$($ProxyUrl.Replace("'", "''"))'") }
  if ($WhisperModel) { $scriptArgs += @("-WhisperModel", "'$($WhisperModel.Replace("'", "''"))'") }
  $quotedScript = $ScriptPath.Replace("'", "''")
  $command = "`$env:AGENTDOCK_ELEVATION_ATTEMPTED='1'; `$env:AGENTDOCK_ELEVATED_WINDOW='1'; & '$quotedScript' $($scriptArgs -join ' '); Write-Host ''; Write-Host 'AgentDock 管理员窗口已结束，输入 exit 后再关闭。' -ForegroundColor DarkGray"
  return @("-NoProfile", "-ExecutionPolicy", "Bypass", "-NoExit", "-Command", $command)
}

function Suggest-Elevation {
  if (Test-IsAdministrator) {
    Ok "当前是管理员 PowerShell，将优先安装到 C:\Program Files 并写入系统 PATH"
    return
  }
  if ($env:AGENTDOCK_ELEVATION_ATTEMPTED -eq "1") {
    Warn "当前仍不是管理员，将安装到用户目录。"
    return
  }
  if ($Yes) {
    Warn "当前不是管理员，自动模式下不弹 UAC，将安装到用户目录。"
    return
  }
  Write-Host ""
  Warn "当前不是管理员 PowerShell。"
  Say "推荐以管理员身份运行：Node.js、Python、ffmpeg 等会安装到 C:\Program Files，并写入系统 PATH。"
  $ans = Read-Host "是否弹出 UAC 并以管理员身份重新运行？[Y=推荐 / n=继续用户目录安装]"
  if ($ans -match '^[nN]$') {
    Warn "继续使用用户目录安装。"
    return
  }
  try {
    $scriptPath = Get-CurrentScriptPathForElevation
    $arguments = Build-ElevationArguments $scriptPath
    $env:AGENTDOCK_ELEVATION_ATTEMPTED = "1"
    Start-Process -FilePath "powershell" -ArgumentList $arguments -Verb RunAs
    exit 0
  } catch {
    Warn "管理员重启失败：$($_.Exception.Message)"
    Warn "将继续使用用户目录安装。"
  }
}

function Normalize-WhisperModel([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
  $Value = $Value.Trim().ToLowerInvariant()
  switch ($Value) {
    "fast" { "turbo" }
    "normal" { "base" }
    "regular" { "base" }
    "default" { "base" }
    default { $Value }
  }
}

function Get-WhisperCachedModels {
  $items = New-Object System.Collections.Generic.List[string]
  $cacheRoots = @(
    $env:WHISPER_CACHE,
    $env:HF_HOME,
    $env:HUGGINGFACE_HUB_CACHE,
    $env:TRANSFORMERS_CACHE,
    (Join-Path $env:USERPROFILE ".cache\whisper"),
    (Join-Path $env:USERPROFILE ".cache\huggingface\hub"),
    (Join-Path $env:LOCALAPPDATA "huggingface\hub")
  ) | Where-Object { $_ -and (Test-Path $_) }

  foreach ($root in ($cacheRoots | Select-Object -Unique)) {
    try {
      if ($root -like "*\whisper") {
        Get-ChildItem -Path $root -File -ErrorAction SilentlyContinue |
          Where-Object { $_.Name -match '^(tiny|base|small|medium|large|turbo)(\..*)?\.pt$|^(tiny|base|small|medium|large|turbo)\.pt$' } |
          ForEach-Object {
            $model = $_.BaseName -replace '\..*$', ''
            $items.Add("$model：$($_.FullName)（$(Format-ByteSize $_.Length)）")
          }
      }
      Get-ChildItem -Path $root -Directory -Recurse -Depth 2 -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'whisper|faster-whisper|mlx.*whisper' } |
        ForEach-Object { $items.Add("$($_.Name)：$($_.FullName)") }
    } catch {}
  }
  return ($items | Select-Object -Unique)
}

function Show-WhisperCachedModels {
  $models = @(Get-WhisperCachedModels)
  if ($models.Count -eq 0) {
    Warn "未检测到已缓存的 Whisper 模型"
    return
  }
  Ok "已检测到 Whisper 模型缓存："
  foreach ($model in $models) { Say "  - $model" }
}

function Clear-WhisperModelCache([string]$Model) {
  $cacheRoots = @(
    $env:WHISPER_CACHE,
    (Join-Path $env:USERPROFILE ".cache\whisper")
  ) | Where-Object { $_ -and (Test-Path $_) }
  foreach ($root in ($cacheRoots | Select-Object -Unique)) {
    try {
      Get-ChildItem -Path $root -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "^$([regex]::Escape($Model))(\..*)?\.pt$" } |
        ForEach-Object {
          Warn "删除损坏或未完成的模型缓存：$($_.FullName)"
          Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
        }
    } catch {}
  }
}

function Get-WhisperModelCacheFiles([string]$Model) {
  $cacheRoots = @(
    $env:WHISPER_CACHE,
    (Join-Path $env:USERPROFILE ".cache\whisper")
  ) | Where-Object { $_ -and (Test-Path $_) }
  $files = New-Object System.Collections.Generic.List[object]
  foreach ($root in ($cacheRoots | Select-Object -Unique)) {
    try {
      Get-ChildItem -Path $root -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "^$([regex]::Escape($Model))(\..*)?\.pt$" } |
        ForEach-Object { $files.Add($_) }
    } catch {}
  }
  return $files
}

function Confirm-WhisperModelRedownload([string]$Model) {
  if ($Yes) { return "use" }
  $files = @(Get-WhisperModelCacheFiles $Model)
  if ($files.Count -eq 0) { return "download" }
  Warn "已存在 $Model 模型缓存："
  foreach ($file in $files) { Say "  - $($file.FullName)（$(Format-ByteSize $file.Length)）" }
  $answer = Read-Host "回车=使用现有缓存并校验；r=覆盖重新下载；s=跳过"
  switch ($answer.ToLowerInvariant()) {
    "r" { return "redownload" }
    "s" { return "skip" }
    default { return "use" }
  }
}

function Choose-WhisperModel {
  if ($WhisperModel) { return Normalize-WhisperModel $WhisperModel }
  if ($Yes) { return "turbo" }
  Step "Whisper 模型选择"
  Show-WhisperCachedModels
  Say "选择要预下载的 Whisper 模型："
  Say "  1) fast / turbo：约 1.6GB，809M 参数，速度优先，推荐日常使用"
  Say "  2) normal / base：约 142MB，74M 参数，常规轻量，适合快速试用"
  Say "  3) tiny：约 75MB，39M 参数，最快，准确率较低"
  Say "  4) small：约 466MB，244M 参数，准确率更好，资源占用适中"
  Say "  5) medium：约 1.5GB，769M 参数，准确率较高，下载和运行都更重"
  Say "  6) large：约 2.9GB，1.55B 参数，准确率最高，下载最大，运行最重"
  Say "  7) skip：跳过预下载，首次使用 Whisper 时再下载"
  $choice = Read-Host "输入序号或模型名 [默认 1]"
  if ([string]::IsNullOrWhiteSpace($choice)) { $choice = "1" }
  switch ($choice) {
    "1" { "turbo" }
    "2" { "base" }
    "3" { "tiny" }
    "4" { "small" }
    "5" { "medium" }
    "6" { "large" }
    "7" { "skip" }
    default { Normalize-WhisperModel $choice }
  }
}

function Download-WhisperModel([string]$Model) {
  $Model = Normalize-WhisperModel $Model
  if ([string]::IsNullOrWhiteSpace($Model)) { return }
  if ($Model -eq "skip") { Warn "已跳过 Whisper 模型预下载"; return }
  $allowed = @("tiny", "base", "small", "medium", "large", "turbo")
  if ($allowed -notcontains $Model) {
    Warn "未知 Whisper 模型：$Model，跳过预下载"
    return
  }
  Step "预下载 Whisper 模型：$Model"
  Say "首次加载会下载模型文件，Whisper 会显示缓存和下载进度。"
  $mainPython = Get-MainPythonCommand
  if (-not $mainPython) { Fail "未检测到可用 Python，无法预下载 Whisper 模型"; return }
  $cacheChoice = Confirm-WhisperModelRedownload $Model
  if ($cacheChoice -eq "skip") { Warn "已跳过 Whisper 模型：$Model"; return }
  if ($cacheChoice -eq "redownload") { Clear-WhisperModelCache $Model }
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    Say "Whisper 模型下载尝试 $attempt/3：$Model"
    Invoke-PythonCommand $mainPython @("-c", "import whisper; whisper.load_model('$Model'); print('Whisper model ready: $Model')")
    if ($LASTEXITCODE -eq 0) {
      Ok "Whisper 模型已就绪：$Model"
      return
    }
    Warn "Whisper 模型下载或校验失败：$Model"
    if ($attempt -lt 3) {
      Clear-WhisperModelCache $Model
      Warn "准备重试下载 Whisper 模型：$Model"
    }
  }
  Fail "Whisper 模型下载失败，已重试 3 次：$Model"
}

function Format-ByteSize([double]$Bytes) {
  if ($Bytes -ge 1GB) { return ("{0:N1} GB" -f ($Bytes / 1GB)) }
  if ($Bytes -ge 1MB) { return ("{0:N1} MB" -f ($Bytes / 1MB)) }
  if ($Bytes -ge 1KB) { return ("{0:N1} KB" -f ($Bytes / 1KB)) }
  return ("{0:N0} B" -f $Bytes)
}

function Write-DownloadProgressLine([double]$Downloaded, [double]$Total) {
  if ($Total -gt 0) {
    $percent = [Math]::Min(100, ($Downloaded / $Total) * 100)
    $line = "下载进度：{0,6:N1}%  {1} / {2}" -f $percent, (Format-ByteSize $Downloaded), (Format-ByteSize $Total)
  } else {
    $line = "下载进度：{0}" -f (Format-ByteSize $Downloaded)
  }
  Write-Host -NoNewline ("`r{0,-78}" -f $line) -ForegroundColor Cyan
}

function Invoke-WebDownload([string]$Url, [string]$OutFile) {
  Say "下载地址：$Url"
  Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
  $request = [System.Net.HttpWebRequest]::Create($Url)
  $request.Method = "GET"
  $request.UserAgent = "AgentDock Installer"
  $request.Timeout = 60000
  $request.ReadWriteTimeout = 60000
  $request.AllowAutoRedirect = $true
  if ($ProxyUrl) {
    $request.Proxy = New-Object System.Net.WebProxy($ProxyUrl, $true)
  }

  $response = $null
  $inputStream = $null
  $outputStream = $null
  try {
    $response = $request.GetResponse()
    $total = [double]$response.ContentLength
    $inputStream = $response.GetResponseStream()
    $outputStream = [System.IO.File]::Open($OutFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    $buffer = New-Object byte[] 81920
    $downloaded = [double]0
    $lastUpdate = Get-Date
    while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
      $outputStream.Write($buffer, 0, $read)
      $downloaded += $read
      if (((Get-Date) - $lastUpdate).TotalMilliseconds -ge 200) {
        Write-DownloadProgressLine $downloaded $total
        $lastUpdate = Get-Date
      }
    }
    Write-DownloadProgressLine $downloaded $total
    Write-Host ""
  } catch {
    Write-Host ""
    Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
    throw
  } finally {
    if ($outputStream) { $outputStream.Dispose() }
    if ($inputStream) { $inputStream.Dispose() }
    if ($response) { $response.Dispose() }
  }
  if (-not (Test-Path $OutFile)) {
    throw "下载失败：$Url"
  }
}

function Get-UrlCandidates([string]$Url) {
  $items = New-Object System.Collections.Generic.List[string]
  $items.Add($Url)
  if ($ProxyUrl) { return $items }
  if ($Url.StartsWith("https://github.com/") -or $Url.StartsWith("https://raw.githubusercontent.com/")) {
    foreach ($mirror in $GithubAccelerators) { $items.Add("$mirror$Url") }
    if ($env:GITHUB_ACCELERATORS_EXTRA) {
      foreach ($mirror in ($env:GITHUB_ACCELERATORS_EXTRA -split '[,;\s]+' | Where-Object { $_ })) {
        $items.Add("$mirror$Url")
      }
    }
    foreach ($cdn in (Get-RawJsdelivrCandidates $Url)) { $items.Add($cdn) }
  }
  return $items
}

function Get-RawJsdelivrCandidates([string]$Url) {
  $items = New-Object System.Collections.Generic.List[string]
  if (-not $Url.StartsWith("https://raw.githubusercontent.com/")) { return $items }
  $rest = $Url.Substring("https://raw.githubusercontent.com/".Length)
  $parts = $rest.Split("/", 4)
  if ($parts.Count -lt 4) { return $items }
  $owner = $parts[0]
  $repo = $parts[1]
  $ref = $parts[2]
  $path = $parts[3]
  if (-not $owner -or -not $repo -or -not $ref -or -not $path) { return $items }
  $items.Add("https://cdn.jsdelivr.net/gh/$owner/$repo@$ref/$path")
  $items.Add("https://fastly.jsdelivr.net/gh/$owner/$repo@$ref/$path")
  $items.Add("https://gcore.jsdelivr.net/gh/$owner/$repo@$ref/$path")
  return $items
}

function Download-WithFallback([string]$Url, [string]$OutFile) {
  Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
  foreach ($candidate in (Get-UrlCandidates $Url)) {
    Say "尝试下载：$candidate"
    try {
      Invoke-WebDownload $candidate $OutFile
      Ok "下载成功"
      return $true
    } catch {
      Warn "下载失败，尝试下一个源"
    }
  }
  return $false
}

function Add-UserPath([string]$Dir) {
  if (-not (Test-Path $Dir)) { return }
  $fullDir = [IO.Path]::GetFullPath($Dir).TrimEnd("\")
  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  $parts = @()
  if ($userPath) {
    $parts = $userPath -split ";" | Where-Object { $_ -and $_.Trim() }
  }
  $exists = $false
  foreach ($part in $parts) {
    try {
      if ([IO.Path]::GetFullPath($part).TrimEnd("\").Equals($fullDir, [StringComparison]::OrdinalIgnoreCase)) {
        $exists = $true
        break
      }
    } catch {}
  }
  if (-not $exists) {
    [Environment]::SetEnvironmentVariable("Path", "$fullDir;$userPath", "User")
    Ok "已写入用户 PATH：$fullDir"
  } else {
    Ok "用户 PATH 已包含：$fullDir"
  }
  Refresh-ProcessPath
}

function Add-MachinePath([string]$Dir) {
  if (-not (Test-Path $Dir)) { return }
  if (-not (Test-IsAdministrator)) {
    Warn "当前不是管理员，无法写入系统 PATH，改写入用户 PATH：$Dir"
    Add-UserPath $Dir
    return
  }
  $fullDir = [IO.Path]::GetFullPath($Dir).TrimEnd("\")
  $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
  $parts = @()
  if ($machinePath) {
    $parts = $machinePath -split ";" | Where-Object { $_ -and $_.Trim() }
  }
  $exists = $false
  foreach ($part in $parts) {
    try {
      if ([IO.Path]::GetFullPath($part).TrimEnd("\").Equals($fullDir, [StringComparison]::OrdinalIgnoreCase)) {
        $exists = $true
        break
      }
    } catch {}
  }
  if (-not $exists) {
    [Environment]::SetEnvironmentVariable("Path", "$fullDir;$machinePath", "Machine")
    Ok "已写入系统 PATH：$fullDir"
  } else {
    Ok "系统 PATH 已包含：$fullDir"
  }
  Refresh-ProcessPath
}

function Refresh-ProcessPath {
  $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  $env:Path = "$machinePath;$userPath"
}

function Get-InstallRoot([string]$Name) {
  if (Test-IsAdministrator) {
    return (Join-Path $env:ProgramFiles $Name)
  }
  return (Join-Path $env:LOCALAPPDATA "Programs\$Name")
}

function Test-IsAdministrator {
  try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch {
    return $false
  }
}

function Ensure-Node {
  Load-NvmIfPresent | Out-Null
  if ((HasCommand "node") -and (HasNpm)) {
    Ok "Node.js 已安装：$(node -v)"
    return $true
  }
  if ($Check) { Warn "Node.js / npm 未安装"; return $false }
  if (-not (Confirm-Step "安装 Node.js LTS（飞书 CLI 需要 npm）")) { return $false }
  if (HasCommand "nvm") {
    Use-NvmInstalledNode | Out-Null
    if (-not ((HasCommand "node") -and (HasNpm))) {
      Warn "检测到 nvm，但没有可直接启用的 Node.js 版本，将下载 Node.js 官方 zip"
    }
  }
  if (-not ((HasCommand "node") -and (HasNpm))) {
    Install-NodeFromOfficialZip
  }
  return ((HasCommand "node") -and (HasNpm))
}

function Get-WindowsArchName {
  if ([Environment]::Is64BitOperatingSystem -and $env:PROCESSOR_ARCHITECTURE -match "ARM64") { return "arm64" }
  return "x64"
}

function Install-NodeFromOfficialZip {
  $arch = Get-WindowsArchName
  $indexFile = Join-Path $env:TEMP "node-index.json"
  Say "获取 Node.js 官方版本索引..."
  Invoke-WebDownload "https://nodejs.org/dist/index.json" $indexFile
  $versions = Get-Content $indexFile -Raw | ConvertFrom-Json
  $assetName = "win-$arch-zip"
  $release = $versions | Where-Object { $_.lts -and ($_.files -contains $assetName) } | Select-Object -First 1
  if (-not $release) { throw "未找到适合 Windows $arch 的 Node.js LTS zip 包" }
  $version = $release.version
  $zipUrl = "https://nodejs.org/dist/$version/node-$version-win-$arch.zip"
  $zipFile = Join-Path $env:TEMP "node-$version-win-$arch.zip"
  $targetRoot = Get-InstallRoot "nodejs"
  if (-not (Test-IsAdministrator)) { Warn "当前不是管理员，Node.js 将安装到用户目录：$targetRoot" }
  $targetDir = Join-Path $targetRoot "node-$version-win-$arch"
  Say "准备安装 Node.js $version 到：$targetDir"
  Invoke-WebDownload $zipUrl $zipFile
  Remove-Item $targetDir -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path $targetRoot | Out-Null
  Say "解压 Node.js..."
  Expand-Archive -Path $zipFile -DestinationPath $targetRoot -Force
  if (Test-IsAdministrator) {
    Add-MachinePath $targetDir
    Ok "Node.js 已安装到系统目录：$targetDir"
  } else {
    Add-UserPath $targetDir
    Ok "Node.js 已安装到用户目录：$targetDir"
  }
}

function Use-NvmInstalledNode {
  if (-not (HasCommand "nvm")) { return $false }
  try {
    $versions = (nvm list 2>$null | Select-String -Pattern '\d+\.\d+\.\d+' | ForEach-Object {
      [regex]::Match($_.Line, '\d+\.\d+\.\d+').Value
    } | Where-Object { $_ } | Select-Object -First 1)
    if ($versions) {
      nvm use $versions | Out-Null
      Refresh-ProcessPath
      return $true
    }
  } catch {}
  return $false
}

function Load-NvmIfPresent {
  if (HasCommand "nvm") { return $true }
  $candidateDirs = @(
    $env:NVM_HOME,
    "$env:APPDATA\nvm",
    "$env:LOCALAPPDATA\nvm",
    "$env:ProgramFiles\nvm",
    "${env:ProgramFiles(x86)}\nvm"
  ) | Where-Object { $_ -and (Test-Path $_) }
  foreach ($dir in $candidateDirs) {
    if ($env:Path -notlike "*$dir*") { $env:Path = "$dir;$env:Path" }
  }
  if (HasCommand "nvm") {
    Ok "检测到 nvm 环境"
    if (-not (HasCommand "node")) {
      Use-NvmInstalledNode | Out-Null
    }
    return $true
  }
  return $false
}

function Ensure-Python {
  $python3 = Get-Python3Command
  if ($python3) {
    Ok "Python 3 已安装：$(Get-PythonCommandDisplay $python3)"
    return $true
  }
  if ($Check) { Warn "Python 3 未安装"; return $false }
  Warn "未检测到可用的全局 Python 3。"
  if (-not (Confirm-Step "安装 Python 3（yt-dlp / Whisper 需要）")) { return $false }
  Install-PythonFromOfficialInstaller "3"
  $python3 = Get-Python3Command
  return [bool]$python3
}

function Get-Python3Command {
  $candidates = New-Object System.Collections.Generic.List[string]
  if (HasCommand "python") { $candidates.Add("python") }
  if (HasCommand "python3") { $candidates.Add("python3") }
  if (HasCommand "py") { $candidates.Add("py -3") }
  $candidates.Add("$env:ProgramFiles\Python314\python.exe")
  $candidates.Add("$env:ProgramFiles\Python313\python.exe")
  $candidates.Add("$env:ProgramFiles\Python312\python.exe")
  $candidates.Add("$env:ProgramFiles\Python311\python.exe")
  $candidates.Add("$env:LOCALAPPDATA\Programs\Python\Python314\python.exe")
  $candidates.Add("$env:LOCALAPPDATA\Programs\Python\Python313\python.exe")
  $candidates.Add("$env:LOCALAPPDATA\Programs\Python\Python312\python.exe")
  $candidates.Add("$env:LOCALAPPDATA\Programs\Python\Python311\python.exe")
  foreach ($candidate in $candidates) {
    if (-not $candidate) { continue }
    if ($candidate -like "*.exe" -and -not (Test-Path $candidate)) { continue }
    if (-not (Test-PythonCommand $candidate)) { continue }
    try {
      $major = Invoke-PythonCommand $candidate @("-c", "import sys; print(sys.version_info.major)") 2>$null | Select-Object -First 1
      if ($major -eq "3" -and (Test-StandalonePython $candidate)) { return $candidate }
    } catch {}
  }
  return $null
}

function Get-PythonCommandDisplay([string]$Command) {
  $version = Get-PythonVersion $Command
  $exe = Get-PythonExecutablePath $Command
  if ($exe) { return "$version ($exe)" }
  return $version
}

function Get-PythonVersion([string]$Command) {
  if ($Command -eq "py -3.11") {
    return (py -3.11 --version)
  }
  if ($Command -eq "py -3") {
    return (py -3 --version)
  }
  return (& $Command --version)
}

function Invoke-PythonCommand([string]$PythonCommand, [string[]]$Arguments) {
  if ($PythonCommand -eq "py -3.11") {
    & py -3.11 @Arguments
  } elseif ($PythonCommand -eq "py -3") {
    & py -3 @Arguments
  } else {
    & $PythonCommand @Arguments
  }
}

function Get-PythonInstallerUrl([string]$MinorVersion) {
  $archSuffix = if ((Get-WindowsArchName) -eq "arm64") { "arm64" } else { "amd64" }
  $pageFile = Join-Path $env:TEMP "python-windows.html"
  Invoke-WebDownload "https://www.python.org/downloads/windows/" $pageFile
  $html = Get-Content $pageFile -Raw
  $escapedMinor = [regex]::Escape($MinorVersion)
  if ($MinorVersion -eq "3") {
    $pattern = "https://www\.python\.org/ftp/python/(3\.\d+\.\d+)/python-\1-$archSuffix\.exe"
  } else {
    $pattern = "https://www\.python\.org/ftp/python/($escapedMinor\.\d+)/python-\1-$archSuffix\.exe"
  }
  $matches = [regex]::Matches($html, $pattern)
  if ($matches.Count -gt 0) { return $matches[0].Value }
  if ($MinorVersion -eq "3.11" -and $archSuffix -eq "amd64") {
    return "https://www.python.org/ftp/python/3.11.9/python-3.11.9-amd64.exe"
  }
  throw "未找到适合当前系统的 Python 安装包"
}

function Install-PythonFromOfficialInstaller([string]$MinorVersion) {
  $installerUrl = Get-PythonInstallerUrl $MinorVersion
  $installer = Join-Path $env:TEMP ([IO.Path]::GetFileName($installerUrl))
  Say "准备下载 Python 官方安装器：$installerUrl"
  Invoke-WebDownload $installerUrl $installer
  if (Test-IsAdministrator) {
    Say "执行：Python $MinorVersion 系统静默安装（并行安装，包含 pip，并写入系统 PATH）"
    $args = "/quiet InstallAllUsers=1 PrependPath=1 Include_pip=1 Include_launcher=1 SimpleInstall=1"
  } else {
    Say "执行：Python $MinorVersion 用户静默安装（并行安装，包含 pip，并写入用户 PATH）"
    $args = "/quiet InstallAllUsers=0 PrependPath=1 Include_pip=1 Include_launcher=1 SimpleInstall=1"
  }
  $process = Start-Process -FilePath $installer -ArgumentList $args -Wait -PassThru
  if ($process.ExitCode -ne 0) { throw "Python 安装失败，退出码：$($process.ExitCode)" }
  Register-PythonPaths
  Refresh-ProcessPath
}

function Register-PythonPaths {
  $candidateRoots = @(
    "$env:ProgramFiles\Python",
    "$env:ProgramFiles\Python314",
    "$env:ProgramFiles\Python313",
    "$env:ProgramFiles\Python312",
    "$env:ProgramFiles\Python311",
    "$env:LOCALAPPDATA\Programs\Python",
    "$env:APPDATA\Python"
  ) | Where-Object { $_ -and (Test-Path $_) }
  foreach ($root in $candidateRoots) {
    if (Test-Path (Join-Path $root "python.exe")) { Add-UserPath $root }
    $rootScripts = Join-Path $root "Scripts"
    if (Test-Path $rootScripts) { Add-UserPath $rootScripts }
    Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
      if (Test-Path (Join-Path $_.FullName "python.exe")) { Add-UserPath $_.FullName }
      $scripts = Join-Path $_.FullName "Scripts"
      if (Test-Path $scripts) { Add-UserPath $scripts }
    }
  }
}

function Ensure-Ffmpeg {
  if (HasCommand "ffmpeg") { Ok "ffmpeg 已安装"; return $true }
  if ($Check) { Warn "ffmpeg 未安装"; return $false }
  if (-not (Confirm-Step "安装 ffmpeg（Whisper 处理音频需要）")) { return $false }
  Install-FfmpegFromOfficialZip
  return (HasCommand "ffmpeg")
}

function Ensure-YtDlp {
  if (HasGlobalTool "yt-dlp") {
    Ok "yt-dlp 命令已安装：$(yt-dlp --version | Select-Object -First 1)"
  } elseif (HasCommand "yt-dlp") {
    Warn "检测到 yt-dlp 位于临时 / Hermes / uv cache 路径，仍会安装全局入口：$(Get-CommandSource 'yt-dlp')"
  } elseif ($Check) {
    Warn "yt-dlp 未安装"
    return $false
  }
  if ($Check) { return $true }
  if (-not (Confirm-Step "为主 Python / 可用 Python 安装或更新 yt-dlp 模块，并保留命令入口兜底")) { return $false }
  $script:YtDlpModulesRequested = $true
  Ensure-Python | Out-Null
  Install-YtDlpModules | Out-Null
  Register-PythonPaths
  Refresh-ProcessPath
  if (-not (HasGlobalTool "yt-dlp")) {
    Warn "仍未检测到全局 yt-dlp 命令，改用官方 exe 兜底安装"
    Install-YtDlpFromGithubExe
  }
  return (HasGlobalTool "yt-dlp")
}

function Ensure-Ripgrep {
  if (HasCommand "rg") { Ok "ripgrep 已安装：$(rg --version | Select-Object -First 1)"; return $true }
  if ($Check) { Warn "ripgrep 未安装"; return $false }
  if (-not (Confirm-Step "安装 ripgrep（Hermes Agent 文件搜索依赖）")) { return $false }
  Install-RipgrepFromGithubZip
  return (HasCommand "rg")
}

function Install-RipgrepFromGithubZip {
  $arch = Get-WindowsArchName
  if ($arch -ne "x64") {
    Warn "暂未自动匹配 ripgrep $arch 架构，跳过自动安装"
    return
  }
  $version = "14.1.1"
  $zipUrl = "https://github.com/BurntSushi/ripgrep/releases/download/$version/ripgrep-$version-x86_64-pc-windows-msvc.zip"
  $zipFile = Join-Path $env:TEMP "ripgrep-$version-x86_64-pc-windows-msvc.zip"
  $targetRoot = Get-InstallRoot "ripgrep"
  if (-not (Test-IsAdministrator)) { Warn "当前不是管理员，ripgrep 将安装到用户目录：$targetRoot" }
  Say "准备下载 ripgrep：$zipUrl"
  Download-WithFallback $zipUrl $zipFile | Out-Null
  Remove-Item $targetRoot -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path $targetRoot | Out-Null
  Say "解压 ripgrep..."
  Expand-Archive -Path $zipFile -DestinationPath $targetRoot -Force
  $rgExe = Get-ChildItem -Path $targetRoot -Filter "rg.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $rgExe) { throw "ripgrep 解压后未找到 rg.exe" }
  $binDir = $rgExe.Directory.FullName
  if (Test-IsAdministrator) {
    Add-MachinePath $binDir
    Ok "ripgrep 已安装到系统目录：$binDir"
  } else {
    Add-UserPath $binDir
    Ok "ripgrep 已安装到用户目录：$binDir"
  }
}

function Install-FfmpegFromOfficialZip {
  $zipUrl = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"
  $zipFile = Join-Path $env:TEMP "ffmpeg-release-essentials.zip"
  $targetRoot = Get-InstallRoot "ffmpeg"
  if (-not (Test-IsAdministrator)) { Warn "当前不是管理员，ffmpeg 将安装到用户目录：$targetRoot" }
  Say "准备下载 ffmpeg 官方构建：$zipUrl"
  Invoke-WebDownload $zipUrl $zipFile
  Remove-Item $targetRoot -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path $targetRoot | Out-Null
  Say "解压 ffmpeg..."
  Expand-Archive -Path $zipFile -DestinationPath $targetRoot -Force
  $ffmpegExe = Get-ChildItem -Path $targetRoot -Filter "ffmpeg.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $ffmpegExe) { throw "ffmpeg 解压后未找到 ffmpeg.exe" }
  $binDir = $ffmpegExe.Directory.FullName
  if (Test-IsAdministrator) {
    Add-MachinePath $binDir
    Ok "ffmpeg 已安装到系统目录：$binDir"
  } else {
    Add-UserPath $binDir
    Ok "ffmpeg 已安装到用户目录：$binDir"
  }
}

function Install-YtDlpFromGithubExe {
  $exeUrl = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe"
  $targetRoot = Get-InstallRoot "yt-dlp"
  if (-not (Test-IsAdministrator)) { Warn "当前不是管理员，yt-dlp 将安装到用户目录：$targetRoot" }
  New-Item -ItemType Directory -Force -Path $targetRoot | Out-Null
  $targetExe = Join-Path $targetRoot "yt-dlp.exe"
  Say "准备下载 yt-dlp：$exeUrl"
  Download-WithFallback $exeUrl $targetExe | Out-Null
  if (-not (Test-Path $targetExe)) { throw "yt-dlp 下载后未找到可执行文件" }
  if (Test-IsAdministrator) {
    Add-MachinePath $targetRoot
    Ok "yt-dlp 已安装到系统目录：$targetExe"
  } else {
    Add-UserPath $targetRoot
    Ok "yt-dlp 已安装到用户目录：$targetExe"
  }
  Refresh-ProcessPath
}

function Install-Hermes {
  Step "Hermes Agent"
  if (HasHermes) { Ok "Hermes 已安装：$(Invoke-Hermes @("--version") | Select-Object -First 1)"; return }
  if ($Check) { Warn "Hermes 未安装"; return }
  $missing = Get-HermesMissingPrereqs
  if ($missing.Count -gt 0) {
    Warn "Hermes 前置依赖仍缺失：$($missing -join ', ')"
    Warn "如果继续，Hermes 官方安装器可能会自行调用 uv/winget 下载这些依赖，速度可能很慢且不一定走代理。"
    if (-not (Confirm-Step "仍然继续安装 Hermes Agent")) { return }
  }
  if (-not (Confirm-Step "安装 Hermes Agent")) { return }
  $script = Join-Path $env:TEMP "hermes-install.ps1"
  try {
    Invoke-WebDownload "https://hermes-agent.nousresearch.com/install.ps1" $script
    if ($ProxyUrl) { Say "Hermes 子安装器将继承代理：$ProxyUrl" }
    Apply-NpmProxy
    Enable-GitHttpsRewrite
    Say "提示：Hermes 后续可能会安装自己的 npm/browser tools 依赖，这是项目依赖，不是重新安装 Node.js。"
    powershell -ExecutionPolicy Bypass -File $script
    Register-ToolPaths
    if ($script:YtDlpModulesRequested) {
      Say "Hermes 安装后同步 yt-dlp 到新检测到的 Python 环境"
      Install-YtDlpModules | Out-Null
      Register-PythonPaths
      Refresh-ProcessPath
    }
    if ($script:WhisperModulesRequested) {
      Say "Hermes 安装后同步 Whisper 到新检测到的 Python 环境"
      Install-WhisperModules | Out-Null
      Register-PythonPaths
      Refresh-ProcessPath
    }
  } catch {
    Fail "Hermes 安装脚本下载或执行失败：$($_.Exception.Message)"
  }
}

function Configure-HermesAgent {
  Step "Hermes Agent 配置"
  if (-not (HasHermes)) {
    Warn "Hermes 未安装，跳过配置"
    return
  }
  if ($Check) { return }
  if ($Yes) {
    Warn "自动模式下跳过 Hermes 交互配置；可稍后手动运行 hermes model 和 hermes gateway setup"
    return
  }
  Say "可在这里配置 Hermes 的接口模型和消息通道。"
  Say "下面会进入 Hermes 自带英文向导，先看中文速查说明即可。"
  if (Confirm-Step "配置 Hermes 接口模型") {
    Show-HermesModelGuide
    try { Invoke-Hermes @("model") } catch { Warn "Hermes 接口模型配置失败：$($_.Exception.Message)" }
  }
  if (Confirm-Step "配置 Hermes 飞书 / Lark 通道") {
    Show-HermesGatewayGuide
    try { Invoke-Hermes @("gateway", "setup") } catch { Warn "Hermes 通道配置失败：$($_.Exception.Message)" }
  }
}

function Show-HermesModelGuide {
  Step "Hermes 接口模型配置说明"
  Say "即将运行：hermes model"
  Say "常见英文提示对照："
  Say "  Select provider：选择模型服务商。"
  Say "  OpenAI ▸ / OpenAI Codex：如果你已经登录 Codex CLI，推荐选这个。"
  Say "  Import these credentials?：是否导入现有 Codex 登录凭证；一般输入 y。"
  Say "  Select default model：选择默认模型；不知道选哪个可用默认项，或选择 gpt-5.5。"
  Say "  Leave unchanged / Skip：保持当前配置不变。"
  Say "提示：如果你用 OpenRouter / Anthropic / OpenAI API，需要提前准备对应 API Key。"
}

function Show-HermesGatewayGuide {
  Step "Hermes 飞书 / Lark 通道配置说明"
  Say "即将运行：hermes gateway setup"
  Say "常见英文提示对照："
  Say "  Select a platform to configure：选择要配置的平台，选择 Feishu / Lark。"
  Say "  Scan QR code...：扫码自动创建机器人，推荐选默认项。"
  Say "  Enter existing App ID...：已有飞书应用时，手动输入 App ID 和 App Secret。"
  Say "  Open this URL in Feishu / Lark on your phone：用手机飞书打开链接并授权。"
  Say "  How should direct messages be authorized：私聊权限；新手可选 DM pairing approval，更开放可选 Allow all direct messages。"
  Say "  How should group chats be handled：群聊响应方式；推荐 Respond only when @mentioned。"
  Say "  Home chat ID：通知/定时任务默认发送到哪个会话；不确定可直接回车留空。"
  Say "  Done：配置完 Feishu / Lark 后选择 Done 退出平台选择。"
}

function Get-HermesMissingPrereqs {
  $missing = New-Object System.Collections.Generic.List[string]
  if (-not (Get-Python3Command)) { $missing.Add("Python 3") }
  if (-not (HasCommand "rg")) { $missing.Add("ripgrep") }
  if (-not (HasCommand "ffmpeg")) { $missing.Add("ffmpeg") }
  if (-not (HasCommand "node")) { $missing.Add("Node.js") }
  return $missing
}

function Install-CodexCli {
  Step "Codex CLI"
  if (HasCommand "codex") { Ok "Codex CLI 已安装：$(codex --version | Select-Object -First 1)"; return }
  if ($Check) { Warn "Codex CLI 未安装"; return }
  if (-not (Confirm-Step "安装 Codex CLI")) { return }
  try {
    $env:CODEX_INSTALLER_USE_RELEASES_OPENAI_COM = "false"
    $script = Join-Path $env:TEMP "codex-install.ps1"
    Invoke-WebDownload "https://chatgpt.com/codex/install.ps1" $script
    if ($ProxyUrl) { Say "Codex 子安装器将继承代理：$ProxyUrl" }
    powershell -ExecutionPolicy Bypass -File $script
    Register-ToolPaths
  } catch {
    Fail "Codex CLI 安装失败：$($_.Exception.Message)"
  }
}

function Install-CodexDesktop {
  Step "ChatGPT / Codex Desktop"
  $desktop = Get-CodexDesktopInstall
  if ($desktop) { Ok "检测到 $desktop"; return }
  if ($Check) { Warn "未检测到 ChatGPT / Codex Desktop 应用"; return }
  Show-CodexDesktopInstallHelp
  if (-not (Confirm-Step "打开 ChatGPT / Codex Desktop 官方安装入口")) { return }
  if (HasCommand "codex") {
    try { codex app | Out-Null } catch {}
  }
  Start-Process "https://openai.com/chatgpt/download/"
  Start-Process "ms-windows-store://pdp/?productid=9PLM9XGG6VKS"
  Warn "桌面 App 需要在打开的官方页面中完成下载和登录"
}

function Show-CodexDesktopInstallHelp {
  Warn "未检测到 ChatGPT / Codex Desktop。"
  Say "官方下载页：https://openai.com/chatgpt/download/"
  Say "Microsoft Store 页面：https://apps.microsoft.com/detail/9PLM9XGG6VKS"
  Say "Microsoft Store 直达协议：ms-windows-store://pdp/?productid=9PLM9XGG6VKS"
  Say "可选命令行安装（可能依赖 winget / Microsoft Store，网络不好时会卡）："
  Say "  winget install --id 9PLM9XGG6VKS -s msstore"
  Say "备用网盘包（微软商店 Codex 安装包）：https://www.doubao.com/drive/shr/DAAFfMpBmlyOqwdFDPBcIYCjnKf"
  Say "提示：脚本默认不自动执行 winget；如商店无法打开，可手动使用备用包。"
}

function Get-CodexDesktopInstall {
  $packages = @()
  $packages += Get-AppxPackage -Name "*ChatGPT*" -ErrorAction SilentlyContinue
  $packages += Get-AppxPackage -Name "*Codex*" -ErrorAction SilentlyContinue
  foreach ($package in ($packages | Where-Object { $_ })) {
    if ($package.InstallLocation) {
      $exe = Join-Path $package.InstallLocation "app\ChatGPT.exe"
      if (Test-Path $exe) { return "ChatGPT.exe：$exe" }
      $exe = Join-Path $package.InstallLocation "ChatGPT.exe"
      if (Test-Path $exe) { return "ChatGPT.exe：$exe" }
      return "$($package.Name)：$($package.InstallLocation)"
    }
  }

  $windowsApps = Join-Path $env:ProgramFiles "WindowsApps"
  if (Test-Path $windowsApps) {
    $matches = Get-ChildItem -Path $windowsApps -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -like "OpenAI.Codex_*" -or $_.Name -like "*ChatGPT*" -or $_.Name -like "*Codex*" }
    foreach ($match in $matches) {
      $exe = Join-Path $match.FullName "app\ChatGPT.exe"
      if (Test-Path $exe) { return "ChatGPT.exe：$exe" }
      $exe = Join-Path $match.FullName "ChatGPT.exe"
      if (Test-Path $exe) { return "ChatGPT.exe：$exe" }
    }
  }

  $localApps = @(
    "$env:LOCALAPPDATA\Programs\ChatGPT\ChatGPT.exe",
    "$env:LOCALAPPDATA\Programs\Codex\Codex.exe",
    "$env:ProgramFiles\ChatGPT\ChatGPT.exe",
    "$env:ProgramFiles\Codex\Codex.exe"
  )
  foreach ($exe in $localApps) {
    if (Test-Path $exe) { return "$([IO.Path]::GetFileName($exe))：$exe" }
  }

  return $null
}

function Install-Node {
  Step "Node.js"
  Ensure-Node | Out-Null
  Apply-PackageMirrors
}

function Install-LarkCli {
  Step "飞书 / Lark CLI"
  if (HasLarkCli) { Ok "lark-cli 已安装：$(Invoke-LarkCli @("--version") | Select-Object -First 1)"; return }
  if ($Check) { Warn "lark-cli 未安装"; return }
  if (-not (Ensure-Node)) { Fail "npm 不可用，无法安装飞书 CLI"; return }
  if (-not (Confirm-Step "安装飞书 / Lark CLI")) { return }
  Register-NpmGlobalPath
  Install-NpmGlobal "@larksuite/cli"
  Register-NpmGlobalPath
  try { Invoke-LarkCli @("update") | Out-Null } catch {}
}

function Configure-LarkCliAuth {
  Step "飞书 / Lark CLI 授权"
  if (-not (HasLarkCli)) {
    Warn "lark-cli 未安装，跳过授权配置"
    return
  }
  $ready = Show-LarkAuthStatus
  if ($Check) { return }
  if ($ready) { return }
  if ($Yes) {
    Warn "自动模式下跳过飞书 CLI 交互授权；可稍后手动运行 lark-cli auth login --recommend"
    return
  }
  Say "飞书 CLI 需要授权后才能访问日历、文档、多维表格、消息等用户 API。"
  if (-not (Ensure-LarkCliBinding)) { return }
  Say "推荐先使用最小推荐权限登录：lark-cli auth login --recommend"
  Say "如果后续某个功能提示缺权限，再按提示追加对应 domain 或 scope。"
  if (Confirm-Step "登录 / 授权飞书 CLI 用户身份") {
    try { Invoke-LarkCli @("auth", "login", "--recommend") } catch { Warn "飞书 CLI 授权失败：$($_.Exception.Message)" }
    Show-LarkAuthStatus | Out-Null
  }
}

function Register-NpmGlobalPath {
  $globalPrefix = if (Test-IsAdministrator) {
    Join-Path $env:ProgramFiles "npm-global"
  } else {
    Join-Path $env:APPDATA "npm"
  }
  New-Item -ItemType Directory -Force -Path $globalPrefix | Out-Null
  Invoke-Npm @("config", "set", "prefix", $globalPrefix) | Out-Null
  if (Test-IsAdministrator) {
    Add-MachinePath $globalPrefix
  } else {
    Add-UserPath $globalPrefix
  }
  try {
    $npmPrefix = (Invoke-Npm @("config", "get", "prefix") 2>$null).Trim()
    if ($npmPrefix -and (Test-Path $npmPrefix)) {
      if (Test-IsAdministrator -and $npmPrefix.StartsWith($env:ProgramFiles, [StringComparison]::OrdinalIgnoreCase)) {
        Add-MachinePath $npmPrefix
      } else {
        Add-UserPath $npmPrefix
      }
    }
  } catch {}
  $npmRoaming = Join-Path $env:APPDATA "npm"
  if (Test-Path $npmRoaming) { Add-UserPath $npmRoaming }
}

function Register-ToolPaths {
  $candidates = @(
    "$env:ProgramFiles\Hermes\bin",
    "$env:ProgramFiles\hermes\bin",
    "$env:LOCALAPPDATA\Programs\Hermes\bin",
    "$env:LOCALAPPDATA\Programs\hermes\bin",
    "$env:USERPROFILE\.hermes\bin",
    "$env:USERPROFILE\.local\bin",
    "$env:ProgramFiles\Codex\bin",
    "$env:LOCALAPPDATA\Programs\Codex\bin"
  ) | Where-Object { $_ -and (Test-Path $_) }
  foreach ($dir in $candidates) {
    if (Test-IsAdministrator -and $dir.StartsWith($env:ProgramFiles, [StringComparison]::OrdinalIgnoreCase)) {
      Add-MachinePath $dir
    } else {
      Add-UserPath $dir
    }
  }
}

function Install-Python {
  Step "Python 3"
  Ensure-Python | Out-Null
}

function Install-Ffmpeg {
  Step "ffmpeg"
  Ensure-Ffmpeg | Out-Null
}

function Install-YtDlp {
  Step "yt-dlp"
  Ensure-YtDlp | Out-Null
}

function Install-Ripgrep {
  Step "ripgrep"
  Ensure-Ripgrep | Out-Null
}

function Install-Whisper {
  Step "Whisper"
  $whisperInstalled = HasGlobalTool "whisper"
  if ($whisperInstalled) { Ok "Whisper 已安装" }
  if ((-not $whisperInstalled) -and (HasCommand "whisper")) {
    Warn "检测到 whisper 位于临时 / Hermes / uv cache 路径，仍会安装全局入口：$(Get-CommandSource 'whisper')"
  }
  if ($Check -and -not $whisperInstalled) { Warn "Whisper 未安装"; return }
  if ($Check) { return }
  Ensure-Python | Out-Null
  Ensure-Ffmpeg | Out-Null
  $mainPython = Get-MainPythonCommand
  if (-not $mainPython) { Fail "Python 不可用，无法安装 Whisper"; return }
  if (-not $whisperInstalled) {
    if (-not (Confirm-Step "为可用 Python 安装 / 更新 Whisper 模块（保留主 Python 命令入口）")) { return }
    $script:WhisperModulesRequested = $true
    Install-PythonModuleAll "pip" "pip" | Out-Null
    Install-WhisperModules | Out-Null
  }
  $pythonScripts = Get-PythonUserScripts $mainPython
  if ($pythonScripts) { Add-UserPath $pythonScripts }
  Register-PythonPaths
  Refresh-ProcessPath
  $model = Choose-WhisperModel
  Download-WhisperModel $model
}

function Check-All {
  Step "环境检测"
  Say "系统：Windows $([Environment]::OSVersion.Version)"
  if (HasCommand "node") {
    Ok "Node.js：$(node -v)"
  } else {
    Load-NvmIfPresent | Out-Null
    if (HasCommand "nvm") { Ok "nvm：已检测到" } else { Warn "nvm：未检测到" }
    if (HasCommand "node") { Ok "Node.js：$(node -v)" } else { Warn "Node.js：未安装" }
  }
  $python3 = Get-Python3Command
  if ($python3) { Ok "Python 3：$(Get-PythonCommandDisplay $python3)" } else { Warn "Python 3：未安装" }
  if (HasCommand "ffmpeg") { Ok "ffmpeg：已安装" } else { Warn "ffmpeg：未安装" }
  if (HasGlobalTool "yt-dlp") { Ok "yt-dlp：$(yt-dlp --version | Select-Object -First 1)" } else { Warn "yt-dlp：未安装全局入口" }
  if (HasCommand "rg") { Ok "ripgrep：$(rg --version | Select-Object -First 1)" } else { Warn "ripgrep：未安装" }
  if (HasHermes) { Ok "Hermes：$(Invoke-Hermes @("--version") | Select-Object -First 1)" } else { Warn "Hermes：未安装" }
  if (HasCommand "codex") { Ok "Codex CLI：$(codex --version | Select-Object -First 1)" } else { Warn "Codex CLI：未安装" }
  $desktop = Get-CodexDesktopInstall
  if ($desktop) { Ok "ChatGPT / Codex Desktop：$desktop" } else { Warn "ChatGPT / Codex Desktop：未检测到" }
  if (HasLarkCli) {
    Ok "lark-cli：$(Invoke-LarkCli @("--version") | Select-Object -First 1)"
    Show-LarkAuthStatus | Out-Null
  } else {
    Warn "lark-cli：未安装"
  }
  if (HasGlobalTool "whisper") { Ok "Whisper：已安装" } else { Warn "Whisper：未安装全局入口" }
}

Prepare-ConsoleOutput
Show-Intro
Suggest-Elevation
Refresh-ProcessPath
Write-Host "------------------------------------------------------------"
Write-Host "Agent 航海环境部署工具 (Windows)"
Write-Host "------------------------------------------------------------"

Check-All
if ($Check) { Graceful-Exit }
Apply-PackageMirrors
Enable-GitHttpsRewrite
Install-Node
Install-Python
Install-Ffmpeg
Install-YtDlp
Install-Ripgrep
Install-Hermes
Install-CodexCli
Install-CodexDesktop
Install-LarkCli
Configure-LarkCliAuth
Configure-HermesAgent
Install-Whisper
Check-All
Write-Host "------------------------------------------------------------"
Ok "处理完成。新开一个 PowerShell 后，PATH 配置会完整生效。"
Restore-ProxyEnvironment
Keep-TerminalOpen
