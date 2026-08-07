# Agent 航海环境部署工具

面向零基础用户的一键安装脚本，支持安装：

- Xcode Command Line Tools（macOS）
- Homebrew（macOS）
- Hermes Agent
- ChatGPT Desktop / Codex Desktop 中的 Codex 入口
- Codex CLI
- Node.js
- 飞书 / Lark CLI
- Python 3
- Whisper

脚本支持 HTTP 代理下载，内置常用本地代理选项：

- `http://127.0.0.1:7890`
- `http://127.0.0.1:7897`
- `http://127.0.0.1:1080`
- `http://127.0.0.1:10808`

也支持自定义输入，例如：

- `7890`
- `127.0.0.1:7890`
- `http://127.0.0.1:7890`
- 留空表示不使用代理

未启用代理时，脚本会优先使用国内镜像 / 加速源：npm 使用 `registry.npmmirror.com`，pip / uv 使用清华、阿里云等 PyPI 镜像，GitHub 资源会尝试 ghfast、gh-proxy、gh.llkk.cc、jsDelivr 等候选源。

启用代理后，脚本会改为使用官方源并让网络全部走代理：设置 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY`、`PIP_PROXY` 以及小写版本 `http_proxy`、`https_proxy`、`all_proxy`，npm 临时切到 `registry.npmjs.org`，pip / uv 临时切到官方 PyPI。下载主脚本和调用 Hermes/Codex 等子安装器时都会继承这些环境变量。第三方子安装器内部如果使用尊重这些环境变量的工具（如 PowerShell、curl、pip、uv、npm 等），通常会继续走代理。

脚本会在正常完成或通过 `q` 退出时恢复安装前的代理环境变量；临时写入的 npm `proxy` / `https-proxy` / `registry` 配置也会恢复。

安装 Hermes Agent 时会临时设置 Git URL rewrite 和 Git `http.proxy` / `https.proxy`，让 `git@github.com:` 优先改走 `https://github.com/`，并让 HTTPS clone 走所选代理，避免 SSH 22 端口在代理/国内网络下卡住；脚本结束时会恢复安装前的 Git 配置。

GitHub 资源下载会自动尝试多个中国镜像 / 加速源，适合国内网络环境。内置候选包括：

- `https://ghfast.top/`
- `https://gh-proxy.com/`
- `https://gh.llkk.cc/`
- jsDelivr raw 文件 CDN：`cdn.jsdelivr.net`、`fastly.jsdelivr.net`、`gcore.jsdelivr.net`

也可以通过环境变量追加自己的加速源：

```bash
GITHUB_ACCELERATORS_EXTRA="https://your-proxy.example/" bash install.sh
```

