#!/usr/bin/env bash

# Agent 航海环境部署工具 (macOS)
# 失败不中断，方便新手看到完整检测结果。

set +e

if [ -t 1 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'
  YLW=$'\033[33m'; BLU=$'\033[34m'; CYN=$'\033[36m'; RST=$'\033[0m'
else
  BOLD=""; DIM=""; RED=""; GRN=""; YLW=""; BLU=""; CYN=""; RST=""
fi

say(){ printf '%s\n' "$*"; }
ok(){ printf "${GRN}OK${RST} %s\n" "$*"; }
warn(){ printf "${YLW}WARN${RST} %s\n" "$*"; }
err(){ printf "${RED}ERR${RST} %s\n" "$*"; }
step(){ printf "\n${BOLD}${BLU}==> %s${RST}\n" "$*"; }
hr(){ printf '%s\n' "------------------------------------------------------------"; }
has_cmd(){ command -v "$1" >/dev/null 2>&1; }
effects_enabled(){ [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; }

CHECK_ONLY=0
ASSUME_YES=0
PROXY_INPUT=""
NO_PROXY_MODE=0
WHISPER_MODEL_INPUT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK_ONLY=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --proxy) shift; PROXY_INPUT="${1:-}" ;;
    --no-proxy) NO_PROXY_MODE=1 ;;
    --whisper-model) shift; WHISPER_MODEL_INPUT="${1:-}" ;;
    *) warn "忽略未知参数：$1" ;;
  esac
  shift
done

GITHUB_ACCELERATORS="
https://ghfast.top/
https://gh-proxy.com/
https://gh.llkk.cc/
"

normalize_proxy(){
  local value="$1"
  value="$(printf '%s' "$value" | tr -d '[:space:]')"
  [ -z "$value" ] && return 0
  if printf '%s' "$value" | grep -Eq '^[0-9]+$'; then
    printf 'http://127.0.0.1:%s\n' "$value"
  elif printf '%s' "$value" | grep -Eq '^[^/:]+:[0-9]+$'; then
    printf 'http://%s\n' "$value"
  elif printf '%s' "$value" | grep -Eq '^(http|https|socks5)://'; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$value"
  fi
}

choose_proxy(){
  if [ "$NO_PROXY_MODE" = "1" ]; then
    PROXY_URL=""
    return
  fi
  if [ -n "$PROXY_INPUT" ]; then
    PROXY_URL="$(normalize_proxy "$PROXY_INPUT")"
    return
  fi
  if [ "$ASSUME_YES" = "1" ]; then
    PROXY_URL="http://127.0.0.1:7890"
    return
  fi

  step "网络代理设置"
  say "请选择下载代理："
  say "  1) http://127.0.0.1:7890"
  say "  2) http://127.0.0.1:7897"
  say "  3) http://127.0.0.1:1080"
  say "  4) http://127.0.0.1:10808"
  say "  5) 自定义"
  say "  6) 不使用代理"
  printf "${CYN}输入序号、自定义代理，或只输入端口 [默认 1]：${RST}"
  IFS= read -r choice </dev/tty 2>/dev/null
  choice="${choice:-1}"
  case "$choice" in
    1) PROXY_URL="http://127.0.0.1:7890" ;;
    2) PROXY_URL="http://127.0.0.1:7897" ;;
    3) PROXY_URL="http://127.0.0.1:1080" ;;
    4) PROXY_URL="http://127.0.0.1:10808" ;;
    5)
      printf "${CYN}请输入代理地址或端口：${RST}"
      IFS= read -r custom_proxy </dev/tty 2>/dev/null
      PROXY_URL="$(normalize_proxy "$custom_proxy")"
      ;;
    6|n|N|none|no) PROXY_URL="" ;;
    *) PROXY_URL="$(normalize_proxy "$choice")" ;;
  esac
}

apply_proxy_env(){
  [ -z "$PROXY_URL" ] && { warn "未启用代理"; return; }
  export http_proxy="$PROXY_URL"
  export https_proxy="$PROXY_URL"
  export HTTP_PROXY="$PROXY_URL"
  export HTTPS_PROXY="$PROXY_URL"
  export ALL_PROXY="$PROXY_URL"
  ok "已启用代理：$PROXY_URL"
}

