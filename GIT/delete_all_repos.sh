#!/bin/bash
#
# delete_all_repos.sh
#
# 功能:
#   使用提供的 GitHub API Token 非交互地删除当前用户(Authenticated User)名下的所有仓库。
#   幂等: 已删除的仓库不会再次出现；若遇到 404 也视作成功跳过。
#
# 使用:
#   ./delete_all_repos.sh <your_github_api_token>
#
# 依赖:
#   - bash
#   - curl
#   - jq
#
# 权限要求:
#   - Token 至少需要 `delete_repo` scope (删除私有仓库需要；仅公有仓库时也建议包含该 scope)。
#
# 注意:
#   - 该操作不可逆，请确保你已备份所需数据。
#   - 脚本无任何交互确认，直接删除。
#

set -euo pipefail

# ---------- 参数检查 ----------
if [[ $# -ne 1 || -z "${1:-}" ]]; then
  echo "错误: 缺少 GitHub API Token。" >&2
  echo "用法: $0 <your_github_api_token>" >&2
  exit 1
fi

API_TOKEN="$1"

# ---------- 配置 ----------
API_ROOT="https://api.github.com"
ACCEPT_HDR="application/vnd.github+json"
API_VER="2022-11-28"   # 官方 v3 版本标头
PER_PAGE=100
SLEEP_BETWEEN_DELETES=0.2  # 避免触发速率限制(秒)

# ---------- 依赖检查 ----------
for cmd in curl jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "错误: 需要依赖 '$cmd'，请先安装。" >&2
    exit 1
  fi
done

# ---------- 函数 ----------
gh_get() {
  # $1: url (含查询参数)
  curl -sS \
    -H "Accept: ${ACCEPT_HDR}" \
    -H "X-GitHub-Api-Version: ${API_VER}" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    "$1"
}

gh_delete() {
  # $1: full_name 形如 owner/repo
  local full_name="$1"
  # 仅返回 HTTP code，正文丢弃
  curl -sS -o /dev/null -w "%{http_code}" -X DELETE \
    -H "Accept: ${ACCEPT_HDR}" \
    -H "X-GitHub-Api-Version: ${API_VER}" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    "${API_ROOT}/repos/${full_name}"
}

# ---------- 验证 Token & 获取登录名 ----------
echo "验证 Token..."
USER_JSON="$(gh_get "${API_ROOT}/user")" || {
  echo "错误: 无法访问 /user 接口，请检查网络或 Token。" >&2
  exit 1
}

LOGIN="$(jq -r '.login // empty' <<<"$USER_JSON")"
if [[ -z "$LOGIN" || "$LOGIN" == "null" ]]; then
  MSG="$(jq -r '.message // empty' <<<"$USER_JSON")"
  echo "错误: 读取登录名失败。GitHub 返回: ${MSG:-<无>}" >&2
  exit 1
fi
echo "已认证用户: ${LOGIN}"

# ---------- 分页列出仓库(full_name) ----------
# 仅删除自己拥有的仓库，避免组织或协作权限仓库误删
# 使用 affiliation=owner；visibility=all；per_page=100；分页直到为空
TMP_LIST="$(mktemp)"
trap 'rm -f "$TMP_LIST"' EXIT

echo "开始拉取仓库列表(分页，${PER_PAGE}/页)..."
page=1
total_listed=0
while : ; do
  URL="${API_ROOT}/user/repos?affiliation=owner&per_page=${PER_PAGE}&page=${page}"
  RESP="$(gh_get "$URL")" || {
    echo "错误: 获取第 ${page} 页数据失败。" >&2
    exit 1
  }

  COUNT="$(jq 'length' <<<"$RESP")"
  if [[ "${COUNT}" -eq 0 ]]; then
    break
  fi

  # 取出 full_name，确保非空
  jq -r '.[] | .full_name | select(type=="string" and length>0)' <<<"$RESP" >> "$TMP_LIST"
  total_listed=$(( total_listed + COUNT ))

  # 若不足一整页，认为到末尾
  if [[ "${COUNT}" -lt "${PER_PAGE}" ]]; then
    break
  fi
  page=$(( page + 1 ))
done

# 去重(极少见，但稳妥)
if [[ -s "$TMP_LIST" ]]; then
  mapfile -t REPOS < <(sort -u "$TMP_LIST")
else
  REPOS=()
fi

echo "共发现 ${#REPOS[@]} 个仓库待处理(拥有者=${LOGIN})。"

# ---------- 删除阶段(非交互) ----------
deleted=0
skipped_404=0
failed=0

for full_name in "${REPOS[@]}"; do
  # 再次校验 owner 是否当前用户，避免误删(例如你拥有的 org 仓库会出现在 owner 中，但一般 owner!=login)
  owner_part="${full_name%%/*}"
  if [[ "$owner_part" != "$LOGIN" ]]; then
    # 只删除 owner == 当前用户 的仓库；其他一律跳过（更安全）
    echo "跳过非本人仓库: ${full_name}"
    continue
  fi

  code="$(gh_delete "$full_name" || true)"
  case "$code" in
    204)
      echo "已删除: ${full_name}"
      deleted=$(( deleted + 1 ))
      ;;
    404)
      echo "不存在(视为已删除): ${full_name}"
      skipped_404=$(( skipped_404 + 1 ))
      ;;
    403)
      echo "无权限删除(403): ${full_name}" >&2
      failed=$(( failed + 1 ))
      ;;
    401)
      echo "未授权(401)，Token 失效或权限不足: ${full_name}" >&2
      failed=$(( failed + 1 ))
      ;;
    *)
      echo "删除失败(HTTP ${code}): ${full_name}" >&2
      failed=$(( failed + 1 ))
      ;;
  esac

  # 轻微延迟，温和对待 API 速率限制
  sleep "${SLEEP_BETWEEN_DELETES}"
done

# ---------- 结果汇总 ----------
echo "------------------------------------------"
echo "处理完成。汇总:"
echo "  已删除:      ${deleted}"
echo "  已不存在:    ${skipped_404}"
echo "  失败:        ${failed}"
echo "  总计(尝试):  $(( deleted + skipped_404 + failed ))"
echo "  所有者过滤后待处理数: ${#REPOS[@]}"
echo "------------------------------------------"

# 退出码: 只要存在失败，返回非零，便于外部自动化检测
if [[ $failed -gt 0 ]]; then
  exit 2
fi
exit 0
