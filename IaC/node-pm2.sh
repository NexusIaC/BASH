#!/bin/bash

# 检查是否传入了一个参数
if [ -z "$1" ]; then
  echo "请提供一个参数。"
  exit 1
fi

# 获取传入的参数
PARAM=$1

# 执行命令
pm2 start server.js --name "$PARAM"
pm2 save
pm2 startup
pm2 status