curl_download(){
  local url="$1" out="$2"
  if [ -n "$PROXY_URL" ]; then
    run_with_spinner "下载资源" curl -fsSL --connect-timeout 12 --retry 2 --proxy "$PROXY_URL" "$url" -o "$out"
  else
    run_with_spinner "下载资源" curl -fsSL --connect-timeout 12 --retry 2 "$url" -o "$out"
  fi
}

intro_animation(){
  effects_enabled || return
  local title="AgentDock" subtitle="Agent environment bootstrap" i width
  printf '\033[?25l'
  printf '\n%s' "${CYN}"
  printf '    ___                    __  ____             __  \n'
  printf '   /   |  ____ ____  ____ / /_/ __ \\____  _____/ /__\n'
  printf '  / /| | / __ `/ _ \\/ __ `/ __/ / / / __ \\/ ___/ //_/\n'
  printf ' / ___ |/ /_/ /  __/ /_/ / /_/ /_/ / /_/ / /__/ ,<   \n'
  printf '/_/  |_|\\__, /\\___/\\__,_/\\__/_____/\\____/\\___/_/|_|  \n'
  printf '       /____/                                         \n'
  printf '%s' "${RST}"
  printf "${BOLD}"
  for ((i=0; i<${#title}; i++)); do
    printf '%s' "${title:i:1}"
    sleep 0.025
  done
  printf "${RST} ${DIM}%s${RST}\n" "$subtitle"
  printf "${DIM}["
  width=28
  for ((i=0; i<width; i++)); do
    printf '#'
    sleep 0.015
  done
  printf "] ready${RST}\n\n"
  printf '\033[?25h'
}

run_with_spinner(){
  local label="$1" pid status i spin
  shift
  if ! effects_enabled; then
    "$@"
    return $?
  fi
  "$@" &
  pid=$!
  i=0
  spin='|/-\'
  printf '\033[?25l'
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r%s%s%s %s...' "${CYN}" "${spin:i++%4:1}" "${RST}" "$label"
    sleep 0.12
  done
  wait "$pid"
  status=$?
  if [ "$status" -eq 0 ]; then
    printf '\r%sOK%s %s    \n' "$GRN" "$RST" "$label"
  else
    printf '\r%sERR%s %s    \n' "$RED" "$RST" "$label"
  fi
  printf '\033[?25h'
  return "$status"
}

github_candidates(){
  local url="$1" mirror
  printf '%s\n' "$url"
  case "$url" in
    https://github.com/*|https://raw.githubusercontent.com/*)
      for mirror in $GITHUB_ACCELERATORS; do
        printf '%s%s\n' "$mirror" "$url"
      done
      if [ -n "${GITHUB_ACCELERATORS_EXTRA:-}" ]; then
        for mirror in $GITHUB_ACCELERATORS_EXTRA; do
          printf '%s%s\n' "$mirror" "$url"
        done
      fi
      raw_jsdelivr_candidates "$url"
      ;;
  esac
}

raw_jsdelivr_candidates(){
  local url="$1" rest owner repo ref path
  case "$url" in
    https://raw.githubusercontent.com/*) ;;
    *) return ;;
  esac
  rest="${url#https://raw.githubusercontent.com/}"
  owner="$(printf '%s' "$rest" | cut -d/ -f1)"
  repo="$(printf '%s' "$rest" | cut -d/ -f2)"
  ref="$(printf '%s' "$rest" | cut -d/ -f3)"
  path="$(printf '%s' "$rest" | cut -d/ -f4-)"
  [ -n "$owner" ] && [ -n "$repo" ] && [ -n "$ref" ] && [ -n "$path" ] || return
  printf 'https://cdn.jsdelivr.net/gh/%s/%s@%s/%s\n' "$owner" "$repo" "$ref" "$path"
  printf 'https://fastly.jsdelivr.net/gh/%s/%s@%s/%s\n' "$owner" "$repo" "$ref" "$path"
  printf 'https://gcore.jsdelivr.net/gh/%s/%s@%s/%s\n' "$owner" "$repo" "$ref" "$path"
}

download_with_fallback(){
  local url="$1" out="$2" candidate
  rm -f "$out"
  while IFS= read -r candidate; do
    [ -z "$candidate" ] && continue
    say "尝试下载：$candidate"
    if curl_download "$candidate" "$out"; then
      ok "下载成功"
      return 0
    fi
    warn "下载失败，尝试下一个源"
  done <<EOF
$(github_candidates "$url")
EOF
  return 1
}

confirm(){
  local prompt="$1"
  [ "$ASSUME_YES" = "1" ] && return 0
  printf "${CYN}%s${RST} ${DIM}[回车=继续 / s=跳过 / q=退出]：${RST}" "$prompt"
  IFS= read -r ans </dev/tty 2>/dev/null
  case "$ans" in
    q|Q) graceful_exit ;;
    s|S) return 1 ;;
    *) return 0 ;;
  esac
}

