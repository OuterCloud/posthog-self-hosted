#!/usr/bin/env bash
# ============================================================
# PostHog 数据清理脚本（v3）
# 使用 PostHog 官方 Persons API 删除非指定域名的用户及其事件
#
# 官方文档：https://posthog.com/docs/privacy/data-storage
# API 参考：https://posthog.com/docs/api/persons-2 (bulk_delete)
#
# 原理：
# 1. 通过 Persons API 列出所有 person，删除非保留域名的
# 2. 通过 Events API 收集匿名 distinct_id
# 3. 调用 bulk_delete API 按 distinct_id 删除匿名事件
# 4. PostHog 内部异步处理 ClickHouse 数据清理
#
# 用法：bash cleanup.sh
# ============================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

POSTHOG_HOST="${POSTHOG_HOST:-http://localhost:8000}"
BATCH_SIZE=100

# 加载本地配置（如果存在）
CONFIG_FILE="$SCRIPT_DIR/config.local.sh"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

echo ""
echo "=========================================="
echo "  PostHog 数据清理 v3（官方 API）"
echo "=========================================="
echo ""

# ---- 检查依赖 ----
for cmd in curl jq; do
    command -v "$cmd" &>/dev/null || error "需要 ${cmd}，请先安装: yum install -y ${cmd}"
done

# ---- 获取 API Key ----
if [[ -n "${POSTHOG_PERSONAL_API_KEY:-}" ]]; then
    API_KEY="$POSTHOG_PERSONAL_API_KEY"
else
    echo "  需要 Personal API Key 来调用 PostHog API"
    echo "  获取方式：PostHog → 左下角头像 → Settings → Personal API Keys"
    echo ""
    read -rp "输入 Personal API Key: " API_KEY
    [[ -z "$API_KEY" ]] && error "API Key 不能为空"
fi

# ---- 验证 API Key ----
info "验证 API 连接..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${API_KEY}" \
    "${POSTHOG_HOST}/api/users/@me/" 2>/dev/null)
[[ "$HTTP_CODE" != "200" ]] && error "API 认证失败 (HTTP ${HTTP_CODE})，请检查 API Key 和 POSTHOG_HOST"
info "API 连接正常"

# ---- 获取 Project ID ----
PROJECT_ID=$(curl -s -H "Authorization: Bearer ${API_KEY}" \
    "${POSTHOG_HOST}/api/users/@me/" 2>/dev/null | jq -r '.team.id // .organization.teams[0].id // empty')
if [[ -z "$PROJECT_ID" ]]; then
    PROJECT_ID=$(curl -s -H "Authorization: Bearer ${API_KEY}" \
        "${POSTHOG_HOST}/api/projects/" 2>/dev/null | jq -r '.results[0].id // empty')
fi
[[ -z "$PROJECT_ID" ]] && { read -rp "无法自动获取 Project ID，请手动输入: " PROJECT_ID; }
[[ -z "$PROJECT_ID" ]] && error "Project ID 不能为空"
info "Project ID: ${PROJECT_ID}"

# ---- 输入保留域名 ----
read -rp "输入要保留的邮箱域名（如 example.com）: " KEEP_DOMAIN
KEEP_DOMAIN="${KEEP_DOMAIN:-${COMPANY_DOMAIN:-}}"
[[ -z "$KEEP_DOMAIN" ]] && error "域名不能为空"
if ! echo "$KEEP_DOMAIN" | grep -qP '^[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$'; then
    error "域名格式不合法: ${KEEP_DOMAIN}"
fi

# ============================================================
# 阶段一：处理已识别用户（有 person profile 的）
# ============================================================
info "收集所有 persons..."
DELETE_IDS=()
KEEP_DISTINCT_IDS=()
KEEP_COUNT=0
DELETE_COUNT=0
NEXT_URL="${POSTHOG_HOST}/api/environments/${PROJECT_ID}/persons/?limit=100"

