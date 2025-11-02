
#!/usr/bin/env bash
set -euo pipefail

# ——————————————————————————————————————————————————————————————————
# 非交互式部署配置：CA 名称与批处理模式
CA_NAME="Ragdoll-AS"
export EASYRSA_BATCH=1
export EASYRSA_REQ_CN="${CA_NAME}"
# ——————————————————————————————————————————————————————————————————

# 随机端口号（30000–65000 之间）
PORT=$(shuf -i 30000-65000 -n 1)

# 1. 更新并安装依赖（增加 curl）
apt update
apt upgrade -y
apt install -y openvpn easy-rsa curl iptables

# 2. 初始化 Easy-RSA
make-cadir ~/openvpn-ca
cd ~/openvpn-ca
ln -s /usr/share/easy-rsa/easyrsa /usr/local/bin/easyrsa
openvpn --version
easyrsa --version

# 3. 生成 PKI、DH、TLS-Crypt 密钥、证书
easyrsa init-pki

# 3.1 非交互生成 CA（使用 CA_NAME），完成后移除外部 CN 设置
easyrsa --batch build-ca nopass
unset EASYRSA_REQ_CN

easyrsa gen-dh

# 使用新版语法生成 tls-crypt 密钥
openvpn --genkey secret ta.key

# 非交互生成服务端与客户端证书
easyrsa --batch build-server-full server nopass
easyrsa --batch build-client-full CUBE nopass

# 4. 验证文件
ls pki/ca.crt
ls pki/dh.pem
ls ta.key
ls pki/issued/server.crt
ls pki/private/server.key
ls pki/issued/CUBE.crt
ls pki/private/CUBE.key

# 5. 复制到 /etc/openvpn
cp pki/ca.crt /etc/openvpn/ca.crt
cp pki/issued/server.crt /etc/openvpn/server.crt
cp pki/private/server.key /etc/openvpn/server.key
cp pki/dh.pem /etc/openvpn/dh.pem
cp ta.key /etc/openvpn/ta.key

# 6. 固定端口及 server.conf（启用 tls-crypt，并支持 IPv6）
echo "PORT=$PORT" > /etc/openvpn/port.env
cat <<EOF >/etc/openvpn/server.conf
port $PORT
proto udp
dev tun

# IPv4 子网
server 10.8.0.0 255.255.255.0
# IPv6 ULA 子网
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

cipher AES-256-CBC
auth SHA256
compress lz4-v2
user nobody
group nogroup
verb 3
status /var/log/openvpn/openvpn-status.log
explicit-exit-notify 1
EOF

# 7. 开启 IPv4 与 IPv6 转发
cat <<EOF >> /etc/sysctl.conf
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
EOF
sysctl -p

# 8. 配置防火墙 NAT 与转发（IPv4 & IPv6）
OUT_IF=$(ip route get 8.8.8.8 | awk '{print $5; exit}')

# IPv4 NAT
iptables -t nat -A POSTROUTING -s 10.8.0.0/24 \
  -o "$OUT_IF" \
  -j MASQUERADE

# IPv6 NAT & 转发（仅当 OUT_IF6 非空时执行）
OUT_IF6=$(ip -6 route show default | awk '{print $5; exit}' || true)
if [ -n "$OUT_IF6" ]; then
  ip6tables -t nat -A POSTROUTING -s fd00:beef:1234:5678::/64 \
    -o "$OUT_IF6" \
    -j MASQUERADE
  ip6tables -A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
  ip6tables -A FORWARD -s fd00:beef:1234:5678::/64 -j ACCEPT
fi

# 转发规则（IPv4）
iptables -A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -s 10.8.0.0/24 -j ACCEPT

# 持久化 iptables（含 IPv6）
sudo debconf-set-selections << 'EOD'
iptables-persistent iptables-persistent/autosave_v4 boolean true
iptables-persistent iptables-persistent/autosave_v6 boolean true
EOD

sudo DEBIAN_FRONTEND=noninteractive apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
netfilter-persistent save

# 9. 启动服务
systemctl enable openvpn@server
systemctl start openvpn@server

# 10. 客户端目录与基础配置（移除外部 tls-crypt 行）
mkdir -p ~/openvpn-ca/client-configs/files
chmod 700 ~/openvpn-ca/client-configs/files

source /etc/openvpn/port.env
SERVER_IP=$(curl -s --fail https://ip.saelink.net/IP/)
if [ -z "$SERVER_IP" ]; then
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
remote $SERVER_IP $PORT
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
echo "已生成基础配置：$OUTPUT_FILE (remote $SERVER_IP:$PORT)"

# 11. 生成 make_config.sh 并创建 CUBE.ovpn（内联 tls-crypt）
cat > ~/openvpn-ca/client-configs/make_config.sh << 'EOM'
#!/usr/bin/env bash
KEY_DIR="$HOME/openvpn-ca/pki/private"
OUTPUT_DIR="$HOME/openvpn-ca/client-configs/files"
BASE_CONFIG="$HOME/openvpn-ca/client-configs/base.conf"
if [ -z "$1" ]; then
  echo "Usage: $0 <client-name>"
  exit 1
fi
CLIENT_NAME="$1"
mkdir -p "$OUTPUT_DIR"
cat "$BASE_CONFIG" \
  <(echo -e '<ca>') \
  "$HOME/openvpn-ca/pki/ca.crt" \
  <(echo -e '</ca>\n<cert>') \
  "$HOME/openvpn-ca/pki/issued/${CLIENT_NAME}.crt" \
  <(echo -e '</cert>\n<key>') \
  "$KEY_DIR/${CLIENT_NAME}.key" \
  <(echo -e '</key>\n<tls-crypt>') \
  "$HOME/openvpn-ca/ta.key" \
  <(echo -e '</tls-crypt>') \
  > "$OUTPUT_DIR/${CLIENT_NAME}.ovpn"
echo "Client configuration generated: $OUTPUT_DIR/${CLIENT_NAME}.ovpn"
EOM

chmod +x ~/openvpn-ca/client-configs/make_config.sh
~/openvpn-ca/client-configs/make_config.sh CUBE
~/openvpn-ca/client-configs/make_config.sh CUBE01
~/openvpn-ca/client-configs/make_config.sh CUBE02
~/openvpn-ca/client-configs/make_config.sh CUBE03

# 12. 输出客户端配置
cat ~/openvpn-ca/client-configs/files/CUBE.ovpn
