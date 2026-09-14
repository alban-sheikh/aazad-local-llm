#!/usr/bin/env bash
# Aazad Chat installer for Linux and macOS
#
#   curl -fsSL https://raw.githubusercontent.com/alban-sheikh/aazad-local-llm/main/install.sh | bash
#
# Detects your hardware, asks about the AI engine (Ollama), models, storage and
# app settings, shows a summary, and changes nothing until you confirm.
# Run it again any time to update Aazad Chat or change settings.
#
# Pass options through the pipe with "bash -s --", for example:
#   curl -fsSL .../install.sh | bash -s -- --dry-run
#
# Works with the bash 3.2 that ships with macOS: no bash 4 features on purpose.

set -euo pipefail

REPO="alban-sheikh/aazad-local-llm"
BRANCH="main"
OLLAMA_URL="http://127.0.0.1:11434"
SERVICE="${AAZAD_SERVICE_NAME:-aazad-chat}" # advanced: lets a test install sit beside a real one

# name|good for|capabilities|download size (GB, from the Ollama registry)
CATALOG=(
  "gemma3:1b|General chat (tiny)|chat|0.8"
  "llama3.2:1b|General chat (tiny)|chat|1.3"
  "qwen3:1.7b|Reasoning (tiny)|chat, thinking|1.4"
  "qwen2.5-coder:3b|Coding (small)|code|1.9"
  "llama3.2:3b|General chat, fast|chat, tools|2.0"
  "qwen3:4b|Reasoning (small)|chat, thinking|2.5"
  "phi4-mini|General chat|chat, tools|2.5"
  "gemma3:4b|Chat + images|chat, vision|3.3"
  "qwen2.5-coder:7b|Coding|code|4.7"
  "llama3.1:8b|General chat|chat, tools|4.9"
  "qwen3:8b|Reasoning|chat, thinking|5.2"
  "deepseek-r1:8b|Step-by-step reasoning|thinking|5.2"
  "gemma3:12b|Chat + images|chat, vision|8.2"
  "qwen2.5-coder:14b|Coding|code|9.0"
  "deepseek-r1:14b|Step-by-step reasoning|thinking|9.0"
  "phi4:14b|General chat, reasoning|chat|9.1"
  "qwen3:14b|Reasoning|chat, thinking|9.3"
  "gemma3:27b|Chat + images|chat, vision|17.4"
  "qwen3:30b|Reasoning, fast (MoE)|chat, thinking|18.6"
  "qwen2.5-coder:32b|Coding|code|19.9"
  "deepseek-r1:32b|Step-by-step reasoning|thinking|19.9"
  "qwen3:32b|Reasoning|chat, thinking|20.2"
  "llama3.3:70b|General chat|chat, tools|42.5"
  "deepseek-r1:70b|Step-by-step reasoning|thinking|42.5"
  "qwen2.5:72b|General chat|chat, tools|47.4"
  "nomic-embed-text|Search / RAG (embeddings)|embedding|0.3"
)

# ---------------------------------------------------------------- options
YES=0
DRY_RUN=0
UNINSTALL=0
OPT_OLLAMA=""
OPT_MODELS=""
OPT_MODELS_DIR=""
OPT_KEEP_ALIVE=""
OPT_CONTEXT=""
OPT_APP_DIR=""
OPT_DATA_DIR=""
OPT_PORT=""
OPT_AUTOSTART=""
OPT_SHORTCUT=""
OPT_OPEN=""

usage() {
  cat <<'EOF'
Aazad Chat installer (Linux and macOS)

Usage: install.sh [options]

  -y, --yes               Accept the default for every question
      --dry-run           Ask everything and show what would change, but change nothing
      --uninstall         Remove Aazad Chat (asks before deleting chats; never removes Ollama or models)
  -h, --help              Show this help

Answer questions ahead of time (each skips its prompt):
      --ollama=MODE       keep | system | user | brew | app | skip
      --models=LIST       r (recommended) | n (none) | numbers or names, e.g. "gemma3:4b qwen2.5-coder:7b"
      --models-dir=PATH   Where Ollama stores models
      --keep-alive=TIME   5m | 30m | 1h | -1 (always loaded)
      --context=SIZE      auto | 4096 | 8192 | 16384 | 32768
      --app-dir=PATH      Where Aazad Chat is installed
      --data-dir=PATH     Where chats are saved
      --port=PORT         Web app port (default 3210)
      --autostart=yes|no  Start Aazad Chat when you log in
      --shortcut=yes|no   Add an app menu shortcut
      --open=yes|no       Open the browser when done

Example: curl -fsSL https://raw.githubusercontent.com/alban-sheikh/aazad-local-llm/main/install.sh | bash -s -- --dry-run
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -y | --yes) YES=1 ;;
      --dry-run) DRY_RUN=1 ;;
      --uninstall) UNINSTALL=1 ;;
      --ollama=*) OPT_OLLAMA="${1#*=}" ;;
      --models=*) OPT_MODELS="${1#*=}" ;;
      --models-dir=*) OPT_MODELS_DIR="${1#*=}" ;;
      --keep-alive=*) OPT_KEEP_ALIVE="${1#*=}" ;;
      --context=*) OPT_CONTEXT="${1#*=}" ;;
      --app-dir=*) OPT_APP_DIR="${1#*=}" ;;
      --data-dir=*) OPT_DATA_DIR="${1#*=}" ;;
      --port=*) OPT_PORT="${1#*=}" ;;
      --autostart=*) OPT_AUTOSTART="${1#*=}" ;;
      --shortcut=*) OPT_SHORTCUT="${1#*=}" ;;
      --open=*) OPT_OPEN="${1#*=}" ;;
      -h | --help) usage; exit 0 ;;
      *) die "Unknown option: $1 (see --help)" ;;
    esac
    shift
  done
}

# ---------------------------------------------------------------- output & prompts
BOLD="" DIM="" RED="" GREEN="" YELLOW="" BLUE="" RESET=""
TTY=""

setup_ui() {
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    BOLD=$'\033[1m' DIM=$'\033[2m' RED=$'\033[31m' GREEN=$'\033[32m' YELLOW=$'\033[33m' BLUE=$'\033[34m' RESET=$'\033[0m'
  fi
  if [ "$YES" = 0 ]; then
    if { : </dev/tty; } 2>/dev/null; then
      TTY=/dev/tty
    else
      die "No terminal available for questions. Re-run with --yes to accept the defaults (see --help)."
    fi
  fi
}

say() { printf '%s\n' "$*"; }
info() { printf '%s\n' "${BLUE}›${RESET} $*"; }
ok() { printf '%s\n' "${GREEN}✓${RESET} $*"; }
warn() { printf '%s\n' "${YELLOW}!${RESET} $*" >&2; }
die() { printf '%s\n' "${RED}✗ $*${RESET}" >&2; exit 1; }
section() { printf '\n%s\n' "${BOLD}$*${RESET}"; }

# ask VAR "Question" "default"
ask() {
  local _var=$1 _prompt=$2 _def=$3 _reply=""
  if [ "$YES" = 1 ]; then
    printf -v "$_var" '%s' "$_def"
    return 0
  fi
  read -r -p "$_prompt [$_def]: " _reply <"$TTY" || true
  printf -v "$_var" '%s' "${_reply:-$_def}"
}

