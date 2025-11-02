#!/usr/bin/env bash
set -euo pipefail

# Create two OpenVPN client profiles (TCP/443 & UDP/443) for existing OpenVPN-SSL setup.
# Usage: bash create_client_dual_profiles.sh <Username>

CN="${1:-}"
if [ -z "$CN" ]; then
  echo "Usage: $0 <Username>"
  exit 1
fi
# 仅允许常见安全字符
if ! [[ "$CN" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ERROR: Invalid username. Allowed: letters, digits, dot, underscore, dash."
  exit 1
fi

BASE="/root/OpenVPN-SSL"
PORT=443

# 绿色输出
if command -v tput >/dev/null 2>&1; then
  GREEN="$(tput setaf 2)"; RESET="$(tput sgr0)"
else
  GREEN=$'\033[32m'; RESET=$'\033[0m'
fi
g(){ echo "${GREEN}$*${RESET}"; }

# 基础环境校验
[ -d "$BASE/pki" ] || { echo "ERROR: $BASE/pki not found. Please run the TCP/443 installer first."; exit 1; }
for need in "$BASE/pki/ca.crt" "$BASE/ta.key"; do
  [ -f "$need" ] || { echo "ERROR: Missing $need"; exit 1; }
done

# 定位 easyrsa
if [ -x /usr/local/bin/easyrsa ]; then
  EASYRSA=/usr/local/bin/easyrsa
elif [ -x /usr/share/easy-rsa/easyrsa ]; then
  EASYRSA=/usr/share/easy-rsa/easyrsa
else
  echo "ERROR: easyrsa not found. apt install -y easy-rsa"
  exit 1
fi

# 生成/复用客户端证书
CRT="$BASE/pki/issued/${CN}.crt"
KEY="$BASE/pki/private/${CN}.key"
if [ ! -f "$CRT" ] || [ ! -f "$KEY" ]; then
  g "[+] Creating client certificate: ${CN}"
  ( cd "$BASE" && "$EASYRSA" --batch build-client-full "$CN" nopass )
else
  g "[=] Client certificate exists: ${CN} (reusing)"
fi

# 准备客户端目录
CLIENT_DIR="$BASE/client-configs/files"
mkdir -p "$CLIENT_DIR"
chmod 700 "$CLIENT_DIR"

# 获取（或复用）公网 IP
SERVER_IP="$(curl -s --fail https://ip.saelink.net/IP/ || true)"
if [ -z "$SERVER_IP" ]; then
  echo "ERROR: Unable to fetch public IP from https://ip.saelink.net/IP/"
  exit 1
fi

# 生成/复用 base-tcp.conf 与 base-udp.conf（用 printf 避免 heredoc 粘贴问题）
BASE_TCP="$BASE/client-configs/base-tcp.conf"
BASE_UDP="$BASE/client-configs/base-udp.conf"

make_base_tcp() {
  : > "$BASE_TCP"
  {
    printf "%s\n" "client"
    printf "%s\n" "dev tun"
    printf "%s\n" "proto tcp-client"
    printf "%s\n" "remote ${SERVER_IP} ${PORT}"
    printf "%s\n" "resolv-retry infinite"
    printf "%s\n" "nobind"
    printf "%s\n" "persist-key"
    printf "%s\n" "persist-tun"
    printf "%s\n" "remote-cert-tls server"
    printf "%s\n" ""
    printf "%s\n" "tls-version-min 1.2"
    printf "%s\n" "tls-cert-profile preferred"
    printf "%s\n" ";tls-version-min 1.3"
    printf "%s\n" ";tls-ciphersuites TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256"
    printf "%s\n" ""
    printf "%s\n" "data-ciphers AES-256-GCM:CHACHA20-POLY1305"
    printf "%s\n" "data-ciphers-fallback AES-256-GCM"
    printf "%s\n" "ncp-ciphers AES-256-GCM:CHACHA20-POLY1305"
    printf "%s\n" ";cipher AES-256-CBC"
    printf "%s\n" ";auth SHA256"
    printf "%s\n" ""
    printf "%s\n" "verb 3"
  } >> "$BASE_TCP"
}

make_base_udp() {
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
    printf "%s\n" ";tls-version-min 1.3"
    printf "%s\n" ";tls-ciphersuites TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256"
    printf "%s\n" ""
    printf "%s\n" "data-ciphers AES-256-GCM:CHACHA20-POLY1305"
    printf "%s\n" "data-ciphers-fallback AES-256-GCM"
    printf "%s\n" "ncp-ciphers AES-256-GCM:CHACHA20-POLY1305"
    printf "%s\n" ";cipher AES-256-CBC"
    printf "%s\n" ";auth SHA256"
    printf "%s\n" ""
    printf "%s\n" "verb 3"
  } >> "$BASE_UDP"
}

# 若不存在则创建；若存在则复用（如需强制刷新，可手动删除再运行）
[ -f "$BASE_TCP" ] || make_base_tcp
[ -f "$BASE_UDP" ] || make_base_udp

# 关键文件校验
for f in "$BASE/pki/ca.crt" "$CRT" "$KEY" "$BASE/ta.key" "$BASE_TCP" "$BASE_UDP"; do
  [ -f "$f" ] || { echo "ERROR: Missing $f"; exit 1; }
done

# 生成两份内联配置
OUT_TCP="$CLIENT_DIR/${CN}-tcp.ovpn"
OUT_UDP="$CLIENT_DIR/${CN}-udp.ovpn"

# TCP
{
  cat "$BASE_TCP"
  printf "%s\n" "<ca>";        cat "$BASE/pki/ca.crt";             printf "%s\n" "</ca>"
  printf "%s\n" "<cert>";      cat "$CRT";                          printf "%s\n" "</cert>"
  printf "%s\n" "<key>";       cat "$KEY";                          printf "%s\n" "</key>"
  printf "%s\n" "<tls-crypt>"; cat "$BASE/ta.key";                  printf "%s\n" "</tls-crypt>"
} > "$OUT_TCP"
chmod 600 "$OUT_TCP"

# UDP
{
  cat "$BASE_UDP"
  printf "%s\n" "<ca>";        cat "$BASE/pki/ca.crt";             printf "%s\n" "</ca>"
  printf "%s\n" "<cert>";      cat "$CRT";                          printf "%s\n" "</cert>"
  printf "%s\n" "<key>";       cat "$KEY";                          printf "%s\n" "</key>"
  printf "%s\n" "<tls-crypt>"; cat "$BASE/ta.key";                  printf "%s\n" "</tls-crypt>"
} > "$OUT_UDP"
chmod 600 "$OUT_UDP"

g "[✓] Generated:"
g "    $OUT_TCP"
g "    $OUT_UDP"
g "[=] No server changes were made. Instance uses TCP/UDP 443."
g "[提示] 若系统中有 nginx 绑定 443，且你希望与 OpenVPN 共端口，请将 nginx 改绑到 8443 并使用 port-share。"