while [[ -n "$NEXT_URL" && "$NEXT_URL" != "null" ]]; do
    RESPONSE=$(curl -s -H "Authorization: Bearer ${API_KEY}" "$NEXT_URL" 2>/dev/null)
    PERSON_COUNT=$(echo "$RESPONSE" | jq '.results | length')

    for i in $(seq 0 $((PERSON_COUNT - 1))); do
        PERSON_ID=$(echo "$RESPONSE" | jq -r ".results[$i].id")
        EMAIL=$(echo "$RESPONSE" | jq -r ".results[$i].properties.email // empty")
        DIDS=$(echo "$RESPONSE" | jq -r ".results[$i].distinct_ids[]" 2>/dev/null)

        SHOULD_KEEP=false
        [[ -n "$EMAIL" ]] && echo "$EMAIL" | grep -qi "@${KEEP_DOMAIN}$" && SHOULD_KEEP=true
        if [[ "$SHOULD_KEEP" == "false" && -n "$DIDS" ]]; then
            while IFS= read -r did; do
                echo "$did" | grep -qi "@${KEEP_DOMAIN}$" && SHOULD_KEEP=true && break
            done <<< "$DIDS"
        fi

        if [[ "$SHOULD_KEEP" == "true" ]]; then
            KEEP_COUNT=$((KEEP_COUNT + 1))
            while IFS= read -r did; do
                KEEP_DISTINCT_IDS+=("$did")
            done <<< "$DIDS"
        else
            DELETE_IDS+=("$PERSON_ID")
            DELETE_COUNT=$((DELETE_COUNT + 1))
        fi
    done

    printf "\r  已扫描 %d 个 persons（保留 %d，待删除 %d）" \
        $((KEEP_COUNT + DELETE_COUNT)) "$KEEP_COUNT" "$DELETE_COUNT"
    NEXT_URL=$(echo "$RESPONSE" | jq -r '.next // empty')
done
echo ""
echo "  保留: ${KEEP_COUNT} 个 @${KEEP_DOMAIN} 用户"
echo "  删除: ${DELETE_COUNT} 个非 @${KEEP_DOMAIN} 用户"