# confirm "Question" Y|N  -> exit status 0 for yes
confirm() {
  local _def=$2 _reply="" _hint="y/N"
  [ "$_def" = Y ] && _hint="Y/n"
  if [ "$YES" = 1 ]; then
    [ "$_def" = Y ]
    return
  fi
  while true; do
    read -r -p "$1 [$_hint]: " _reply <"$TTY" || true
    case "${_reply:-$_def}" in
      [Yy]*) return 0 ;;
      [Nn]*) return 1 ;;
    esac
  done
}

# choose VAR "Question" DEFAULT_NUMBER "option 1" "option 2" ...  -> stores the chosen number
choose() {
  local _var=$1 _prompt=$2 _def=$3 _i=1 _o _reply=""
  shift 3
  if [ "$YES" = 1 ]; then
    printf -v "$_var" '%s' "$_def"
    return 0
  fi
  say "$_prompt"
  for _o in "$@"; do
    printf '  %s%d)%s %s\n' "$BOLD" "$_i" "$RESET" "$_o"
    _i=$((_i + 1))
  done
  while true; do
    read -r -p "Choose 1-$# [$_def]: " _reply <"$TTY" || true
    _reply=${_reply:-$_def}
    case "$_reply" in
      '' | *[!0-9]*) ;;
      *)
        if [ "$_reply" -ge 1 ] && [ "$_reply" -le $# ]; then
          printf -v "$_var" '%s' "$_reply"
          return 0
        fi
        ;;
    esac
    warn "Please type a number from 1 to $#."
  done
}

yesno_opt() { # yesno_opt "$OPT_VALUE" "Question" Y|N -> echo yes|no
  case "$1" in
    yes | y | true | 1) echo yes ;;
    no | n | false | 0) echo no ;;
    *) if confirm "$2" "$3"; then echo yes; else echo no; fi ;;
  esac
}

# ---------------------------------------------------------------- small utilities
calc() { awk "BEGIN { printf \"%.1f\", $* }"; }
fge() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a >= b) }'; }
fgt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'; }
field() { printf '%s' "$1" | cut -d'|' -f"$2"; }
have() { command -v "$1" >/dev/null 2>&1; }

expand_path() {
  local p=$1
  case "$p" in
    \~) p=$HOME ;;
    \~/*) p="$HOME/${p#\~/}" ;;
  esac
  case "$p" in
    /*) ;;
    *) p="$PWD/$p" ;;
  esac
  printf '%s' "${p%/}"
}

nearest_existing_dir() {
  local d=$1
  while [ ! -d "$d" ]; do d=$(dirname "$d"); done
  printf '%s' "$d"
}

free_gb() { df -Pk "$(nearest_existing_dir "$1")" | awk 'NR == 2 { printf "%.1f", $4 / 1048576 }'; }

resolved() { # show where a directory really points (follows symlinks)
  if [ -d "$1" ]; then (cd -P "$1" 2>/dev/null && pwd) || printf '%s' "$1"; else printf '%s' "$1"; fi
}

xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

port_in_use() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

wait_http() {
  local _i
  for ((_i = 0; _i < $2 * 2; _i++)); do
    if curl -fsS -m 2 -o /dev/null "$1" 2>/dev/null; then return 0; fi
    sleep 0.5
  done
  return 1
}

run() { # run a command, or just show it in --dry-run
  if [ "$DRY_RUN" = 1 ]; then
    printf '  %s[dry-run]%s %s\n' "$DIM" "$RESET" "$*"
  else
    "$@"
  fi
}

write_file() { # write_file PATH [sudo]   (content on stdin)
  local _path=$1 _sudo=${2:-}
  if [ "$DRY_RUN" = 1 ]; then
    printf '  %s[dry-run] write %s%s\n' "$DIM" "$_path" "$RESET"
    sed "s/^/      ${DIM}/; s/\$/${RESET}/"
    return 0
  fi
  if [ "$_sudo" = sudo ]; then
    sudo mkdir -p "$(dirname "$_path")"
    sudo tee "$_path" >/dev/null
  else
    mkdir -p "$(dirname "$_path")"
    cat >"$_path"
  fi
}

systemd_user_ok() { [ "$PLATFORM" = linux ] && have systemctl && systemctl --user show-environment >/dev/null 2>&1; }

# ---------------------------------------------------------------- detection
detect_system() {
  case "$(uname -s)" in
    Linux) PLATFORM=linux ;;
    Darwin) PLATFORM=macos ;;
    *) die "This installer is for Linux and macOS. On Windows, use install.ps1 (see the README)." ;;
  esac
  case "$(uname -m)" in
    x86_64 | amd64) ARCH=amd64 ;;
    arm64 | aarch64) ARCH=arm64 ;;
    *) ARCH=$(uname -m) ;;
  esac

  for tool in curl tar; do have "$tool" || die "'$tool' is required. Please install it and run the installer again."; done

  RAM_GB=0 GPU_NAME="none (CPU only)" GPU_GB=0 GPU_KIND=none
  if [ "$PLATFORM" = linux ]; then
    RAM_GB=$(awk '/^MemTotal:/ { printf "%.1f", $2 / 1048576 }' /proc/meminfo)
    if have nvidia-smi && nvidia-smi -L >/dev/null 2>&1; then
      local line
      line=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits | sort -t, -k2 -nr | head -1)
      GPU_NAME=$(printf '%s' "${line%,*}" | xargs)
      GPU_GB=$(calc "${line##*,} / 1024")
      GPU_KIND=nvidia
    else
      local f bytes best=0
      for f in /sys/class/drm/card*/device/mem_info_vram_total; do
        [ -r "$f" ] || continue
        bytes=$(cat "$f")
        if [ "$bytes" -gt "$best" ]; then best=$bytes; fi
      done
      if [ "$best" -gt 2147483648 ]; then
        GPU_GB=$(calc "$best / 1073741824")
        GPU_NAME="AMD Radeon"
        GPU_KIND=amd
      fi
    fi
  else
    RAM_GB=$(calc "$(sysctl -n hw.memsize) / 1073741824")
    if [ "$ARCH" = arm64 ]; then
      GPU_KIND=apple
      GPU_NAME="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'Apple Silicon') (shared memory)"
      if fgt "$RAM_GB" 36; then GPU_GB=$(calc "$RAM_GB * 0.75"); else GPU_GB=$(calc "$RAM_GB * 0.67"); fi
    fi
  fi

  if [ "$PLATFORM" = linux ]; then
    DEF_APP_DIR="$HOME/.local/opt/$SERVICE"
    DEF_DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/$SERVICE"
  else
    DEF_APP_DIR="$HOME/Library/Application Support/AazadChat/app"
    DEF_DATA_DIR="$HOME/Library/Application Support/AazadChat"
  fi
}

systemd_env_value() { # systemd_env_value --user|--system VAR
  local scope=$1 var=$2
  if [ "$scope" = --system ]; then scope=""; fi
  # shellcheck disable=SC2086
  systemctl $scope show ollama -p Environment --value 2>/dev/null | tr ' ' '\n' | sed -n "s/^$var=//p" | tail -1
}