```powershell
$env:GITHUB_ACCELERATORS_EXTRA = "https://your-proxy.example/"
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

终端支持彩色启动动画。涉及下载时会显示下载地址和进度；Windows 使用自定义单行下载进度，避免 PowerShell 默认进度条占用大块屏幕区域。Windows 会主动开启 ANSI/VT 终端显示，避免 Hermes 等子安装器出现 `ESC[35m` 这类控制码；如果当前终端不支持，会临时设置 `NO_COLOR=1` 关闭子安装器颜色输出。

交互确认不会自动安装：按回车继续，输入 `s` 跳过当前步骤，输入 `q` 退出并保留终端窗口。如果某个环境已经安装但脚本没有检测到，建议输入 `s` 跳过。

Windows 会按权限选择安装位置：管理员 PowerShell 优先安装到 `C:\Program Files` 并写入系统 PATH；非管理员回退到 `%LOCALAPPDATA%\Programs` / 用户目录并写入用户 PATH。Node.js、Python、ffmpeg、yt-dlp、npm 全局命令、Python Scripts、Hermes/Codex 常见命令目录都会刷新到当前脚本进程；新开的 PowerShell 也会继承这些路径。

Windows 如果不是管理员 PowerShell，脚本会提醒是否弹出 UAC 并以管理员身份重新运行。选择同意后会优先安装到 `C:\Program Files`；选择否，则继续使用用户目录安装。

macOS 也会维护 PATH：安装模式会写入 Homebrew、`~/.local/bin`、Hermes、npm 全局命令、Python user bin 等常见目录到 `.zshrc`、`.zprofile`、`.bash_profile`、`.bashrc`，并立即刷新当前脚本进程。nvm 会写入初始化脚本，不会把某个固定 Node 版本目录写死到 PATH；`--check` 检测模式不会修改配置文件。

安装顺序会先处理依赖环境，再安装上层工具：

1. macOS 基础依赖：Xcode Command Line Tools、Homebrew
2. 通用运行环境：nvm / Node.js、Python 3
3. 媒体 / Hermes 依赖：ffmpeg、yt-dlp、ripgrep（Windows）
4. Agent 工具：Hermes Agent、Codex CLI、ChatGPT / Codex Desktop、飞书 CLI
5. Hermes 配置：接口模型、飞书 / Lark 通道
6. Whisper

## macOS

复制下面一行命令到终端运行：

```bash
curl -fsSL https://raw.githubusercontent.com/CozeBoy/AgentDock/main/install.sh | bash
```

如果刚更新过仓库，想强制拉取最新脚本、避免缓存，可以运行：

```bash
curl -fsSL -H "Cache-Control: no-cache" -H "Pragma: no-cache" "https://raw.githubusercontent.com/CozeBoy/AgentDock/main/install.sh?ts=$(date +%s)" | bash
```

本地测试：

```bash
bash install.sh
bash install.sh --check
bash install.sh --yes
```

带参数运行远程脚本：

```bash
curl -fsSL https://raw.githubusercontent.com/CozeBoy/AgentDock/main/install.sh | bash -s -- --proxy 7890
curl -fsSL https://raw.githubusercontent.com/CozeBoy/AgentDock/main/install.sh | bash -s -- --check --no-proxy
```

## Windows

复制下面一行命令到 PowerShell 运行：

```powershell
irm https://raw.githubusercontent.com/CozeBoy/AgentDock/main/install.ps1 | iex
```

如果刚更新过仓库，想强制拉取最新脚本、避免缓存，可以运行：

```powershell
$u = "https://raw.githubusercontent.com/CozeBoy/AgentDock/main/install.ps1?ts=$([guid]::NewGuid())"; $s = (iwr -UseBasicParsing -Headers @{"Cache-Control"="no-cache"; "Pragma"="no-cache"} $u).Content; if ($s -notmatch "Get-LarkCliCommand") { throw "仍然拿到旧脚本，请稍后重试或关闭代理缓存" }; iex $s
```

本地测试：

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Check
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Yes
```

不要直接运行 `.\install.ps1`：很多 Windows 默认执行策略会拦截本地 `.ps1` 文件并提示 `PSSecurityException`。上面的 `-ExecutionPolicy Bypass` 只对这次命令生效，不会永久修改系统策略。也可以在当前窗口临时执行：

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\install.ps1
```

如果要带参数，建议先下载再运行：

```powershell
irm https://raw.githubusercontent.com/CozeBoy/AgentDock/main/install.ps1 -OutFile install.ps1
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Proxy 7890
```

## 参数

macOS:

- `--check`：只检测，不安装。
- `--yes`：尽量自动确认，适合批量部署。
- `--proxy <proxy>`：指定代理，例如 `--proxy 7890`。
- `--no-proxy`：不使用代理。
- `--whisper-model <model>`：安装后预下载 Whisper 模型，可选 `fast`、`normal`、`tiny`、`base`、`small`、`medium`、`large`、`turbo`、`skip`。

Windows:

- `-Check`：只检测，不安装。
- `-Yes`：尽量自动确认，适合批量部署。
- `-Proxy <proxy>`：指定代理，例如 `-Proxy 7890`。
- `-NoProxy`：不使用代理。
- `-WhisperModel <model>`：安装后预下载 Whisper 模型，可选 `fast`、`normal`、`tiny`、`base`、`small`、`medium`、`large`、`turbo`、`skip`。

## Whisper 模型参考

| 选项 | 实际模型 | 大致下载体积 | 参数量 | 说明 |
| --- | --- | ---: | ---: | --- |
| `fast` | `turbo` | 约 1.6GB | 809M | 速度优先，推荐日常使用 |
| `normal` | `base` | 约 142MB | 74M | 常规轻量，适合快速试用 |
| `tiny` | `tiny` | 约 75MB | 39M | 最快，准确率较低 |
| `small` | `small` | 约 466MB | 244M | 准确率更好，资源占用适中 |
| `medium` | `medium` | 约 1.5GB | 769M | 准确率较高，下载和运行都更重 |
| `large` | `large` | 约 2.9GB | 1.55B | 准确率最高，下载最大，运行最重 |
| `skip` | 不预下载 | 0 | - | 首次使用 Whisper 时再下载 |

再次运行脚本时，如果 Whisper 已安装，脚本会先检测并展示本机已缓存的模型，然后仍然进入模型选择；可以选择新的模型继续预下载，也可以选择 `skip` 跳过。如果选择的模型已经存在，会提示使用现有缓存、覆盖重新下载或跳过。

Whisper 模型下载如果中断或校验失败，脚本会自动删除当前模型的损坏缓存并重试，最多重试 3 次；不会删除其他已缓存模型。

## 安装来源

- Xcode Command Line Tools：macOS 系统自带 `xcode-select --install`
- Homebrew：官方安装脚本 `https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh`
- Hermes Agent：官方安装脚本 `https://hermes-agent.nousresearch.com/install.sh` / `install.ps1`
- Hermes 配置：安装完成后会可选运行 `hermes model` 设置接口模型，并可选运行 `hermes gateway setup` 配置消息通道；飞书通道在 Hermes 当前版本支持时可在 gateway setup 中选择 Feishu / Lark。自动模式会跳过这些交互配置，可稍后手动执行这两个命令
  - `Select provider`：选择模型服务商；已登录 Codex CLI 时可选 `OpenAI` -> `OpenAI Codex`
  - `Import these credentials?`：是否导入已有 Codex 登录凭证，一般输入 `y`
  - `Select default model`：选择默认模型，不确定可用默认项或 `gpt-5.5`
  - `Select a platform to configure`：选择消息平台，飞书选择 `Feishu / Lark`
  - `Scan QR code...`：扫码自动创建机器人，推荐默认项
  - `How should direct messages be authorized`：私聊权限，新手推荐 `DM pairing approval`
  - `How should group chats be handled`：群聊响应方式，推荐只在被 @ 时响应
- Codex CLI：官方安装脚本 `https://chatgpt.com/codex/install.sh` / `install.ps1`
- ChatGPT / Codex Desktop：macOS 检查 `/Applications/ChatGPT.app` 和 `/Applications/Codex.app`；Windows 检查 Appx 包、WindowsApps 下的 `OpenAI.Codex_*\\app\\ChatGPT.exe`、常见本地安装目录。Windows 未安装时会提示官方下载页 `https://openai.com/chatgpt/download/`、Microsoft Store 页面 `https://apps.microsoft.com/detail/9PLM9XGG6VKS`、Store 直达协议 `ms-windows-store://pdp/?productid=9PLM9XGG6VKS`，以及备用微软商店 Codex 安装包网盘地址 `https://www.doubao.com/drive/shr/DAAFfMpBmlyOqwdFDPBcIYCjnKf`。如果想命令行尝试安装，可手动运行 `winget install --id 9PLM9XGG6VKS -s msstore`，但脚本默认不自动执行 winget
- Node.js：macOS 会先加载已有 nvm，再优先 Homebrew，否则使用 nvm；Windows 会先加载常见 nvm-windows 路径，否则下载官方 Node.js LTS zip；管理员 PowerShell 安装到 `C:\Program Files\nodejs` 并写入系统 PATH，非管理员回退到用户目录并写入用户 PATH
- 飞书 CLI：npm 包 `@larksuite/cli`；脚本会额外检测 `lark-cli auth status`，区分用户身份和 Bot 身份。如果用户身份未登录，会提示运行 `lark-cli auth login --recommend` 完成推荐权限授权
- Python 3：脚本会接受已有的任意全局 Python 3，例如 Python 3.11 / 3.12 / 3.13 / 3.14；只有完全未检测到 Python 3 时才提示安装。Hermes Agent 如果需要 Python 3.11，会使用自己的隔离运行时，脚本不会把 Hermes 自带 Python 当作全局 Python，也不会加入全局 PATH
- ffmpeg：macOS 使用 Homebrew；Windows 下载 gyan.dev 官方 zip 并解压到系统/用户目录
- yt-dlp：优先通过 Python 模块安装（`python -m pip install --user --upgrade yt-dlp`），并且主 Python 会优先处理；如果 pip 没有生成全局命令入口，会用 `uv tool install yt-dlp` 兜底创建用户级入口。Hermes 自带 Python 只服务 Hermes，不会加入全局 PATH，也不会作为 yt-dlp 安装目标；`uvx --from yt-dlp ...` 这类临时运行 / cache 入口不会被视为已全局安装。Windows 如果仍未检测到命令，会下载 GitHub 官方 `yt-dlp.exe` 兜底，这只是命令入口兜底，不替代主 Python 模块安装
- ripgrep：Windows 会在 Hermes Agent 前预装 ripgrep，避免 Hermes 子安装器再走 winget
- Whisper：Python 包 `openai-whisper`，会尽量给可写且带 pip 的系统/用户 Python 与主 Python 3 安装模块；如果 pip 没有生成全局 `whisper` 命令入口，会用 `uv tool install openai-whisper` 兜底创建用户级入口。Hermes 自带 Python 只服务 Hermes，不会加入全局 PATH，也不会作为 Whisper 安装目标；`uvx` / Hermes profile cache 中的临时入口不会被视为已全局安装。安装模块后会单独选择是否预下载模型，支持 `fast/turbo`、`normal/base`、`tiny`、`small`、`medium`、`large`、`skip`
