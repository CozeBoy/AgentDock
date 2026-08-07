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

tool_path(){
  command -v "$1" 2>/dev/null || true
}

is_transient_tool_path(){
  case "$1" in
    *"/.cache/uv/"*|*"/.cache/hermes/"*|*"/.hermes/"*|*"/hermes/"*|*"/Library/Caches/uv/"*|*"/Caches/uv/"*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

has_global_tool(){
  local path
  path="$(tool_path "$1")"
  [ -n "$path" ] || return 1
  ! is_transient_tool_path "$path"
}

CHECK_ONLY=0
ASSUME_YES=0
PROXY_INPUT=""
NO_PROXY_MODE=0
WHISPER_MODEL_INPUT=""
YTDLP_MODULES_REQUESTED=0
WHISPER_MODULES_REQUESTED=0

ORIGINAL_http_proxy="${http_proxy-}"
ORIGINAL_https_proxy="${https_proxy-}"
ORIGINAL_all_proxy="${all_proxy-}"
ORIGINAL_HTTP_PROXY="${HTTP_PROXY-}"
ORIGINAL_HTTPS_PROXY="${HTTPS_PROXY-}"
ORIGINAL_ALL_PROXY="${ALL_PROXY-}"
ORIGINAL_PIP_PROXY="${PIP_PROXY-}"
ORIGINAL_PIP_INDEX_URL="${PIP_INDEX_URL-}"
ORIGINAL_PIP_EXTRA_INDEX_URL="${PIP_EXTRA_INDEX_URL-}"
ORIGINAL_UV_DEFAULT_INDEX="${UV_DEFAULT_INDEX-}"
ORIGINAL_UV_INDEX="${UV_INDEX-}"
ORIGINAL_UV_INDEX_URL="${UV_INDEX_URL-}"
PROXY_ENV_APPLIED=0
PACKAGE_MIRRORS_APPLIED=0
NPM_PROXY_CHANGED=0
ORIGINAL_NPM_PROXY=""
ORIGINAL_NPM_HTTPS_PROXY=""
ORIGINAL_NPM_REGISTRY=""
NPM_REGISTRY_CHANGED=0
GIT_HTTPS_REWRITE_APPLIED=0
ORIGINAL_GIT_INSTEADOF=""
ORIGINAL_GIT_HTTP_PROXY=""
ORIGINAL_GIT_HTTPS_PROXY=""

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
  export all_proxy="$PROXY_URL"
  export HTTP_PROXY="$PROXY_URL"
  export HTTPS_PROXY="$PROXY_URL"
  export ALL_PROXY="$PROXY_URL"
  export PIP_PROXY="$PROXY_URL"
  PROXY_ENV_APPLIED=1
  ok "已启用代理：$PROXY_URL"
}

restore_var(){
  local name="$1" value="$2"
  if [ -n "$value" ]; then
    export "$name=$value"
  else
    unset "$name"
  fi
}

cleanup_proxy(){
  [ "$PROXY_ENV_APPLIED" = "1" ] || [ "$PACKAGE_MIRRORS_APPLIED" = "1" ] || [ "$NPM_PROXY_CHANGED" = "1" ] || [ "$NPM_REGISTRY_CHANGED" = "1" ] || [ "$GIT_HTTPS_REWRITE_APPLIED" = "1" ] || return
  restore_var http_proxy "$ORIGINAL_http_proxy"
  restore_var https_proxy "$ORIGINAL_https_proxy"
  restore_var all_proxy "$ORIGINAL_all_proxy"
  restore_var HTTP_PROXY "$ORIGINAL_HTTP_PROXY"
  restore_var HTTPS_PROXY "$ORIGINAL_HTTPS_PROXY"
  restore_var ALL_PROXY "$ORIGINAL_ALL_PROXY"
  restore_var PIP_PROXY "$ORIGINAL_PIP_PROXY"
  restore_var PIP_INDEX_URL "$ORIGINAL_PIP_INDEX_URL"
  restore_var PIP_EXTRA_INDEX_URL "$ORIGINAL_PIP_EXTRA_INDEX_URL"
  restore_var UV_DEFAULT_INDEX "$ORIGINAL_UV_DEFAULT_INDEX"
  restore_var UV_INDEX "$ORIGINAL_UV_INDEX"
  restore_var UV_INDEX_URL "$ORIGINAL_UV_INDEX_URL"
  if [ "$NPM_PROXY_CHANGED" = "1" ] && has_cmd npm; then
    if [ -n "$ORIGINAL_NPM_PROXY" ]; then npm config set proxy "$ORIGINAL_NPM_PROXY" >/dev/null 2>&1; else npm config delete proxy >/dev/null 2>&1; fi
    if [ -n "$ORIGINAL_NPM_HTTPS_PROXY" ]; then npm config set https-proxy "$ORIGINAL_NPM_HTTPS_PROXY" >/dev/null 2>&1; else npm config delete https-proxy >/dev/null 2>&1; fi
  fi
  if [ "$NPM_REGISTRY_CHANGED" = "1" ] && has_cmd npm; then
    if [ -n "$ORIGINAL_NPM_REGISTRY" ]; then npm config set registry "$ORIGINAL_NPM_REGISTRY" >/dev/null 2>&1; else npm config delete registry >/dev/null 2>&1; fi
  fi
  restore_git_https_rewrite
  ok "已恢复安装前的代理 / 镜像 / npm / Git 配置"
  PROXY_ENV_APPLIED=0
  PACKAGE_MIRRORS_APPLIED=0
  NPM_PROXY_CHANGED=0
  NPM_REGISTRY_CHANGED=0
}