detect_existing() {
  OLLAMA_BIN=$(command -v ollama || true)
  if [ -z "$OLLAMA_BIN" ] && [ -x "$HOME/.local/bin/ollama" ]; then OLLAMA_BIN="$HOME/.local/bin/ollama"; fi
  OLLAMA_RUNNING=0
  OLLAMA_VERSION=""
  local v
  if v=$(curl -fsS -m 3 "$OLLAMA_URL/api/version" 2>/dev/null); then
    OLLAMA_RUNNING=1
    OLLAMA_VERSION=$(printf '%s' "$v" | sed -E 's/.*"version":"([^"]*)".*/\1/')
  fi

  OLLAMA_MANAGER=none
  if [ "$PLATFORM" = linux ] && have systemctl; then
    if systemctl --user cat ollama.service >/dev/null 2>&1; then
      OLLAMA_MANAGER=systemd-user
    elif systemctl cat ollama.service >/dev/null 2>&1; then
      OLLAMA_MANAGER=systemd-system
    fi
  elif [ "$PLATFORM" = macos ]; then
    if have brew && brew services list 2>/dev/null | grep -q '^ollama '; then
      OLLAMA_MANAGER=brew
    elif [ -d /Applications/Ollama.app ] || [ -d "$HOME/Applications/Ollama.app" ]; then
      OLLAMA_MANAGER=app
    fi
  fi

  CUR_MODELS_DIR="" CUR_KEEP_ALIVE="" CUR_CONTEXT=""
  case "$OLLAMA_MANAGER" in
    systemd-user)
      CUR_MODELS_DIR=$(systemd_env_value --user OLLAMA_MODELS)
      CUR_KEEP_ALIVE=$(systemd_env_value --user OLLAMA_KEEP_ALIVE)
      CUR_CONTEXT=$(systemd_env_value --user OLLAMA_CONTEXT_LENGTH)
      ;;
    systemd-system)
      CUR_MODELS_DIR=$(systemd_env_value --system OLLAMA_MODELS)
      CUR_KEEP_ALIVE=$(systemd_env_value --system OLLAMA_KEEP_ALIVE)
      CUR_CONTEXT=$(systemd_env_value --system OLLAMA_CONTEXT_LENGTH)
      ;;
    brew | app)
      CUR_MODELS_DIR=$(launchctl getenv OLLAMA_MODELS 2>/dev/null || true)
      CUR_KEEP_ALIVE=$(launchctl getenv OLLAMA_KEEP_ALIVE 2>/dev/null || true)
      CUR_CONTEXT=$(launchctl getenv OLLAMA_CONTEXT_LENGTH 2>/dev/null || true)
      ;;
  esac
  CUR_KEEP_ALIVE=${CUR_KEEP_ALIVE:-5m}
  CUR_CONTEXT=${CUR_CONTEXT:-auto}

  INSTALLED_MODELS=" "
  if [ "$OLLAMA_RUNNING" = 1 ] && [ -n "$OLLAMA_BIN" ]; then
    INSTALLED_MODELS=" $("$OLLAMA_BIN" list 2>/dev/null | awk 'NR > 1 { print $1 }' | tr '\n' ' ') "
  fi

  # an earlier Aazad Chat install
  EXISTING_APP_DIR="" EXISTING_DATA_DIR="" EXISTING_PORT=""
  if [ "$PLATFORM" = linux ] && have systemctl && systemctl --user cat "$SERVICE.service" >/dev/null 2>&1; then
    local exec_line
    exec_line=$(systemctl --user show "$SERVICE" -p ExecStart --value 2>/dev/null)
    EXISTING_APP_DIR=$(printf '%s' "$exec_line" | grep -o '/[^ ;"]*/server\.py' | head -1 | sed 's#/server\.py$##')
    EXISTING_DATA_DIR=$(systemctl --user show "$SERVICE" -p Environment --value | tr ' ' '\n' | sed -n 's/^AAZAD_CHAT_DATA=//p' | tail -1)
    EXISTING_PORT=$(systemctl --user show "$SERVICE" -p Environment --value | tr ' ' '\n' | sed -n 's/^AAZAD_CHAT_PORT=//p' | tail -1)
  elif [ "$PLATFORM" = macos ] && [ -f "$HOME/Library/LaunchAgents/com.aazad.$SERVICE.plist" ]; then
    local plist="$HOME/Library/LaunchAgents/com.aazad.$SERVICE.plist"
    EXISTING_APP_DIR=$(/usr/libexec/PlistBuddy -c 'Print :WorkingDirectory' "$plist" 2>/dev/null || true)
    EXISTING_DATA_DIR=$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:AAZAD_CHAT_DATA' "$plist" 2>/dev/null || true)
    EXISTING_PORT=$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:AAZAD_CHAT_PORT' "$plist" 2>/dev/null || true)
  fi

  # settings saved by a previous run of this installer
  CONF_APP_DIR="" CONF_AUTOSTART="" CONF_SHORTCUT=""
  local conf="${EXISTING_DATA_DIR:-$DEF_DATA_DIR}/install.conf" key value
  if [ -f "$conf" ]; then
    while IFS='=' read -r key value; do
      case "$key" in
        APP_DIR) CONF_APP_DIR=$value ;;
        AUTOSTART) CONF_AUTOSTART=$value ;;
        SHORTCUT) CONF_SHORTCUT=$value ;;
      esac
    done <"$conf"
  fi
}

is_installed() {
  case "$INSTALLED_MODELS" in
    *" $1 "* | *" $1:latest "*) return 0 ;;
  esac
  return 1
}

fit_of() { # fit_of SIZE_GB -> gpu | partial | cpu | no
  local s=$1
  if fgt "$GPU_GB" 0 && fge "$GPU_GB" "$(calc "$s + 1.5")"; then
    echo gpu
  elif fgt "$GPU_GB" 0 && fge "$(calc "$GPU_GB + $RAM_GB * 0.5")" "$(calc "$s + 2")"; then
    echo partial
  elif fge "$(calc "$RAM_GB * 0.75")" "$(calc "$s + 2")"; then
    echo cpu
  else
    echo no
  fi
}

fit_label() {
  case "$1" in
    gpu) printf '%s' "${GREEN}fast (GPU)${RESET}" ;;
    partial) printf '%s' "${YELLOW}partly GPU, slower${RESET}" ;;
    cpu) printf '%s' "${YELLOW}CPU, slow${RESET}" ;;
    *) printf '%s' "${RED}too big${RESET}" ;;
  esac
}

recommended_models() {
  if fge "$GPU_GB" 40; then echo "llama3.3:70b qwen2.5-coder:32b"
  elif fge "$GPU_GB" 21.5; then echo "gemma3:27b qwen2.5-coder:32b"
  elif fge "$GPU_GB" 10.5; then echo "gemma3:12b qwen2.5-coder:14b"
  elif fge "$GPU_GB" 6.5; then echo "gemma3:4b qwen2.5-coder:7b"
  elif fge "$GPU_GB" 3.5; then echo "gemma3:4b qwen2.5-coder:3b"
  elif fge "$RAM_GB" 14; then echo "llama3.2:3b"
  else echo "gemma3:1b"
  fi
}

