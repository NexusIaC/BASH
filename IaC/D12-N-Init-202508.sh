# nginx_init
#!/bin/bash

apt -y update
DEBIAN_FRONTEND=noninteractive apt-get -y upgrade
timedatectl set-timezone Asia/Shanghai
apt -y install vim nano gcc rsync p7zip-full unzip curl wget sshpass nload snmp snmpd net-tools tree iftop sudo nmap make git apache2-utils expect yq dnsutils

apt -y install python3-pip
pip install --break-system-packages python-docx openpyxl python-pptx PyMuPDF xlrd pyth

# 安装 OpenAI Python SDK
pip install openai --break-system-packages

# 添加 Node.js 22.x LTS 官方仓库并安装（含 npm）
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -  
apt-get install -y nodejs                            

# 全局安装 pm2
npm install -g pm2


apt install -y apt-transport-https lsb-release ca-certificates wget
wget -O /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg
echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/sury-php.list
apt update
apt install -y acl curl fping git graphviz mtr-tiny nginx-full nmap php-cli php-curl php-fpm php-gd php-gmp php-json php-mbstring php-mysql php-snmp php-xml php-zip python3-dotenv python3-pymysql python3-redis python3-setuptools python3-systemd python3-pip rrdtool snmp snmpd whois

php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
php composer-setup.php --install-dir=/usr/local/bin --filename=composer

apt -y install snapd
snap install core
snap refresh core
snap install --classic certbot
ln -s /snap/bin/certbot /usr/bin/certbot



#!/bin/bash

# 安装SNMP服务和工具（如果尚未安装）
sudo apt-get update
sudo apt-get install -y snmpd snmp

# 停止snmpd服务以进行配置
sudo systemctl stop snmpd

# 配置snmpd.conf，包括基本的系统信息和允许所有地址访问
sudo bash -c 'cat > /etc/snmp/snmpd.conf << EOF
# 基本系统信息
sysLocation    Foundry
sysContact     Eiswein.OS@outlook.com
sysServices    72

# 允许所有地址访问
agentAddress  udp:161,udp6:[::1]:161

# Define a view which includes everything
view all included .1 80

# SNMPv3用户访问配置 - 此处配置仅为示例
# 推荐通过net-snmp工具创建用户以确保安全性
rouser AzureEC priv

# 其他配置...
EOF'

# 使用net-snmp工具创建SNMPv3用户AzureEC
# 注意: 请根据实际情况替换下面命令中的密码
sudo net-snmp-create-v3-user -ro -A "publicAzure+++++++" -a SHA -X "publicAzure+++++++" -x AES AzureEC

# 重启snmpd服务
sudo systemctl restart snmpd

echo "SNMP configuration has been updated and snmpd service restarted."

# 使用snmpwalk测试配置（此步骤可选）
echo "Attempting to use snmpwalk to verify the SNMP configuration..."
snmpwalk -v3 -u AzureEC -l authPriv -a SHA -A 'publicAzure+++++++' -x AES -X 'publicAzure+++++++' localhost || echo "snmpwalk test failed. Check SNMP configuration."


mkdir -p /etc/apt/keyrings
curl -LsS https://mariadb.org/mariadb_release_signing_key.asc \
  | gpg --batch --yes --dearmor -o /etc/apt/keyrings/mariadb-release-signing-keyring.gpg

tee /etc/apt/sources.list.d/mariadb.list <<EOF
deb [arch=amd64 signed-by=/etc/apt/keyrings/mariadb-release-signing-keyring.gpg] https://archive.mariadb.org/mariadb-11.8.2/repo/debian bookworm main
EOF

apt update
DEBIAN_FRONTEND=noninteractive apt install -y mariadb-server mariadb-client

systemctl enable --now mariadb
mariadb --version

echo "Run 'mariadb-secure-installation' manually to secure your MariaDB installation."

# 修改 /etc/php/8.4/cli/php.ini
sed -i 's/upload_max_filesize = .*/upload_max_filesize = 8000M/' /etc/php/8.4/cli/php.ini
sed -i 's/post_max_size = .*/post_max_size = 8000M/' /etc/php/8.4/cli/php.ini
sed -i 's/memory_limit = .*/memory_limit = 800M/' /etc/php/8.4/cli/php.ini
sed -i 's/max_execution_time = .*/max_execution_time = 300/' /etc/php/8.4/cli/php.ini
sed -i 's/max_input_time = .*/max_input_time = 300/' /etc/php/8.4/cli/php.ini
sed -i 's/max_file_uploads = .*/max_file_uploads = 500/' /etc/php/8.4/cli/php.ini

# 修改 /etc/php/8.4/fpm/php.ini
sed -i 's/upload_max_filesize = .*/upload_max_filesize = 8000M/' /etc/php/8.4/fpm/php.ini
sed -i 's/post_max_size = .*/post_max_size = 8000M/' /etc/php/8.4/fpm/php.ini
sed -i 's/memory_limit = .*/memory_limit = 800M/' /etc/php/8.4/fpm/php.ini
sed -i 's/max_execution_time = .*/max_execution_time = 300/' /etc/php/8.4/fpm/php.ini
sed -i 's/max_input_time = .*/max_input_time = 300/' /etc/php/8.4/fpm/php.ini
sed -i 's/max_file_uploads = .*/max_file_uploads = 500/' /etc/php/8.4/fpm/php.ini


systemctl restart php8.4-fpm
