#!/usr/bin/env bash

# Avdb Magic Tools Android/macOS client injector.
#
# Safety contract:
#   * The selected source is never modified in place.
#   * Every input is copied below ~/AvdbMagicTools before it is inspected,
#     decoded, patched, signed, or packaged.
#   * Every generated key and build result stays below ~/AvdbMagicTools.

set -Eeuo pipefail
umask 077

SCRIPT_VERSION="1.0.0"
SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" >/dev/null 2>&1 && pwd -P)"
AVDB_ROOT="${AVDB_MAGIC_TOOLS_HOME:-$HOME/AvdbMagicTools}"
TOOLS_DIR="$AVDB_ROOT/tools"
DOWNLOADS_DIR="$AVDB_ROOT/downloads"
KEYSTORE_DIR="$AVDB_ROOT/keystore"
JOBS_DIR="$AVDB_ROOT/jobs"
LOGS_DIR="$AVDB_ROOT/logs"
RUN_ID="$(date '+%Y%m%d-%H%M%S')-$$"
LOG_FILE="$LOGS_DIR/run-$RUN_ID.log"
CURRENT_STEP="初始化"
MOUNT_POINT=""
MOUNT_ATTACHED="false"
PLATFORM="unknown"
CPU_ARCH="$(uname -m 2>/dev/null || printf 'unknown')"
MODE=""
INPUT_PATH=""
LOADER_PATH="${AVDB_LOADER_PATH:-}"
KEYSTORE_PATH="${AVDB_ANDROID_KEYSTORE:-}"
KEY_ALIAS="${AVDB_ANDROID_KEY_ALIAS:-avdbmagictools}"
MAC_BUNDLE_ID="${AVDB_MAC_BUNDLE_ID:-com.emby.avdb.macos}"
MAC_DISPLAY_NAME="${AVDB_MAC_DISPLAY_NAME:-Emby-Avdb-Mac}"
MAC_SIGN_IDENTITY="${AVDB_MAC_SIGN_IDENTITY:--}"
APKTOOL_JAR=""
APKTOOL_COMMAND=""
JAVA_COMMAND=""
KEYTOOL_COMMAND=""
ANDROID_SDK_ROOT_LOCAL=""
APKSIGNER_JAR=""
ZIPALIGN_COMMAND=""
SDKMANAGER_COMMAND=""
LAST_KEYSTORE_PASSWORD=""
GENERATED_KEYSTORE=""
GENERATED_ALIAS=""
RESOLVED_LOADER=""

mkdir -p "$TOOLS_DIR" "$DOWNLOADS_DIR" "$KEYSTORE_DIR" "$JOBS_DIR" "$LOGS_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

printf '\033]0;Avdb Magic Tools 自动化注入脚本\007'

color_supported() {
    [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ]
}

if color_supported; then
    C_BLUE='\033[1;34m'
    C_GREEN='\033[1;32m'
    C_YELLOW='\033[1;33m'
    C_RED='\033[1;31m'
    C_RESET='\033[0m'
else
    C_BLUE=''
    C_GREEN=''
    C_YELLOW=''
    C_RED=''
    C_RESET=''
fi

banner() {
    printf '\n%s============================================================%s\n' "$C_BLUE" "$C_RESET"
    printf '%s          Avdb Magic Tools 自动化注入脚本%s\n' "$C_BLUE" "$C_RESET"
    printf '%s                     v%s%s\n' "$C_BLUE" "$SCRIPT_VERSION" "$C_RESET"
    printf '%s============================================================%s\n' "$C_BLUE" "$C_RESET"
    printf '工作目录：%s\n' "$AVDB_ROOT"
    printf '运行日志：%s\n\n' "$LOG_FILE"
}

begin_step() {
    CURRENT_STEP="$1"
    printf '\n[%s] %s ...\n' "$(date '+%H:%M:%S')" "$CURRENT_STEP"
}

ok() {
    printf '%s[ Ok ]%s %s\n' "$C_GREEN" "$C_RESET" "$1"
}

warn() {
    printf '%s[提示]%s %s\n' "$C_YELLOW" "$C_RESET" "$1"
}

fail() {
    printf '%s[失败]%s %s\n' "$C_RED" "$C_RESET" "$1" >&2
    printf '当前步骤：%s\n' "$CURRENT_STEP" >&2
    printf '日志位置：%s\n' "$LOG_FILE" >&2
    exit 1
}

on_error() {
    local status="$1"
    local line="$2"
    printf '\n%s[失败]%s 步骤“%s”执行失败（脚本第 %s 行，退出码 %s）。\n' \
        "$C_RED" "$C_RESET" "$CURRENT_STEP" "$line" "$status" >&2
    printf '所有源文件均未被原地修改。任务副本和日志保留在：%s\n' "$AVDB_ROOT" >&2
    printf '详细日志：%s\n' "$LOG_FILE" >&2
    exit "$status"
}

cleanup_mount() {
    if [ "$MOUNT_ATTACHED" = "true" ] && [ -n "$MOUNT_POINT" ]; then
        hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
        MOUNT_ATTACHED="false"
    fi
}

trap 'on_error "$?" "$LINENO"' ERR
trap cleanup_mount EXIT INT TERM

detect_platform() {
    case "$(uname -s 2>/dev/null || true)" in
        Darwin*) PLATFORM="macos" ;;
        MINGW*|MSYS*|CYGWIN*) PLATFORM="windows" ;;
        Linux*)
            if [ -r /proc/version ] && grep -qi microsoft /proc/version; then
                PLATFORM="wsl"
            else
                PLATFORM="linux"
            fi
            ;;
        *) PLATFORM="unknown" ;;
    esac
}

confirm() {
    local prompt="$1"
    local answer=""
    printf '%s [y/N] ' "$prompt"
    IFS= read -r answer || true
    case "$answer" in
        y|Y|yes|YES|Yes) return 0 ;;
        *) return 1 ;;
    esac
}

read_default() {
    local variable_name="$1"
    local prompt="$2"
    local default_value="$3"
    local answer=""
    printf '%s [%s]: ' "$prompt" "$default_value"
    IFS= read -r answer || true
    if [ -z "$answer" ]; then
        answer="$default_value"
    fi
    printf -v "$variable_name" '%s' "$answer"
}