trap cleanup_proxy EXIT

apply_npm_proxy(){
  [ -n "$PROXY_URL" ] || return
  has_cmd npm || return
  if [ "$NPM_PROXY_CHANGED" != "1" ]; then
    ORIGINAL_NPM_PROXY="$(npm config get proxy 2>/dev/null)"
    [ "$ORIGINAL_NPM_PROXY" = "null" ] && ORIGINAL_NPM_PROXY=""
    ORIGINAL_NPM_HTTPS_PROXY="$(npm config get https-proxy 2>/dev/null)"
    [ "$ORIGINAL_NPM_HTTPS_PROXY" = "null" ] && ORIGINAL_NPM_HTTPS_PROXY=""
  fi
  npm config set proxy "$PROXY_URL" >/dev/null 2>&1
  npm config set https-proxy "$PROXY_URL" >/dev/null 2>&1
  npm config set fetch-timeout 600000 >/dev/null 2>&1
  npm config set fetch-retries 5 >/dev/null 2>&1
  NPM_PROXY_CHANGED=1
  ok "已临时设置 npm 代理：$PROXY_URL"
}

apply_package_mirrors(){
  if [ "$PACKAGE_MIRRORS_APPLIED" = "1" ]; then
    if [ -n "$PROXY_URL" ]; then
      has_cmd npm && set_npm_registry_official
    else
      has_cmd npm && apply_npm_registry_mirror
    fi
    return
  fi
  if [ -n "$PROXY_URL" ]; then
    export PIP_INDEX_URL="https://pypi.org/simple"
    unset PIP_EXTRA_INDEX_URL
    export UV_DEFAULT_INDEX="https://pypi.org/simple"
    unset UV_INDEX
    unset UV_INDEX_URL
    PACKAGE_MIRRORS_APPLIED=1
    ok "已临时设置 pip / uv 使用官方源，网络全部走代理"
    has_cmd npm && set_npm_registry_official
    return
  fi
  export PIP_INDEX_URL="https://pypi.tuna.tsinghua.edu.cn/simple"
  export PIP_EXTRA_INDEX_URL="https://mirrors.aliyun.com/pypi/simple https://pypi.org/simple"
  export UV_INDEX="https://pypi.tuna.tsinghua.edu.cn/simple https://mirrors.aliyun.com/pypi/simple"
  export UV_DEFAULT_INDEX="https://pypi.org/simple"
  export UV_INDEX_URL="$PIP_INDEX_URL"
  PACKAGE_MIRRORS_APPLIED=1
  ok "已临时设置 pip / uv 国内镜像，官方源作为兜底"

  has_cmd npm || return
  apply_npm_registry_mirror
}

apply_npm_registry_mirror(){
  [ -n "$PROXY_URL" ] && return
  has_cmd npm || return
  [ "$NPM_REGISTRY_CHANGED" = "1" ] && return
  ORIGINAL_NPM_REGISTRY="$(npm config get registry 2>/dev/null)"
  [ "$ORIGINAL_NPM_REGISTRY" = "undefined" ] && ORIGINAL_NPM_REGISTRY=""
  npm config set registry "https://registry.npmmirror.com" >/dev/null 2>&1
  NPM_REGISTRY_CHANGED=1
  ok "已临时设置 npm registry：https://registry.npmmirror.com"
}

set_npm_registry_official(){
  has_cmd npm || return
  [ "$NPM_REGISTRY_CHANGED" != "1" ] && {
    ORIGINAL_NPM_REGISTRY="$(npm config get registry 2>/dev/null)"
    [ "$ORIGINAL_NPM_REGISTRY" = "undefined" ] && ORIGINAL_NPM_REGISTRY=""
  }
  npm config set registry "https://registry.npmjs.org/" >/dev/null 2>&1
  NPM_REGISTRY_CHANGED=1
  ok "已临时设置 npm registry：https://registry.npmjs.org/"
}

without_proxy_env(){
  env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u PIP_PROXY "$@"
}

npm_install_global(){
  local package_name="$1"
  if [ -n "$PROXY_URL" ]; then
    apply_npm_proxy
    set_npm_registry_official
    say "${DIM}执行：npm install -g $package_name（走代理访问官方 npm registry）${RST}"
    npm install -g "$package_name"
    return
  fi
  apply_npm_registry_mirror
  say "${DIM}执行：npm install -g $package_name（优先 npm 国内镜像）${RST}"
  npm install -g "$package_name" || {
    warn "npm 国内镜像安装失败，切换官方源直连重试：$package_name"
    npm config set registry "https://registry.npmjs.org/" >/dev/null 2>&1
    npm install -g "$package_name"
  }
}

