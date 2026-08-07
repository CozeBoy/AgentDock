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
function EffectsEnabled { return (-not $env:NO_COLOR) }

function Enable-AnsiConsole {
  if ($env:NO_COLOR) { return $false }
  try {
    if (-not ("AgentDockConsole" -as [type])) {
      Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class AgentDockConsole {
  [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr GetStdHandle(int nStdHandle);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out int lpMode);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetConsoleMode(IntPtr hConsoleHandle, int dwMode);
}
"@ -ErrorAction Stop
    }
    $stdout = [AgentDockConsole]::GetStdHandle(-11)
    $mode = 0
    if (-not [AgentDockConsole]::GetConsoleMode($stdout, [ref]$mode)) { return $false }
    $enableVirtualTerminal = 0x0004
    return [AgentDockConsole]::SetConsoleMode($stdout, ($mode -bor $enableVirtualTerminal))
  } catch {
    return $false
  }
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
  if ($script:NpmProxyChanged -and (HasCommand "npm")) {
    if ($script:OriginalNpmProxy) { npm config set proxy $script:OriginalNpmProxy | Out-Null } else { npm config delete proxy | Out-Null }
    if ($script:OriginalNpmHttpsProxy) { npm config set https-proxy $script:OriginalNpmHttpsProxy | Out-Null } else { npm config delete https-proxy | Out-Null }
  }
  if ($script:NpmRegistryChanged -and (HasCommand "npm")) {
    if ($script:OriginalNpmRegistry) { npm config set registry $script:OriginalNpmRegistry | Out-Null } else { npm config delete registry | Out-Null }
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
  if (-not (HasCommand "npm")) { return }
  if (-not $script:NpmProxyChanged) {
    $script:OriginalNpmProxy = (npm config get proxy 2>$null)
    if ($script:OriginalNpmProxy -eq "null") { $script:OriginalNpmProxy = $null }
    $script:OriginalNpmHttpsProxy = (npm config get https-proxy 2>$null)
    if ($script:OriginalNpmHttpsProxy -eq "null") { $script:OriginalNpmHttpsProxy = $null }
  }
  npm config set proxy $ProxyUrl | Out-Null
  npm config set https-proxy $ProxyUrl | Out-Null
  npm config set fetch-timeout 600000 | Out-Null
  npm config set fetch-retries 5 | Out-Null
  $script:NpmProxyChanged = $true
  Ok "已临时设置 npm 代理：$ProxyUrl"
}

function Set-NpmRegistryTemporary([string]$Registry) {
  if (-not (HasCommand "npm")) { return }
  if (-not $script:NpmRegistryChanged) {
    $script:OriginalNpmRegistry = (npm config get registry 2>$null)
    if ($script:OriginalNpmRegistry -eq "undefined") { $script:OriginalNpmRegistry = $null }
  }
  npm config set registry $Registry | Out-Null
  $script:NpmRegistryChanged = $true
}

function Apply-PackageMirrors {
  if ($script:PackageMirrorsApplied) {
    if (HasCommand "npm") {
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
    if (HasCommand "npm") {
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
  if (HasCommand "npm") {
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
    npm install -g $PackageName
    return
  }
  Set-NpmRegistryTemporary "https://registry.npmmirror.com"
  Say "执行：npm install -g $PackageName（优先 npm 国内镜像）"
  Invoke-WithoutProxy { npm install -g $PackageName }
  if ($LASTEXITCODE -ne 0) {
    Warn "npm 国内镜像安装失败，切换官方源直连重试：$PackageName"
    Set-NpmRegistryTemporary "https://registry.npmjs.org/"
    npm install -g $PackageName
  }
}

function Install-PipUser([string]$PythonCommand, [string[]]$PipArgs) {
  if ($ProxyUrl) {
    Say "执行：$PythonCommand -m pip install --user $($PipArgs -join ' ')（走代理访问官方 PyPI）"
    $args = @("-m", "pip", "install", "--user", "--index-url", "https://pypi.org/simple") + $PipArgs
    Invoke-PythonCommand $PythonCommand $args
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

function Get-PythonIdentity([string]$PythonCommand) {
  try {
    $code = "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}:{sys.executable}')"
    $result = Invoke-PythonCommand $PythonCommand @("-c", $code) 2>$null
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

function Get-PythonTargets {
  $raw = New-Object System.Collections.Generic.List[string]
  $python311 = Get-Python311Command
  if ($python311) { $raw.Add($python311) }
  if (HasCommand "py") {
    $raw.Add("py -3.11")
    $raw.Add("py -3")
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

  foreach ($root in @("$env:LOCALAPPDATA\hermes", "$env:USERPROFILE\.hermes", "$env:LOCALAPPDATA\uv\python", "$env:APPDATA\uv\python")) {
    if (-not $root -or -not (Test-Path $root)) { continue }
    try {
      Get-ChildItem -Path $root -Filter "python.exe" -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $raw.Add($_.FullName)
      }
    } catch {}
  }

  $seen = @{}
  foreach ($candidate in $raw) {
    if (-not $candidate) { continue }
    if (-not (Test-PythonCommand $candidate)) { continue }
    $identity = Get-PythonIdentity $candidate
    if (-not $identity -or $seen.ContainsKey($identity)) { continue }
    $seen[$identity] = $true
    $candidate
  }
}

function Get-MainPythonCommand {
  $python311 = Get-Python311Command
  if ($python311) { return $python311 }
  if (HasCommand "python") { return "python" }
  if (HasCommand "py") { return "py -3" }
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
  foreach ($python in (Get-PythonTargets)) {
    Say "为 Python 安装 $Label 模块：$python"
    Install-PipUser $python @("--upgrade", $PackageName)
    if ($LASTEXITCODE -eq 0) { $installed = $true }
  }
  $mainPython = Get-MainPythonCommand
  if ($mainPython) {
    $scripts = Get-PythonUserScripts $mainPython
    if ($scripts -and (Test-Path $scripts)) { Add-UserPath $scripts }
  }
  return $installed
}

function Install-YtDlpModules {
  return (Install-PythonModuleAll "yt-dlp" "yt-dlp")
}

function Install-WhisperModules {
  return (Install-PythonModuleAll "openai-whisper" "Whisper")
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

function Get-CurrentScriptPathForElevation {
  if ($PSCommandPath -and (Test-Path $PSCommandPath)) { return $PSCommandPath }
  if ($MyInvocation.MyCommand.Path -and (Test-Path $MyInvocation.MyCommand.Path)) { return $MyInvocation.MyCommand.Path }
  $tmpScript = Join-Path $env:TEMP "AgentDock-install-elevated.ps1"
  Say "当前脚本来自远程管道，将保存到临时文件用于管理员运行：$tmpScript"
  Invoke-WebDownload "https://raw.githubusercontent.com/CozeBoy/AgentDock/main/install.ps1" $tmpScript
  return $tmpScript
}

function Build-ElevationArguments([string]$ScriptPath) {
  $parts = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$ScriptPath`"")
  if ($Check) { $parts += "-Check" }
  if ($Yes) { $parts += "-Yes" }
  if ($NoProxy) { $parts += "-NoProxy" }
  if ($ProxyUrl) { $parts += @("-Proxy", "`"$ProxyUrl`"") }
  if ($WhisperModel) { $parts += @("-WhisperModel", "`"$WhisperModel`"") }
  return ($parts -join " ")
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

function Choose-WhisperModel {
  if ($WhisperModel) { return Normalize-WhisperModel $WhisperModel }
  if ($Yes) { return "turbo" }
  Step "Whisper 模型选择"
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
  Invoke-PythonCommand $mainPython @("-c", "import whisper; whisper.load_model('$Model'); print('Whisper model ready: $Model')")
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
  if ((HasCommand "node") -and (HasCommand "npm")) {
    Ok "Node.js 已安装：$(node -v)"
    return $true
  }
  if ($Check) { Warn "Node.js / npm 未安装"; return $false }
  if (-not (Confirm-Step "安装 Node.js LTS（飞书 CLI 需要 npm）")) { return $false }
  if (HasCommand "nvm") {
    Use-NvmInstalledNode | Out-Null
    if (-not ((HasCommand "node") -and (HasCommand "npm"))) {
      Warn "检测到 nvm，但没有可直接启用的 Node.js 版本，将下载 Node.js 官方 zip"
    }
  }
  if (-not ((HasCommand "node") -and (HasCommand "npm"))) {
    Install-NodeFromOfficialZip
  }
  return ((HasCommand "node") -and (HasCommand "npm"))
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
  return (Ensure-Python311)
}

function Ensure-Python311 {
  $python311 = Get-Python311Command
  if ($python311) {
    Ok "Python 3.11 已安装：$(Get-Python311Version $python311)"
    return $true
  }
  if ($Check) { Warn "Python 3.11 未安装"; return $false }
  Warn "将并行安装 Python 3.11，不会删除或覆盖已有 Python 版本。"
  if (-not (Confirm-Step "安装 Python 3.11（Hermes Agent 和 Whisper 推荐）")) { return $false }
  Install-PythonFromOfficialInstaller "3.11"
  $python311 = Get-Python311Command
  return [bool]$python311
}

function Get-Python311Command {
  if (HasCommand "py") {
    try {
      py -3.11 --version *> $null
      if ($LASTEXITCODE -eq 0) { return "py -3.11" }
    } catch {}
  }
  $candidates = @(
    "$env:ProgramFiles\Python311\python.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe"
  )
  foreach ($candidate in $candidates) {
    if (Test-Path $candidate) { return $candidate }
  }
  if (HasCommand "python") {
    try {
      $version = (& python -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>$null)
      if ($version -eq "3.11") { return "python" }
    } catch {}
  }
  return $null
}

function Get-Python311Version([string]$Command) {
  if ($Command -eq "py -3.11") {
    return (py -3.11 --version)
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
  $pattern = "https://www\.python\.org/ftp/python/($escapedMinor\.\d+)/python-\1-$archSuffix\.exe"
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
    Say "执行：Python 3.11 系统静默安装（并行安装，包含 pip，并写入系统 PATH）"
    $args = "/quiet InstallAllUsers=1 PrependPath=1 Include_pip=1 Include_launcher=1 SimpleInstall=1"
  } else {
    Say "执行：Python 3.11 用户静默安装（并行安装，包含 pip，并写入用户 PATH）"
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
    "$env:ProgramFiles\Python311",
    "$env:ProgramFiles\Python313",
    "$env:ProgramFiles\Python312",
    "$env:LOCALAPPDATA\Programs\Python",
    "$env:APPDATA\Python"
  ) | Where-Object { $_ -and (Test-Path $_) }
  foreach ($root in $candidateRoots) {
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
  if (HasCommand "yt-dlp") {
    Ok "yt-dlp 命令已安装：$(yt-dlp --version | Select-Object -First 1)"
  } elseif ($Check) {
    Warn "yt-dlp 未安装"
    return $false
  }
  if ($Check) { return $true }
  if (-not (Confirm-Step "为可用 Python 安装 / 更新 yt-dlp 模块（保留主 Python 命令入口）")) { return $false }
  $script:YtDlpModulesRequested = $true
  Ensure-Python | Out-Null
  Install-YtDlpModules | Out-Null
  Register-PythonPaths
  Refresh-ProcessPath
  if (-not (HasCommand "yt-dlp")) {
    Warn "pip 安装后仍未检测到 yt-dlp 命令，改用官方 exe 兜底安装"
    Install-YtDlpFromGithubExe
  }
  return (HasCommand "yt-dlp")
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
  if (HasCommand "hermes") { Ok "Hermes 已安装：$(hermes --version | Select-Object -First 1)"; return }
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

function Get-HermesMissingPrereqs {
  $missing = New-Object System.Collections.Generic.List[string]
  if (-not (Get-Python311Command)) { $missing.Add("Python 3.11") }
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
  if (-not (Confirm-Step "打开 ChatGPT / Codex Desktop 官方安装入口")) { return }
  if (HasCommand "codex") {
    try { codex app | Out-Null } catch {}
  }
  Start-Process "https://chatgpt.com/codex"
  Warn "桌面 App 需要在打开的官方页面中完成下载和登录"
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
  if (HasCommand "lark-cli") { Ok "lark-cli 已安装：$(lark-cli --version | Select-Object -First 1)"; return }
  if ($Check) { Warn "lark-cli 未安装"; return }
  if (-not (Ensure-Node)) { Fail "npm 不可用，无法安装飞书 CLI"; return }
  if (-not (Confirm-Step "安装飞书 / Lark CLI")) { return }
  Register-NpmGlobalPath
  Install-NpmGlobal "@larksuite/cli"
  Register-NpmGlobalPath
  try { lark-cli update | Out-Null } catch {}
}

function Register-NpmGlobalPath {
  $globalPrefix = if (Test-IsAdministrator) {
    Join-Path $env:ProgramFiles "npm-global"
  } else {
    Join-Path $env:APPDATA "npm"
  }
  New-Item -ItemType Directory -Force -Path $globalPrefix | Out-Null
  npm config set prefix $globalPrefix | Out-Null
  if (Test-IsAdministrator) {
    Add-MachinePath $globalPrefix
  } else {
    Add-UserPath $globalPrefix
  }
  try {
    $npmPrefix = (npm config get prefix 2>$null).Trim()
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
  Step "Python 3.11"
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
  $whisperInstalled = HasCommand "whisper"
  if ($whisperInstalled) { Ok "Whisper 已安装" }
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
  Load-NvmIfPresent | Out-Null
  Say "系统：Windows $([Environment]::OSVersion.Version)"
  if (HasCommand "nvm") { Ok "nvm：已检测到" } else { Warn "nvm：未检测到" }
  if (HasCommand "node") { Ok "Node.js：$(node -v)" } else { Warn "Node.js：未安装" }
  $python311 = Get-Python311Command
  if ($python311) { Ok "Python 3.11：$(Get-Python311Version $python311)" } else { Warn "Python 3.11：未安装" }
  if (HasCommand "ffmpeg") { Ok "ffmpeg：已安装" } else { Warn "ffmpeg：未安装" }
  if (HasCommand "yt-dlp") { Ok "yt-dlp：$(yt-dlp --version | Select-Object -First 1)" } else { Warn "yt-dlp：未安装" }
  if (HasCommand "rg") { Ok "ripgrep：$(rg --version | Select-Object -First 1)" } else { Warn "ripgrep：未安装" }
  if (HasCommand "hermes") { Ok "Hermes：$(hermes --version | Select-Object -First 1)" } else { Warn "Hermes：未安装" }
  if (HasCommand "codex") { Ok "Codex CLI：$(codex --version | Select-Object -First 1)" } else { Warn "Codex CLI：未安装" }
  $desktop = Get-CodexDesktopInstall
  if ($desktop) { Ok "ChatGPT / Codex Desktop：$desktop" } else { Warn "ChatGPT / Codex Desktop：未检测到" }
  if (HasCommand "lark-cli") { Ok "lark-cli：$(lark-cli --version | Select-Object -First 1)" } else { Warn "lark-cli：未安装" }
  if (HasCommand "whisper") { Ok "Whisper：已安装" } else { Warn "Whisper：未安装" }
}

Prepare-ConsoleOutput
Show-Intro
Suggest-Elevation
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
Install-Whisper
Check-All
Write-Host "------------------------------------------------------------"
Ok "处理完成。新开一个 PowerShell 后，PATH 配置会完整生效。"
Restore-ProxyEnvironment
Keep-TerminalOpen