size_of() { # size_of MODEL -> GB from the catalog, or empty
  local e
  for e in "${CATALOG[@]}"; do
    if [ "$(field "$e" 1)" = "$1" ]; then field "$e" 4; return 0; fi
  done
  return 0
}

find_python() {
  local c path
  for c in python3 python; do
    path=$(command -v "$c" 2>/dev/null) || continue
    # On a Mac without developer tools, /usr/bin/python3 only opens an install dialog
    if [ "$PLATFORM" = macos ] && [ "$path" = /usr/bin/python3 ] && ! xcode-select -p >/dev/null 2>&1; then continue; fi
    if "$path" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null; then
      printf '%s' "$path"
      return 0
    fi
  done
  return 1
}

python_hint() {
  if [ "$PLATFORM" = macos ]; then
    say "  Install Python 3.9+ with:  brew install python   (or: xcode-select --install)"
    return
  fi
  local id=""
  # shellcheck disable=SC1091
  if [ -r /etc/os-release ]; then id=$(. /etc/os-release && echo "${ID:-} ${ID_LIKE:-}"); fi
  case "$id" in
    *debian* | *ubuntu*) say "  Install it with:  sudo apt install python3" ;;
    *fedora* | *rhel* | *centos*) say "  Install it with:  sudo dnf install python3" ;;
    *arch*) say "  Install it with:  sudo pacman -S python" ;;
    *suse*) say "  Install it with:  sudo zypper install python3" ;;
    *) say "  Install Python 3.9 or newer with your package manager." ;;
  esac
}

