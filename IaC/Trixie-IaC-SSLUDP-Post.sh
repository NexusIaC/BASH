#!/usr/bin/env bash
set -euo pipefail

# 上传 /root/OpenVPN-SSL/client-configs/files/ 中的所有文件到指定站点：
#   目标接口固定为：https://<host>/CLI/post.php
#   表单字段名：file  （与 post.php 保持一致）
#   上传时重命名为：<hostname>-<YYYYMMDD>-<original_name>
#
# 用法：
#   bash upload.sh file.formulax.work
#   （也可传入带协议的完整形式，如 https://file.formulax.work ；脚本会规范化）
#
# 依赖：curl

# ---------- 参数解析与端点构造 ----------
if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <host-or-url>"
  echo "Example: $0 file.domain.work"
  exit 1
fi

INPUT="$1"
# 若传入带 http/https，剥去协议与路径，仅保留主机名
if [[ "$INPUT" =~ ^https?:// ]]; then
  HOST="$(echo "$INPUT" | sed -E 's#^https?://##; s#/.*$##')"
else
  HOST="$INPUT"
fi
ENDPOINT="https://${HOST}/CLI/post.php"

# ---------- 颜色输出 ----------
if command -v tput >/dev/null 2>&1; then
  GREEN="$(tput setaf 2)"; RED="$(tput setaf 1)"; YELLOW="$(tput setaf 3)"; RESET="$(tput sgr0)"
else
  GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
fi
g(){ echo "${GREEN}$*${RESET}"; }
w(){ echo "${YELLOW}$*${RESET}"; }
e(){ echo "${RED}$*${RESET}"; }

# ---------- 前置检查 ----------
DIR="/root/OpenVPN-SSL/client-configs/files"
[[ -d "$DIR" ]] || { e "ERROR: Directory not found: $DIR"; exit 1; }

if ! command -v curl >/dev/null 2>&1; then
  e "ERROR: curl not found. Install it with: apt update && apt install -y curl"
  exit 1
fi

HOSTNAME_RAW="$(cat /etc/hostname 2>/dev/null || hostname)"
# 安全化主机名（仅保留字母/数字/点/下划线/连字符）
HOSTNAME_SAFE="$(echo -n "$HOSTNAME_RAW" | tr -cd 'A-Za-z0-9._-')"
[[ -n "$HOSTNAME_SAFE" ]] || HOSTNAME_SAFE="host"

STAMP="$(date +%Y%m%d)"  # 按示例使用 YYYYMMDD

# ---------- 列出待上传文件 ----------
shopt -s nullglob
FILES=( "$DIR"/* )
shopt -u nullglob
if [[ ${#FILES[@]} -eq 0 ]]; then
  w "No files found in $DIR — nothing to upload."
  exit 0
fi

g "[+] Upload endpoint : $ENDPOINT"
g "[+] Hostname prefix : $HOSTNAME_SAFE"
g "[+] Date stamp      : $STAMP"
g "[+] Source dir      : $DIR"
echo

# ---------- 逐个上传 ----------
ALL_OK=1
for SRC in "${FILES[@]}"; do
  [[ -f "$SRC" ]] || continue
  BASENAME="$(basename "$SRC")"
  REMOTE_NAME="${HOSTNAME_SAFE}-${STAMP}-${BASENAME}"

  g "[>] Uploading: $BASENAME  →  $REMOTE_NAME"

  # 说明：使用 -F 'file=@...;filename=REMOTE_NAME' 与你的 post.php 完全匹配（字段名为 file）
  TMP_RESP="$(mktemp)"
  HTTP_CODE="$(
    curl -sS -o "$TMP_RESP" -w '%{http_code}' \
      -F "file=@${SRC};filename=${REMOTE_NAME}" \
      "$ENDPOINT" || echo "000"
  )"

  if [[ "$HTTP_CODE" == "200" ]] && grep -q '"status"[[:space:]]*:[[:space:]]*"success"' "$TMP_RESP"; then
    g "    OK (HTTP 200) — uploaded as: $REMOTE_NAME"
  else
    ALL_OK=0
    e "    FAILED (HTTP ${HTTP_CODE})"
    if [[ -s "$TMP_RESP" ]]; then
      echo "    Response: $(cat "$TMP_RESP")"
    fi
  fi
  rm -f "$TMP_RESP"
done

echo
if [[ "$ALL_OK" -eq 1 ]]; then
  g "[✓] All files uploaded successfully."
else
  w "[!] Some uploads failed. See messages above."
fi
