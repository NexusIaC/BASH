#!/bin/bash

# 确保传入两个参数（API 令牌和 Git 仓库 URL）
if [ -z "$1" ] || [ -z "$2" ]; then
  echo -e "\033[36m使用方法: $0 <api-token> <git-repository-url>\033[0m"
  exit 1
fi

# 设置变量
PROJECT_DIR="$(pwd)"          # 当前目录为项目目录
ACCESS_TOKEN="$1"             # 从命令行参数获取 Gitea 访问令牌
GITEA_URL="$2"                # 从命令行参数获取 Gitea 仓库 URL
BRANCH_NAME="main"            # 默认分支名称，可以修改为 "master" 或其他

# 进入项目目录（当前目录）
cd "$PROJECT_DIR" || { echo -e "\033[36m项目目录不存在！\033[0m"; exit 1; }

# 自动清除旧的 Git 凭证缓存
git credential-cache exit
rm -f ~/.git-credentials

# 解决 dubious ownership 问题
git config --global --add safe.directory "$PROJECT_DIR"

# 设置 Git 用户信息（如果没有设置）
git config --global user.name "Cube"
git config --global user.email "your-email@example.com"

# 确保 Gitea URL 正确（移除不必要的 https:// 部分）
if [[ "$GITEA_URL" =~ ^https:// ]]; then
  GITEA_URL="${GITEA_URL#https://}"  # 移除开头的 https://
fi

# 使用传入的 Gitea URL 和令牌构建远程仓库地址
REMOTE_URL="https://your_username:$ACCESS_TOKEN@$GITEA_URL"

# 检查是否已经是一个 Git 仓库
if [ ! -d ".git" ]; then
  # 如果没有初始化 Git 仓库，初始化并进行首次提交
  echo -e "\033[36m初始化新的 Git 仓库...\033[0m"
  git init
  git add .
  
  # 获取主机名
  HOSTNAME=$(cat /etc/hostname)

  # 首次提交使用主机名
  git commit -m "Initial commit from $HOSTNAME"
  echo -e "\033[36m初始提交已创建。\033[0m"
fi

# 检查是否已经设置了远程仓库，如果没有则设置
git remote get-url origin &>/dev/null
if [ $? -ne 0 ]; then
  echo -e "\033[36m没有找到远程 'origin'，正在添加远程仓库 'origin'...\033[0m"
  git remote add origin "$REMOTE_URL"
else
  echo -e "\033[36m远程 'origin' 已经存在，正在更新远程仓库 URL...\033[0m"
  git remote set-url origin "$REMOTE_URL"
fi

# 确保分支存在，切换或创建分支
git branch -M "$BRANCH_NAME"

# 显示将要同步的文件
echo -e "\033[36m将要同步的文件:\033[0m"
git status --short

# 添加所有更改，包括删除的文件
git add -A  # 确保添加所有更改（包括删除的文件）

# 提交更改，使用主机名作为提交消息
echo -e "\033[36m正在提交更改...\033[0m"
git commit -m "Sync from $HOSTNAME"

# 强制推送到远程仓库，覆盖所有远程内容
echo -e "\033[36m强制推送到远程 Gitea 仓库，完全覆盖远程内容...\033[0m"
git push origin "$BRANCH_NAME" --force

echo -e "\033[36m项目已强制推送到 Gitea 仓库 $GITEA_URL，完全覆盖远程内容。\033[0m"