keep_terminal_open(){
  [ "$ASSUME_YES" = "1" ] && return
  [ -t 0 ] || [ -r /dev/tty ] || return
  local shell_path
  shell_path="${SHELL:-/bin/zsh}"
  say "${DIM}脚本已结束，终端将保持打开。输入 exit 后再退出。${RST}"
  exec "$shell_path" -l
}

graceful_exit(){
  keep_terminal_open
  exit 0
}

normalize_whisper_model(){
  local value="$1"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  case "$value" in
    fast) printf '%s\n' "turbo" ;;
    normal|regular|default) printf '%s\n' "base" ;;
    tiny|base|small|medium|large|turbo|skip|"") printf '%s\n' "$value" ;;
    *) printf '%s\n' "$value" ;;
  esac
}

choose_whisper_model(){
  if [ -n "$WHISPER_MODEL_INPUT" ]; then
    WHISPER_MODEL="$(normalize_whisper_model "$WHISPER_MODEL_INPUT")"
    return
  fi
  if [ "$ASSUME_YES" = "1" ]; then
    WHISPER_MODEL="turbo"
    return
  fi

  step "Whisper 模型选择"
  say "选择要预下载的 Whisper 模型："
  say "  1) fast / turbo：速度优先，推荐日常使用"
  say "  2) normal / base：常规模型，体积较小"
  say "  3) tiny：最快，准确率较低"
  say "  4) small：更准，下载更大"
  say "  5) medium：较准，下载较大"
  say "  6) large：最准，下载最大"
  say "  7) 跳过预下载"
  printf "${CYN}输入序号或模型名 [默认 1]：${RST}"
  IFS= read -r model_choice </dev/tty 2>/dev/null
  model_choice="${model_choice:-1}"
  case "$model_choice" in
    1) WHISPER_MODEL="turbo" ;;
    2) WHISPER_MODEL="base" ;;
    3) WHISPER_MODEL="tiny" ;;
    4) WHISPER_MODEL="small" ;;
    5) WHISPER_MODEL="medium" ;;
    6) WHISPER_MODEL="large" ;;
    7|s|S|skip) WHISPER_MODEL="skip" ;;
    *) WHISPER_MODEL="$(normalize_whisper_model "$model_choice")" ;;
  esac
}

download_whisper_model(){
  local model="$1"
  model="$(normalize_whisper_model "$model")"
  [ -z "$model" ] && return
  [ "$model" = "skip" ] && { warn "已跳过 Whisper 模型预下载"; return; }
  case "$model" in
    tiny|base|small|medium|large|turbo) ;;
    *) warn "未知 Whisper 模型：$model，跳过预下载"; return ;;
  esac
  step "预下载 Whisper 模型：$model"
  python3 - <<PY
import whisper
whisper.load_model("$model")
print("Whisper model ready: $model")
PY
}

add_path_once(){
  local dir="$1" marker="$2" rc line
  [ -d "$dir" ] || return
  case ":$PATH:" in *":$dir:"*) ;; *) export PATH="$dir:$PATH" ;; esac
  line="export PATH=\"$dir:\$PATH\" # Agent 航海环境部署工具：$marker"
  for rc in "$HOME/.zshrc" "$HOME/.bash_profile"; do
    [ -e "$rc" ] || touch "$rc" 2>/dev/null
    grep -qF "$dir" "$rc" 2>/dev/null || printf '\n%s\n' "$line" >> "$rc"
  done
}

