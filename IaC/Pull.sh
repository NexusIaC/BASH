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

# 检查指定的目录是否存在
if [ ! -d "$PROJECT_DIR" ]; then
  echo -e "\033[36m目录不存在，正在创建目录 $PROJECT_DIR...\033[0m"
  mkdir -p "$PROJECT_DIR"
fi

# 进入项目目录（当前目录）
cd "$PROJECT_DIR" || { echo -e "\033[36m项目目录无法找到！\033[0m"; exit 1; }

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
  # 如果没有初始化 Git 仓库，初始化并进行首次拉取
  echo -e "\033[36m初始化新的 Git 仓库...\033[0m"
  git init
  echo -e "\033[36m从远程仓库拉取内容...\033[0m"
  git remote add origin "$REMOTE_URL"
  git fetch origin "$BRANCH_NAME"
  git reset --hard "origin/$BRANCH_NAME"
  echo -e "\033[36m仓库已初始化并与远程同步。\033[0m"
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

# 确保分支存在，切换到目标分支
git checkout "$BRANCH_NAME"

# 显示将要同步的文件
echo -e "\033[36m将要同步的文件:\033[0m"
git status --short

# 强制拉取远程仓库的内容并覆盖本地内容
echo -e "\033[36m正在强制拉取远程 Gitea 仓库的内容，并覆盖本地文件...\033[0m"

# 设置 GIT_ASKPASS 环境变量，避免交互式输入
export GIT_ASKPASS="echo"
export GIT_TERMINAL_PROMPT=0
export GIT_USERNAME="Cube"  # 替换为你的 Gitea 用户名
export GIT_PASSWORD="$ACCESS_TOKEN"  # 使用硬编码的访问令牌

# 拉取并重置本地更改
if ! git fetch origin "$BRANCH_NAME"; then
  echo -e "\033[36m错误：远程仓库可能不存在，或者您没有权限访问它。\033[0m"
  echo -e "\033[36m请确保仓库存在且您有正确的访问权限。\033[0m"
  exit 1
fi

git reset --hard "origin/$BRANCH_NAME"

echo -e "\033[36m项目已与 Git 仓库 $GITEA_URL 同步。\033[0m"