read_secret_twice() {
    local variable_name="$1"
    local first=""
    local second=""
    while :; do
        printf '请输入签名密码（至少 6 位，不会写入日志）：'
        IFS= read -r -s first
        printf '\n请再次输入签名密码：'
        IFS= read -r -s second
        printf '\n'
        if [ ${#first} -lt 6 ]; then
            warn "密码长度不足 6 位，请重新输入。"
        elif [ "$first" != "$second" ]; then
            warn "两次密码不一致，请重新输入。"
        else
            printf -v "$variable_name" '%s' "$first"
            return 0
        fi
    done
}

read_secret_once() {
    local variable_name="$1"
    local prompt="$2"
    local answer=""
    printf '%s' "$prompt"
    IFS= read -r -s answer
    printf '\n'
    printf -v "$variable_name" '%s' "$answer"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

sha256_file() {
    local file="$1"
    if command_exists shasum; then
        shasum -a 256 "$file" | awk '{print $1}'
    elif command_exists sha256sum; then
        sha256sum "$file" | awk '{print $1}'
    elif command_exists certutil; then
        certutil -hashfile "$file" SHA256 | sed -n '2p' | tr -d ' \r\n'
    else
        fail "缺少 SHA-256 工具（shasum、sha256sum 或 certutil）。"
    fi
}

assert_file() {
    [ -f "$1" ] || fail "文件不存在：$1"
}

assert_directory() {
    [ -d "$1" ] || fail "目录不存在：$1"
}

assert_generated_path() {
    case "$1" in
        "$AVDB_ROOT"/*) return 0 ;;
        *) fail "安全检查拒绝操作工作目录之外的路径：$1" ;;
    esac
}

reset_generated_directory() {
    local directory="$1"
    assert_generated_path "$directory"
    if [ -e "$directory" ]; then
        rm -rf -- "$directory"
    fi
    mkdir -p "$directory"
}

normalize_selected_path() {
    local value="$1"
    value="$(printf '%s' "$value" | tr -d '\r')"
    if [ "$PLATFORM" = "windows" ] && command_exists cygpath; then
        value="$(cygpath -u "$value")"
    elif [ "$PLATFORM" = "wsl" ] && command_exists wslpath; then
        value="$(wslpath -u "$value")"
    fi
    # macOS folder selection can return an application bundle with a trailing
    # slash (for example, /Applications/Emby.app/). Strip it so suffix-based
    # input detection still recognizes the .app bundle. Preserve the root path.
    while [ "$value" != "/" ] && [ "${value%/}" != "$value" ]; do
        value="${value%/}"
    done
    printf '%s' "$value"
}

choose_file() {
    local prompt="$1"
    local filter="$2"
    local picked=""

    if [ "$PLATFORM" = "macos" ] && command_exists osascript \
        && [ -z "${SSH_CONNECTION:-}" ] && [ -z "${SSH_TTY:-}" ]; then
        picked="$(osascript - "$prompt" <<'APPLESCRIPT'
on run argv
    set chosenItem to choose file with prompt (item 1 of argv)
    return POSIX path of chosenItem
end run
APPLESCRIPT
)" || picked=""
    elif { [ "$PLATFORM" = "windows" ] || [ "$PLATFORM" = "wsl" ]; } \
        && command_exists powershell.exe; then
        picked="$(MSYS_NO_PATHCONV=1 powershell.exe -NoProfile -STA -Command \
            '& { param($title, $filter) Add-Type -AssemblyName System.Windows.Forms; $dialog = New-Object System.Windows.Forms.OpenFileDialog; $dialog.Title = $title; $dialog.Filter = $filter; if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $dialog.FileName } }' \
            "$prompt" "$filter" | tr -d '\r')" || picked=""
    elif command_exists zenity; then
        picked="$(zenity --file-selection --title="$prompt")" || picked=""
    elif command_exists kdialog; then
        picked="$(kdialog --getopenfilename "$HOME" "$filter")" || picked=""
    fi

    if [ -z "$picked" ]; then
        warn "图形文件选择器不可用或已取消，将使用终端输入。"
        printf '%s\n> ' "$prompt" >/dev/tty
        IFS= read -r picked </dev/tty || return 1
    fi

    picked="$(normalize_selected_path "$picked")"
    [ -n "$picked" ] || return 1
    printf '%s' "$picked"
}

check_basic_commands() {
    local missing=""
    local tool=""
    for tool in awk sed grep find cp mkdir date basename dirname tee cmp tr \
        head tail sort mv chmod; do
        if ! command_exists "$tool"; then
            missing="$missing $tool"
        fi
    done
    [ -z "$missing" ] || fail "缺少 Bash 基础工具：$missing。请使用 macOS Terminal、Git Bash 或 WSL 运行。"
}

ensure_download_commands() {
    local missing=""
    command_exists curl || missing="$missing curl"
    command_exists unzip || missing="$missing unzip"
    [ -z "$missing" ] && return 0

    warn "缺少下载/解压依赖：$missing"
    confirm "是否现在安装这些依赖？" || fail "用户取消安装依赖：$missing"
    case "$PLATFORM" in
        macos)
            if command_exists brew; then
                brew install $missing
            else
                fail "macOS 未找到 Homebrew。请先安装 Homebrew，或手动安装：$missing"
            fi
            ;;
        linux|wsl)
            if command_exists apt-get; then
                sudo apt-get update
                sudo apt-get install -y $missing
            elif command_exists dnf; then
                sudo dnf install -y $missing
            else
                fail "没有可用的软件包管理器，请手动安装：$missing"
            fi
            ;;
        windows)
            fail "当前 Git Bash 缺少：$missing。请重新安装 Git for Windows，并勾选常用 Unix 工具。"
            ;;
        *) fail "无法为未知平台安装：$missing" ;;
    esac
    command_exists curl && command_exists unzip \
        || fail "依赖安装后仍无法找到 curl/unzip，请重新打开终端后重试。"
}

portable_java_arch() {
    case "$CPU_ARCH" in
        arm64|aarch64) printf 'aarch64' ;;
        x86_64|amd64) printf 'x64' ;;
        *) fail "暂不支持自动安装 Java 的 CPU 架构：$CPU_ARCH" ;;
    esac
}

find_portable_java() {
    local candidate=""
    candidate="$(find "$TOOLS_DIR/jdk" -type f \
        \( -path '*/Contents/Home/bin/java' -o -path '*/bin/java' -o -path '*/bin/java.exe' \) \
        2>/dev/null | head -n 1 || true)"
    if [ -n "$candidate" ]; then
        JAVA_COMMAND="$candidate"
        case "$candidate" in
            */Contents/Home/bin/java)
                KEYTOOL_COMMAND="${candidate%/bin/java}/bin/keytool"
                ;;
            *.exe)
                KEYTOOL_COMMAND="${candidate%/java.exe}/keytool.exe"
                ;;
            *)
                KEYTOOL_COMMAND="${candidate%/java}/keytool"
                ;;
        esac
        [ -x "$KEYTOOL_COMMAND" ] || KEYTOOL_COMMAND=""
        return 0
    fi
    return 1
}

install_portable_java() {
    local java_os=""
    local package_type="tar.gz"
    local archive=""
    local url=""
    local extract_dir="$TOOLS_DIR/jdk"

    ensure_download_commands
    case "$PLATFORM" in
        macos) java_os="mac" ;;
        windows) java_os="windows"; package_type="zip" ;;
        linux|wsl) java_os="linux" ;;
        *) fail "无法在未知平台自动安装 Java。" ;;
    esac
    url="https://api.adoptium.net/v3/binary/latest/17/ga/$(portable_java_arch)/jdk/hotspot/normal/$java_os?project=jdk"
    archive="$DOWNLOADS_DIR/temurin17-$PLATFORM-$CPU_ARCH.$package_type"
    if [ "$package_type" = "tar.gz" ] && ! command_exists tar; then
        fail "自动安装 Java 需要 tar，请先安装 tar 后重试。"
    fi

    begin_step "下载便携式 Temurin Java 17"
    curl -fL --retry 3 --connect-timeout 20 "$url" -o "$archive.part"
    mv "$archive.part" "$archive"
    reset_generated_directory "$extract_dir"
    if [ "$package_type" = "zip" ]; then
        unzip -q "$archive" -d "$extract_dir"
    else
        tar -xzf "$archive" -C "$extract_dir"
    fi
    find_portable_java || fail "Java 已下载，但未找到 java/keytool 可执行文件。"
    "$JAVA_COMMAND" -version
    ok "便携式 Java 已安装到 $extract_dir"
}

