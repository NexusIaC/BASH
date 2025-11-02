#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# OpenVPN-SSL 升级脚本（最小改动修复版）
#   1) TCP/443 + port-share 127.0.0.1:8443
#   2) UDP/443（独立实例）
# 复用 /root/OpenVPN-SSL PKI。修补：ip_forward、IPv6 条件推送、
# FORWARD 规则顺序、TCPMSS。
# =========================================================

SERVICE_TCP="OpenVPN-SSL"
SERVICE_UDP="OpenVPN-SSL-UDP"
BASE="/root/OpenVPN-SSL"
PORT=443

V4_TCP_NET="10.9.0.0"
V4_TCP_MASK="255.255.255.0"
V6_TCP_CIDR="fd00:beef:1234:5679::/64"

V4_UDP_NET="10.10.0.0"
V4_UDP_MASK="255.255.255.0"
V6_UDP_CIDR="fd00:beef:1234:5680::/64"

export DEBIAN_FRONTEND=noninteractive
umask 077

# 绿色输出
if command -v tput >/dev/null 2>&1; then
  GREEN="$(tput setaf 2)"; RESET="$(tput sgr0)"
else
  GREEN=$'\033[32m'; RESET=$'\033[0m'
fi
g(){ echo "${GREEN}$*${RESET}"; }

# -------------------- 安装依赖 --------------------
g "[+] 安装依赖（openvpn, easy-rsa, curl, iptables-persistent）..."
apt update
apt install -y openvpn easy-rsa curl iptables iptables-persistent >/dev/null
ln -sf /usr/share/easy-rsa/easyrsa /usr/local/bin/easyrsa || true

# -------------------- PKI/证书幂等 --------------------
[ -d "$BASE" ] || { g "[+] 创建 PKI 目录：$BASE"; make-cadir "$BASE"; }
cd "$BASE"
[ -d "$BASE/pki" ] || { g "[+] 初始化 PKI：$BASE/pki"; easyrsa init-pki; }

if [ ! -f pki/ca.crt ]; then
  g "[+] 生成 CA"; EASYRSA_BATCH=1 EASYRSA_REQ_CN="OpenVPN-SSL-CA" easyrsa --batch build-ca nopass
fi
[ -f pki/dh.pem ] || { g "[+] 生成 DH（可能耗时）"; easyrsa gen-dh; }
[ -f ta.key ] || { g "[+] 生成 tls-crypt 密钥"; openvpn --genkey secret ta.key; }
if [ ! -f "pki/issued/${SERVICE_TCP}-server.crt" ]; then
  g "[+] 生成服务端证书：${SERVICE_TCP}-server（TCP/UDP共用）"
  easyrsa --batch build-server-full "${SERVICE_TCP}-server" nopass
fi

# -------------------- 安装到 /etc/openvpn --------------------
CONF_TCP_DIR="/etc/openvpn/${SERVICE_TCP}"
CONF_UDP_DIR="/etc/openvpn/${SERVICE_UDP}"
install -d -m 700 "$CONF_TCP_DIR" "$CONF_UDP_DIR"

install -m 600 -D "$BASE/pki/ca.crt"                               "$CONF_TCP_DIR/ca.crt"
install -m 600 -D "$BASE/pki/issued/${SERVICE_TCP}-server.crt"     "$CONF_TCP_DIR/server.crt"
install -m 600 -D "$BASE/pki/private/${SERVICE_TCP}-server.key"    "$CONF_TCP_DIR/server.key"
install -m 600 -D "$BASE/pki/dh.pem"                               "$CONF_TCP_DIR/dh.pem"
install -m 600 -D "$BASE/ta.key"                                   "$CONF_TCP_DIR/ta.key"
ln -sfn "$CONF_TCP_DIR/ca.crt"     "$CONF_UDP_DIR/ca.crt"
ln -sfn "$CONF_TCP_DIR/server.crt" "$CONF_UDP_DIR/server.crt"
ln -sfn "$CONF_TCP_DIR/server.key" "$CONF_UDP_DIR/server.key"
ln -sfn "$CONF_TCP_DIR/dh.pem"     "$CONF_UDP_DIR/dh.pem"
ln -sfn "$CONF_TCP_DIR/ta.key"     "$CONF_UDP_DIR/ta.key"

