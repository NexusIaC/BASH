#!/bin/bash

# 检查是否安装了 certbot
if ! command -v certbot >/dev/null 2>&1; then
    echo -e "\x1b[91m错误：未检测到 certbot，请先安装 certbot。\x1b[0m" >&2
    exit 1
fi

# 颜色定义：
#   SKY_BLUE  = Bright Cyan (ANSI 96)
#   YELLOW    = Yellow (ANSI 33)
#   GREEN     = Green (ANSI 32)
#   NO_COLOR  = 重置颜色 (ANSI 0)
SKY_BLUE="\x1b[96m"
YELLOW="\x1b[33m"
GREEN="\x1b[32m"
NO_COLOR="\x1b[0m"

# 执行 certbot 并筛选“Certificate Name”与“Expiry Date”行，再用 sed 为不同部分着色
certbot certificates |
  grep -E "Certificate Name|Expiry Date" |
  sed -E "
    # 匹配 Certificate Name 行，将前缀 'Certificate Name: ' 着色为天蓝色，将域名部分着色为黄色
    s|^(\s*Certificate Name:\s*)(.*)$|${SKY_BLUE}\1${YELLOW}\2${NO_COLOR}|;

    # 匹配 Expiry Date 行，并分别着色：
    #   \1 = 前导空白 + 'Expiry Date: '
    #   \2 = 时间戳 (格式 'YYYY-MM-DD HH:MM:SS+ZZ:ZZ')
    #   \3 = 时间戳后续（如 '(VALID: 84 days)'）
    s|^(\s*Expiry Date:\s*)([0-9]{4}-[0-9]{2}-[0-9]{2}\s[0-9]{2}:[0-9]{2}:[0-9]{2}\+[0-9]{2}:[0-9]{2})(.*)$|${SKY_BLUE}\1${GREEN}\2${SKY_BLUE}\3${NO_COLOR}|
  "