ensure_java() {
    if find_portable_java; then
        ok "使用工作目录中的 Java：$JAVA_COMMAND"
        return 0
    fi
    if command_exists java && command_exists keytool \
        && java -version >/dev/null 2>&1 \
        && keytool -help >/dev/null 2>&1; then
        JAVA_COMMAND="$(command -v java)"
        KEYTOOL_COMMAND="$(command -v keytool)"
        ok "已检测到 Java 和 keytool"
        return 0
    fi

    warn "未检测到完整 Java JDK（需要 java 和 keytool）。"
    confirm "是否下载便携式 Temurin Java 17 到 $TOOLS_DIR？" \
        || fail "Android 操作需要 Java JDK，用户取消安装。"
    install_portable_java
}

run_apktool() {
    if [ -n "$APKTOOL_COMMAND" ]; then
        "$APKTOOL_COMMAND" "$@"
    else
        "$JAVA_COMMAND" -jar "$APKTOOL_JAR" "$@"
    fi
}

ensure_apktool() {
    local default_url="https://github.com/iBotPeaches/Apktool/releases/download/v3.0.3/apktool_3.0.3.jar"
    local default_sha="dbf930b076c6b9be08d57c449cacefc3bdd6b71ebd59b3066fc0e1f5b14f9423"
    local apktool_url="${AVDB_APKTOOL_URL:-$default_url}"
    local apktool_sha="${AVDB_APKTOOL_SHA256:-}"
    local actual_sha=""
    if [ "$apktool_url" = "$default_url" ] && [ -z "$apktool_sha" ]; then
        apktool_sha="$default_sha"
    fi
    if command_exists apktool; then
        APKTOOL_COMMAND="$(command -v apktool)"
        if run_apktool --version >/dev/null 2>&1; then
            ok "已检测到 apktool：$APKTOOL_COMMAND"
            return 0
        fi
        warn "系统中的 apktool 无法运行，将改用工作目录中的官方 JAR。"
        APKTOOL_COMMAND=""
    fi
    APKTOOL_JAR="$TOOLS_DIR/apktool.jar"
    if [ -f "$APKTOOL_JAR" ]; then
        run_apktool --version >/dev/null
        ok "使用工作目录中的 apktool：$APKTOOL_JAR"
        return 0
    fi

    warn "未检测到 apktool。"
    confirm "是否从 Apktool 官方 GitHub Release 下载到 $TOOLS_DIR？" \
        || fail "Android APK 解包需要 apktool，用户取消安装。"
    ensure_download_commands
    begin_step "下载 apktool"
    curl -fL --retry 3 --connect-timeout 20 "$apktool_url" -o "$APKTOOL_JAR.part"
    mv "$APKTOOL_JAR.part" "$APKTOOL_JAR"
    if [ -n "$apktool_sha" ]; then
        actual_sha="$(sha256_file "$APKTOOL_JAR")"
        [ "$actual_sha" = "$apktool_sha" ] \
            || fail "apktool SHA-256 校验失败。期望 $apktool_sha，实际 $actual_sha"
    fi
    run_apktool --version >/dev/null
    ok "apktool 已安装并校验：$APKTOOL_JAR"
}

normalize_sdk_root() {
    local value="$1"
    [ -n "$value" ] || return 1
    if [ "$PLATFORM" = "windows" ] && command_exists cygpath; then
        value="$(cygpath -u "$value" 2>/dev/null || printf '%s' "$value")"
    fi
    printf '%s' "$value"
}

find_android_build_tools() {
    local sdk_roots=()
    local root=""
    local signer=""
    local aligner=""

    [ -n "${ANDROID_SDK_ROOT:-}" ] && sdk_roots+=("$ANDROID_SDK_ROOT")
    [ -n "${ANDROID_HOME:-}" ] && sdk_roots+=("$ANDROID_HOME")
    sdk_roots+=("$TOOLS_DIR/android-sdk")
    if [ "$PLATFORM" = "macos" ]; then
        sdk_roots+=("$HOME/Library/Android/sdk")
    elif [ "$PLATFORM" = "windows" ] && [ -n "${LOCALAPPDATA:-}" ]; then
        sdk_roots+=("${LOCALAPPDATA}/Android/Sdk")
    elif [ "$PLATFORM" = "wsl" ]; then
        sdk_roots+=("$HOME/Android/Sdk")
    fi

    for root in "${sdk_roots[@]}"; do
        root="$(normalize_sdk_root "$root")"
        [ -d "$root/build-tools" ] || continue
        signer="$(find "$root/build-tools" -type f -path '*/lib/apksigner.jar' 2>/dev/null | sort | tail -n 1 || true)"
        aligner="$(find "$root/build-tools" -type f \( -name zipalign -o -name zipalign.exe \) 2>/dev/null | sort | tail -n 1 || true)"
        if [ -n "$signer" ] && [ -n "$aligner" ]; then
            ANDROID_SDK_ROOT_LOCAL="$root"
            APKSIGNER_JAR="$signer"
            ZIPALIGN_COMMAND="$aligner"
            return 0
        fi
    done
    return 1
}

android_commandline_tools_info() {
    case "$PLATFORM:$CPU_ARCH" in
        macos:arm64|macos:aarch64)
            printf '%s|%s' \
                'https://dl.google.com/android/repository/commandlinetools-mac_arm64-15859902_latest.zip' \
                '835b62a26162b229b441d1f6d4680383815a270809eb33522c0d480fa5002c4e'
            ;;
        macos:x86_64|macos:amd64)
            printf '%s|%s' \
                'https://dl.google.com/android/repository/commandlinetools-mac_x86_64-15859902_latest.zip' \
                'c5a6378ab5cf7e0d5701921405115befff13e9ff7417fb588389338f8bd050f3'
            ;;
        windows:*)
            printf '%s|%s' \
                'https://dl.google.com/android/repository/commandlinetools-win-15859902_latest.zip' \
                '90ae805d20434428bffcb699c290860f19bb5f66a67e6b330067e3de801fb04a'
            ;;
        linux:*|wsl:*)
            printf '%s|%s' \
                'https://dl.google.com/android/repository/commandlinetools-linux-15859902_latest.zip' \
                '4e4c464f145a7512b57d088ac6c278c03c9eea610886b35a5e0804e74eedf583'
            ;;
        *) fail "当前系统没有可用的 Android Command-line Tools 下载配置。" ;;
    esac
}

find_sdkmanager() {
    local candidate=""
    if command_exists sdkmanager; then
        SDKMANAGER_COMMAND="$(command -v sdkmanager)"
        return 0
    fi
    candidate="$(find "$TOOLS_DIR/android-sdk/cmdline-tools" -type f \
        \( -name sdkmanager -o -name sdkmanager.bat \) 2>/dev/null | head -n 1 || true)"
    if [ -n "$candidate" ]; then
        SDKMANAGER_COMMAND="$candidate"
        return 0
    fi
    return 1
}

run_sdkmanager() {
    local windows_sdk_root=""
    local windows_command=""
    if [ "$PLATFORM" = "windows" ] && [[ "$SDKMANAGER_COMMAND" == *.bat ]]; then
        windows_sdk_root="$(cygpath -w "$ANDROID_SDK_ROOT_LOCAL")"
        windows_command="$(cygpath -w "$SDKMANAGER_COMMAND")"
        MSYS_NO_PATHCONV=1 powershell.exe -NoProfile -Command \
            '& { $command = $args[0]; $rest = @($args[1..($args.Length - 1)]); & $command @rest; exit $LASTEXITCODE }' \
            "$windows_command" "--sdk_root=$windows_sdk_root" "$@"
    else
        "$SDKMANAGER_COMMAND" "--sdk_root=$ANDROID_SDK_ROOT_LOCAL" "$@"
    fi
}