# ---------------------------------------------------------------- questions
ask_questions() {
  section "Your computer"
  say "  System:  $PLATFORM ($ARCH)"
  say "  Memory:  $RAM_GB GB RAM"
  if [ "$GPU_KIND" = none ]; then
    say "  GPU:     none found, models will run on the CPU"
  else
    say "  GPU:     $GPU_NAME, $GPU_GB GB usable for models"
  fi

  PYTHON=$(find_python || true)
  if [ -z "$PYTHON" ]; then
    warn "Python 3.9 or newer is required to run Aazad Chat, and it wasn't found."
    python_hint
    exit 1
  fi
  say "  Python:  $PYTHON ($("$PYTHON" -c 'import platform; print(platform.python_version())'))"

  # 1. Ollama
  section "1. AI engine (Ollama)"
  PLANNED_MANAGER=$OLLAMA_MANAGER
  if [ -n "$OPT_OLLAMA" ]; then
    OLLAMA_ACTION=$OPT_OLLAMA
  elif [ -n "$OLLAMA_BIN" ] || [ "$OLLAMA_RUNNING" = 1 ]; then
    OLLAMA_ACTION=keep
  else
    local n
    if [ "$PLATFORM" = linux ]; then
      choose n "Ollama is not installed. How should it be installed?" 1 \
        "Official installer: system-wide service that starts at boot (asks for your sudo password)" \
        "Into your home folder: no sudo, runs as your user" \
        "Skip: I'll install Ollama myself"
      case "$n" in 1) OLLAMA_ACTION=system ;; 2) OLLAMA_ACTION=user ;; *) OLLAMA_ACTION=skip ;; esac
    elif have brew; then
      choose n "Ollama is not installed. How should it be installed?" 1 \
        "Homebrew: brew install ollama, runs as a background service" \
        "Ollama app: open the download page, then continue once it's installed" \
        "Skip: I'll install Ollama myself"
      case "$n" in 1) OLLAMA_ACTION=brew ;; 2) OLLAMA_ACTION=app ;; *) OLLAMA_ACTION=skip ;; esac
    else
      choose n "Ollama is not installed. How should it be installed?" 1 \
        "Ollama app: open the download page, then continue once it's installed" \
        "Skip: I'll install Ollama myself"
      case "$n" in 1) OLLAMA_ACTION=app ;; *) OLLAMA_ACTION=skip ;; esac
    fi
  fi
  case "$OLLAMA_ACTION" in
    keep)
      if [ "$OLLAMA_RUNNING" = 1 ]; then ok "Using the Ollama already on this computer (version $OLLAMA_VERSION)"
      else warn "Ollama is installed but not running. The installer will try to start it."; fi
      ;;
    system) PLANNED_MANAGER=systemd-system ;;
    user) if systemd_user_ok; then PLANNED_MANAGER=systemd-user; else PLANNED_MANAGER=none; fi ;;
    brew) PLANNED_MANAGER=brew ;;
    app) PLANNED_MANAGER=app ;;
    skip) warn "Skipping Ollama. Models can't be downloaded until it's installed and running." ;;
    *) die "--ollama must be keep, system, user, brew, app or skip" ;;
  esac

  # 2. Models
  section "2. Models"
  local rec entry name good caps size fit mark i=1
  rec=$(recommended_models)
  printf '  %s%-3s %-18s %-26s %-15s %8s  %s%s\n' "$DIM" "#" "Model" "Good for" "Capabilities" "Download" "On this computer" "$RESET"
  for entry in "${CATALOG[@]}"; do
    IFS='|' read -r name good caps size <<<"$entry"
    fit=$(fit_of "$size")
    mark=""
    case " $rec " in *" $name "*) mark=" ${BOLD}★ recommended${RESET}" ;; esac
    if is_installed "$name"; then mark="$mark ${GREEN}(installed)${RESET}"; fi
    printf '  %-3s %-18s %-26s %-15s %5s GB  %s%s\n' "$i" "$name" "$good" "$caps" "$size" "$(fit_label "$fit")" "$mark"
    i=$((i + 1))
  done

  local default_sel="" m reply=""
  for m in $rec; do is_installed "$m" || default_sel="$default_sel $m"; done
  local def_answer=n
  [ -n "$default_sel" ] && def_answer=r
  if [ "$OLLAMA_ACTION" = skip ] && [ "$OLLAMA_RUNNING" = 0 ]; then
    def_answer=n
  fi
  if [ -n "$OPT_MODELS" ]; then
    reply=$OPT_MODELS
  elif [ "$YES" = 1 ]; then
    reply=$def_answer
  else
    say ""
    say "  Type numbers or names separated by spaces (e.g. ${BOLD}8 9${RESET}), ${BOLD}r${RESET} = recommended ★, ${BOLD}n${RESET} = none."
    say "  You can download more later from the Models button in the app."
    read -r -p "Models to download [$def_answer]: " reply <"$TTY" || true
    reply=${reply:-$def_answer}
  fi

  SELECTED_MODELS=""
  local tok total=0 sz
  set -f
  for tok in $(printf '%s' "$reply" | tr ',' ' '); do
    case "$tok" in
      r | R) for m in $rec; do add_model "$m"; done ;;
      n | N | none) ;;
      *[!0-9]*)
        if [ -z "$(size_of "$tok")" ]; then info "$tok isn't in the list above; it will be downloaded if the Ollama library has it."; fi
        add_model "$tok"
        ;;
      *)
        tok=$((10#$tok))
        if [ "$tok" -ge 1 ] && [ "$tok" -le "${#CATALOG[@]}" ]; then
          add_model "$(field "${CATALOG[$((tok - 1))]}" 1)"
        else
          warn "There is no model number $tok, skipped."
        fi
        ;;
    esac
  done
  set +f
  for m in $SELECTED_MODELS; do
    sz=$(size_of "$m")
    if [ -n "$sz" ]; then
      total=$(calc "$total + $sz")
      if [ "$(fit_of "$sz")" = no ]; then warn "$m ($sz GB) is too big for this computer's memory and may not run."; fi
    fi
  done
  MODELS_TOTAL_GB=$total
  if [ -n "$SELECTED_MODELS" ]; then ok "Will download: $SELECTED_MODELS (about $total GB)"; else info "No models will be downloaded."; fi

  # 3. Storage
  section "3. Model storage"
  local default_models_dir
  case "$PLANNED_MANAGER" in
    systemd-system) default_models_dir=/usr/share/ollama/.ollama/models ;;
    *) default_models_dir="$HOME/.ollama/models" ;;
  esac
  MANAGER_DEFAULT_MODELS_DIR=$default_models_dir
  if [ "$OLLAMA_ACTION" = keep ] && [ -n "$CUR_MODELS_DIR" ]; then default_models_dir=$CUR_MODELS_DIR; fi
  CUR_MODELS_DIR=${CUR_MODELS_DIR:-$MANAGER_DEFAULT_MODELS_DIR}
  if [ -d "$default_models_dir" ] && [ "$(resolved "$default_models_dir")" != "$default_models_dir" ]; then
    info "Models are currently in $default_models_dir → $(resolved "$default_models_dir")"
  fi
  say "  Pick a drive with enough space that is always connected. Models can be large."
  if [ -n "$OPT_MODELS_DIR" ]; then MODELS_DIR=$OPT_MODELS_DIR; else ask MODELS_DIR "Folder for models" "$default_models_dir"; fi
  MODELS_DIR=$(expand_path "$MODELS_DIR")
  MOVE_MODELS=no
  if [ "$MODELS_DIR" != "$CUR_MODELS_DIR" ]; then
    if [ "$PLANNED_MANAGER" = none ]; then
      warn "Ollama isn't managed by a service this installer knows, so the folder can't be set automatically."
      warn "Set OLLAMA_MODELS=$MODELS_DIR yourself (see the README), or keep the current folder."
    fi
    if [ -d "$CUR_MODELS_DIR/blobs" ] && [ -n "$(ls -A "$CUR_MODELS_DIR/blobs" 2>/dev/null)" ]; then
      MOVE_MODELS=$(yesno_opt "" "Move the models already in $CUR_MODELS_DIR ($(du -sh "$CUR_MODELS_DIR" 2>/dev/null | cut -f1)) to the new folder?" Y)
    fi
  fi
  local free
  free=$(free_gb "$MODELS_DIR")
  if fgt "$(calc "$MODELS_TOTAL_GB + 2")" "$free"; then
    warn "Only $free GB free there, but the selected models need about $MODELS_TOTAL_GB GB."
    confirm "Continue anyway?" N || die "Stopped. Choose fewer models or another folder."
  else
    ok "$free GB free in $(nearest_existing_dir "$MODELS_DIR")"
  fi

  # 4. Model settings
  section "4. Model settings"
  if [ -n "$OPT_KEEP_ALIVE" ]; then
    KEEP_ALIVE=$OPT_KEEP_ALIVE
  else
    local def=2
    case "$CUR_KEEP_ALIVE" in 5m) [ "$OLLAMA_ACTION" = keep ] && def=1 ;; 30m) def=2 ;; 1h) def=3 ;; -1) def=4 ;; esac
    [ "$OLLAMA_ACTION" = keep ] || def=2
    choose n "How long should a model stay loaded after you use it? (loading takes seconds on SSD, up to a minute on HDD)" "$def" \
      "5 minutes (Ollama's default, frees memory quickly)" \
      "30 minutes (recommended)" \
      "1 hour" \
      "Always, until unloaded (fastest replies, keeps memory busy)"
    case "$n" in 1) KEEP_ALIVE=5m ;; 2) KEEP_ALIVE=30m ;; 3) KEEP_ALIVE=1h ;; *) KEEP_ALIVE=-1 ;; esac
  fi
  if [ -n "$OPT_CONTEXT" ]; then
    CONTEXT=$OPT_CONTEXT
  else
    local cdef=1
    case "$CUR_CONTEXT" in 4096) cdef=2 ;; 8192) cdef=3 ;; 16384) cdef=4 ;; 32768) cdef=5 ;; esac
    choose n "Default context length (how much of a conversation a model remembers; more uses more memory)" "$cdef" \
      "Automatic (Ollama picks from your GPU memory; recommended)" \
      "4K tokens" "8K tokens" "16K tokens" "32K tokens"
    case "$n" in 1) CONTEXT=auto ;; 2) CONTEXT=4096 ;; 3) CONTEXT=8192 ;; 4) CONTEXT=16384 ;; *) CONTEXT=32768 ;; esac
  fi

  ok "Keep loaded: $KEEP_ALIVE · context length: $CONTEXT"

  # 5. Aazad Chat
  section "5. Aazad Chat"
  local def_app=${EXISTING_APP_DIR:-${CONF_APP_DIR:-$DEF_APP_DIR}}
  if [ -n "$OPT_APP_DIR" ]; then APP_DIR=$OPT_APP_DIR; else ask APP_DIR "Install folder" "$def_app"; fi
  APP_DIR=$(expand_path "$APP_DIR")
  if [ -d "$APP_DIR" ] && [ -n "$(ls -A "$APP_DIR" 2>/dev/null)" ] && [ ! -f "$APP_DIR/server.py" ]; then
    die "$APP_DIR already contains other files. Choose an empty or new folder."
  fi
  if [ -d "$APP_DIR/.git" ]; then info "That folder is a git checkout; it will be updated with git pull."; fi

  local def_data=${EXISTING_DATA_DIR:-$DEF_DATA_DIR}
  if [ -n "$OPT_DATA_DIR" ]; then DATA_DIR=$OPT_DATA_DIR; else ask DATA_DIR "Folder for saved chats" "$def_data"; fi
  DATA_DIR=$(expand_path "$DATA_DIR")

  local def_port=${EXISTING_PORT:-3210}
  while true; do
    if [ -n "$OPT_PORT" ]; then PORT=$OPT_PORT; else ask PORT "Port for the web app" "$def_port"; fi
    case "$PORT" in '' | *[!0-9]*) warn "The port must be a number."; OPT_PORT=""; [ "$YES" = 1 ] && die "Invalid port"; continue ;; esac
    if port_in_use "$PORT" && ! curl -fsS -m 2 "http://127.0.0.1:$PORT/" 2>/dev/null | grep -q '<title>Aazad Chat'; then
      warn "Port $PORT is used by another program."
      OPT_PORT=""
      [ "$YES" = 1 ] && die "Port $PORT is busy. Use --port to pick another."
      def_port=$((PORT + 1))
      continue
    fi
    break
  done

  AUTOSTART=$(yesno_opt "$OPT_AUTOSTART" "Start Aazad Chat automatically when you log in?" "$( [ "${CONF_AUTOSTART:-yes}" = no ] && echo N || echo Y)")
  SHORTCUT=$(yesno_opt "$OPT_SHORTCUT" "Add Aazad Chat to your app menu?" "$( [ "${CONF_SHORTCUT:-yes}" = no ] && echo N || echo Y)")
  OPEN_BROWSER=$(yesno_opt "$OPT_OPEN" "Open Aazad Chat in your browser when done?" Y)
}

