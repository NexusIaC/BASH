#!/bin/bash

# 检查是否提供了域名作为参数
if [ -z "$1" ]; then
  echo "Usage: $0 your_domain"
  exit 1
fi

DOMAIN=$1
WEB_ROOT="/var/www/$DOMAIN"
NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
PHP_VERSION="php8.4" # 根据系统安装的PHP版本进行调整

# 创建网站的根目录
mkdir -p $WEB_ROOT

# 初始配置Nginx虚拟主机以处理HTTP请求，为certbot证书申请做准备
cat > $NGINX_CONF <<- 'EOM'
server {
    listen 80;
    server_name DOMAIN_PLACEHOLDER;
    root WEB_ROOT_PLACEHOLDER;

    location / {
        try_files $uri $uri/ =404;
    }
}
EOM

# 替换占位符
sed -i "s|DOMAIN_PLACEHOLDER|$DOMAIN|g" $NGINX_CONF
sed -i "s|WEB_ROOT_PLACEHOLDER|$WEB_ROOT|g" $NGINX_CONF

# 创建符号链接，启用Nginx虚拟主机配置
ln -s /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/

# 重新加载Nginx，应用配置变更
systemctl reload nginx

# 使用certbot自动申请Let's Encrypt SSL证书
certbot certonly --webroot -w $WEB_ROOT -d $DOMAIN --agree-tos --email root@omnios.world --non-interactive

# 删除原始的HTTP服务器配置
rm $NGINX_CONF

# 配置Nginx虚拟主机以处理HTTP和HTTPS请求
cat > $NGINX_CONF <<- EOM
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri; # 将所有HTTP请求重定向到HTTPS
}

server {
    listen 443 ssl;
    server_name $DOMAIN;
    root $WEB_ROOT; # 指定网站根目录
    client_max_body_size 8000M; # 设置客户端请求体的最大大小
    index index.php index.html;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem; # 指定SSL证书
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem; # 指定SSL证书密钥

    access_log /var/log/nginx/$DOMAIN-access.log; # 配置访问日志
    error_log /var/log/nginx/$DOMAIN-error.log; # 配置错误日志

    # 强制浏览器使用HTTPS连接，提高安全性
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    location / {
        try_files \$uri \$uri/ /index.php\$request_uri;
    }

    location ~ \.php(?:\$|/) {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        include snippets/fastcgi-php.conf;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
        fastcgi_param HTTPS on;
        fastcgi_pass unix:/var/run/php/$PHP_VERSION-fpm.sock;
    }


}
EOM

# 重新加载Nginx，应用配置变更
systemctl reload nginx

# 检查HTTPS连接是否正常
sleep 5
curl --head https://$DOMAIN
