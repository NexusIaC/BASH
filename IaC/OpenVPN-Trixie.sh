#!/usr/bin/env bash
set -euo pipefail

# ——————————————————————————————————————————————————————————————————
# 非交互式部署配置：CA 名称与批处理模式
CA_NAME="Ragdoll-AS"
export EASYRSA_BATCH=1
export EASYRSA_REQ_CN="${CA_NAME}"
umask 077
# ——————————————————————————————————————————————————————————————————

# 随机端口号（30000–65000 之间）
PORT=$(shuf -i 30000-65000 -n 1)

# 0. 客户端列表（需要唯一证书的客户端）
CLIENTS=(CUBE CUBE01 CUBE02 CUBE03)

# 1. 更新并安装依赖
export DEBIAN_FRONTEND=noninteractive
apt update
apt upgrade -y
apt install -y openvpn easy-rsa curl iptables iptables-persistent

# 2. 初始化 Easy-RSA
if [ ! -d "$HOME/openvpn-ca" ]; then
  make-cadir "$HOME/openvpn-ca"
fi
cd "$HOME/openvpn-ca"
ln -sf /usr/share/easy-rsa/easyrsa /usr/local/bin/easyrsa || true
openvpn --version || true
easyrsa --version

# 3. 生成 PKI、DH、TLS-Crypt 密钥、证书
if [ ! -d pki ]; then
  easyrsa init-pki
fi

# 3.1 非交互生成 CA（使用 CA_NAME）
if [ ! -f pki/ca.crt ]; then
  easyrsa --batch build-ca nopass
fi
unset EASYRSA_REQ_CN

# DH 参数（可能较慢）
if [ ! -f pki/dh.pem ]; then
  easyrsa gen-dh
fi

# 生成 tls-crypt 密钥
if [ ! -f ta.key ]; then
  openvpn --genkey secret ta.key
fi

# 服务端证书
if [ ! -f pki/issued/server.crt ]; then
  easyrsa --batch build-server-full server nopass
fi

# 4 个客户端证书（每个客户端唯一）
for CN in "${CLIENTS[@]}"; do
  if [ ! -f "pki/issued/${CN}.crt" ]; then
    easyrsa --batch build-client-full "${CN}" nopass
  fi
done

# 4. 验证文件
test -f pki/ca.crt
test -f pki/dh.pem
test -f ta.key
test -f pki/issued/server.crt
test -f pki/private/server.key
for CN in "${CLIENTS[@]}"; do
  test -f "pki/issued/${CN}.crt"
  test -f "pki/private/${CN}.key"
done

# 5. 复制到 /etc/openvpn（设置严格权限）
install -Dm600 pki/ca.crt                /etc/openvpn/ca.crt
install -Dm600 pki/issued/server.crt     /etc/openvpn/server.crt
install -Dm600 pki/private/server.key    /etc/openvpn/server.key
install -Dm600 pki/dh.pem                /etc/openvpn/dh.pem
install -Dm600 ta.key                    /etc/openvpn/ta.key

# 6. server.conf（启用 tls-crypt，并支持 IPv6）
echo "PORT=$PORT" > /etc/openvpn/port.env
mkdir -p /etc/openvpn/server
cat <<'EOF' >/etc/openvpn/server/server.conf
# 该文件由安装脚本生成
port __PORT__
proto udp
dev tun

# IPv4 子网
server 10.8.0.0 255.255.255.0
# IPv6 ULA 子网（如无 IPv6，可保留不影响）
server-ipv6 fd00:beef:1234:5678::/64

ca /etc/openvpn/ca.crt
cert /etc/openvpn/server.crt
key /etc/openvpn/server.key
dh /etc/openvpn/dh.pem

topology subnet
ifconfig-pool-persist /var/log/openvpn/ipp.txt

# 劫持所有 IPv4 和 IPv6 流量
push "redirect-gateway def1 bypass-dhcp"
push "route-ipv6 ::/0"

# 推送 DNS
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 1.0.0.1"
push "dhcp-option DNS6 2606:4700:4700::1111"
push "dhcp-option DNS6 2606:4700:4700::1001"

keepalive 10 120
persist-key
persist-tun

tls-crypt /etc/openvpn/ta.key

# 加密/认证（保持与客户端一致）
cipher AES-256-CBC
auth SHA256
compress lz4-v2

user nobody
group nogroup
verb 3
status /var/log/openvpn/openvpn-status.log
explicit-exit-notify 1
EOF

# 替换端口并兼容旧式路径
sed -i "s/__PORT__/${PORT}/g" /etc/openvpn/server/server.conf
ln -sfn /etc/openvpn/server/server.conf /etc/openvpn/server.conf

# 7. 打开内核转发
if ! grep -q "net.ipv4.ip_forward" /etc/sysctl.conf; then
  cat <<EOF >> /etc/sysctl.conf
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
EOF
fi
sysctl -p