mkdir -p /etc/openvpn/server /var/log/openvpn

# -------------------- 探测出口并判断 IPv6 能力 --------------------
OUT_IF="$(ip route get 8.8.8.8 | awk '{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1); exit}}}')"
OUT_IF6="$(ip -6 route show default | awk '{print $5; exit}' || true)"
ENABLE_V6=0
if [ -n "${OUT_IF6:-}" ] && ip6tables -t nat -L >/dev/null 2>&1; then
  ENABLE_V6=1
fi

# 生成 IPv6 段（仅当 ENABLE_V6=1 时写入）
if [ "$ENABLE_V6" -eq 1 ]; then
  V6_TCP_BLOCK="server-ipv6 ${V6_TCP_CIDR}"
  V6_UDP_BLOCK="server-ipv6 ${V6_UDP_CIDR}"
  V6_PUSH_BLOCK=$'push "route-ipv6 ::/0"\npush "dhcp-option DNS6 2606:4700:4700::1111"\npush "dhcp-option DNS6 2606:4700:4700::1001"'
else
  V6_TCP_BLOCK=""
  V6_UDP_BLOCK=""
  V6_PUSH_BLOCK=""
fi

# -------------------- server.conf（TCP/443 + port-share） --------------------
cat > "/etc/openvpn/server/${SERVICE_TCP}.conf" <<EOF
# Auto-generated TCP/443 with port-share
port ${PORT}
proto tcp-server
dev tun

server ${V4_TCP_NET} ${V4_TCP_MASK}
${V6_TCP_BLOCK}

ca ${CONF_TCP_DIR}/ca.crt
cert ${CONF_TCP_DIR}/server.crt
key ${CONF_TCP_DIR}/server.key
dh ${CONF_TCP_DIR}/dh.pem

topology subnet
ifconfig-pool-persist /var/log/openvpn/${SERVICE_TCP}-ipp.txt

# Default route
push "redirect-gateway def1 bypass-dhcp"
${V6_PUSH_BLOCK}

# DNS
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 1.0.0.1"

keepalive 10 180
persist-key
persist-tun

tls-crypt ${CONF_TCP_DIR}/ta.key
tls-version-min 1.2
tls-cert-profile preferred
;tls-version-min 1.3
;tls-ciphersuites TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256

data-ciphers AES-256-GCM:CHACHA20-POLY1305
data-ciphers-fallback AES-256-GCM
ncp-ciphers AES-256-GCM:CHACHA20-POLY1305

allow-compression no

# 非-OpenVPN TLS/HTTPS 共端口
port-share 127.0.0.1 8443

user nobody
group nogroup
verb 3
status /var/log/openvpn/${SERVICE_TCP}-status.log
# explicit-exit-notify 仅用于 UDP
EOF

ln -sfn "/etc/openvpn/server/${SERVICE_TCP}.conf" "/etc/openvpn/${SERVICE_TCP}.conf" || true

# -------------------- server.conf（UDP/443） --------------------
cat > "/etc/openvpn/server/${SERVICE_UDP}.conf" <<EOF
# Auto-generated UDP/443
port ${PORT}
proto udp
dev tun

server ${V4_UDP_NET} ${V4_UDP_MASK}
${V6_UDP_BLOCK}

ca ${CONF_UDP_DIR}/ca.crt
cert ${CONF_UDP_DIR}/server.crt
key ${CONF_UDP_DIR}/server.key
dh ${CONF_UDP_DIR}/dh.pem

topology subnet
ifconfig-pool-persist /var/log/openvpn/${SERVICE_UDP}-ipp.txt

# Default route
push "redirect-gateway def1 bypass-dhcp"
${V6_PUSH_BLOCK}

# DNS
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 1.0.0.1"

keepalive 10 120
persist-key
persist-tun

tls-crypt ${CONF_UDP_DIR}/ta.key
tls-version-min 1.2
tls-cert-profile preferred

