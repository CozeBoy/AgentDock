param(
  [switch]$Check,
  [switch]$Yes,
  [string]$Proxy,
  [switch]$NoProxy,
  [string]$WhisperModel
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "Continue"

function Say($Text) { Write-Host $Text }
function Ok($Text) { Write-Host "OK $Text" -ForegroundColor Green }
function Warn($Text) { Write-Host "WARN $Text" -ForegroundColor Yellow }
function Fail($Text) { Write-Host "ERR $Text" -ForegroundColor Red }
function Step($Text) { Write-Host ""; Write-Host "==> $Text" -ForegroundColor Cyan }
function HasCommand($Name) { [bool](Get-Command $Name -ErrorAction SilentlyContinue) }
function EffectsEnabled { return (-not $env:NO_COLOR) }

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
  Ok "已启用代理：$ProxyUrl"
} else {
  Warn "未启用代理"
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
  Keep-TerminalOpen
  exit 0
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
  Say "  1) fast / turbo：速度优先，推荐日常使用"
  Say "  2) normal / base：常规模型，体积较小"
  Say "  3) tiny：最快，准确率较低"
  Say "  4) small：更准，下载更大"
  Say "  5) medium：较准，下载较大"
  Say "  6) large：最准，下载最大"
  Say "  7) 跳过预下载"
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
  python -c "import whisper; whisper.load_model('$Model'); print('Whisper model ready: $Model')"
}

function Invoke-WebDownload([string]$Url, [string]$OutFile) {
  Say "下载地址：$Url"
  $params = @{
    Uri = $Url
    OutFile = $OutFile
    UseBasicParsing = $true
    TimeoutSec = 60
    ErrorAction = "Stop"
  }
  if ($ProxyUrl) { $params["Proxy"] = $ProxyUrl }
  Invoke-WebRequest @params
  if (-not (Test-Path $OutFile)) {
    throw "下载失败：$Url"
  }
}

