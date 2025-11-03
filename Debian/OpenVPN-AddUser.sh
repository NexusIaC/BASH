#!/usr/bin/env bash
set -euo pipefail
umask 077

# Create one OpenVPN UDP client profile for OpenVPN-SSL setup using tls-crypt-v2.
# Usage:
#   bash create_client_profile_udp.sh <Username> [Auth]
#   - <Username>: required, client certificate CN
#   - [Auth]: optional, if "Auth" (case-insensitive), add 'auth-user-pass' to profile

CN="${1:-}"
if [ -z "$CN" ]; then
  echo "Usage: $0 <Username> [Auth]"
  exit 1
fi
# allow only safe characters
if ! [[ "$CN" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ERROR: Invalid username. Allowed: letters, digits, dot, underscore, dash."
  exit 1
fi

AUTH_MODE="${2:-}"
AUTH_FLAG=0
if printf '%s\n' "$AUTH_MODE" | grep -qiE '^auth$'; then
  AUTH_FLAG=1
fi

BASE="/root/OpenVPN-SSL"

# colored output
if command -v tput >/dev/null 2>&1; then
  GREEN="$(tput setaf 2)"; RESET="$(tput sgr0)"
else
  GREEN=$'\033[32m'; RESET=$'\033[0m'
fi
g(){ echo "${GREEN}$*${RESET}"; }

# prerequisites (no ta.key; keep PKI/CA)
[ -d "$BASE/pki" ] || { echo "ERROR: $BASE/pki not found. Run the server installer first."; exit 1; }
[ -f "$BASE/pki/ca.crt" ] || { echo "ERROR: Missing $BASE/pki/ca.crt"; exit 1; }

# locate easyrsa
if [ -x /usr/local/bin/easyrsa ]; then
  EASYRSA=/usr/local/bin/easyrsa
elif [ -x /usr/share/easy-rsa/easyrsa ]; then
  EASYRSA=/usr/share/easy-rsa/easyrsa
else
  echo "ERROR: easyrsa not found. apt install -y easy-rsa"
  exit 1
fi

# create/reuse client cert
CRT="$BASE/pki/issued/${CN}.crt"
KEY="$BASE/pki/private/${CN}.key"
if [ ! -f "$CRT" ] || [ ! -f "$KEY" ]; then
  g "[+] Creating client certificate: ${CN}"
  ( cd "$BASE" && "$EASYRSA" --batch build-client-full "$CN" nopass )
else
  g "[=] Client certificate exists: ${CN} (reusing)"
fi

# --------------- find UDP server conf & port & tc2 key ----------------
find_udp_server_conf() {
  local c
  # prefer conf that has 'proto udp*' AND 'tls-crypt-v2'
  for c in /etc/openvpn/server/*.conf; do
    [ -f "$c" ] || continue
    if awk 'tolower($1)=="proto" && $2 ~ /^udp/ {f=1} END{exit !f}' "$c"; then
      if awk 'tolower($1)=="tls-crypt-v2" {exit 0} END{exit 1}' "$c"; then
        echo "$c"; return 0
      fi
    fi
  done
  # otherwise any conf with 'proto udp*'
  for c in /etc/openvpn/server/*.conf; do
    [ -f "$c" ] || continue
    if awk 'tolower($1)=="proto" && $2 ~ /^udp/ {exit 0} END{exit 1}' "$c"; then
      echo "$c"; return 0
    fi
  done
  # final fallback to the canonical name
  [ -f /etc/openvpn/server/OpenVPN-SSL-UDP.conf ] && { echo /etc/openvpn/server/OpenVPN-SSL-UDP.conf; return 0; }
  return 1
}

SERVER_CONF="$(find_udp_server_conf)" || { echo "ERROR: Could not locate a UDP server .conf in /etc/openvpn/server/"; exit 1; }

# parse port from server conf; if missing, fall back to 443
PORT="$(awk '/^[[:space:]]*port[[:space:]]+[0-9]+/ {print $2; exit}' "$SERVER_CONF" || true)"
PORT="${PORT:-443}"

# parse tls-crypt-v2 server key path from that conf; else try common fallbacks
SERVER_TC2="$(awk '/^[[:space:]]*tls-crypt-v2[[:space:]]+/ {print $2; exit}' "$SERVER_CONF" || true)"
if [ -z "${SERVER_TC2:-}" ] || [ ! -f "$SERVER_TC2" ]; then
  for p in /etc/openvpn/*/tc2-server.key /etc/openvpn/tc2-server.key; do
    if [ -f "$p" ]; then SERVER_TC2="$p"; break; fi
  done
fi
[ -n "${SERVER_TC2:-}" ] && [ -f "$SERVER_TC2" ] || { echo "ERROR: Could not find server tls-crypt-v2 key (tc2-server.key)."; exit 1; }

# ---------------- generate per-client tls-crypt-v2 key (wrapped) ----------------
CLIENT_DIR="$BASE/client-configs/files"
mkdir -p "$CLIENT_DIR"; chmod 700 "$CLIENT_DIR"

TC2="$CLIENT_DIR/${CN}-tc2-client.key"
if [ ! -f "$TC2" ]; then
  openvpn --tls-crypt-v2 "$SERVER_TC2" --genkey tls-crypt-v2-client "$TC2"
  chmod 600 "$TC2"
fi

# ---------------- public IP ----------------
SERVER_IP="$(curl -s --fail https://ip.saelink.net/IP/ || true)"
if [ -z "$SERVER_IP" ]; then
  echo "ERROR: Unable to fetch public IP from https://ip.saelink.net/IP/"
  exit 1
fi

# ---------------- build a single UDP base config (ALWAYS REBUILD) ----------------
BASE_UDP="$BASE/client-configs/base-udp.conf"
: > "$BASE_UDP"
{
  printf "%s\n" "client"
  printf "%s\n" "dev tun"
  printf "%s\n" "proto udp"
  printf "%s\n" "remote ${SERVER_IP} ${PORT}"
  printf "%s\n" "resolv-retry infinite"
  printf "%s\n" "nobind"
  printf "%s\n" "persist-key"
  printf "%s\n" "persist-tun"
  printf "%s\n" "remote-cert-tls server"
  printf "%s\n" ""
  printf "%s\n" "tls-version-min 1.2"
  printf "%s\n" "tls-cert-profile preferred"
  printf "%s\n" ""
  printf "%s\n" "data-ciphers AES-256-GCM:CHACHA20-POLY1305"
  printf "%s\n" "data-ciphers-fallback AES-256-GCM"
  printf "%s\n" "verb 3"
} >> "$BASE_UDP"
chmod 600 "$BASE_UDP"

# sanity checks
for f in "$BASE/pki/ca.crt" "$CRT" "$KEY" "$BASE_UDP" "$TC2"; do
  [ -f "$f" ] || { echo "ERROR: Missing $f"; exit 1; }
done

# ---------------- output: only UDP profile ----------------
OUT_UDP="$CLIENT_DIR/${CN}-udp.ovpn"
{
  cat "$BASE_UDP"
  if [ "$AUTH_FLAG" -eq 1 ]; then
    printf "%s\n" "auth-user-pass"
  fi
  printf "%s\n" "<ca>";            cat "$BASE/pki/ca.crt";   printf "%s\n" "</ca>"
  printf "%s\n" "<cert>";          cat "$CRT";                printf "%s\n" "</cert>"
  printf "%s\n" "<key>";           cat "$KEY";                printf "%s\n" "</key>"
  printf "%s\n" "<tls-crypt-v2>";  cat "$TC2";                printf "%s\n" "</tls-crypt-v2>"
} > "$OUT_UDP"
chmod 600 "$OUT_UDP"

# —— 安全去重：若意外出现多行 auth-user-pass，仅保留首行 ——
if grep -qE '^[[:space:]]*auth-user-pass[[:space:]]*$' "$OUT_UDP"; then
  TMP="$(mktemp)"
  awk 'BEGIN{seen=0}
       { if ($0 ~ /^[[:space:]]*auth-user-pass[[:space:]]*$/) { if (seen==1) next; seen=1 } ; print }' \
       "$OUT_UDP" > "$TMP" && mv "$TMP" "$OUT_UDP"
  chmod 600 "$OUT_UDP"
fi

g "[✓] Generated UDP profile:"
g "    $OUT_UDP"
g "[=] Parsed from server conf: $(basename "$SERVER_CONF")  (port=${PORT})"
[ "$AUTH_FLAG" -eq 1 ] && g "[=] 'Auth' enabled: profile includes exactly one 'auth-user-pass'."
g "[=] tls-crypt-v2 in use (no ta.key)."
