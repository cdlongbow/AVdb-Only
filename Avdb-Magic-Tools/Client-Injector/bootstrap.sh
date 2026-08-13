#!/usr/bin/env bash

# Downloads the verified Avdb Magic Tools injector and its matching Loader,
# then hands the interactive session to the injector.

set -Eeuo pipefail
umask 077

RAW_BASE="${AVDB_RAW_BASE:-https://raw.githubusercontent.com/li-peifeng/AVdb-Only/refs/heads/main/Avdb-Magic-Tools/Client-Injector}"
WORK_ROOT="${AVDB_MAGIC_TOOLS_HOME:-$HOME/AvdbMagicTools}"
BOOTSTRAP_DIR="$WORK_ROOT/bootstrap"
ARCHIVE_DIR="$BOOTSTRAP_DIR/archive"
RUN_ID="$(date '+%Y%m%d-%H%M%S')-$$"
INJECTOR_NAME="avdb-magic-tools-injector.sh"
LOADER_NAME="AvdbMagicTools.js"
INJECTOR_SHA256="77f2cc29bd7635b91a6807a105d07771892625de6b8d7d3bd0667c1815e5b6c4"
LOADER_SHA256="97e501d110e3060ed57e1f84314e1ac5eddc9ec98440b0c73c762d28dc52c4c0"

fail() {
    printf '[失败] %s\n' "$1" >&2
    exit 1
}

sha256_file() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        fail '缺少 shasum 或 sha256sum，无法验证下载文件。'
    fi
}

download_verified() {
    local name="$1"
    local expected="$2"
    local destination="$BOOTSTRAP_DIR/$name"
    local temporary="$BOOTSTRAP_DIR/$name.$RUN_ID.part"
    local actual=""

    printf '[下载] %s\n' "$name"
    curl -fL --retry 3 --connect-timeout 20 \
        "$RAW_BASE/$name?cacheBust=$RUN_ID" -o "$temporary"
    actual="$(sha256_file "$temporary")"
    [ "$actual" = "$expected" ] \
        || fail "$name SHA-256 不匹配；期望 $expected，实际 $actual"

    if [ -f "$destination" ]; then
        cp "$destination" "$ARCHIVE_DIR/$name.before-$RUN_ID"
    fi
    mv "$temporary" "$destination"
    printf '[ Ok ] %s SHA-256 校验通过\n' "$name"
}

command -v curl >/dev/null 2>&1 || fail '缺少 curl，无法下载自动化脚本。'
mkdir -p "$BOOTSTRAP_DIR" "$ARCHIVE_DIR"

download_verified "$INJECTOR_NAME" "$INJECTOR_SHA256"
download_verified "$LOADER_NAME" "$LOADER_SHA256"
chmod 755 "$BOOTSTRAP_DIR/$INJECTOR_NAME"
chmod 644 "$BOOTSTRAP_DIR/$LOADER_NAME"

printf '\n[ Ok ] 文件已保存到 %s\n\n' "$BOOTSTRAP_DIR"

if [ "${AVDB_BOOTSTRAP_NO_TTY:-0}" != "1" ] && [ -t 1 ] && [ -r /dev/tty ]; then
    exec bash "$BOOTSTRAP_DIR/$INJECTOR_NAME" "$@" </dev/tty
fi
exec bash "$BOOTSTRAP_DIR/$INJECTOR_NAME" "$@"