ensure_xcode_clt(){
  if xcode-select -p >/dev/null 2>&1 && git --version >/dev/null 2>&1; then
    ok "Xcode Command Line Tools 已可用"
    return 0
  fi
  warn "未检测到 Xcode Command Line Tools，将打开系统安装弹窗"
  xcode-select --install 2>/dev/null
  warn "请完成弹窗安装后重新运行本脚本"
  return 1
}

ensure_homebrew(){
  if has_cmd brew; then
    ok "Homebrew 已安装：$(brew --version 2>/dev/null | head -1)"
    return 0
  fi
  if [ "$CHECK_ONLY" = "1" ]; then
    warn "Homebrew 未安装"
    return 1
  fi
  confirm "安装 Homebrew（Node.js、ffmpeg、Python 等依赖会优先使用它安装）" || return 1
  local tmp_script="$TMPDIR/homebrew-install.sh"
  if download_with_fallback "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh" "$tmp_script"; then
    NONINTERACTIVE=1 bash "$tmp_script"
    if [ -x "/opt/homebrew/bin/brew" ]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
      add_path_once "/opt/homebrew/bin" "Homebrew"
    elif [ -x "/usr/local/bin/brew" ]; then
      eval "$(/usr/local/bin/brew shellenv)"
      add_path_once "/usr/local/bin" "Homebrew"
    fi
  fi
  has_cmd brew && ok "Homebrew 安装完成：$(brew --version 2>/dev/null | head -1)"
}

