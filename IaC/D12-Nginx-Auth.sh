# Debian Nginx 基本验证自动化


#!/bin/bash

# 检查是否提供了域名参数
if [ -z "$1" ]; then
    echo "Usage: $0 <domain>"
    exit 1
fi

# 定义变量
DOMAIN=$1
CONFIG_FILE="/etc/nginx/sites-enabled/$DOMAIN"

# 检查配置文件是否存在
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Configuration file does not exist: $CONFIG_FILE"
    exit 1
fi

# 检查auth_basic是否已设置
if grep -q 'auth_basic "Restricted Access";' "$CONFIG_FILE"; then
    echo "auth_basic already set for $DOMAIN"
    exit 1
fi

# 向配置文件中插入认证设置
awk '/client_max_body_size/ {
    print $0
    print "    auth_basic \"Restricted Access\";"
    print "    auth_basic_user_file /etc/nginx/.htpasswd;"
    next
}
{ print }' "$CONFIG_FILE" > temp_file && mv temp_file "$CONFIG_FILE"

echo "Authentication settings added to $CONFIG_FILE"

nginx -t
systemctl restart nginx
