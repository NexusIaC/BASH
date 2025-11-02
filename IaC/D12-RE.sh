#!/usr/bin/env bash

# 检查是否提供了两个参数
if [[ $# -ne 2 ]]; then
  echo "Error: You must provide exactly two arguments: domain and port." >&2
  exit 1
fi

domain="$1"
port="$2"

# 检查端口是否为有效的数字
if ! [[ "$port" =~ ^[0-9]+$ ]]; then
  echo "Error: Port must be a valid number." >&2
  exit 1
fi

file="/etc/nginx/sites-enabled/$domain"
tmp="${file}.tmp"

# 检查目标文件是否存在
if [[ ! -f "$file" ]]; then
  echo "Error: $file not found" >&2
  exit 1
fi

# 检查目标文件中是否包含所需的模式
if ! grep -q 'try_files \$uri \$uri/ /index\.php\$request_uri;' "$file" \
    || ! grep -q 'fastcgi_pass unix:/var/run/php/php8\.4-fpm\.sock;' "$file"; then
  echo "Pattern not found; no changes made." >&2
  exit 0
fi

# 使用awk处理文件内容
awk -v port="$port" '
/^[[:space:]]*location[[:space:]]*\/[[:space:]]*\{/ {
    in_loc=1
    print "    location / {"
    print "        proxy_pass         http://127.0.0.1:" port ";"
    print "        proxy_http_version 1.1;"
    print "        proxy_set_header   Upgrade $http_upgrade;"
    print "        proxy_set_header   Connection   \"upgrade\";"
    print "        proxy_set_header   Host         $host;"
    print "        proxy_set_header   X-Real-IP    $remote_addr;"
    print "        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;"
    print "        proxy_buffering    off;   # For SSE or WebSocket buffering should be off"
    print "    }"
    next
}
in_loc {
    if ($0 ~ /^\s*\}/) { in_loc=0; skip_php=1 }
    next
}
skip_php && /^[[:space:]]*$/ {
    next
}
skip_php==1 && /^[[:space:]]*location[[:space:]]*~[[:space:]]*\\\.php/ {
    skip_php=2
    next
}
skip_php==2 {
    if ($0 ~ /^\s*\}/) { skip_php=0 }
    next
}
{ print }
' "$file" > "$tmp" && mv "$tmp" "$file"

# 运行 nginx -t 测试配置
nginx -t

# 检查是否测试成功

systemctl restart nginx