install_android_commandline_tools() {
    local info=""
    local url=""
    local expected_sha=""
    local archive="$DOWNLOADS_DIR/android-commandline-tools-$PLATFORM-$CPU_ARCH.zip"
    local actual_sha=""
    local extract_dir="$TOOLS_DIR/android-sdk-setup-$RUN_ID"
    local build_tools_version="${AVDB_ANDROID_BUILD_TOOLS_VERSION:-36.0.0}"

    ensure_download_commands
    info="$(android_commandline_tools_info)"
    url="${info%%|*}"
    expected_sha="${info#*|}"
    ANDROID_SDK_ROOT_LOCAL="$TOOLS_DIR/android-sdk"

    begin_step "下载 Android Command-line Tools"
    curl -fL --retry 3 --connect-timeout 20 "$url" -o "$archive.part"
    mv "$archive.part" "$archive"
    actual_sha="$(sha256_file "$archive")"
    [ "$actual_sha" = "$expected_sha" ] \
        || fail "Android Command-line Tools SHA-256 校验失败。期望 $expected_sha，实际 $actual_sha"
    ok "Android Command-line Tools 下载并校验完成"

    begin_step "安装 Android Command-line Tools 到工作目录"
    reset_generated_directory "$extract_dir"
    unzip -q "$archive" -d "$extract_dir"
    assert_directory "$extract_dir/cmdline-tools"
    reset_generated_directory "$ANDROID_SDK_ROOT_LOCAL/cmdline-tools/latest"
    cp -R "$extract_dir/cmdline-tools/." "$ANDROID_SDK_ROOT_LOCAL/cmdline-tools/latest/"
    find_sdkmanager || fail "已解压 Android SDK，但找不到 sdkmanager。"
    ok "sdkmanager 已安装到 $SDKMANAGER_COMMAND"

    warn "下一步会显示 Google Android SDK License；是否接受必须由你在 sdkmanager 中亲自决定。"
    confirm "是否继续进入 SDK License 确认？" \
        || fail "用户取消 Android SDK License 确认。"
    begin_step "确认 Android SDK License"
    run_sdkmanager --licenses
    ok "SDK License 步骤完成"

    begin_step "安装 Android Build Tools $build_tools_version"
    if ! run_sdkmanager "build-tools;$build_tools_version" "platform-tools"; then
        warn "默认 Build Tools $build_tools_version 安装失败。"
        read_default build_tools_version "请输入 sdkmanager 中可用的 Build Tools 版本" "35.0.0"
        run_sdkmanager "build-tools;$build_tools_version" "platform-tools"
    fi
    find_android_build_tools \
        || fail "Build Tools 安装完成，但找不到 apksigner.jar 或 zipalign。"
    ok "Android Build Tools 已就绪"
}

ensure_android_build_tools() {
    if find_android_build_tools; then
        ok "已检测到 Android Build Tools：$(dirname "$ZIPALIGN_COMMAND")"
        return 0
    fi

    warn "未检测到完整 Android Build Tools（需要 zipalign 和 apksigner）。"
    warn "Android SDK 受 Google SDK License 约束：https://developer.android.com/studio/terms"
    confirm "是否已阅读并同意继续下载到 $TOOLS_DIR，随后亲自完成 License 确认？" \
        || fail "APK 签名需要 Android Build Tools，用户取消安装。"
    install_android_commandline_tools
}

run_apksigner() {
    "$JAVA_COMMAND" -jar "$APKSIGNER_JAR" "$@"
}

copy_and_verify_file() {
    local source="$1"
    local destination="$2"
    local source_hash=""
    local destination_hash=""
    assert_file "$source"
    assert_generated_path "$destination"
    source_hash="$(sha256_file "$source")"
    cp "$source" "$destination"
    destination_hash="$(sha256_file "$destination")"
    [ "$source_hash" = "$destination_hash" ] \
        || fail "复制校验失败：$source -> $destination"
    printf '%s' "$source_hash"
}

resolve_loader() {
    local selected=""
    local candidate=""
    local job_input_dir="$1"
    local destination="$job_input_dir/AvdbMagicTools.js"

    if [ -z "$LOADER_PATH" ]; then
        for candidate in \
            "$SCRIPT_DIR/AvdbMagicTools.js" \
            "$SCRIPT_DIR/../Web/Client/AvdbMagicTools.js" \
            "$SCRIPT_DIR/Web/Client/AvdbMagicTools.js" \
            "$PWD/Web/Client/AvdbMagicTools.js"; do
            if [ -f "$candidate" ]; then
                LOADER_PATH="$candidate"
                break
            fi
        done
    fi
    if [ -z "$LOADER_PATH" ]; then
        selected="$(choose_file "请选择 AvdbMagicTools.js Loader" "JavaScript (*.js)|*.js|All files (*.*)|*.*")" \
            || fail "未选择 AvdbMagicTools.js Loader。"
        LOADER_PATH="$selected"
    fi

    assert_file "$LOADER_PATH"
    grep -Fq 'LOADER_VERSION = 1' "$LOADER_PATH" \
        || fail "所选文件不是受支持的 AvdbMagicTools.js Loader：$LOADER_PATH"
    copy_and_verify_file "$LOADER_PATH" "$destination" >/dev/null
    ok "Loader 已复制到任务目录：$destination"
    RESOLVED_LOADER="$destination"
}

patch_loader_registration() {
    local target="$1"
    local temporary="$target.avdbtmp"
    assert_file "$target"
    if grep -Fq './modules/AvdbMagicTools.js' "$target"; then
        ok "app.js 已包含 Loader 注册，跳过重复注入"
        return 0
    fi
    if ! grep -Fq 'Promise.all(list.map(loadPlugin))' "$target"; then
        fail "app.js 中未找到受支持的注入锚点：Promise.all(list.map(loadPlugin))"
    fi
    awk '
        BEGIN { changed = 0 }
        {
            if (!changed) {
                changed = sub(/Promise[.]all[(]list[.]map[(]loadPlugin[)][)]/,
                    "list.push(\"./modules/AvdbMagicTools.js\"),Promise.all(list.map(loadPlugin))")
            }
            print
        }
        END { if (!changed) exit 42 }
    ' "$target" > "$temporary" || {
        rm -f -- "$temporary"
        fail "写入 app.js Loader 注册失败。"
    }
    mv "$temporary" "$target"
    grep -Fq './modules/AvdbMagicTools.js' "$target" \
        || fail "app.js 注入后校验失败。"
    ok "app.js Loader 注册完成"
}

patch_restricted_plugins() {
    local target="$1"
    local temporary="$target.avdbtmp"
    assert_file "$target"
    if grep -Eq 'features[.]restrictedplugins[[:space:]]*=[[:space:]]*false' "$target"; then
        ok "restrictedplugins 已为 false，跳过重复修改"
        return 0
    fi
    if ! grep -Eq 'features[.]restrictedplugins[[:space:]]*=[[:space:]]*true' "$target"; then
        fail "apphost.js 中未找到 features.restrictedplugins = true。"
    fi
    awk '
        BEGIN { changed = 0 }
        {
            if (!changed) {
                changed = sub(/features[.]restrictedplugins[[:space:]]*=[[:space:]]*true/,
                    "features.restrictedplugins = false")
            }
            print
        }
        END { if (!changed) exit 42 }
    ' "$target" > "$temporary" || {
        rm -f -- "$temporary"
        fail "写入 apphost.js restrictedplugins 失败。"
    }
    mv "$temporary" "$target"
    grep -Eq 'features[.]restrictedplugins[[:space:]]*=[[:space:]]*false' "$target" \
        || fail "apphost.js 修改后校验失败。"
    ok "apphost.js restrictedplugins 已设为 false"
}

