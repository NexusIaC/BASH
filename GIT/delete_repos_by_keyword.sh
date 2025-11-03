#!/bin/bash
#
# delete_repos_by_keyword.sh
#
# 功能:
#   使用 GitHub API Token 删除当前认证用户名下、仓库名包含指定关键词的仓库。
#   幂等: 已删除或不存在(404)视为成功跳过。
#
# 用法:
#   ./delete_repos_by_keyword.sh <your_github_api_token> <keyword>
#
# 依赖:
#   - bash
#   - curl
#   - jq
#
# 注意:
#   - 该操作不可逆。脚本在删除前会列出目标并倒计时 10 秒，可按 Ctrl+C 取消。
#   - Token 需具备 delete_repo scope 才能删除私有仓库。
#

set -euo pipefail

# ---------- 颜色 ----------
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ $(tput colors 2>/dev/null || echo 0) -ge 256 ]]; then
  CYAN='\033[38;5;39m'   # DeepSkyBlue1
else
  CYAN='\033[0;36m'
fi
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

# ---------- 参数检查 ----------
if [[ $# -ne 2 ]]; then
  echo -e "${RED}错误:${NC} 需要 2 个参数。"
  echo "用法: $0 <your_github_api_token> <keyword>"
  exit 1
fi

API_TOKEN="$1"
KEYWORD_RAW="$2"
if [[ -z "$API_TOKEN" || -z "$KEYWORD_RAW" ]]; then
  echo -e "${RED}错误:${NC} Token 与关键词均不能为空。"
  exit 1
fi

# 统一小写做包含匹配（大小写不敏感）
shopt -s nocasematch
KEYWORD="$KEYWORD_RAW"
shopt -u nocasematch

# ---------- 配置 ----------
API_ROOT="https://api.github.com"
ACCEPT_HDR="application/vnd.github+json"
API_VER="2022-11-28"
PER_PAGE=100
SLEEP_BETWEEN_DELETES=0.2

# ---------- 依赖检查 ----------
for cmd in curl jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo -e "${RED}错误:${NC} 需要依赖 '${cmd}'，请先安装。"
    exit 1
  fi
done

# ---------- 封装 ----------
gh_get() {
  curl -sS \
    -H "Accept: ${ACCEPT_HDR}" \
    -H "X-GitHub-Api-Version: ${API_VER}" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    "$1"
}

gh_delete() {
  local full_name="$1"
  curl -sS -o /dev/null -w "%{http_code}" -X DELETE \
    -H "Accept: ${ACCEPT_HDR}" \
    -H "X-GitHub-Api-Version: ${API_VER}" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    "${API_ROOT}/repos/${full_name}"
}

# ---------- 验证身份 ----------
echo -e "${CYAN}验证 Token...${NC}"
USER_JSON="$(gh_get "${API_ROOT}/user")" || {
  echo -e "${RED}错误:${NC} 无法访问 /user 接口。"
  exit 1
}
LOGIN="$(jq -r '.login // empty' <<<"$USER_JSON")"
if [[ -z "$LOGIN" || "$LOGIN" == "null" ]]; then
  MSG="$(jq -r '.message // empty' <<<"$USER_JSON")"
  echo -e "${RED}错误:${NC} 获取登录名失败。GitHub 返回: ${MSG:-<无>}"
  exit 1
fi
echo -e "已认证用户: ${BOLD}${LOGIN}${NC}"
echo -e "匹配关键词: ${BOLD}${KEYWORD_RAW}${NC}"

# ---------- 拉取列表并过滤 ----------
TMP_ALL="$(mktemp)"
TMP_TARGET="$(mktemp)"
trap 'rm -f "$TMP_ALL" "$TMP_TARGET"' EXIT

echo -e "${CYAN}分页拉取本人拥有的仓库(每页 ${PER_PAGE})...${NC}"
page=1
while : ; do
  URL="${API_ROOT}/user/repos?affiliation=owner&per_page=${PER_PAGE}&page=${page}"
  RESP="$(gh_get "$URL")" || {
    echo -e "${RED}错误:${NC} 拉取第 ${page} 页失败。"
    exit 1
  }

  COUNT="$(jq 'length' <<<"$RESP")"
  [[ "$COUNT" -eq 0 ]] && break

  # 仅抽取必要字段：full_name 与 name
  jq -r '.[] | [.full_name, .name] | @tsv' <<<"$RESP" >> "$TMP_ALL"

  [[ "$COUNT" -lt "$PER_PAGE" ]] && break
  page=$((page + 1))
done

# 过滤：owner 必须等于本人；name 包含关键词（大小写不敏感）
# 用 awk 做 owner 过滤，用 bash 做关键词过滤（避免复杂转义）
if [[ -s "$TMP_ALL" ]]; then
  while IFS=$'\t' read -r full_name repo_name; do
    [[ -z "$full_name" || -z "$repo_name" ]] && continue
    owner_part="${full_name%%/*}"
    [[ "$owner_part" != "$LOGIN" ]] && continue
    # 大小写不敏感匹配
    if [[ "${repo_name,,}" == *"${KEYWORD,,}"* ]]; then
      printf "%s\t%s\n" "$full_name" "$repo_name" >> "$TMP_TARGET"
    fi
  done < "$TMP_ALL"
fi

mapfile -t TO_DELETE < <(cut -f1 "$TMP_TARGET" 2>/dev/null || true)

if [[ ${#TO_DELETE[@]} -eq 0 ]]; then
  echo -e "${YELLOW}未找到需要删除的仓库（匹配关键词且属于 ${LOGIN}）。${NC}"
  exit 0
fi

# ---------- 预览并倒计时 ----------
echo -e "${CYAN}即将删除以下仓库（共 ${#TO_DELETE[@]} 个）：${NC}"
nl -ba "$TMP_TARGET" | awk -F'\t' -v c="${CYAN}" -v n="${NC}" '{
  # 1: 序号+制表，2: full_name, 3: repo_name
  printf(" %3d. %s%s%s (name=\"%s\")\n", NR, c, $2, n, $3)
}'

echo -e "${YELLOW}10 秒后开始删除。按 Ctrl+C 取消...${NC}"
for i in {10..1}; do
  printf "\r开始删除倒计时: %2d " "$i"
  sleep 1
done
printf "\r%-30s\n" "开始执行删除..."

# ---------- 删除 ----------
deleted=0
skipped_404=0
failed=0

for full_name in "${TO_DELETE[@]}"; do
  code="$(gh_delete "$full_name" || true)"
  case "$code" in
    204)
      echo -e "${GREEN}已删除:${NC} ${full_name}"
      deleted=$((deleted + 1))
      ;;
    404)
      echo -e "${GREEN}已不存在(视为已删除):${NC} ${full_name}"
      skipped_404=$((skipped_404 + 1))
      ;;
    403)
      echo -e "${RED}无权限(403):${NC} ${full_name}"
      failed=$((failed + 1))
      ;;
    401)
      echo -e "${RED}未授权(401):${NC} ${full_name}  — 请检查 Token 或 scope(delete_repo)"
      failed=$((failed + 1))
      ;;
    *)
      echo -e "${RED}删除失败(HTTP ${code}):${NC} ${full_name}"
      failed=$((failed + 1))
      ;;
  esac
  sleep "${SLEEP_BETWEEN_DELETES}"
done

# ---------- 汇总 ----------
echo -e "${CYAN}------------------------------------------${NC}"
echo -e "${BOLD}处理完成。汇总:${NC}"
echo -e "  ${GREEN}已删除:${NC}      ${deleted}"
echo -e "  ${GREEN}已不存在:${NC}    ${skipped_404}"
if [[ $failed -gt 0 ]]; then
  echo -e "  ${RED}失败:${NC}        ${failed}"
else
  echo -e "  失败:        ${failed}"
fi
echo -e "  总计(尝试):  $(( deleted + skipped_404 + failed ))"
echo -e "${CYAN}------------------------------------------${NC}"

# 返回码：只要有失败则非零
if [[ $failed -gt 0 ]]; then
  exit 2
fi
exit 0