pip_install_user(){
  local py="$1"; shift
  if [ -n "$PROXY_URL" ]; then
    say "${DIM}执行：$py -m pip install --user $*（走代理访问官方 PyPI）${RST}"
    "$py" -m pip install --user --index-url "https://pypi.org/simple" "$@"
    if [ "$?" != "0" ]; then
      warn "官方 PyPI 代理安装失败，切换国内镜像重试"
      "$py" -m pip install --user --index-url "https://pypi.tuna.tsinghua.edu.cn/simple" --extra-index-url "https://mirrors.aliyun.com/pypi/simple" --extra-index-url "https://pypi.org/simple" "$@"
    fi
    return
  fi
  say "${DIM}执行：$py -m pip install --user $*（优先 pip 国内镜像）${RST}"
  if without_proxy_env "$py" -m pip install --user --index-url "$PIP_INDEX_URL" --extra-index-url "https://mirrors.aliyun.com/pypi/simple" --extra-index-url "https://pypi.org/simple" "$@"; then
    return 0
  fi
  warn "pip 国内镜像安装失败，切换官方源直连重试"
  "$py" -m pip install --user --index-url "https://pypi.org/simple" "$@"
}

uv_tool_install(){
  local package_name="$1" command_name="$2"
  has_cmd uv || return 1
  add_path_once "$HOME/.local/bin" "uv tool"
  if [ -n "$PROXY_URL" ]; then
    say "${DIM}执行：uv tool install $package_name（走代理访问官方 PyPI，创建用户级命令入口）${RST}"
    uv tool install "$package_name"
  else
    say "${DIM}执行：uv tool install $package_name（优先 uv / pip 镜像，创建用户级命令入口）${RST}"
    without_proxy_env uv tool install "$package_name" || uv tool install "$package_name"
  fi
  refresh_common_paths
  has_global_tool "$command_name"
}

enable_git_https_rewrite(){
  [ "$GIT_HTTPS_REWRITE_APPLIED" = "1" ] && return
  has_cmd git || return
  ORIGINAL_GIT_INSTEADOF="$(git config --global --get url.https://github.com/.insteadOf 2>/dev/null)"
  ORIGINAL_GIT_HTTP_PROXY="$(git config --global --get http.proxy 2>/dev/null)"
  ORIGINAL_GIT_HTTPS_PROXY="$(git config --global --get https.proxy 2>/dev/null)"
  git config --global url.https://github.com/.insteadOf git@github.com: >/dev/null 2>&1
  if [ -n "$PROXY_URL" ]; then
    git config --global http.proxy "$PROXY_URL" >/dev/null 2>&1
    git config --global https.proxy "$PROXY_URL" >/dev/null 2>&1
  fi
  GIT_HTTPS_REWRITE_APPLIED=1
  ok "已临时设置 Git：SSH 地址改走 HTTPS，HTTPS clone 使用代理"
}

restore_git_https_rewrite(){
  [ "$GIT_HTTPS_REWRITE_APPLIED" = "1" ] || return
  has_cmd git || return
  if [ -n "$ORIGINAL_GIT_INSTEADOF" ]; then
    git config --global url.https://github.com/.insteadOf "$ORIGINAL_GIT_INSTEADOF" >/dev/null 2>&1
  else
    git config --global --unset url.https://github.com/.insteadOf >/dev/null 2>&1
  fi
  if [ -n "$ORIGINAL_GIT_HTTP_PROXY" ]; then
    git config --global http.proxy "$ORIGINAL_GIT_HTTP_PROXY" >/dev/null 2>&1
  else
    git config --global --unset http.proxy >/dev/null 2>&1
  fi
  if [ -n "$ORIGINAL_GIT_HTTPS_PROXY" ]; then
    git config --global https.proxy "$ORIGINAL_GIT_HTTPS_PROXY" >/dev/null 2>&1
  else
    git config --global --unset https.proxy >/dev/null 2>&1
  fi
  GIT_HTTPS_REWRITE_APPLIED=0
  ok "已恢复安装前的 Git 配置"
}

curl_download(){
  local url="$1" out="$2"
  say "${DIM}下载地址：$url${RST}"
  if [ -n "$PROXY_URL" ]; then
    curl -fL --connect-timeout 12 --retry 2 --progress-bar --proxy "$PROXY_URL" "$url" -o "$out"
  else
    curl -fL --connect-timeout 12 --retry 2 --progress-bar "$url" -o "$out"
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
  [ -n "$PROXY_URL" ] && return
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
  say "${YLW}等待确认：$prompt${RST}"
  printf "${CYN}请按回车继续；如果你确认已安装但未检测到，输入 s 跳过；输入 q 退出：${RST}"
  if [ -r /dev/tty ]; then
    IFS= read -r ans </dev/tty 2>/dev/null || ans=""
  else
    ans=""
  fi
  case "$ans" in
    q|Q) graceful_exit ;;
    s|S) return 1 ;;
    *) ok "已确认，开始处理：$prompt"; return 0 ;;
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
  cleanup_proxy
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