install_loader_copy() {
    local loader_copy="$1"
    local modules_dir="$2"
    local destination="$modules_dir/AvdbMagicTools.js"
    mkdir -p "$modules_dir"
    cp "$loader_copy" "$destination"
    [ "$(sha256_file "$loader_copy")" = "$(sha256_file "$destination")" ] \
        || fail "Loader 复制到客户端后 SHA-256 不一致。"
    ok "AvdbMagicTools.js 已注入 modules 目录"
}

mac_source_manifest() {
    local app="$1"
    local manifest="$2"
    local relative=""
    : > "$manifest"
    for relative in \
        'Contents/Info.plist' \
        'Contents/Resources/www/app.js' \
        'Contents/Resources/www/native/ios/apphost.js' \
        'Contents/Resources/www/native/macos/apphost.js'; do
        if [ -f "$app/$relative" ]; then
            printf '%s  %s\n' "$(sha256_file "$app/$relative")" "$relative" >> "$manifest"
        fi
    done
}

snapshot_macos_source() {
    local source="$1"
    local snapshot="$2"
    if [ -d "$source" ]; then
        mac_source_manifest "$source" "$snapshot"
    else
        assert_file "$source"
        printf '%s  %s\n' "$(sha256_file "$source")" "$(basename "$source")" > "$snapshot"
    fi
}

plist_set_string() {
    local plist="$1"
    local key="$2"
    local value="$3"
    if plutil -extract "$key" raw -o - "$plist" >/dev/null 2>&1; then
        plutil -replace "$key" -string "$value" "$plist"
    else
        plutil -insert "$key" -string "$value" "$plist"
    fi
}

copy_macos_input() {
    local source="$1"
    local job_dir="$2"
    local input_dir="$job_dir/input"
    local work_dir="$job_dir/work"
    local lower=""
    local copied=""
    local extracted="$work_dir/extracted"
    local found_app=""

    lower="$(printf '%s' "$source" | tr '[:upper:]' '[:lower:]')"
    mkdir -p "$input_dir" "$work_dir"
    case "$lower" in
        *.app)
            assert_directory "$source"
            copied="$input_dir/Original-Emby.app"
            ditto "$source" "$copied"
            printf '%s' "$copied"
            ;;
        *.dmg)
            assert_file "$source"
            copied="$input_dir/$(basename "$source")"
            copy_and_verify_file "$source" "$copied" >/dev/null
            MOUNT_POINT="$job_dir/mount"
            mkdir -p "$MOUNT_POINT"
            hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_POINT" "$copied" >/dev/null
            MOUNT_ATTACHED="true"
            found_app="$(find "$MOUNT_POINT" -maxdepth 3 -type d -name '*.app' | head -n 1 || true)"
            [ -n "$found_app" ] || fail "DMG 中未找到 .app。"
            ditto "$found_app" "$input_dir/Original-Emby.app"
            cleanup_mount
            printf '%s' "$input_dir/Original-Emby.app"
            ;;
        *.zip)
            assert_file "$source"
            copied="$input_dir/$(basename "$source")"
            copy_and_verify_file "$source" "$copied" >/dev/null
            reset_generated_directory "$extracted"
            ditto -x -k "$copied" "$extracted"
            found_app="$(find "$extracted" -maxdepth 4 -type d -name '*.app' | head -n 1 || true)"
            [ -n "$found_app" ] || fail "ZIP 中未找到 .app。"
            ditto "$found_app" "$input_dir/Original-Emby.app"
            printf '%s' "$input_dir/Original-Emby.app"
            ;;
        *) fail "macOS 输入只支持 .app、.dmg 或 .zip：$source" ;;
    esac
}

macos_architectures() {
    local app="$1"
    local plist="$app/Contents/Info.plist"
    local executable_name=""
    local executable=""
    executable_name="$(plutil -extract CFBundleExecutable raw -o - "$plist" 2>/dev/null || true)"
    if [ -n "$executable_name" ]; then
        executable="$app/Contents/MacOS/$executable_name"
    fi
    if [ -f "$executable" ]; then
        lipo -archs "$executable" 2>/dev/null || file "$executable"
    else
        printf '未知（Info.plist 未提供有效 CFBundleExecutable）'
    fi
}

ensure_macos_dependencies() {
    local missing=""
    local tool=""
    [ "$PLATFORM" = "macos" ] \
        || fail "macOS .app 重新签名必须在 macOS 执行；Windows 可运行 Android 选项。"
    for tool in ditto plutil codesign xattr hdiutil lipo; do
        command_exists "$tool" || missing="$missing $tool"
    done
    if [ -n "$missing" ]; then
        warn "缺少 Apple 开发工具：$missing"
        confirm "是否运行 xcode-select --install？" || fail "用户取消安装 Apple Command Line Tools。"
        xcode-select --install || true
        fail "已启动 Apple Command Line Tools 安装。安装完成后请重新运行脚本。"
    fi
    ok "macOS 解包、签名和打包依赖已就绪"
}

