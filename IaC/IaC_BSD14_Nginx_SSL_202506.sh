#!/bin/sh

# 检查是否提供了域名作为参数
if [ $# -ne 1 ]; then
    echo "Usage: $0 <domain>"
    exit 1
fi

DOMAIN=$1
CONF_DIR="/usr/local/etc/nginx/conf.d"
CONF_FILE="${CONF_DIR}/${DOMAIN}.conf"
WEB_ROOT="/usr/local/www/${DOMAIN}"

# 检查 conf.d 目录是否存在，不存在则创建
if [ ! -d "$CONF_DIR" ]; then
    mkdir -p "$CONF_DIR"
fi

# 检查网站根目录是否存在，不存在则创建
if [ ! -d "$WEB_ROOT" ]; then
    mkdir -p "$WEB_ROOT"
fi


cat << EOF > "$CONF_FILE"
server {
    listen 80;
    server_name $DOMAIN;
    root $WEB_ROOT; # 指定网站根目录

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

service nginx restart

certbot certonly --webroot -w $WEB_ROOT -d $DOMAIN --agree-tos --email omniosccccccc@msn.com --non-interactive


rm "$CONF_FILE"


# 创建Nginx配置文件，不包括SSL配置
cat << EOF > "$CONF_FILE"
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri; # 将所有HTTP请求重定向到HTTPS
}

server {
    listen 443 ssl;
    server_name $DOMAIN;
    root $WEB_ROOT; # 指定网站根目录
    ssl_certificate /usr/local/etc/letsencrypt/live/$DOMAIN/fullchain.pem; # 指定SSL证书
    ssl_certificate_key /usr/local/etc/letsencrypt/live/$DOMAIN/privkey.pem; # 指定SSL证书密钥
    index index.php index.html; # 设置默认加载页面，PHP优先
    # 设置客户端请求体的最大大小
    client_max_body_size 8000M;

    # 记录访问日志和错误日志
    access_log /var/log/nginx/$DOMAIN-access.log;
    error_log /var/log/nginx/$DOMAIN-error.log;

    location / {
        try_files \$uri \$uri/ /index.php\$request_uri;
    }

    location ~ \.php(?:\$|/) {
        root $WEB_ROOT;
        fastcgi_pass 127.0.0.1:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

}
EOF

# 重启Nginx和PHP-FPM服务
service nginx restart
service php-fpm restart

echo '<?php phpinfo(); ?>' > "${WEB_ROOT}/index.php"

echo  https://$DOMAIN
echo "配置完成，Nginx 和 PHP-FPM 已重启。"
