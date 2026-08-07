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

安装顺序会先处理依赖环境，再安装上层工具：

1. macOS 基础依赖：Xcode Command Line Tools、Homebrew
2. 通用运行环境：nvm / Node.js、Python
3. Agent 工具：Hermes Agent、Codex CLI、ChatGPT / Codex Desktop、飞书 CLI
4. Whisper 依赖与工具：ffmpeg、Whisper

## macOS

复制下面一行命令到终端运行：

```bash
curl -fsSL https://raw.githubusercontent.com/CozeBoy/AgentDock/main/install.sh | bash
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

本地测试：

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Check
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Yes
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

## 安装来源

- Xcode Command Line Tools：macOS 系统自带 `xcode-select --install`
- Homebrew：官方安装脚本 `https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh`
- Hermes Agent：官方安装脚本 `https://hermes-agent.nousresearch.com/install.sh` / `install.ps1`
- Codex CLI：官方安装脚本 `https://chatgpt.com/codex/install.sh` / `install.ps1`
- ChatGPT / Codex Desktop：macOS 检查 `/Applications/ChatGPT.app` 和 `/Applications/Codex.app`；Windows 检查 Appx 包、WindowsApps 下的 `OpenAI.Codex_*\\app\\ChatGPT.exe`、常见本地安装目录
- Node.js：macOS 会先加载已有 nvm，再优先 Homebrew，否则使用 nvm；Windows 会先加载常见 nvm-windows 路径，否则使用 winget 安装 LTS 版
- 飞书 CLI：npm 包 `@larksuite/cli`
- Python 3：macOS 优先 Homebrew；Windows 使用 winget
- Whisper：Python 包 `openai-whisper`，模型支持 `fast/turbo`、`normal/base`、`tiny`、`small`、`medium`、`large`