run_macos_flow() {
    local selected="${INPUT_PATH:-}"
    local job_dir="$JOBS_DIR/macos-$RUN_ID"
    local input_app=""
    local package_dir="$job_dir/package"
    local output_dir="$job_dir/output"
    local final_app=""
    local app_js=""
    local apphost_js=""
    local loader_copy=""
    local source_manifest="$job_dir/source-before.sha256"
    local source_manifest_after="$job_dir/source-after.sha256"
    local original_manifest="$job_dir/original-before.sha256"
    local original_manifest_after="$job_dir/original-after.sha256"
    local zip_output=""
    local dmg_output=""

    begin_step "检查 macOS 依赖"
    ensure_macos_dependencies

    if [ -z "$selected" ]; then
        selected="$(choose_file "请选择 Emby 官方原版 .app、.dmg 或 .zip" "macOS App/DMG/ZIP|*.app;*.dmg;*.zip|All files (*.*)|*.*")" \
            || fail "用户取消选择 macOS Emby 文件。"
    fi
    selected="$(normalize_selected_path "$selected")"
    if [ -t 0 ]; then
        read_default MAC_BUNDLE_ID "Bundle Identifier" "$MAC_BUNDLE_ID"
        read_default MAC_DISPLAY_NAME "应用显示名称" "$MAC_DISPLAY_NAME"
        read_default MAC_SIGN_IDENTITY "签名身份（- 表示 ad-hoc 临时签名）" "$MAC_SIGN_IDENTITY"
    fi
    final_app="$package_dir/$MAC_DISPLAY_NAME.app"

    begin_step "复制 macOS 源文件到任务目录"
    mkdir -p "$job_dir/input" "$package_dir" "$output_dir"
    snapshot_macos_source "$selected" "$original_manifest"
    input_app="$(copy_macos_input "$selected" "$job_dir")"
    mac_source_manifest "$input_app" "$source_manifest"
    ditto "$input_app" "$final_app"
    ok "源文件副本已创建，原文件不会被修改"

    begin_step "检查 macOS 客户端结构"
    app_js="$final_app/Contents/Resources/www/app.js"
    if [ -f "$final_app/Contents/Resources/www/native/ios/apphost.js" ]; then
        apphost_js="$final_app/Contents/Resources/www/native/ios/apphost.js"
    elif [ -f "$final_app/Contents/Resources/www/native/macos/apphost.js" ]; then
        apphost_js="$final_app/Contents/Resources/www/native/macos/apphost.js"
    else
        fail "客户端中未找到 native/ios/apphost.js 或 native/macos/apphost.js。"
    fi
    assert_file "$app_js"
    if ! codesign --verify --deep --strict "$input_app" > "$job_dir/source-codesign.txt" 2>&1; then
        tail -n 40 "$job_dir/source-codesign.txt" >&2
        fail "所选 macOS 应用的原始签名无效，拒绝继续修改副本。"
    fi
    ok "检测到应用架构：$(macos_architectures "$final_app")"

    begin_step "复制并验证 AvdbMagicTools.js"
    resolve_loader "$job_dir/input"
    loader_copy="$RESOLVED_LOADER"

    begin_step "注入 macOS Loader"
    patch_loader_registration "$app_js"
    patch_restricted_plugins "$apphost_js"
    install_loader_copy "$loader_copy" "$final_app/Contents/Resources/www/modules"
    ok "macOS Loader 注入完成"

    begin_step "设置独立应用标识"
    plist_set_string "$final_app/Contents/Info.plist" CFBundleIdentifier "$MAC_BUNDLE_ID"
    plist_set_string "$final_app/Contents/Info.plist" CFBundleDisplayName "$MAC_DISPLAY_NAME"
    plist_set_string "$final_app/Contents/Info.plist" CFBundleName "$MAC_DISPLAY_NAME"
    ok "应用标识已设置为 $MAC_BUNDLE_ID"

    begin_step "重新签名 macOS 应用"
    xattr -cr "$final_app"
    codesign --force --deep --sign "$MAC_SIGN_IDENTITY" "$final_app"
    codesign --verify --deep --strict --verbose=2 "$final_app"
    ok "macOS 应用签名验证通过"

    begin_step "打包 macOS 应用"
    zip_output="$output_dir/$MAC_DISPLAY_NAME-$RUN_ID.zip"
    dmg_output="$output_dir/$MAC_DISPLAY_NAME-$RUN_ID.dmg"
    ditto -c -k --sequesterRsrc --keepParent "$final_app" "$zip_output"
    hdiutil create -volname "$MAC_DISPLAY_NAME" -srcfolder "$package_dir" \
        -ov -format UDZO "$dmg_output" >/dev/null
    assert_file "$zip_output"
    assert_file "$dmg_output"
    ok "ZIP 和 DMG 打包完成"

    begin_step "确认源文件未被修改"
    mac_source_manifest "$input_app" "$source_manifest_after"
    snapshot_macos_source "$selected" "$original_manifest_after"
    cmp -s "$source_manifest" "$source_manifest_after" \
        || fail "任务目录中的只读输入副本发生变化，安全验收失败。"
    cmp -s "$original_manifest" "$original_manifest_after" \
        || fail "原始 macOS 输入发生变化，安全验收失败。"
    if [ -d "$selected" ]; then
        codesign --verify --deep --strict "$selected" >/dev/null 2>&1 \
            || fail "原始 macOS 应用在任务结束时签名不再有效。"
    fi
    ok "源文件及任务输入副本保持不变"

    printf '\n%s完成%s\n' "$C_GREEN" "$C_RESET"
    printf '应用副本：%s\n' "$final_app"
    printf 'ZIP：%s\n' "$zip_output"
    printf 'DMG：%s\n' "$dmg_output"
    printf '任务目录：%s\n' "$job_dir"
    warn "ad-hoc 签名只适合本机测试；分发时请通过 AVDB_MAC_SIGN_IDENTITY 使用有效 Developer ID。"
}