add_model() {
  if is_installed "$1"; then
    info "$1 is already installed, skipping its download."
    return 0
  fi
  case " $SELECTED_MODELS " in
    *" $1 "*) ;;
    *) SELECTED_MODELS="${SELECTED_MODELS:+$SELECTED_MODELS }$1" ;;
  esac
}

ollama_action_text() {
  case "$OLLAMA_ACTION" in
    keep) echo "use the existing Ollama" ;;
    system) echo "install with the official installer (system service, sudo)" ;;
    user) echo "install into ~/.local/opt/ollama (no sudo)" ;;
    brew) echo "install with Homebrew" ;;
    app) echo "install the Ollama app from ollama.com" ;;
    skip) echo "skip" ;;
  esac
}

show_summary() {
  section "Summary"
  say "  AI engine:        $(ollama_action_text)"
  say "  Models:           ${SELECTED_MODELS:-none}${SELECTED_MODELS:+ (about $MODELS_TOTAL_GB GB)}"
  say "  Model folder:     $MODELS_DIR$([ "$MOVE_MODELS" = yes ] && echo "  (move existing models from $CUR_MODELS_DIR)")"
  say "  Keep loaded:      $KEEP_ALIVE"
  say "  Context length:   $CONTEXT"
  say "  App folder:       $APP_DIR"
  say "  Chats folder:     $DATA_DIR/chats"
  say "  Address:          http://127.0.0.1:$PORT"
  say "  Start at login:   $AUTOSTART"
  say "  Menu shortcut:    $SHORTCUT"
  if [ "$DRY_RUN" = 1 ]; then say ""; warn "Dry run: nothing will be changed."; fi
}

# ---------------------------------------------------------------- install steps
install_ollama() {
  case "$OLLAMA_ACTION" in
    keep | skip) ;;
    system)
      info "Running the official Ollama installer (it may ask for your sudo password)…"
      if [ "$DRY_RUN" = 1 ]; then run sh -c "curl -fsSL https://ollama.com/install.sh | sh"; else curl -fsSL https://ollama.com/install.sh | sh; fi
      OLLAMA_BIN=$(command -v ollama || echo /usr/local/bin/ollama)
      OLLAMA_MANAGER=systemd-system
      ;;
    user)
      have zstd || die "'zstd' is needed to unpack Ollama. Install it (e.g. sudo apt install zstd) and run the installer again."
      local dest="$HOME/.local/opt/ollama"
      info "Downloading Ollama into $dest…"
      run mkdir -p "$dest" "$HOME/.local/bin"
      if [ "$DRY_RUN" = 1 ]; then
        run sh -c "curl -fsSL https://ollama.com/download/ollama-linux-$ARCH.tar.zst | zstd -d | tar -xf - -C '$dest'"
      else
        curl -fL --progress-bar "https://ollama.com/download/ollama-linux-$ARCH.tar.zst" | zstd -d | tar -xf - -C "$dest"
      fi
      run ln -sfn "$dest/bin/ollama" "$HOME/.local/bin/ollama"
      OLLAMA_BIN="$HOME/.local/bin/ollama"
      if systemd_user_ok; then
        write_file "$HOME/.config/systemd/user/ollama.service" <<EOF
[Unit]
Description=Ollama (installed by the Aazad Chat installer)
After=network-online.target

[Service]
ExecStart=$dest/bin/ollama serve
Environment=OLLAMA_HOST=127.0.0.1:11434
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF
        run systemctl --user daemon-reload
        run systemctl --user enable --now ollama.service
        OLLAMA_MANAGER=systemd-user
      else
        warn "No systemd user session: starting Ollama in the background for now."
        run sh -c "nohup '$dest/bin/ollama' serve >'$HOME/.ollama-serve.log' 2>&1 &"
      fi
      ;;
    brew)
      run brew install ollama
      run brew services start ollama
      OLLAMA_BIN=$(command -v ollama || echo /opt/homebrew/bin/ollama)
      OLLAMA_MANAGER=brew
      ;;
    app)
      run open "https://ollama.com/download/mac"
      if [ "$DRY_RUN" = 0 ]; then
        say "  Install Ollama from the page that just opened, start it once, then come back here."
        read -r -p "Press Enter when Ollama is running… " _ <"$TTY" || true
      fi
      OLLAMA_BIN=$(command -v ollama || echo /usr/local/bin/ollama)
      OLLAMA_MANAGER=app
      ;;
  esac

  if [ "$OLLAMA_ACTION" != skip ] && [ "$DRY_RUN" = 0 ]; then
    if ! wait_http "$OLLAMA_URL/api/version" 5; then
      case "$OLLAMA_MANAGER" in
        systemd-user) systemctl --user start ollama.service || true ;;
        systemd-system) sudo systemctl start ollama.service || true ;;
        brew) brew services start ollama || true ;;
        app) open -a Ollama || true ;;
        none) [ -n "$OLLAMA_BIN" ] && nohup "$OLLAMA_BIN" serve >"$HOME/.ollama-serve.log" 2>&1 & ;;
      esac
      wait_http "$OLLAMA_URL/api/version" 60 || warn "Ollama isn't answering yet at $OLLAMA_URL."
    fi
    if curl -fsS -m 3 -o /dev/null "$OLLAMA_URL/api/version"; then ok "Ollama is running"; fi
  fi
}

restart_ollama() {
  case "$OLLAMA_MANAGER" in
    systemd-user) run systemctl --user daemon-reload; run systemctl --user restart ollama.service ;;
    systemd-system) run sudo systemctl daemon-reload; run sudo systemctl restart ollama.service ;;
    brew) run brew services restart ollama ;;
    app) run osascript -e 'quit app "Ollama"'; run sleep 3; run open -a Ollama ;;
  esac
  [ "$DRY_RUN" = 1 ] || wait_http "$OLLAMA_URL/api/version" 60 || warn "Ollama didn't come back after the restart."
}

stop_ollama() {
  case "$OLLAMA_MANAGER" in
    systemd-user) run systemctl --user stop ollama.service ;;
    systemd-system) run sudo systemctl stop ollama.service ;;
    brew) run brew services stop ollama ;;
    app) run osascript -e 'quit app "Ollama"' ;;
  esac
}