function Get-UrlCandidates([string]$Url) {
  $items = New-Object System.Collections.Generic.List[string]
  $items.Add($Url)
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

function Refresh-ProcessPath {
  $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  $env:Path = "$machinePath;$userPath"
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
  $targetRoot = Join-Path $env:LOCALAPPDATA "Programs\nodejs"
  $targetDir = Join-Path $targetRoot "node-$version-win-$arch"
  Say "准备安装 Node.js $version 到：$targetDir"
  Invoke-WebDownload $zipUrl $zipFile
  Remove-Item $targetDir -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path $targetRoot | Out-Null
  Say "解压 Node.js..."
  Expand-Archive -Path $zipFile -DestinationPath $targetRoot -Force
  Add-UserPath $targetDir
  Ok "Node.js 已安装到用户目录：$targetDir"
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
  if (HasCommand "python") { Ok "Python 已安装"; return $true }
  if ($Check) { Warn "Python 未安装"; return $false }
  if (-not (Confirm-Step "安装 Python 3（Whisper 需要）")) { return $false }
  Install-PythonFromOfficialInstaller
  return (HasCommand "python")
}

function Get-PythonInstallerUrl {
  $pageFile = Join-Path $env:TEMP "python-windows.html"
  Invoke-WebDownload "https://www.python.org/downloads/windows/" $pageFile
  $html = Get-Content $pageFile -Raw
  $archSuffix = if ((Get-WindowsArchName) -eq "arm64") { "arm64" } else { "amd64" }
  $pattern = "https://www\.python\.org/ftp/python/(\d+\.\d+\.\d+)/python-\1-$archSuffix\.exe"
  $matches = [regex]::Matches($html, $pattern)
  if ($matches.Count -gt 0) { return $matches[0].Value }
  if ($archSuffix -eq "amd64") {
    return "https://www.python.org/ftp/python/3.12.10/python-3.12.10-amd64.exe"
  }
  throw "未找到适合当前系统的 Python 安装包"
}

function Install-PythonFromOfficialInstaller {
  $installerUrl = Get-PythonInstallerUrl
  $installer = Join-Path $env:TEMP ([IO.Path]::GetFileName($installerUrl))
  Say "准备下载 Python 官方安装器：$installerUrl"
  Invoke-WebDownload $installerUrl $installer
  Say "执行：Python 用户静默安装（包含 pip，并写入用户 PATH）"
  $process = Start-Process -FilePath $installer -ArgumentList "/quiet InstallAllUsers=0 PrependPath=1 Include_pip=1 Include_launcher=1 SimpleInstall=1" -Wait -PassThru
  if ($process.ExitCode -ne 0) { throw "Python 安装失败，退出码：$($process.ExitCode)" }
  Register-PythonPaths
  Refresh-ProcessPath
}

function Register-PythonPaths {
  $candidateRoots = @(
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

function Install-FfmpegFromOfficialZip {
  $zipUrl = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"
  $zipFile = Join-Path $env:TEMP "ffmpeg-release-essentials.zip"
  $targetRoot = Join-Path $env:LOCALAPPDATA "Programs\ffmpeg"
  Say "准备下载 ffmpeg 官方构建：$zipUrl"
  Invoke-WebDownload $zipUrl $zipFile
  Remove-Item $targetRoot -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path $targetRoot | Out-Null
  Say "解压 ffmpeg..."
  Expand-Archive -Path $zipFile -DestinationPath $targetRoot -Force
  $ffmpegExe = Get-ChildItem -Path $targetRoot -Filter "ffmpeg.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $ffmpegExe) { throw "ffmpeg 解压后未找到 ffmpeg.exe" }
  $binDir = $ffmpegExe.Directory.FullName
  Add-UserPath $binDir
  Ok "ffmpeg 已安装到用户目录：$binDir"
}

function Install-Hermes {
  Step "Hermes Agent"
  if (HasCommand "hermes") { Ok "Hermes 已安装：$(hermes --version | Select-Object -First 1)"; return }
  if ($Check) { Warn "Hermes 未安装"; return }
  if (-not (Confirm-Step "安装 Hermes Agent")) { return }
  $script = Join-Path $env:TEMP "hermes-install.ps1"
  try {
    Invoke-WebDownload "https://hermes-agent.nousresearch.com/install.ps1" $script
    powershell -ExecutionPolicy Bypass -File $script
  } catch {
    Fail "Hermes 安装脚本下载或执行失败：$($_.Exception.Message)"
  }
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
    powershell -ExecutionPolicy Bypass -File $script
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
}

function Install-LarkCli {
  Step "飞书 / Lark CLI"
  if (HasCommand "lark-cli") { Ok "lark-cli 已安装：$(lark-cli --version | Select-Object -First 1)"; return }
  if ($Check) { Warn "lark-cli 未安装"; return }
  if (-not (Ensure-Node)) { Fail "npm 不可用，无法安装飞书 CLI"; return }
  if (-not (Confirm-Step "安装飞书 / Lark CLI")) { return }
  if ($ProxyUrl) {
    npm config set proxy $ProxyUrl | Out-Null
    npm config set https-proxy $ProxyUrl | Out-Null
  }
  npm install -g @larksuite/cli
  Register-NpmGlobalPath
  try { lark-cli update | Out-Null } catch {}
}

function Register-NpmGlobalPath {
  try {
    $npmPrefix = (npm config get prefix 2>$null).Trim()
    if ($npmPrefix -and (Test-Path $npmPrefix)) { Add-UserPath $npmPrefix }
  } catch {}
  $npmRoaming = Join-Path $env:APPDATA "npm"
  if (Test-Path $npmRoaming) { Add-UserPath $npmRoaming }
}

function Install-Python {
  Step "Python 3"
  Ensure-Python | Out-Null
}

function Install-Whisper {
  Step "Whisper"
  $whisperInstalled = HasCommand "whisper"
  if ($whisperInstalled) { Ok "Whisper 已安装" }
  if ($Check -and -not $whisperInstalled) { Warn "Whisper 未安装"; return }
  if ($Check) { return }
  Ensure-Python | Out-Null
  Ensure-Ffmpeg | Out-Null
  if (-not (HasCommand "python")) { Fail "Python 不可用，无法安装 Whisper"; return }
  if (-not $whisperInstalled) {
    if (-not (Confirm-Step "安装 Whisper（openai-whisper Python 包）")) { return }
    Say "执行：python -m pip install --user --upgrade pip"
    python -m pip install --user --upgrade pip
    Say "执行：python -m pip install --user --upgrade openai-whisper"
    python -m pip install --user --upgrade openai-whisper
  }
  $pythonUserBase = (python -m site --user-base 2>$null)
  if ($pythonUserBase) { Add-UserPath (Join-Path $pythonUserBase "Scripts") }
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
  if (HasCommand "python") { Ok "Python：$(python --version)" } else { Warn "Python：未安装" }
  if (HasCommand "hermes") { Ok "Hermes：$(hermes --version | Select-Object -First 1)" } else { Warn "Hermes：未安装" }
  if (HasCommand "codex") { Ok "Codex CLI：$(codex --version | Select-Object -First 1)" } else { Warn "Codex CLI：未安装" }
  $desktop = Get-CodexDesktopInstall
  if ($desktop) { Ok "ChatGPT / Codex Desktop：$desktop" } else { Warn "ChatGPT / Codex Desktop：未检测到" }
  if (HasCommand "lark-cli") { Ok "lark-cli：$(lark-cli --version | Select-Object -First 1)" } else { Warn "lark-cli：未安装" }
  if (HasCommand "ffmpeg") { Ok "ffmpeg：已安装" } else { Warn "ffmpeg：未安装" }
  if (HasCommand "whisper") { Ok "Whisper：已安装" } else { Warn "Whisper：未安装" }
}

Show-Intro
Write-Host "------------------------------------------------------------"
Write-Host "Agent 航海环境部署工具 (Windows)"
Write-Host "------------------------------------------------------------"

Check-All
if ($Check) { Graceful-Exit }
Install-Node
Install-Python
Install-Hermes
Install-CodexCli
Install-CodexDesktop
Install-LarkCli
Ensure-Ffmpeg | Out-Null
Install-Whisper
Check-All
Write-Host "------------------------------------------------------------"
Ok "处理完成。新开一个 PowerShell 后，PATH 配置会完整生效。"
Keep-TerminalOpen