# 8. 防火墙 NAT 与转发（IPv4 & IPv6）
OUT_IF=$(ip route get 8.8.8.8 | awk '{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1); exit}}}')
# IPv4 NAT
iptables -t nat -C POSTROUTING -s 10.8.0.0/24 -o "$OUT_IF" -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o "$OUT_IF" -j MASQUERADE

# IPv6 NAT & 转发（若有默认 IPv6 路由且内核支持 nat 表）
OUT_IF6=$(ip -6 route show default | awk '{print $5; exit}' || true)
if [ -n "${OUT_IF6:-}" ] && ip6tables -t nat -L >/dev/null 2>&1; then
  ip6tables -t nat -C POSTROUTING -s fd00:beef:1234:5678::/64 -o "$OUT_IF6" -j MASQUERADE 2>/dev/null || \
  ip6tables -t nat -A POSTROUTING -s fd00:beef:1234:5678::/64 -o "$OUT_IF6" -j MASQUERADE
  ip6tables -C FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
  ip6tables -A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
  ip6tables -C FORWARD -s fd00:beef:1234:5678::/64 -j ACCEPT 2>/dev/null || \
  ip6tables -A FORWARD -s fd00:beef:1234:5678::/64 -j ACCEPT
fi

# 转发规则（IPv4）
iptables -C FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
iptables -A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -C FORWARD -s 10.8.0.0/24 -j ACCEPT 2>/dev/null || \
iptables -A FORWARD -s 10.8.0.0/24 -j ACCEPT

# 持久化规则
netfilter-persistent save

# 9. 启动服务（兼容两种 systemd 单元）
if systemctl list-unit-files | grep -q '^openvpn-server@\.service'; then
  systemctl enable openvpn-server@server
  systemctl restart openvpn-server@server
else
  systemctl enable openvpn@server
  systemctl restart openvpn@server
fi

# 10. 客户端目录与基础配置（公网 IP 保持你的自有服务）
mkdir -p "$HOME/openvpn-ca/client-configs/files"
chmod 700 "$HOME/openvpn-ca/client-configs/files"

source /etc/openvpn/port.env
SERVER_IP=$(curl -s --fail https://ip.saelink.net/IP/)
if [ -z "${SERVER_IP:-}" ]; then
  echo "ERROR: 无法获取公网 IP 地址。" >&2
  exit 1
fi

OUTPUT_FILE="$HOME/openvpn-ca/client-configs/base.conf"
mkdir -p "$(dirname "$OUTPUT_FILE")"
cat > "$OUTPUT_FILE" <<EOF
client
dev tun
proto udp
pull
remote ${SERVER_IP} ${PORT}
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server

cipher AES-256-CBC
auth SHA256
compress lz4-v2
verb 3
EOF
echo "已生成基础配置：$OUTPUT_FILE (remote ${SERVER_IP}:${PORT})"

# 11. 生成 make_config.sh 并创建 4 个 .ovpn（内联 tls-crypt）
cat > "$HOME/openvpn-ca/client-configs/make_config.sh" << 'EOM'
#!/usr/bin/env bash
set -euo pipefail
BASE="$HOME/openvpn-ca"
KEY_DIR="$BASE/pki/private"
OUTPUT_DIR="$BASE/client-configs/files"
BASE_CONFIG="$BASE/client-configs/base.conf"

if [ -z "${1:-}" ]; then
  echo "Usage: $0 <client-name>"
  exit 1
fi
CLIENT_NAME="$1"

# 基本存在性检查
for f in "$BASE_CONFIG" "$BASE/pki/ca.crt" "$BASE/pki/issued/${CLIENT_NAME}.crt" "$KEY_DIR/${CLIENT_NAME}.key" "$BASE/ta.key"; do
  if [ ! -f "$f" ]; then
    echo "Missing file: $f" >&2
    exit 1
  fi
done

mkdir -p "$OUTPUT_DIR"

# 生成内联 ovpn
cat "$BASE_CONFIG" \
  <(echo '<ca>') \
  "$BASE/pki/ca.crt" \
  <(echo '</ca>') \
  <(echo '<cert>') \
  "$BASE/pki/issued/${CLIENT_NAME}.crt" \
  <(echo '</cert>') \
  <(echo '<key>') \
  "$KEY_DIR/${CLIENT_NAME}.key" \
  <(echo '</key>') \
  <(echo '<tls-crypt>') \
  "$BASE/ta.key" \
  <(echo '</tls-crypt>') \
  > "$OUTPUT_DIR/${CLIENT_NAME}.ovpn"

chmod 600 "$OUTPUT_DIR/${CLIENT_NAME}.ovpn"
echo "Client configuration generated: $OUTPUT_DIR/${CLIENT_NAME}.ovpn"
EOM

chmod +x "$HOME/openvpn-ca/client-configs/make_config.sh"

# 为每个客户端生成 .ovpn
for CN in "${CLIENTS[@]}"; do
  "$HOME/openvpn-ca/client-configs/make_config.sh" "$CN"
done

# 12. 输出结果路径
echo "四个客户端配置文件已生成："
for CN in "${CLIENTS[@]}"; do
  echo " - $HOME/openvpn-ca/client-configs/files/${CN}.ovpn"
done