apply_ollama_settings() {
  [ "$OLLAMA_ACTION" = skip ] && return 0
  local lines="" var_models="" changed=0
  [ "$KEEP_ALIVE" != 5m ] && lines="${lines}OLLAMA_KEEP_ALIVE=$KEEP_ALIVE"$'\n'
  [ "$CONTEXT" != auto ] && lines="${lines}OLLAMA_CONTEXT_LENGTH=$CONTEXT"$'\n'
  if [ "$MODELS_DIR" != "$MANAGER_DEFAULT_MODELS_DIR" ]; then
    var_models="OLLAMA_MODELS=$MODELS_DIR"
    lines="${lines}${var_models}"$'\n'
  fi

  if [ "$KEEP_ALIVE" != "$CUR_KEEP_ALIVE" ] || [ "$CONTEXT" != "$CUR_CONTEXT" ] || [ "$MODELS_DIR" != "$CUR_MODELS_DIR" ]; then changed=1; fi

  case "$OLLAMA_MANAGER" in
    systemd-user | systemd-system)
      local dropin sudo_arg=""
      if [ "$OLLAMA_MANAGER" = systemd-user ]; then
        dropin="$HOME/.config/systemd/user/ollama.service.d/aazad.conf"
      else
        dropin="/etc/systemd/system/ollama.service.d/aazad.conf"
        sudo_arg=sudo
      fi
      local content
      content="# Written by the Aazad Chat installer. Run it again to change these settings."$'\n'"[Service]"$'\n'
      local l
      while IFS= read -r l; do [ -n "$l" ] && content="${content}Environment=\"$l\""$'\n'; done <<<"$lines"
      if [ -f "$dropin" ]; then
        if [ "$(cat "$dropin")"$'\n' = "$content" ]; then changed=0; else changed=1; fi
      fi
      if [ "$changed" = 0 ]; then
        ok "Ollama settings unchanged"
        return 0
      fi
      if [ "$MOVE_MODELS" = yes ]; then move_models "$sudo_arg"; fi
      if [ -n "$var_models" ]; then
        run $sudo_arg mkdir -p "$MODELS_DIR"
        if [ "$OLLAMA_MANAGER" = systemd-system ]; then run sudo chown -R ollama:ollama "$MODELS_DIR"; fi
      fi
      printf '%s' "$content" | write_file "$dropin" "$sudo_arg"
      restart_ollama
      ok "Ollama settings saved in $dropin"
      ;;
    brew | app)
      if [ "$changed" = 0 ]; then ok "Ollama settings unchanged"; return 0; fi
      [ "$MOVE_MODELS" = yes ] && move_models ""
      [ -n "$var_models" ] && run mkdir -p "$MODELS_DIR"
      local plist="$HOME/Library/LaunchAgents/com.aazad.ollama-env.plist" args="" l
      while IFS= read -r l; do
        [ -n "$l" ] || continue
        args="$args      <string>launchctl setenv $(xml_escape "${l%%=*}") '$(xml_escape "${l#*=}")';</string>"$'\n'
        run launchctl setenv "${l%%=*}" "${l#*=}"
      done <<<"$lines"
      [ "$KEEP_ALIVE" = 5m ] && run launchctl unsetenv OLLAMA_KEEP_ALIVE
      [ "$CONTEXT" = auto ] && run launchctl unsetenv OLLAMA_CONTEXT_LENGTH
      [ -z "$var_models" ] && [ "$MODELS_DIR" = "$MANAGER_DEFAULT_MODELS_DIR" ] && run launchctl unsetenv OLLAMA_MODELS
      write_file "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.aazad.ollama-env</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>-c</string>
    <string>
$args    </string>
  </array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
      restart_ollama
      ok "Ollama settings saved (applied at every login by $plist)"
      ;;
    *)
      if [ "$changed" = 1 ]; then
        warn "Ollama isn't run by a service this installer manages, so these settings weren't applied:"
        printf '%s' "$lines" | sed 's/^/      /' >&2
        warn "See 'Change Ollama settings' in the README."
      fi
      ;;
  esac
}