show_whisper_cached_models(){
  local roots root found=0 name size
  roots="
${WHISPER_CACHE:-}
${HF_HOME:-}
${HUGGINGFACE_HUB_CACHE:-}
${TRANSFORMERS_CACHE:-}
${XDG_CACHE_HOME:-$HOME/.cache}/whisper
${XDG_CACHE_HOME:-$HOME/.cache}/huggingface/hub
$HOME/.cache/whisper
$HOME/.cache/huggingface/hub
"
  while IFS= read -r root; do
    [ -n "$root" ] && [ -d "$root" ] || continue
    if [ "$(basename "$root")" = "whisper" ]; then
      while IFS= read -r file; do
        [ -n "$file" ] || continue
        name="$(basename "$file")"
        name="${name%.pt}"
        name="${name%%.*}"
        size="$(du -h "$file" 2>/dev/null | awk '{print $1}')"
        [ "$found" = "0" ] && ok "已检测到 Whisper 模型缓存："
        found=1
        say "  - $name：$file${size:+（$size）}"
      done <<EOF
$(find "$root" -maxdepth 1 -type f -name "*.pt" 2>/dev/null | grep -E '/(tiny|base|small|medium|large|turbo)(\..*)?\.pt$' || true)
EOF
    fi
    while IFS= read -r dir; do
      [ -n "$dir" ] || continue
      [ "$found" = "0" ] && ok "已检测到 Whisper 模型缓存："
      found=1
      say "  - $(basename "$dir")：$dir"
    done <<EOF
$(find "$root" -maxdepth 3 -type d 2>/dev/null | grep -Ei 'whisper|faster-whisper|mlx.*whisper' || true)
EOF
  done <<EOF
$roots
EOF
  [ "$found" = "1" ] || warn "未检测到已缓存的 Whisper 模型"
}

clear_whisper_model_cache(){
  local model="$1" roots root file
  roots="
${WHISPER_CACHE:-}
${XDG_CACHE_HOME:-$HOME/.cache}/whisper
$HOME/.cache/whisper
"
  while IFS= read -r root; do
    [ -n "$root" ] && [ -d "$root" ] || continue
    while IFS= read -r file; do
      [ -n "$file" ] || continue
      warn "删除损坏或未完成的模型缓存：$file"
      rm -f "$file" 2>/dev/null
    done <<EOF
$(find "$root" -maxdepth 1 -type f -name "${model}*.pt" 2>/dev/null || true)
EOF
  done <<EOF
$roots
EOF
}

whisper_model_cache_files(){
  local model="$1" roots root
  roots="
${WHISPER_CACHE:-}
${XDG_CACHE_HOME:-$HOME/.cache}/whisper
$HOME/.cache/whisper
"
  while IFS= read -r root; do
    [ -n "$root" ] && [ -d "$root" ] || continue
    find "$root" -maxdepth 1 -type f -name "${model}*.pt" 2>/dev/null
  done <<EOF
$roots
EOF
}

confirm_whisper_model_redownload(){
  local model="$1" files answer file size
  [ "$ASSUME_YES" = "1" ] && { printf '%s\n' "use"; return; }
  files="$(whisper_model_cache_files "$model")"
  [ -z "$files" ] && { printf '%s\n' "download"; return; }
  warn "已存在 $model 模型缓存："
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    size="$(du -h "$file" 2>/dev/null | awk '{print $1}')"
    say "  - $file${size:+（$size）}"
  done <<EOF
$files
EOF
  printf "${CYN}回车=使用现有缓存并校验；r=覆盖重新下载；s=跳过：${RST}"
  IFS= read -r answer </dev/tty 2>/dev/null
  case "$answer" in
    r|R) printf '%s\n' "redownload" ;;
    s|S) printf '%s\n' "skip" ;;
    *) printf '%s\n' "use" ;;
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
  show_whisper_cached_models
  say "选择要预下载的 Whisper 模型："
  say "  1) fast / turbo：约 1.6GB，809M 参数，速度优先，推荐日常使用"
  say "  2) normal / base：约 142MB，74M 参数，常规轻量，适合快速试用"
  say "  3) tiny：约 75MB，39M 参数，最快，准确率较低"
  say "  4) small：约 466MB，244M 参数，准确率更好，资源占用适中"
  say "  5) medium：约 1.5GB，769M 参数，准确率较高，下载和运行都更重"
  say "  6) large：约 2.9GB，1.55B 参数，准确率最高，下载最大，运行最重"
  say "  7) skip：跳过预下载，首次使用 Whisper 时再下载"
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
  say "${DIM}首次加载会下载模型文件，Whisper 会显示缓存和下载进度。${RST}"
  local py attempt cache_choice
  py="$(main_python_cmd)"
  [ -n "$py" ] || { warn "Python 3 不可用，跳过 Whisper 模型预下载"; return; }
  cache_choice="$(confirm_whisper_model_redownload "$model")"
  [ "$cache_choice" = "skip" ] && { warn "已跳过 Whisper 模型：$model"; return; }
  [ "$cache_choice" = "redownload" ] && clear_whisper_model_cache "$model"
  for attempt in 1 2 3; do
    say "${DIM}Whisper 模型下载尝试 $attempt/3：$model${RST}"
    "$py" - <<PY
import whisper
whisper.load_model("$model")
print("Whisper model ready: $model")
PY
    if [ "$?" = "0" ]; then
      ok "Whisper 模型已就绪：$model"
      return
    fi
    warn "Whisper 模型下载或校验失败：$model"
    if [ "$attempt" != "3" ]; then
      clear_whisper_model_cache "$model"
      warn "准备重试下载 Whisper 模型：$model"
    fi
  done
  err "Whisper 模型下载失败，已重试 3 次：$model"
}