if [[ "$DELETE_COUNT" -gt 0 ]]; then
    warn "⚠️  将删除 ${DELETE_COUNT} 个已识别用户及其事件，不可恢复"
    read -rp "输入 YES 确认: " CONFIRM
    if [[ "$CONFIRM" == "YES" ]]; then
        info "批量删除已识别用户..."
        DELETED=0; FAILED=0; TOTAL=${#DELETE_IDS[@]}
        for ((i=0; i<TOTAL; i+=BATCH_SIZE)); do
            BATCH=("${DELETE_IDS[@]:$i:$BATCH_SIZE}")
            IDS_JSON=$(printf '%s\n' "${BATCH[@]}" | jq -R . | jq -s .)
            HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
                -H "Authorization: Bearer ${API_KEY}" -H "Content-Type: application/json" \
                -d "{\"ids\": ${IDS_JSON}, \"delete_events\": true}" \
                "${POSTHOG_HOST}/api/environments/${PROJECT_ID}/persons/bulk_delete/" 2>/dev/null)
            if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "204" ]]; then
                DELETED=$((DELETED + ${#BATCH[@]}))
            else
                for pid in "${BATCH[@]}"; do
                    DEL_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
                        -H "Authorization: Bearer ${API_KEY}" \
                        "${POSTHOG_HOST}/api/environments/${PROJECT_ID}/persons/${pid}/?delete_events=true" 2>/dev/null)
                    [[ "$DEL_CODE" == "204" || "$DEL_CODE" == "200" ]] && DELETED=$((DELETED + 1)) || FAILED=$((FAILED + 1))
                done
            fi
            printf "\r  进度: %d / %d（失败: %d）" "$DELETED" "$TOTAL" "$FAILED"
        done
        echo ""
        info "已识别用户: 成功 ${DELETED}, 失败 ${FAILED}"
    else
        info "跳过已识别用户删除"
    fi
else
    info "没有需要删除的已识别用户"
fi

# ============================================================
# 阶段二：处理匿名事件（无 person profile，只有 distinct_id）
# ============================================================
echo ""
info "检查匿名事件..."

ANON_DISTINCT_IDS=()
SEEN_DIDS=()
PAGE=0
MAX_PAGES=50
EVENTS_URL="${POSTHOG_HOST}/api/environments/${PROJECT_ID}/events/?limit=100"

while [[ -n "$EVENTS_URL" && "$EVENTS_URL" != "null" && "$PAGE" -lt "$MAX_PAGES" ]]; do
    RESPONSE=$(curl -s -H "Authorization: Bearer ${API_KEY}" "$EVENTS_URL" 2>/dev/null)
    EVENT_COUNT=$(echo "$RESPONSE" | jq '.results | length')
    [[ "$EVENT_COUNT" == "0" ]] && break

    for i in $(seq 0 $((EVENT_COUNT - 1))); do
        DID=$(echo "$RESPONSE" | jq -r ".results[$i].distinct_id")
        [[ -z "$DID" || "$DID" == "null" ]] && continue

        # 跳过已见过的
        SKIP=false
        for seen in "${SEEN_DIDS[@]+"${SEEN_DIDS[@]}"}"; do
            [[ "$seen" == "$DID" ]] && SKIP=true && break
        done
        [[ "$SKIP" == "true" ]] && continue
        SEEN_DIDS+=("$DID")

        # 跳过保留用户的 distinct_id
        for kid in "${KEEP_DISTINCT_IDS[@]+"${KEEP_DISTINCT_IDS[@]}"}"; do
            [[ "$kid" == "$DID" ]] && SKIP=true && break
        done
        # 跳过匹配保留域名的
        echo "$DID" | grep -qi "@${KEEP_DOMAIN}$" && SKIP=true

        [[ "$SKIP" == "false" ]] && ANON_DISTINCT_IDS+=("$DID")
    done

    PAGE=$((PAGE + 1))
    printf "\r  已扫描 %d 页事件，发现 %d 个匿名 distinct_id" "$PAGE" "${#ANON_DISTINCT_IDS[@]}"
    EVENTS_URL=$(echo "$RESPONSE" | jq -r '.next // empty')
done
echo ""

ANON_COUNT=${#ANON_DISTINCT_IDS[@]}
if [[ "$ANON_COUNT" -eq 0 ]]; then
    info "没有匿名事件需要清理"
else
    echo "  发现 ${ANON_COUNT} 个匿名 distinct_id"
    warn "⚠️  将通过 bulk_delete API 按 distinct_id 删除这些匿名事件"
    read -rp "输入 YES 确认: " CONFIRM_ANON
    if [[ "$CONFIRM_ANON" == "YES" ]]; then
        info "批量删除匿名事件..."
        ANON_DELETED=0; ANON_FAILED=0; ANON_TOTAL=$ANON_COUNT
        for ((i=0; i<ANON_TOTAL; i+=BATCH_SIZE)); do
            BATCH=("${ANON_DISTINCT_IDS[@]:$i:$BATCH_SIZE}")
            IDS_JSON=$(printf '%s\n' "${BATCH[@]}" | jq -R . | jq -s .)
            HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
                -H "Authorization: Bearer ${API_KEY}" -H "Content-Type: application/json" \
                -d "{\"distinct_ids\": ${IDS_JSON}, \"delete_events\": true}" \
                "${POSTHOG_HOST}/api/environments/${PROJECT_ID}/persons/bulk_delete/" 2>/dev/null)
            if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "204" ]]; then
                ANON_DELETED=$((ANON_DELETED + ${#BATCH[@]}))
            else
                ANON_FAILED=$((ANON_FAILED + ${#BATCH[@]}))
            fi
            printf "\r  进度: %d / %d（失败: %d）" "$ANON_DELETED" "$ANON_TOTAL" "$ANON_FAILED"
        done
        echo ""
        info "匿名事件: 成功 ${ANON_DELETED}, 失败 ${ANON_FAILED}"
    else
        info "跳过匿名事件清理"
    fi
fi

# ---- 完成 ----
echo ""
info "清理完成。事件数据由 PostHog 异步清理，刷新页面验证。"