move_models() {
  local s=${1:-}
  info "Moving models from $CUR_MODELS_DIR to $MODELS_DIR…"
  stop_ollama
  run $s mkdir -p "$MODELS_DIR"
  if [ -n "$(ls -A "$MODELS_DIR" 2>/dev/null)" ]; then
    warn "$MODELS_DIR is not empty, so existing models were not moved."
    return 0
  fi
  local item
  for item in "$CUR_MODELS_DIR"/*; do
    [ -e "$item" ] && run $s mv "$item" "$MODELS_DIR/"
  done
  ok "Models moved"
}

pull_models() {
  [ -n "$SELECTED_MODELS" ] || return 0
  if [ "$DRY_RUN" = 0 ] && ! curl -fsS -m 3 -o /dev/null "$OLLAMA_URL/api/version"; then
    warn "Ollama isn't running, so models weren't downloaded. Later, run: ollama pull <model>"
    return 0
  fi
  local m failed=""
  for m in $SELECTED_MODELS; do
    info "Downloading $m…"
    if ! run "${OLLAMA_BIN:-ollama}" pull "$m"; then failed="$failed $m"; fi
  done
  if [ -n "$failed" ]; then warn "These models didn't download:$failed. Try again later with: ollama pull <model>"; else ok "Models ready"; fi
}

install_app() {
  if [ -d "$APP_DIR/.git" ]; then
    if [ -n "$(git -C "$APP_DIR" status --porcelain 2>/dev/null)" ]; then
      warn "$APP_DIR has local changes, so it wasn't updated. Commit or stash them, then run git pull."
    else
      info "Updating Aazad Chat (git pull)…"
      run git -C "$APP_DIR" pull --ff-only
    fi
    return 0
  fi
  info "Downloading Aazad Chat…"
  local tmp
  tmp=$(mktemp -d)
  if [ "$DRY_RUN" = 1 ]; then
    run sh -c "curl -fsSL https://codeload.github.com/$REPO/tar.gz/refs/heads/$BRANCH | tar -xz -C '$tmp'"
    run rm -rf "$APP_DIR"
    run cp -R "$tmp/<download>/." "$APP_DIR"
  else
    curl -fsSL "https://codeload.github.com/$REPO/tar.gz/refs/heads/$BRANCH" | tar -xz -C "$tmp"
    local src
    src=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -1)
    [ -f "$src/server.py" ] || die "The download didn't contain Aazad Chat. Please try again."
    rm -rf "$APP_DIR"
    mkdir -p "$APP_DIR"
    cp -R "$src/." "$APP_DIR"
  fi
  rm -rf "$tmp"
  ok "Aazad Chat files are in $APP_DIR"
}

setup_service() {
  run mkdir -p "$DATA_DIR/chats"
  if systemd_user_ok; then
    local unit="$HOME/.config/systemd/user/$SERVICE.service"
    write_file "$unit" <<EOF
[Unit]
Description=Aazad Chat (http://127.0.0.1:$PORT)
Wants=ollama.service
After=ollama.service

[Service]
ExecStart="$PYTHON" "$APP_DIR/server.py"
Environment="AAZAD_CHAT_PORT=$PORT"
Environment="AAZAD_CHAT_DATA=$DATA_DIR"
Environment="OLLAMA_URL=$OLLAMA_URL"
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
    run systemctl --user daemon-reload
    if [ "$AUTOSTART" = yes ]; then run systemctl --user enable "$SERVICE.service"; else run systemctl --user disable "$SERVICE.service"; fi
    run systemctl --user restart "$SERVICE.service"
  elif [ "$PLATFORM" = macos ]; then
    local plist="$HOME/Library/LaunchAgents/com.aazad.$SERVICE.plist" label="com.aazad.$SERVICE"
    local run_at_load="<false/>"
    [ "$AUTOSTART" = yes ] && run_at_load="<true/>"
    write_file "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(xml_escape "$PYTHON")</string>
    <string>$(xml_escape "$APP_DIR/server.py")</string>
  </array>
  <key>WorkingDirectory</key><string>$(xml_escape "$APP_DIR")</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>AAZAD_CHAT_PORT</key><string>$PORT</string>
    <key>AAZAD_CHAT_DATA</key><string>$(xml_escape "$DATA_DIR")</string>
    <key>OLLAMA_URL</key><string>$OLLAMA_URL</string>
  </dict>
  <key>RunAtLoad</key>$run_at_load
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>StandardOutPath</key><string>$(xml_escape "$DATA_DIR/aazad-chat.log")</string>
  <key>StandardErrorPath</key><string>$(xml_escape "$DATA_DIR/aazad-chat.log")</string>
</dict>
</plist>
EOF
    run launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    run launchctl bootstrap "gui/$(id -u)" "$plist"
    run launchctl kickstart -k "gui/$(id -u)/$label"
  else
    warn "No systemd user session: starting Aazad Chat in the background (it stops when you log out)."
    run sh -c "cd '$APP_DIR' && AAZAD_CHAT_PORT='$PORT' AAZAD_CHAT_DATA='$DATA_DIR' nohup '$PYTHON' server.py >'$DATA_DIR/aazad-chat.log' 2>&1 &"
    if [ "$AUTOSTART" = yes ]; then
      write_file "$HOME/.config/autostart/$SERVICE.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Aazad Chat (server)
Exec=env AAZAD_CHAT_PORT=$PORT AAZAD_CHAT_DATA="$DATA_DIR" "$PYTHON" "$APP_DIR/server.py"
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF
    fi
  fi
  if [ "$DRY_RUN" = 0 ]; then
    if wait_http "http://127.0.0.1:$PORT/" 20; then ok "Aazad Chat is running at http://127.0.0.1:$PORT"; else warn "Aazad Chat didn't answer on port $PORT yet."; fi
  fi
}

setup_shortcut() {
  if [ "$PLATFORM" = linux ]; then
    local file="$HOME/.local/share/applications/$SERVICE.desktop"
    if [ "$SHORTCUT" = yes ]; then
      write_file "$file" <<EOF
[Desktop Entry]
Type=Application
Name=Aazad Chat
GenericName=AI Chat
Comment=Free, private AI on your own computer
Exec=xdg-open http://127.0.0.1:$PORT
Icon=$APP_DIR/web/icon.svg
Terminal=false
Categories=Utility;
Keywords=aazad;ai;chat;llm;assistant;
EOF
      if have update-desktop-database; then run update-desktop-database "$HOME/.local/share/applications"; fi
    elif [ -f "$file" ]; then
      run rm -f "$file"
    fi
  else
    local file="$HOME/Applications/Aazad Chat.webloc"
    if [ "$SHORTCUT" = yes ]; then
      write_file "$file" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>URL</key><string>http://127.0.0.1:$PORT</string></dict></plist>
EOF
    elif [ -f "$file" ]; then
      run rm -f "$file"
    fi
  fi
}

save_conf() {
  write_file "$DATA_DIR/install.conf" <<EOF
APP_DIR=$APP_DIR
DATA_DIR=$DATA_DIR
PORT=$PORT
AUTOSTART=$AUTOSTART
SHORTCUT=$SHORTCUT
KEEP_ALIVE=$KEEP_ALIVE
CONTEXT=$CONTEXT
MODELS_DIR=$MODELS_DIR
EOF
}

do_install() {
  section "Installing"
  install_ollama
  apply_ollama_settings
  pull_models
  install_app
  setup_service
  setup_shortcut
  save_conf
}

finish() {
  local url="http://127.0.0.1:$PORT"
  section "Done"
  if [ "$DRY_RUN" = 1 ]; then
    say "  Dry run finished. Run again without --dry-run to install."
    return 0
  fi
  say "  ${BOLD}Aazad Chat:${RESET} $url"
  say "  Chats:      $DATA_DIR/chats"
  if systemd_user_ok; then
    say "  Manage:     systemctl --user status|restart|stop $SERVICE"
  elif [ "$PLATFORM" = macos ]; then
    say "  Manage:     launchctl kickstart -k gui/$(id -u)/com.aazad.$SERVICE   (restart)"
  fi
  say "  Update or change settings: run this installer again"
  say "  Remove:     run this installer with --uninstall"
  if [ "$OPEN_BROWSER" = yes ]; then
    if [ "$PLATFORM" = macos ]; then open "$url" >/dev/null 2>&1 || true
    elif have xdg-open; then (xdg-open "$url" >/dev/null 2>&1 &) || true
    fi
  fi
}

# ---------------------------------------------------------------- uninstall
uninstall() {
  section "Uninstall Aazad Chat"
  local app=${EXISTING_APP_DIR:-${CONF_APP_DIR:-}} data=${EXISTING_DATA_DIR:-$DEF_DATA_DIR}
  say "  App folder:   ${app:-not found}"
  say "  Chats folder: $data/chats"
  say "  Ollama and your models are not touched."
  confirm "Remove Aazad Chat?" N || { say "Nothing was changed."; exit 0; }

  if [ "$PLATFORM" = linux ]; then
    if have systemctl && systemctl --user cat "$SERVICE.service" >/dev/null 2>&1; then
      run systemctl --user disable --now "$SERVICE.service" || true
      run rm -f "$HOME/.config/systemd/user/$SERVICE.service"
      run systemctl --user daemon-reload
    fi
    run rm -f "$HOME/.local/share/applications/$SERVICE.desktop" "$HOME/.config/autostart/$SERVICE.desktop"
  else
    local label="com.aazad.$SERVICE"
    run launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    run rm -f "$HOME/Library/LaunchAgents/$label.plist" "$HOME/Applications/Aazad Chat.webloc"
  fi

  if [ -n "$app" ] && [ -f "$app/server.py" ]; then
    if [ -d "$app/.git" ]; then
      if confirm "$app is a git checkout (maybe your own copy). Delete it too?" N; then run rm -rf "$app"; fi
    else
      run rm -rf "$app"
    fi
  fi
  if [ -d "$data" ]; then
    if confirm "Also delete your saved chats in $data?" N; then run rm -rf "$data"; else run rm -f "$data/install.conf"; fi
  fi
  local dropin="$HOME/.config/systemd/user/ollama.service.d/aazad.conf"
  if [ -f "$dropin" ] && confirm "Remove the Ollama settings this installer added ($dropin)?" N; then
    run rm -f "$dropin"
    run systemctl --user daemon-reload
    run systemctl --user restart ollama.service
  fi
  ok "Aazad Chat removed."
}

# ---------------------------------------------------------------- main
main() {
  parse_args "$@"
  setup_ui
  say "${BOLD}Aazad Chat installer${RESET}: free, private AI on your own computer"
  detect_system
  detect_existing
  if [ "$UNINSTALL" = 1 ]; then
    uninstall
    return 0
  fi
  ask_questions
  show_summary
  say ""
  if ! confirm "Go ahead?" Y; then
    say "Nothing was changed."
    exit 0
  fi
  do_install
  finish
}

main "$@"