detect_apk_abis() {
    local decoded="$1"
    local abi=""
    local result=""
    if [ -d "$decoded/lib" ]; then
        for abi in "$decoded"/lib/*; do
            [ -d "$abi" ] || continue
            if [ -z "$result" ]; then
                result="$(basename "$abi")"
            else
                result="$result, $(basename "$abi")"
            fi
        done
    fi
    [ -n "$result" ] && printf '%s' "$result" || printf '无原生库或通用 APK'
}

generate_keystore() {
    local default_name="avdb-magic-tools.p12"
    local key_name=""
    local key_path=""
    local alias_value="$KEY_ALIAS"
    local password=""
    local metadata=""

    ensure_java
    if [ -e "$KEYSTORE_DIR/$default_name" ]; then
        default_name="avdb-magic-tools-$RUN_ID.p12"
    fi
    read_default key_name "签名文件名" "$default_name"
    case "$key_name" in
        *.jks|*.keystore|*.p12) ;;
        *) key_name="$key_name.jks" ;;
    esac
    key_path="$KEYSTORE_DIR/$(basename "$key_name")"
    [ ! -e "$key_path" ] || fail "为防止覆盖已有密钥，签名文件已存在：$key_path"
    read_default alias_value "Key Alias" "$alias_value"
    read_secret_twice password

    begin_step "生成 Android 签名"
    export AVDB_KEYSTORE_PASSWORD="$password"
    "$KEYTOOL_COMMAND" -genkeypair -v \
        -keystore "$key_path" \
        -storetype PKCS12 \
        -storepass:env AVDB_KEYSTORE_PASSWORD \
        -keypass:env AVDB_KEYSTORE_PASSWORD \
        -alias "$alias_value" \
        -keyalg RSA \
        -keysize 3072 \
        -validity 36500 \
        -dname "CN=Avdb Magic Tools, OU=Local Build, O=Avdb, L=Local, ST=Local, C=US"
    "$KEYTOOL_COMMAND" -list \
        -keystore "$key_path" \
        -storepass:env AVDB_KEYSTORE_PASSWORD \
        -alias "$alias_value" >/dev/null
    unset AVDB_KEYSTORE_PASSWORD
    chmod 600 "$key_path" 2>/dev/null || true
    metadata="$key_path.info.txt"
    {
        printf 'Created: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf 'Keystore: %s\n' "$key_path"
        printf 'Alias: %s\n' "$alias_value"
        printf 'Password: NOT STORED\n'
    } > "$metadata"
    chmod 600 "$metadata" 2>/dev/null || true

    GENERATED_KEYSTORE="$key_path"
    GENERATED_ALIAS="$alias_value"
    LAST_KEYSTORE_PASSWORD="$password"
    ok "Android 签名已生成并验证"
    printf '\n签名文件：%s\nAlias：%s\n说明文件：%s\n' "$key_path" "$alias_value" "$metadata"
    warn "请离线备份签名文件和密码；丢失后无法用同一签名升级已安装 APK。"
}

select_or_create_keystore() {
    local selected=""
    if [ -n "$KEYSTORE_PATH" ]; then
        assert_file "$KEYSTORE_PATH"
        return 0
    fi
    if [ -f "$KEYSTORE_DIR/avdb-magic-tools.p12" ]; then
        if confirm "检测到默认签名 $KEYSTORE_DIR/avdb-magic-tools.p12，是否使用？"; then
            KEYSTORE_PATH="$KEYSTORE_DIR/avdb-magic-tools.p12"
            return 0
        fi
    fi
    if confirm "没有选定签名，是否现在生成新的 Android 签名？"; then
        generate_keystore
        KEYSTORE_PATH="$GENERATED_KEYSTORE"
        KEY_ALIAS="$GENERATED_ALIAS"
        return 0
    fi
    selected="$(choose_file "请选择 Android 签名文件" "Keystore (*.jks;*.keystore;*.p12)|*.jks;*.keystore;*.p12|All files (*.*)|*.*")" \
        || fail "未选择 Android 签名文件。"
    KEYSTORE_PATH="$selected"
    assert_file "$KEYSTORE_PATH"
}

run_android_flow() {
    local selected="${INPUT_PATH:-}"
    local job_dir="$JOBS_DIR/android-$RUN_ID"
    local input_dir="$job_dir/input"
    local work_dir="$job_dir/work"
    local output_dir="$job_dir/output"
    local copied_apk="$input_dir/Emby-original.apk"
    local decoded="$work_dir/decoded"
    local unsigned_apk="$work_dir/Emby-Avdb-unsigned.apk"
    local aligned_apk="$work_dir/Emby-Avdb-aligned.apk"
    local signed_apk="$output_dir/Emby-Avdb-$RUN_ID.apk"
    local input_hash=""
    local app_js=""
    local apphost_js=""
    local loader_copy=""
    local store_password=""
    local key_password=""
    local verify_log="$job_dir/apksigner-verify.txt"
    local source_verify_log="$job_dir/source-apksigner-verify.txt"
    local artifact_check_dir="$job_dir/artifact-check"

    begin_step "检查 Android 依赖"
    ensure_download_commands
    ensure_java
    ensure_apktool
    ensure_android_build_tools
    ok "Android 解包、对齐和签名依赖已就绪"

    if [ -z "$selected" ]; then
        selected="$(choose_file "请选择 Emby 官方原版 APK" "Android APK (*.apk)|*.apk|All files (*.*)|*.*")" \
            || fail "用户取消选择 Android APK。"
    fi
    selected="$(normalize_selected_path "$selected")"
    case "$(printf '%s' "$selected" | tr '[:upper:]' '[:lower:]')" in
        *.apk) ;;
        *) fail "Android 输入必须是 .apk 文件：$selected" ;;
    esac

    begin_step "复制 Android 源 APK 到任务目录"
    mkdir -p "$input_dir" "$work_dir" "$output_dir"
    input_hash="$(copy_and_verify_file "$selected" "$copied_apk")"
    ok "APK 副本已创建，原 APK 不会被修改"

    begin_step "验证原始 APK 签名"
    if ! run_apksigner verify --verbose --print-certs "$copied_apk" > "$source_verify_log" 2>&1; then
        tail -n 80 "$source_verify_log" >&2
        fail "所选 APK 的原始签名无效；完整输出：$source_verify_log"
    fi
    sed -n '/^Verifies$/,/^Number of signers:/p' "$source_verify_log"
    ok "原始 APK 签名有效"

    begin_step "使用 apktool 解包 APK 副本"
    reset_generated_directory "$decoded"
    run_apktool d -f "$copied_apk" -o "$decoded"
    app_js="$decoded/assets/www/app.js"
    apphost_js="$decoded/assets/www/native/android/apphost.js"
    assert_file "$app_js"
    assert_file "$apphost_js"
    ok "APK 解包完成；检测到 ABI：$(detect_apk_abis "$decoded")"

    begin_step "复制并验证 AvdbMagicTools.js"
    resolve_loader "$input_dir"
    loader_copy="$RESOLVED_LOADER"

    begin_step "注入 Android Loader"
    patch_loader_registration "$app_js"
    patch_restricted_plugins "$apphost_js"
    install_loader_copy "$loader_copy" "$decoded/assets/www/modules"
    ok "Android Loader 注入完成"

    begin_step "重新构建 Android APK"
    run_apktool b "$decoded" -o "$unsigned_apk"
    assert_file "$unsigned_apk"
    ok "APK 重新构建完成"

    begin_step "执行 APK zipalign"
    "$ZIPALIGN_COMMAND" -f -p 4 "$unsigned_apk" "$aligned_apk"
    "$ZIPALIGN_COMMAND" -c -p 4 "$aligned_apk"
    ok "APK 对齐校验通过"

    begin_step "准备 Android 签名"
    select_or_create_keystore
    if [ -n "$GENERATED_KEYSTORE" ] && [ "$KEYSTORE_PATH" = "$GENERATED_KEYSTORE" ]; then
        store_password="$LAST_KEYSTORE_PASSWORD"
        key_password="$LAST_KEYSTORE_PASSWORD"
    else
        read_secret_once store_password "请输入 Keystore 密码："
        read_secret_once key_password "请输入 Key 密码（留空表示与 Keystore 相同）："
        [ -n "$key_password" ] || key_password="$store_password"
    fi
    if [ -t 0 ]; then
        read_default KEY_ALIAS "Key Alias" "$KEY_ALIAS"
    fi
    export AVDB_KEYSTORE_PASSWORD="$store_password"
    "$KEYTOOL_COMMAND" -list \
        -keystore "$KEYSTORE_PATH" \
        -storepass:env AVDB_KEYSTORE_PASSWORD \
        -alias "$KEY_ALIAS" >/dev/null \
        || fail "Keystore 密码或 Alias 不正确。"
    ok "Android 签名信息验证通过"

    begin_step "签名 Android APK"
    export AVDB_KEY_PASSWORD="$key_password"
    run_apksigner sign \
        --ks "$KEYSTORE_PATH" \
        --ks-key-alias "$KEY_ALIAS" \
        --ks-pass env:AVDB_KEYSTORE_PASSWORD \
        --key-pass env:AVDB_KEY_PASSWORD \
        --v4-signing-enabled false \
        --out "$signed_apk" \
        "$aligned_apk"
    unset AVDB_KEYSTORE_PASSWORD AVDB_KEY_PASSWORD
    assert_file "$signed_apk"
    ok "APK 签名完成"

    begin_step "验证签名和最终 APK"
    if ! run_apksigner verify --verbose --print-certs "$signed_apk" > "$verify_log" 2>&1; then
        tail -n 80 "$verify_log" >&2
        fail "apksigner 最终验证失败；完整输出：$verify_log"
    fi
    sed -n '/^Verifies$/,/^Number of signers:/p' "$verify_log"
    "$ZIPALIGN_COMMAND" -c -p 4 "$signed_apk"
    [ "$(sha256_file "$selected")" = "$input_hash" ] \
        || fail "原始 APK 的 SHA-256 发生变化，安全验收失败。"
    mkdir -p "$artifact_check_dir"
    unzip -p "$signed_apk" assets/www/app.js > "$artifact_check_dir/app.js"
    unzip -p "$signed_apk" assets/www/native/android/apphost.js > "$artifact_check_dir/apphost.js"
    unzip -p "$signed_apk" assets/www/modules/AvdbMagicTools.js \
        > "$artifact_check_dir/AvdbMagicTools.js"
    grep -Fq './modules/AvdbMagicTools.js' "$artifact_check_dir/app.js" \
        || fail "最终签名 APK 中未找到 Loader 注册。"
    grep -Eq 'features[.]restrictedplugins[[:space:]]*=[[:space:]]*false' \
        "$artifact_check_dir/apphost.js" \
        || fail "最终签名 APK 中 restrictedplugins 并非 false。"
    [ "$(sha256_file "$loader_copy")" = "$(sha256_file "$artifact_check_dir/AvdbMagicTools.js")" ] \
        || fail "最终签名 APK 中的 Loader SHA-256 不一致。"
    ok "签名、对齐、注入和源文件不变性检查全部通过"

    printf '\n%s完成%s\n' "$C_GREEN" "$C_RESET"
    printf '签名 APK：%s\n' "$signed_apk"
    printf 'SHA-256：%s\n' "$(sha256_file "$signed_apk")"
    printf '任务目录：%s\n' "$job_dir"
    warn "自签名 APK 通常不能覆盖安装官方签名版本；除非使用相同签名，否则需先卸载官方版，应用数据可能丢失。"
}

print_dependency_status() {
    local tool=""
    local status=""
    printf '\n平台：%s (%s)\n' "$PLATFORM" "$CPU_ARCH"
    printf '工作目录：%s\n\n' "$AVDB_ROOT"
    for tool in java keytool apktool curl unzip awk sed grep; do
        if command_exists "$tool"; then
            status="$(command -v "$tool")"
        else
            status="缺少"
        fi
        printf '%-12s %s\n' "$tool" "$status"
    done
    if find_android_build_tools; then
        printf '%-12s %s\n' "zipalign" "$ZIPALIGN_COMMAND"
        printf '%-12s %s\n' "apksigner" "$APKSIGNER_JAR"
    else
        printf '%-12s %s\n' "zipalign" "缺少"
        printf '%-12s %s\n' "apksigner" "缺少"
    fi
    if [ "$PLATFORM" = "macos" ]; then
        for tool in codesign plutil ditto hdiutil lipo; do
            if command_exists "$tool"; then
                status="$(command -v "$tool")"
            else
                status="缺少"
            fi
            printf '%-12s %s\n' "$tool" "$status"
        done
    fi
}

run_self_test() {
    local test_dir="$AVDB_ROOT/self-test/$RUN_ID"
    local source_app_js="$test_dir/source-app.js"
    local source_apphost="$test_dir/source-apphost.js"
    local copied_app_js="$test_dir/copied-app.js"
    local copied_apphost="$test_dir/copied-apphost.js"
    local source_hash_app=""
    local source_hash_host=""

    mkdir -p "$test_dir"
    printf '%s\n' 'return Promise.all(list.map(loadPlugin));' > "$source_app_js"
    printf '%s\n' 'features.restrictedplugins = true;' > "$source_apphost"
    source_hash_app="$(sha256_file "$source_app_js")"
    source_hash_host="$(sha256_file "$source_apphost")"
    cp "$source_app_js" "$copied_app_js"
    cp "$source_apphost" "$copied_apphost"
    patch_loader_registration "$copied_app_js"
    patch_restricted_plugins "$copied_apphost"
    patch_loader_registration "$copied_app_js"
    patch_restricted_plugins "$copied_apphost"
    grep -Fq './modules/AvdbMagicTools.js' "$copied_app_js"
    grep -Eq 'features[.]restrictedplugins[[:space:]]*=[[:space:]]*false' "$copied_apphost"
    [ "$(sha256_file "$source_app_js")" = "$source_hash_app" ]
    [ "$(sha256_file "$source_apphost")" = "$source_hash_host" ]
    ok "自检通过：注入、幂等性和源文件不变性均正确"
}

usage() {
    cat <<EOF
Avdb Magic Tools 自动化注入脚本 v$SCRIPT_VERSION

交互运行：
  bash $(basename "$SCRIPT_PATH")

命令行运行：
  bash $(basename "$SCRIPT_PATH") --mac /path/to/Emby.app --loader /path/to/AvdbMagicTools.js
  bash $(basename "$SCRIPT_PATH") --android /path/to/emby.apk --loader /path/to/AvdbMagicTools.js
  bash $(basename "$SCRIPT_PATH") --generate-keystore
  bash $(basename "$SCRIPT_PATH") --check

可选参数：
  --loader FILE          指定 AvdbMagicTools.js；未指定时自动查找或打开选择器
  --keystore FILE        指定 Android Keystore
  --alias NAME           指定 Android Key Alias
  --bundle-id ID         指定 macOS Bundle Identifier
  --display-name NAME    指定 macOS 应用名称
  --sign-identity NAME   指定 macOS codesign 身份；默认 -（ad-hoc）
  --self-test            只运行安全注入自检
  --help                 显示帮助

环境变量：
  AVDB_MAGIC_TOOLS_HOME              工作根目录，默认 ~/AvdbMagicTools
  AVDB_ANDROID_BUILD_TOOLS_VERSION   默认 36.0.0
  AVDB_APKTOOL_URL                   自定义 Apktool 官方 JAR URL
  AVDB_APKTOOL_SHA256                自定义 Apktool JAR 的 SHA-256
EOF
}

parse_arguments() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --mac)
                [ $# -ge 2 ] || fail "--mac 缺少文件路径。"
                MODE="macos"; INPUT_PATH="$2"; shift 2
                ;;
            --android)
                [ $# -ge 2 ] || fail "--android 缺少 APK 路径。"
                MODE="android"; INPUT_PATH="$2"; shift 2
                ;;
            --generate-keystore)
                MODE="keystore"; shift
                ;;
            --loader)
                [ $# -ge 2 ] || fail "--loader 缺少文件路径。"
                LOADER_PATH="$2"; shift 2
                ;;
            --keystore)
                [ $# -ge 2 ] || fail "--keystore 缺少文件路径。"
                KEYSTORE_PATH="$2"; shift 2
                ;;
            --alias)
                [ $# -ge 2 ] || fail "--alias 缺少名称。"
                KEY_ALIAS="$2"; shift 2
                ;;
            --bundle-id)
                [ $# -ge 2 ] || fail "--bundle-id 缺少值。"
                MAC_BUNDLE_ID="$2"; shift 2
                ;;
            --display-name)
                [ $# -ge 2 ] || fail "--display-name 缺少值。"
                MAC_DISPLAY_NAME="$2"; shift 2
                ;;
            --sign-identity)
                [ $# -ge 2 ] || fail "--sign-identity 缺少值。"
                MAC_SIGN_IDENTITY="$2"; shift 2
                ;;
            --check)
                MODE="check"; shift
                ;;
            --self-test)
                MODE="self-test"; shift
                ;;
            --help|-h)
                usage; exit 0
                ;;
            *) fail "未知参数：$1。使用 --help 查看帮助。" ;;
        esac
    done
}

interactive_menu() {
    local choice=""
    printf '1. macOS Emby 官方原版（ARM64 / Intel AMD64）\n'
    printf '2. Android Emby 官方原版（arm64-v8a / armeabi-v7a / x86 / x86_64）\n'
    printf '3. Android 签名生成\n'
    printf '4. 依赖环境检查\n'
    printf '0. 退出\n\n'
    printf '请选择 [0-4]: '
    IFS= read -r choice
    case "$choice" in
        1) MODE="macos" ;;
        2) MODE="android" ;;
        3) MODE="keystore" ;;
        4) MODE="check" ;;
        0) printf '已退出。\n'; exit 0 ;;
        *) fail "无效选择：$choice" ;;
    esac
}

main() {
    detect_platform
    check_basic_commands
    parse_arguments "$@"
    banner
    if [ -z "$MODE" ]; then
        interactive_menu
    fi

    case "$MODE" in
        macos) run_macos_flow ;;
        android) run_android_flow ;;
        keystore)
            begin_step "检查 Android 签名依赖"
            generate_keystore
            ;;
        check) print_dependency_status ;;
        self-test) run_self_test ;;
        *) fail "没有可执行的菜单选项。" ;;
    esac
}

main "$@"