data-ciphers AES-256-GCM:CHACHA20-POLY1305
data-ciphers-fallback AES-256-GCM
ncp-ciphers AES-256-GCM:CHACHA20-POLY1305

allow-compression no

user nobody
group nogroup
verb 3
status /var/log/openvpn/${SERVICE_UDP}-status.log
explicit-exit-notify 1
EOF

ln -sfn "/etc/openvpn/server/${SERVICE_UDP}.conf" "/etc/openvpn/${SERVICE_UDP}.conf" || true

# -------------------- 内核转发（覆盖式） --------------------
install -m 644 /dev/stdin /etc/sysctl.d/99-openvpn-forward.conf <<SYSCTL
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = ${ENABLE_V6}
net.ipv6.conf.default.forwarding = ${ENABLE_V6}
SYSCTL
sysctl --system >/dev/null

# -------------------- 防火墙/NAT（两子网） --------------------
# IPv4：把 FORWARD 规则插到链首，并加 MSS clamp
for CIDR in "${V4_TCP_NET}/24" "${V4_UDP_NET}/24"; do
  iptables -C FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
  iptables -I FORWARD 1 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  iptables -C FORWARD -s "$CIDR" -j ACCEPT 2>/dev/null || \
  iptables -I FORWARD 2 -s "$CIDR" -j ACCEPT
done
# MSS clamp（避免 PMTU 问题）
iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
iptables -t mangle -I FORWARD 1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# NAT 仍使用默认外网口
for CIDR in "${V4_TCP_NET}/24" "${V4_UDP_NET}/24"; do
  iptables -t nat -C POSTROUTING -s "$CIDR" -o "$OUT_IF" -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -s "$CIDR" -o "$OUT_IF" -j MASQUERADE
endone=1
done

# IPv6：仅当有默认 IPv6 路由且系统支持 nat 表
if [ "$ENABLE_V6" -eq 1 ]; then
  for V6CIDR in "$V6_TCP_CIDR" "$V6_UDP_CIDR"; do
    ip6tables -C FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    ip6tables -I FORWARD 1 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    ip6tables -C FORWARD -s "$V6CIDR" -j ACCEPT 2>/dev/null || \
    ip6tables -I FORWARD 2 -s "$V6CIDR" -j ACCEPT
  done
  ip6tables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
  ip6tables -t mangle -I FORWARD 1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

  if [ -n "${OUT_IF6:-}" ] && ip6tables -t nat -L >/dev/null 2>&1; then
    for V6CIDR in "$V6_TCP_CIDR" "$V6_UDP_CIDR"; do
      ip6tables -t nat -C POSTROUTING -s "$V6CIDR" -o "$OUT_IF6" -j MASQUERADE 2>/dev/null || \
      ip6tables -t nat -A POSTROUTING -s "$V6CIDR" -o "$OUT_IF6" -j MASQUERADE
    done
  fi
fi

# 持久化
netfilter-persistent save >/dev/null

# -------------------- 启动/启用服务 --------------------
tcp_unit=""
udp_unit=""
if systemctl list-unit-files | grep -q '^openvpn-server@\.service'; then
  tcp_unit="openvpn-server@${SERVICE_TCP}"
  udp_unit="openvpn-server@${SERVICE_UDP}"
else
  tcp_unit="openvpn@${SERVICE_TCP}"
  udp_unit="openvpn@${SERVICE_UDP}"
fi

# 如果 443/TCP 被占用（如 nginx），跳过启动 TCP 实例，仅提示如何使用 port-share
if ss -tlnp 2>/dev/null | grep -qE '(:|])443\b'; then
  g "[!] 检测到 TCP/443 已被占用。已部署 ${SERVICE_TCP} 配置，但未启动。"
  g "    若要与 HTTPS 共端口，请将 Web 服务器改绑到 8443，然后启用 'port-share'（已在配置中）。"
else
  systemctl enable "$tcp_unit" >/dev/null
  systemctl restart "$tcp_unit"
  g "[✓] TCP/443 实例已启动：$tcp_unit"
fi

