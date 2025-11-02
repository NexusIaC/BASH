#!/bin/sh

# certbot证书存储路径
CERTBOT_PATH="/usr/local/etc/letsencrypt/live"

# 检查该路径是否存在
if [ ! -d "$CERTBOT_PATH" ]; then
  echo "Error: Certbot certificates directory not found at $CERTBOT_PATH."
  exit 1
fi

# 颜色定义
COLOR_BLUE="\033[34m"
COLOR_GREEN="\033[32m"
COLOR_RED="\033[31m"
COLOR_RESET="\033[0m"

# 临时存储表格数据
table="Domain\tStart Date\tEnd Date\tStatus\n"

# 获取当前日期（以便比较证书是否过期）
current_date=$(date +%s)

# 遍历证书目录
for domain in "$CERTBOT_PATH"/*; do
  if [ -d "$domain" ]; then
    # 证书文件路径
    cert_file="$domain/cert.pem"
    
    # 检查证书文件是否存在
    if [ -f "$cert_file" ]; then
      # 使用 openssl 命令提取证书的开始日期（notBefore）和结束日期（notAfter）
      start_date=$(openssl x509 -in "$cert_file" -noout -dates | grep 'notBefore' | cut -d= -f2)
      end_date=$(openssl x509 -in "$cert_file" -noout -dates | grep 'notAfter' | cut -d= -f2)

      # 去掉 end_date 中的 " GMT" 部分
      end_date_cleaned=$(echo "$end_date" | sed 's/ GMT//')

      # 将结束日期格式转换为 FreeBSD 支持的日期格式
      # 使用 FreeBSD 的 date 命令来转换 end_date
      end_date_seconds=$(date -j -f "%b %d %T %Y" "$end_date_cleaned" +%s)

      # 判断证书是否过期
      if [ $current_date -gt $end_date_seconds ]; then
        status="${COLOR_RED}Expired${COLOR_RESET}"
      else
        status="${COLOR_GREEN}Valid${COLOR_RESET}"
      fi

      # 将域名、开始日期、结束日期和状态信息添加到表格中
      table="${table}${COLOR_BLUE}$(basename "$domain")${COLOR_RESET}\t${COLOR_GREEN}$start_date${COLOR_RESET}\t${COLOR_GREEN}$end_date${COLOR_RESET}\t$status\n"
    else
      echo "Warning: Certificate file for domain $domain not found."
    fi
  fi
done

# 使用 column 命令将表格格式化输出
echo -e "$table" | column -t
