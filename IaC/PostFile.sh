#!/usr/bin/env bash
set -euo pipefail

# Upload exactly one file, preserving its original basename.
# Endpoint: https://<host>/CLI/post.php
# Field:    file
#
# Usage:
#   bash upload.sh file.example.com /absolute/path/to/file.txt
#   bash upload.sh https://file.example.com /absolute/path/to/file.txt
#
# Dependency: curl

# ---------- Args ----------
if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <host-or-url> </absolute/path/to/file>" >&2
  exit 1
fi

INPUT="$1"
SRC="$2"

# absolute path check
if [[ "${SRC}" != /* ]]; then
  echo "ERROR: The second argument must be an absolute file path (e.g., /path/to/file)." >&2
  exit 1
fi
# existence & readability
if [[ ! -f "$SRC" ]]; then
  echo "ERROR: File not found: $SRC" >&2
  exit 1
fi
if [[ ! -r "$SRC" ]]; then
  echo "ERROR: File is not readable: $SRC" >&2
  exit 1
fi

# ---------- Endpoint ----------
if [[ "$INPUT" =~ ^https?:// ]]; then
  HOST="$(echo "$INPUT" | sed -E 's#^https?://##; s#/.*$##')"
else
  HOST="$INPUT"
fi
ENDPOINT="https://${HOST}/CLI/post.php"

# ---------- Colored output ----------
if command -v tput >/dev/null 2>&1; then
  GREEN="$(tput setaf 2)"; RED="$(tput setaf 1)"; RESET="$(tput sgr0)"
else
  GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'
fi
g(){ echo "${GREEN}$*${RESET}"; }
e(){ echo "${RED}$*${RESET}"; }

BASENAME="$(basename -- "$SRC")"

g "[+] Upload endpoint : $ENDPOINT"
g "[+] Source file     : $SRC"
g "[+] Remote filename : $BASENAME (preserve original)"
echo

# ---------- Upload ----------
TMP_RESP="$(mktemp)"
trap 'rm -f "$TMP_RESP"' EXIT

# Note: no ;filename=... here. curl will use $BASENAME automatically.
HTTP_CODE="$(
  curl -sS -o "$TMP_RESP" -w '%{http_code}' \
    -F "file=@${SRC}" \
    "$ENDPOINT" || echo "000"
)"

if [[ "$HTTP_CODE" == "200" ]] && grep -q '"status"[[:space:]]*:[[:space:]]*"success"' "$TMP_RESP"; then
  g "[✓] OK (HTTP 200) — uploaded as: $BASENAME"
  exit 0
else
  e "[✗] FAILED (HTTP ${HTTP_CODE})"
  [[ -s "$TMP_RESP" ]] && echo "Response: $(cat "$TMP_RESP")"
  exit 1
fi