# UDP/443 一般不冲突，直接启用
systemctl enable "$udp_unit" >/dev/null
systemctl restart "$udp_unit"
g "[✓] UDP/443 实例已启动：$udp_unit"

# -------------------- 生成/补齐客户端配置（TCP/UDP 两套） --------------------
CLIENT_DIR="$BASE/client-configs/files"
mkdir -p "$CLIENT_DIR"
chmod 700 "$CLIENT_DIR"

SERVER_IP="$(curl -s --fail https://ip.saelink.net/IP/ || true)"
if [ -z "$SERVER_IP" ]; then
  echo "ERROR: 无法获取公网 IP（https://ip.saelink.net/IP/）。" >&2
  SERVER_IP="YOUR_PUBLIC_IP"
fi

BASE_TCP="$BASE/client-configs/base-tcp.conf"
BASE_UDP="$BASE/client-configs/base-udp.conf"

cat > "$BASE_TCP" <<EOF
client
dev tun
proto tcp-client
remote ${SERVER_IP} ${PORT}
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server

tls-version-min 1.2
tls-cert-profile preferred

data-ciphers AES-256-GCM:CHACHA20-POLY1305
data-ciphers-fallback AES-256-GCM
ncp-ciphers AES-256-GCM:CHACHA20-POLY1305

verb 3
EOF

cat > "$BASE_UDP" <<EOF
client
dev tun
proto udp
remote ${SERVER_IP} ${PORT}
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server

tls-version-min 1.2
tls-cert-profile preferred

data-ciphers AES-256-GCM:CHACHA20-POLY1305
data-ciphers-fallback AES-256-GCM
ncp-ciphers AES-256-GCM:CHACHA20-POLY1305

verb 3
EOF

gen_profiles() {
  local CN="$1"
  local KEY="$BASE/pki/private/${CN}.key"
  local CRT="$BASE/pki/issued/${CN}.crt"
  [ -f "$KEY" ] && [ -f "$CRT" ] || return 0
  local OUT_TCP="$CLIENT_DIR/${CN}-tcp.ovpn"
  local OUT_UDP="$CLIENT_DIR/${CN}-udp.ovpn"

  {
    cat "$BASE_TCP"
    echo "<ca>";  cat "$BASE/pki/ca.crt"; echo "</ca>"
    echo "<cert>";cat "$CRT";             echo "</cert>"
    echo "<key>"; cat "$KEY";             echo "</key>"
    echo "<tls-crypt>"; cat "$BASE/ta.key"; echo "</tls-crypt>"
  } > "$OUT_TCP"; chmod 600 "$OUT_TCP"

  {
    cat "$BASE_UDP"
    echo "<ca>";  cat "$BASE/pki/ca.crt"; echo "</ca>"
    echo "<cert>";cat "$CRT";             echo "</cert>"
    echo "<key>"; cat "$KEY";             echo "</key>"
    echo "<tls-crypt>"; cat "$BASE/ta.key"; echo "</tls-crypt>"
  } > "$OUT_UDP"; chmod 600 "$OUT_UDP"

  g "    生成：$OUT_TCP"
  g "    生成：$OUT_UDP"
}

g "[+] 为所有已存在的客户端证书生成 TCP/UDP 配置："
shopt -s nullglob
for crt in "$BASE/pki/issued/"*.crt; do
  CN="$(basename "$crt" .crt)"
  [[ "$CN" == *server* ]] && continue
  [[ "$CN" == "server" ]] && continue
  gen_profiles "$CN"
done
shopt -u nullglob

g "[✓] 完成。客户端文件目录：$CLIENT_DIR"

if ss -tlnp 2>/dev/null | grep -qiE '(:|])443\b.*(nginx|apache|caddy)'; then
  g "[!] 检测到 Web 服务在 443。若要共端口：将 Web 改到 8443，保持已配置的 'port-share 127.0.0.1 8443'，再启动 ${tcp_unit:-openvpn-server@${SERVICE_TCP}}。"
fi

g "[提示] 本版按需启用 IPv6；无默认 IPv6 路由时不推送 ::/0，避免客户端黑洞。"
