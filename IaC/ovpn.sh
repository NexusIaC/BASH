#!/bin/bash

# 本地文件绝对路径（硬编码）
local_file_path="/root/openvpn-ca/client-configs/files/CUBE.ovpn"

# 从 /etc/hostname 中读取主机名（去除可能的换行符）
hostname=$(tr -d '\n' < /etc/hostname)

# 生成时间戳，格式 YYYYMMDDHHMMSS
timestamp=$(date '+%Y%m%d%H%M%S')

# 构造服务器端保存的文件名：<hostname>-<timestamp>.ovpn
server_file_name="${hostname}-${timestamp}.ovpn"

# 服务器 URL
server_url="https://file.formulax.work/ovpn/post.php"

# 使用 curl 上传文件
curl -v \
     -F "file=@${local_file_path};filename=${server_file_name}" \
     "$server_url"