add_path_once(){
  local dir="$1" marker="$2" rc line changed=0
  [ -d "$dir" ] || return
  dir="$(cd "$dir" 2>/dev/null && pwd -P)"
  case ":$PATH:" in *":$dir:"*) ;; *) export PATH="$dir:$PATH" ;; esac
  [ "$CHECK_ONLY" = "1" ] && return
  line="export PATH=\"$dir:\$PATH\" # Agent 航海环境部署工具：$marker"
  for rc in "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.bash_profile" "$HOME/.bashrc"; do
    [ -e "$rc" ] || touch "$rc" 2>/dev/null
    if ! grep -qF "$dir" "$rc" 2>/dev/null; then
      printf '\n%s\n' "$line" >> "$rc"
      changed=1
    fi
  done
  [ "$changed" = "1" ] && ok "已写入 PATH：$dir"
}

refresh_common_paths(){
  [ -d "/opt/homebrew/bin" ] && add_path_once "/opt/homebrew/bin" "Homebrew"
  [ -d "/usr/local/bin" ] && add_path_once "/usr/local/bin" "Homebrew"
  [ -d "/opt/homebrew/opt/python@3.11/bin" ] && add_path_once "/opt/homebrew/opt/python@3.11/bin" "Python 3"
  [ -d "/usr/local/opt/python@3.11/bin" ] && add_path_once "/usr/local/opt/python@3.11/bin" "Python 3"
  [ -d "$HOME/.local/bin" ] && add_path_once "$HOME/.local/bin" "用户命令"
  [ -d "$HOME/.hermes/bin" ] && add_path_once "$HOME/.hermes/bin" "Hermes"
  ensure_nvm_shell_init
  if has_cmd python3; then
    local python_user_bin
    python_user_bin="$(python3 -m site --user-base 2>/dev/null)/bin"
    [ -d "$python_user_bin" ] && add_path_once "$python_user_bin" "Python 用户命令"
  fi
  if has_cmd npm; then
    local npm_prefix npm_bin
    npm_prefix="$(npm prefix -g 2>/dev/null || npm config get prefix 2>/dev/null)"
    case "$npm_prefix" in
      "$HOME/.nvm"/*) return ;;
    esac
    npm_bin="$npm_prefix/bin"
    [ -d "$npm_bin" ] && add_path_once "$npm_bin" "npm 全局命令"
  fi
}

ensure_nvm_shell_init(){
  local nvm_dir rc changed=0
  [ "$CHECK_ONLY" = "1" ] && return
  nvm_dir="${NVM_DIR:-$HOME/.nvm}"
  [ -s "$nvm_dir/nvm.sh" ] || return
  for rc in "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.bash_profile" "$HOME/.bashrc"; do
    [ -e "$rc" ] || touch "$rc" 2>/dev/null
    if ! grep -q 'Agent 航海环境部署工具：nvm' "$rc" 2>/dev/null; then
      {
        printf '\nexport NVM_DIR="%s" # Agent 航海环境部署工具：nvm\n' "$nvm_dir"
        printf '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" # Agent 航海环境部署工具：nvm\n'
      } >> "$rc"
      changed=1
    fi
  done
  [ "${changed:-0}" = "1" ] && ok "已写入 nvm 初始化"
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
  refresh_common_paths
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
    say "${DIM}执行：nvm install --lts${RST}"
    nvm install --lts
    nvm use --lts
  elif has_cmd brew; then
    say "${DIM}执行：brew install node${RST}"
    brew install node
  else
    warn "未检测到 Homebrew，将通过 nvm 安装 Node.js"
    local tmp_script="$TMPDIR/nvm-install.sh"
    if download_with_fallback "https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh" "$tmp_script"; then
      PROFILE="$HOME/.zshrc" bash "$tmp_script"
      export NVM_DIR="$HOME/.nvm"
      [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
      say "${DIM}执行：nvm install --lts${RST}"
      nvm install --lts
      nvm use --lts
    fi
  fi
  refresh_common_paths
  apply_package_mirrors
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
  if python3_cmd >/dev/null 2>&1; then
    ok "Python 3 已安装：$($(python3_cmd) --version 2>/dev/null)"
    return 0
  fi
  if [ "$CHECK_ONLY" = "1" ]; then
    warn "Python 3 未安装"
    return 1
  fi
  warn "未检测到可用的全局 Python 3。"
  confirm "安装 Python 3（yt-dlp / Whisper 需要）" || return 1
  if has_cmd brew; then
    say "${DIM}执行：brew install python${RST}"
    brew install python
  else
    warn "未检测到 Homebrew，无法自动安装 Python；请稍后手动安装或先安装 Homebrew"
    return 1
  fi
  refresh_common_paths
}

python3_cmd(){
  local candidate major
  for candidate in python3 python python3.14 python3.13 python3.12 python3.11 \
    "/opt/homebrew/bin/python3" \
    "/usr/local/bin/python3" \
    "/opt/homebrew/opt/python@3.14/bin/python3.14" \
    "/usr/local/opt/python@3.14/bin/python3.14" \
    "/opt/homebrew/opt/python@3.13/bin/python3.13" \
    "/usr/local/opt/python@3.13/bin/python3.13" \
    "/opt/homebrew/opt/python@3.12/bin/python3.12" \
    "/usr/local/opt/python@3.12/bin/python3.12" \
    "/opt/homebrew/opt/python@3.11/bin/python3.11" \
    "/usr/local/opt/python@3.11/bin/python3.11"
  do
    if [ -x "$candidate" ] || command -v "$candidate" >/dev/null 2>&1; then
      major="$("$candidate" - <<'PY' 2>/dev/null
import sys
print(sys.version_info.major)
PY
)"
      if [ "$major" = "3" ] && ! python_is_venv "$candidate" && ! python_is_transient_runtime "$candidate"; then
        printf '%s\n' "$candidate"
        return 0
      fi
    fi
  done
  return 1
}

python311_cmd(){
  if has_cmd python3.11; then
    printf '%s\n' "python3.11"
    return 0
  fi
  if [ -x "/opt/homebrew/opt/python@3.11/bin/python3.11" ]; then
    printf '%s\n' "/opt/homebrew/opt/python@3.11/bin/python3.11"
    return 0
  fi
  if [ -x "/usr/local/opt/python@3.11/bin/python3.11" ]; then
    printf '%s\n' "/usr/local/opt/python@3.11/bin/python3.11"
    return 0
  fi
  return 1
}

python_version_key(){
  "$1" - <<'PY' 2>/dev/null
import sys
print(f"{sys.version_info.major}.{sys.version_info.minor}:{sys.executable}")
PY
}

python_has_pip(){
  "$1" -m pip --version >/dev/null 2>&1
}

python_is_venv(){
  [ "$("$1" - <<'PY' 2>/dev/null
import sys
print(sys.prefix != sys.base_prefix)
PY
)" = "True" ]
}

python_is_transient_runtime(){
  local exe
  exe="$("$1" - <<'PY' 2>/dev/null
import sys
print(sys.executable)
PY
)"
  is_transient_tool_path "$exe"
}

python_is_externally_managed(){
  [ "$("$1" - <<'PY' 2>/dev/null
import pathlib, sysconfig
print(pathlib.Path(sysconfig.get_path("stdlib"), "EXTERNALLY-MANAGED").exists())
PY
)" = "True" ]
}

list_python_targets(){
  local candidate key seen=""
  for candidate in \
    "$(python3_cmd 2>/dev/null)" \
    "python3" \
    "python" \
    "python3.11"
  do
    [ -n "$candidate" ] || continue
    if [ -x "$candidate" ] || command -v "$candidate" >/dev/null 2>&1; then
      if ! python_has_pip "$candidate"; then
        warn "跳过 Python（未安装 pip）：$candidate"
        continue
      fi
      if python_is_venv "$candidate"; then
        warn "跳过 Python venv 环境：$candidate"
        continue
      fi
      if python_is_transient_runtime "$candidate"; then
        warn "跳过 Hermes / uv cache 托管 Python：$candidate"
        continue
      fi
      if python_is_externally_managed "$candidate"; then
        warn "跳过 uv/系统托管 Python（externally managed）：$candidate"
        continue
      fi
      key="$(python_version_key "$candidate")"
      [ -n "$key" ] || continue
      case "|$seen|" in *"|$key|"*) continue ;; esac
      seen="${seen}|$key"
      printf '%s\n' "$candidate"
    fi
  done
}

main_python_cmd(){
  if python3_cmd >/dev/null 2>&1; then
    python3_cmd
  elif has_cmd python3; then
    printf '%s\n' "python3"
  elif has_cmd python; then
    printf '%s\n' "python"
  fi
}

install_python_module_all(){
  local package_name="$1" label="$2" py main_py python_user_bin installed=0
  main_py="$(main_python_cmd)"
  while IFS= read -r py; do
    [ -n "$py" ] || continue
    say "${DIM}为 Python 安装 $label 模块：$py${RST}"
    if pip_install_user "$py" --upgrade "$package_name"; then
      installed=1
    fi
  done <<EOF
$(list_python_targets)
EOF
  if [ -n "$main_py" ]; then
    python_user_bin="$("$main_py" -m site --user-base 2>/dev/null)/bin"
    add_path_once "$python_user_bin" "Python 用户命令"
  fi
  return "$installed"
}

install_ytdlp_modules(){
  install_python_module_all "yt-dlp" "yt-dlp"
  if ! has_global_tool yt-dlp; then
    warn "pip 安装后仍未检测到全局 yt-dlp 命令，改用 uv tool install 兜底"
    uv_tool_install "yt-dlp" "yt-dlp"
  fi
}

install_whisper_modules(){
  install_python_module_all "openai-whisper" "Whisper"
  if ! has_global_tool whisper; then
    warn "pip 安装后仍未检测到全局 whisper 命令，改用 uv tool install 兜底"
    uv_tool_install "openai-whisper" "whisper"
  fi
}

ensure_ffmpeg(){
  has_cmd ffmpeg && { ok "ffmpeg 已安装"; return 0; }
  [ "$CHECK_ONLY" = "1" ] && { warn "ffmpeg 未安装"; return 1; }
  confirm "安装 ffmpeg（Whisper 处理音频需要）" || return 1
  if has_cmd brew; then
    say "${DIM}执行：brew install ffmpeg${RST}"
    brew install ffmpeg
  else
    warn "未检测到 Homebrew，无法自动安装 ffmpeg；请稍后手动安装或先安装 Homebrew"
    return 1
  fi
  refresh_common_paths
}

ensure_ytdlp(){
  if has_global_tool yt-dlp; then
    ok "yt-dlp 命令已安装：$(yt-dlp --version 2>/dev/null | head -1)"
  elif has_cmd yt-dlp; then
    warn "检测到 yt-dlp 位于临时 / Hermes / uv cache 路径，仍会安装全局入口：$(tool_path yt-dlp)"
  elif [ "$CHECK_ONLY" = "1" ]; then
    warn "yt-dlp 未安装"
    return 1
  fi
  [ "$CHECK_ONLY" = "1" ] && return 0
  confirm "为可用 Python 安装 / 更新 yt-dlp 模块（保留主 Python 命令入口）" || return 1
  YTDLP_MODULES_REQUESTED=1
  ensure_python || return 1
  install_ytdlp_modules
  refresh_common_paths
  has_global_tool yt-dlp && ok "yt-dlp 安装完成：$(yt-dlp --version 2>/dev/null | head -1)"
}

install_hermes(){
  step "Hermes Agent"
  has_cmd hermes && { ok "Hermes 已安装：$(hermes --version 2>/dev/null | head -1)"; return; }
  [ "$CHECK_ONLY" = "1" ] && { warn "Hermes 未安装"; return; }
  confirm "安装 Hermes Agent" || return
  say "${DIM}提示：Hermes 后续可能会安装自己的 npm/browser tools 依赖，这是项目依赖，不是重新安装 Node.js。${RST}"
  apply_npm_proxy
  curl_download "https://hermes-agent.nousresearch.com/install.sh" "$TMPDIR/hermes-install.sh" &&
    enable_git_https_rewrite &&
    bash "$TMPDIR/hermes-install.sh"
  add_path_once "$HOME/.local/bin" "Hermes"
  add_path_once "$HOME/.hermes/bin" "Hermes"
  refresh_common_paths
  if [ "$YTDLP_MODULES_REQUESTED" = "1" ]; then
    say "${DIM}Hermes 安装后同步 yt-dlp 到新检测到的 Python 环境${RST}"
    install_ytdlp_modules
    refresh_common_paths
  fi
  if [ "$WHISPER_MODULES_REQUESTED" = "1" ]; then
    say "${DIM}Hermes 安装后同步 Whisper 到新检测到的 Python 环境${RST}"
    install_whisper_modules
    refresh_common_paths
  fi
}

configure_hermes_agent(){
  step "Hermes Agent 配置"
  has_cmd hermes || { warn "Hermes 未安装，跳过配置"; return; }
  [ "$CHECK_ONLY" = "1" ] && return
  if [ "$ASSUME_YES" = "1" ]; then
    warn "自动模式下跳过 Hermes 交互配置；可稍后手动运行 hermes model 和 hermes gateway setup"
    return
  fi
  say "可在这里配置 Hermes 的接口模型和消息通道。"
  say "下面会进入 Hermes 自带英文向导，先看中文速查说明即可。"
  if confirm "配置 Hermes 接口模型"; then
    show_hermes_model_guide
    hermes model
  fi
  if confirm "配置 Hermes 飞书 / Lark 通道"; then
    show_hermes_gateway_guide
    hermes gateway setup
  fi
}

show_hermes_model_guide(){
  step "Hermes 接口模型配置说明"
  say "即将运行：hermes model"
  say "常见英文提示对照："
  say "  Select provider：选择模型服务商。"
  say "  OpenAI ▸ / OpenAI Codex：如果你已经登录 Codex CLI，推荐选这个。"
  say "  Import these credentials?：是否导入现有 Codex 登录凭证；一般输入 y。"
  say "  Select default model：选择默认模型；不知道选哪个可用默认项，或选择 gpt-5.5。"
  say "  Leave unchanged / Skip：保持当前配置不变。"
  say "提示：如果你用 OpenRouter / Anthropic / OpenAI API，需要提前准备对应 API Key。"
}

show_hermes_gateway_guide(){
  step "Hermes 飞书 / Lark 通道配置说明"
  say "即将运行：hermes gateway setup"
  say "常见英文提示对照："
  say "  Select a platform to configure：选择要配置的平台，选择 Feishu / Lark。"
  say "  Scan QR code...：扫码自动创建机器人，推荐选默认项。"
  say "  Enter existing App ID...：已有飞书应用时，手动输入 App ID 和 App Secret。"
  say "  Open this URL in Feishu / Lark on your phone：用手机飞书打开链接并授权。"
  say "  How should direct messages be authorized：私聊权限；新手可选 DM pairing approval，更开放可选 Allow all direct messages。"
  say "  How should group chats be handled：群聊响应方式；推荐 Respond only when @mentioned。"
  say "  Home chat ID：通知/定时任务默认发送到哪个会话；不确定可直接回车留空。"
  say "  Done：配置完 Feishu / Lark 后选择 Done 退出平台选择。"
}

install_codex_cli(){
  step "Codex CLI"
  has_cmd codex && { ok "Codex CLI 已安装：$(codex --version 2>/dev/null | head -1)"; return; }
  [ "$CHECK_ONLY" = "1" ] && { warn "Codex CLI 未安装"; return; }
  confirm "安装 Codex CLI" || return
  curl_download "https://chatgpt.com/codex/install.sh" "$TMPDIR/codex-install.sh" &&
    CODEX_INSTALLER_USE_RELEASES_OPENAI_COM=false sh "$TMPDIR/codex-install.sh"
  add_path_once "$HOME/.local/bin" "Codex CLI"
  refresh_common_paths
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
  apply_package_mirrors
}

install_lark_cli(){
  step "飞书 / Lark CLI"
  has_cmd lark-cli && { ok "lark-cli 已安装：$(lark-cli --version 2>/dev/null | head -1)"; return; }
  [ "$CHECK_ONLY" = "1" ] && { warn "lark-cli 未安装"; return; }
  ensure_node
  has_cmd npm || { err "npm 不可用，无法安装飞书 CLI"; return; }
  confirm "安装飞书 / Lark CLI" || return
  ensure_npm_user_prefix
  npm_install_global "@larksuite/cli"
  local npm_bin
  npm_bin="$(npm prefix -g 2>/dev/null)/bin"
  add_path_once "$npm_bin" "npm 全局命令"
  refresh_common_paths
  has_cmd lark-cli && lark-cli update >/dev/null 2>&1
}

install_python(){
  step "Python 3"
  ensure_python
}

install_whisper(){
  step "Whisper"
  local whisper_installed=0
  if has_global_tool whisper || { python3_cmd >/dev/null 2>&1 && "$(python3_cmd)" -m whisper --help >/dev/null 2>&1; }; then
    ok "Whisper 已安装"
    whisper_installed=1
  elif has_cmd whisper; then
    warn "检测到 whisper 位于临时 / Hermes / uv cache 路径，仍会安装全局入口：$(tool_path whisper)"
  fi
  [ "$CHECK_ONLY" = "1" ] && [ "$whisper_installed" = "0" ] && { warn "Whisper 未安装"; return; }
  [ "$CHECK_ONLY" = "1" ] && return
  ensure_python || return
  ensure_ffmpeg
  if [ "$whisper_installed" = "0" ]; then
    confirm "为可用 Python 安装 / 更新 Whisper 模块（保留主 Python 命令入口）" || return
    WHISPER_MODULES_REQUESTED=1
    install_python_module_all "pip" "pip"
    install_whisper_modules
  fi
  refresh_common_paths
  choose_whisper_model
  download_whisper_model "$WHISPER_MODEL"
}

check_all(){
  step "环境检测"
  say "系统：$(sw_vers -productVersion 2>/dev/null) / $(uname -m)"
  has_cmd brew && ok "Homebrew：$(brew --version 2>/dev/null | head -1)" || warn "Homebrew：未安装"
  xcode-select -p >/dev/null 2>&1 && ok "Xcode Command Line Tools：已安装" || warn "Xcode Command Line Tools：未安装"
  if has_cmd node; then
    ok "Node.js：$(node -v 2>/dev/null)"
  else
    load_nvm_if_present
    has_cmd nvm && ok "nvm：已检测到" || warn "nvm：未检测到"
    has_cmd node && ok "Node.js：$(node -v 2>/dev/null)" || warn "Node.js：未安装"
  fi
  python3_cmd >/dev/null 2>&1 && ok "Python 3：$($(python3_cmd) --version 2>/dev/null)" || warn "Python 3：未安装"
  has_cmd hermes && ok "Hermes：$(hermes --version 2>/dev/null | head -1)" || warn "Hermes：未安装"
  has_cmd codex && ok "Codex CLI：$(codex --version 2>/dev/null | head -1)" || warn "Codex CLI：未安装"
  detect_codex_desktop >/dev/null 2>&1 && ok "ChatGPT / Codex Desktop：$(detect_codex_desktop)" || warn "ChatGPT / Codex Desktop：未检测到"
  has_cmd lark-cli && ok "lark-cli：$(lark-cli --version 2>/dev/null | head -1)" || warn "lark-cli：未安装"
  has_cmd ffmpeg && ok "ffmpeg：已安装" || warn "ffmpeg：未安装"
  has_global_tool yt-dlp && ok "yt-dlp：$(yt-dlp --version 2>/dev/null | head -1)" || warn "yt-dlp：未安装全局入口"
  has_global_tool whisper || { python3_cmd >/dev/null 2>&1 && "$(python3_cmd)" -m whisper --help >/dev/null 2>&1; } && ok "Whisper：已安装" || warn "Whisper：未安装全局入口"
}

main(){
  intro_animation
  hr
  say "${BOLD}Agent 航海环境部署工具 (macOS)${RST}"
  hr
  choose_proxy
  apply_proxy_env
  refresh_common_paths
  check_all
  [ "$CHECK_ONLY" = "1" ] && graceful_exit
  apply_package_mirrors
  enable_git_https_rewrite
  install_xcode_tools
  install_homebrew
  install_node
  install_python
  ensure_ffmpeg
  ensure_ytdlp
  install_hermes
  install_codex_cli
  install_codex_desktop
  install_lark_cli
  configure_hermes_agent
  install_whisper
  check_all
  hr
  ok "处理完成。新开一个终端后，PATH 配置会完整生效。"
  cleanup_proxy
  keep_terminal_open
}

main "$@"