ensure_node(){
  load_nvm_if_present
  if has_cmd node && has_cmd npm; then
    ok "Node.js 已安装：$(node -v 2>/dev/null)"
    return 0
  fi
  if [ "$CHECK_ONLY" = "1" ]; then
    warn "Node.js / npm 未安装"
    return 1
  fi
  confirm "安装 Node.js（飞书 CLI 需要 npm）" || return 1
  if has_cmd nvm; then
    nvm install --lts
    nvm use --lts
  elif has_cmd brew; then
    brew install node
  else
    warn "未检测到 Homebrew，将通过 nvm 安装 Node.js"
    local tmp_script="$TMPDIR/nvm-install.sh"
    if download_with_fallback "https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh" "$tmp_script"; then
      PROFILE="$HOME/.zshrc" bash "$tmp_script"
      export NVM_DIR="$HOME/.nvm"
      [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
      nvm install --lts
      nvm use --lts
    fi
  fi
  has_cmd node && has_cmd npm && ok "Node.js 安装完成：$(node -v 2>/dev/null)"
}

load_nvm_if_present(){
  local nvm_dir_candidate
  if has_cmd nvm; then
    return 0
  fi
  for nvm_dir_candidate in "$NVM_DIR" "$HOME/.nvm" "/opt/homebrew/opt/nvm" "/usr/local/opt/nvm"; do
    [ -n "$nvm_dir_candidate" ] || continue
    if [ -s "$nvm_dir_candidate/nvm.sh" ]; then
      export NVM_DIR="$nvm_dir_candidate"
      # shellcheck disable=SC1090
      . "$nvm_dir_candidate/nvm.sh"
      break
    fi
  done
  if has_cmd nvm; then
    ok "检测到 nvm 环境"
    if ! has_cmd node; then
      nvm use --lts >/dev/null 2>&1 || nvm use default >/dev/null 2>&1 || true
    fi
  fi
}

ensure_npm_user_prefix(){
  local prefix user_prefix bin
  has_cmd npm || return 1
  prefix="$(npm prefix -g 2>/dev/null || npm config get prefix 2>/dev/null)"
  if [ -n "$prefix" ] && [ -w "$prefix/lib/node_modules" ]; then
    bin="$prefix/bin"
    add_path_once "$bin" "npm 全局命令"
    return 0
  fi
  user_prefix="$HOME/.npm-global"
  warn "当前 npm 全局目录不可写，改用用户目录安装：$user_prefix"
  mkdir -p "$user_prefix/bin" "$user_prefix/lib/node_modules" 2>/dev/null
  export npm_config_prefix="$user_prefix"
  npm config set prefix "$user_prefix" >/dev/null 2>&1
  add_path_once "$user_prefix/bin" "npm 全局命令"
}

ensure_python(){
  if has_cmd python3; then
    ok "Python 已安装：$(python3 --version 2>/dev/null)"
    return 0
  fi
  if [ "$CHECK_ONLY" = "1" ]; then
    warn "Python3 未安装"
    return 1
  fi
  confirm "安装 Python 3（Whisper 需要）" || return 1
  if has_cmd brew; then
    brew install python
  else
    warn "未检测到 Homebrew，无法自动安装 Python；请稍后手动安装或先安装 Homebrew"
    return 1
  fi
}

ensure_ffmpeg(){
  has_cmd ffmpeg && { ok "ffmpeg 已安装"; return 0; }
  [ "$CHECK_ONLY" = "1" ] && { warn "ffmpeg 未安装"; return 1; }
  confirm "安装 ffmpeg（Whisper 处理音频需要）" || return 1
  if has_cmd brew; then
    brew install ffmpeg
  else
    warn "未检测到 Homebrew，无法自动安装 ffmpeg；请稍后手动安装或先安装 Homebrew"
    return 1
  fi
}

install_hermes(){
  step "Hermes Agent"
  has_cmd hermes && { ok "Hermes 已安装：$(hermes --version 2>/dev/null | head -1)"; return; }
  [ "$CHECK_ONLY" = "1" ] && { warn "Hermes 未安装"; return; }
  confirm "安装 Hermes Agent" || return
  curl_download "https://hermes-agent.nousresearch.com/install.sh" "$TMPDIR/hermes-install.sh" &&
    bash "$TMPDIR/hermes-install.sh"
  add_path_once "$HOME/.local/bin" "Hermes"
  add_path_once "$HOME/.hermes/bin" "Hermes"
}

install_codex_cli(){
  step "Codex CLI"
  has_cmd codex && { ok "Codex CLI 已安装：$(codex --version 2>/dev/null | head -1)"; return; }
  [ "$CHECK_ONLY" = "1" ] && { warn "Codex CLI 未安装"; return; }
  confirm "安装 Codex CLI" || return
  curl_download "https://chatgpt.com/codex/install.sh" "$TMPDIR/codex-install.sh" &&
    CODEX_INSTALLER_USE_RELEASES_OPENAI_COM=false sh "$TMPDIR/codex-install.sh"
  add_path_once "$HOME/.local/bin" "Codex CLI"
}

install_codex_desktop(){
  step "ChatGPT / Codex Desktop"
  if detect_codex_desktop >/dev/null 2>&1; then
    ok "检测到 $(detect_codex_desktop)"
    return
  fi
  [ "$CHECK_ONLY" = "1" ] && { warn "未检测到 ChatGPT / Codex Desktop 应用"; return; }
  confirm "打开 ChatGPT / Codex Desktop 官方安装入口" || return
  if has_cmd codex; then
    codex app >/dev/null 2>&1
  fi
  open "https://chatgpt.com/codex" >/dev/null 2>&1
  warn "桌面 App 需要在打开的官方页面中完成下载和登录"
}

detect_codex_desktop(){
  if [ -d "/Applications/ChatGPT.app" ]; then
    printf '%s\n' "ChatGPT.app：/Applications/ChatGPT.app"
    return 0
  fi
  if [ -d "/Applications/Codex.app" ]; then
    printf '%s\n' "Codex.app：/Applications/Codex.app"
    return 0
  fi
  return 1
}

install_xcode_tools(){
  step "Xcode Command Line Tools"
  ensure_xcode_clt
}

install_homebrew(){
  step "Homebrew"
  ensure_homebrew
}

install_node(){
  step "Node.js"
  ensure_node
}

install_lark_cli(){
  step "飞书 / Lark CLI"
  has_cmd lark-cli && { ok "lark-cli 已安装：$(lark-cli --version 2>/dev/null | head -1)"; return; }
  [ "$CHECK_ONLY" = "1" ] && { warn "lark-cli 未安装"; return; }
  ensure_node
  has_cmd npm || { err "npm 不可用，无法安装飞书 CLI"; return; }
  confirm "安装飞书 / Lark CLI" || return
  ensure_npm_user_prefix
  [ -n "$PROXY_URL" ] && {
    npm config set proxy "$PROXY_URL" >/dev/null 2>&1
    npm config set https-proxy "$PROXY_URL" >/dev/null 2>&1
  }
  npm install -g @larksuite/cli
  local npm_bin
  npm_bin="$(npm prefix -g 2>/dev/null)/bin"
  add_path_once "$npm_bin" "npm 全局命令"
  has_cmd lark-cli && lark-cli update >/dev/null 2>&1
}

install_python(){
  step "Python 3"
  ensure_python
}

install_whisper(){
  step "Whisper"
  local whisper_installed=0
  if python3 -m whisper --help >/dev/null 2>&1 || has_cmd whisper; then
    ok "Whisper 已安装"
    whisper_installed=1
  fi
  [ "$CHECK_ONLY" = "1" ] && [ "$whisper_installed" = "0" ] && { warn "Whisper 未安装"; return; }
  [ "$CHECK_ONLY" = "1" ] && return
  ensure_python || return
  ensure_ffmpeg
  if [ "$whisper_installed" = "0" ]; then
    confirm "安装 Whisper（openai-whisper Python 包）" || return
    python3 -m pip install --user --upgrade pip
    python3 -m pip install --user --upgrade openai-whisper
  fi
  local python_user_bin
  python_user_bin="$(python3 -m site --user-base 2>/dev/null)/bin"
  add_path_once "$python_user_bin" "Python 用户命令"
  choose_whisper_model
  download_whisper_model "$WHISPER_MODEL"
}

check_all(){
  step "环境检测"
  load_nvm_if_present
  say "系统：$(sw_vers -productVersion 2>/dev/null) / $(uname -m)"
  has_cmd hermes && ok "Hermes：$(hermes --version 2>/dev/null | head -1)" || warn "Hermes：未安装"
  has_cmd codex && ok "Codex CLI：$(codex --version 2>/dev/null | head -1)" || warn "Codex CLI：未安装"
  detect_codex_desktop >/dev/null 2>&1 && ok "ChatGPT / Codex Desktop：$(detect_codex_desktop)" || warn "ChatGPT / Codex Desktop：未检测到"
  has_cmd lark-cli && ok "lark-cli：$(lark-cli --version 2>/dev/null | head -1)" || warn "lark-cli：未安装"
  has_cmd whisper || python3 -m whisper --help >/dev/null 2>&1 && ok "Whisper：已安装" || warn "Whisper：未安装"
  has_cmd python3 && ok "Python：$(python3 --version 2>/dev/null)" || warn "Python：未安装"
  has_cmd node && ok "Node.js：$(node -v 2>/dev/null)" || warn "Node.js：未安装"
  has_cmd nvm && ok "nvm：已检测到" || warn "nvm：未检测到"
  has_cmd brew && ok "Homebrew：$(brew --version 2>/dev/null | head -1)" || warn "Homebrew：未安装"
  xcode-select -p >/dev/null 2>&1 && ok "Xcode Command Line Tools：已安装" || warn "Xcode Command Line Tools：未安装"
  has_cmd ffmpeg && ok "ffmpeg：已安装" || warn "ffmpeg：未安装"
}

main(){
  intro_animation
  hr
  say "${BOLD}Agent 航海环境部署工具 (macOS)${RST}"
  hr
  choose_proxy
  apply_proxy_env
  check_all
  [ "$CHECK_ONLY" = "1" ] && graceful_exit
  install_xcode_tools
  install_homebrew
  install_node
  install_python
  install_hermes
  install_codex_cli
  install_codex_desktop
  install_lark_cli
  ensure_ffmpeg
  install_whisper
  check_all
  hr
  ok "处理完成。新开一个终端后，PATH 配置会完整生效。"
  keep_terminal_open
}

main "$@"
