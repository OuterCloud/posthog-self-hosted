#!/usr/bin/env bash
# ============================================================
# PostHog 健康检查 & 自动修复脚本
# 用法：bash doctor.sh          # 仅检查
#       bash doctor.sh --fix    # 检查并修复
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✅${NC} $*"; }
fail() { echo -e "  ${RED}❌${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠️${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

AUTO_FIX=false
[[ "${1:-}" == "--fix" ]] && AUTO_FIX=true

ERRORS=0
FIXES=()        # 收集可修复的问题描述
FIX_CMDS=()     # 对应的修复命令

echo ""
echo "=========================================="
echo "  PostHog 健康检查"
echo "=========================================="

# -------------------- 1. 磁盘空间 --------------------
echo ""
echo "💾 磁盘空间"
while read -r fs size used avail pct mount; do
    [[ "$fs" == "Filesystem" ]] && continue
    # 去掉百分号
    pct_num="${pct%%%}"
    if [[ "$pct_num" -ge 90 ]] 2>/dev/null; then
        fail "${mount}: ${used}/${size} 已用 (${pct}) — 空间严重不足"
        ERRORS=$((ERRORS + 1))
    elif [[ "$pct_num" -ge 80 ]] 2>/dev/null; then
        warn "${mount}: ${used}/${size} 已用 (${pct})"
    else
        ok "${mount}: ${used}/${size} 已用 (${pct}), ${avail} 可用"
    fi
done < <(df -h --type=ext4 --type=xfs --type=btrfs --type=overlay 2>/dev/null || df -h 2>/dev/null | grep -E '^/dev/')

# -------------------- 2. Docker --------------------
echo ""
echo "📦 Docker"
if command -v docker &>/dev/null; then
    ok "Docker $(docker --version | grep -oP '\d+\.\d+\.\d+')"
else
    fail "Docker 未安装"
    ERRORS=$((ERRORS + 1))
fi

DOCKER_ROOT=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo "unknown")
DOCKER_AVAIL=$(df -BG "$DOCKER_ROOT" 2>/dev/null | awk 'NR==2 {gsub(/G/,"",$4); print $4}' || echo "?")
if [[ "$DOCKER_AVAIL" != "?" ]] && [[ "$DOCKER_AVAIL" -lt 10 ]]; then
    fail "Docker 磁盘空间不足: ${DOCKER_AVAIL}GB ($DOCKER_ROOT)"
    ERRORS=$((ERRORS + 1))
else
    ok "Docker 磁盘: ${DOCKER_AVAIL}GB 可用 ($DOCKER_ROOT)"
fi

# -------------------- 3. 内存 --------------------
echo ""
echo "🧠 内存"
MEM_TOTAL=$(free -g 2>/dev/null | awk '/Mem:/ {print $2}' || echo "?")
MEM_AVAIL=$(free -g 2>/dev/null | awk '/Mem:/ {print $7}' || echo "?")
if [[ "$MEM_AVAIL" != "?" ]] && [[ "$MEM_AVAIL" -lt 2 ]]; then
    fail "可用内存不足: ${MEM_AVAIL}GB / ${MEM_TOTAL}GB"
    ERRORS=$((ERRORS + 1))
elif [[ "$MEM_AVAIL" != "?" ]] && [[ "$MEM_AVAIL" -lt 4 ]]; then
    warn "可用内存较低: ${MEM_AVAIL}GB / ${MEM_TOTAL}GB"
else
    ok "内存: ${MEM_AVAIL}GB 可用 / ${MEM_TOTAL}GB 总计"
fi

# -------------------- 4. 容器状态 --------------------
echo ""
echo "🐳 容器状态"
DEAD_SERVICES=()
SERVICES=(db redis7 clickhouse zookeeper kafka web worker plugins ingestion-general ingestion-sessionreplay recording-api ingestion-error-tracking capture feature-flags proxy livestream temporal)
for svc in "${SERVICES[@]}"; do
    STATUS=$(docker compose ps "$svc" --format "{{.Status}}" 2>/dev/null | head -1)
    if [[ -z "$STATUS" ]]; then
        fail "$svc: 未运行"
        DEAD_SERVICES+=("$svc")
        ERRORS=$((ERRORS + 1))
    elif echo "$STATUS" | grep -qi "restarting\|exited\|dead"; then
        fail "$svc: $STATUS"
        DEAD_SERVICES+=("$svc")
        ERRORS=$((ERRORS + 1))
    elif echo "$STATUS" | grep -qi "unhealthy"; then
        warn "$svc: $STATUS"
    else
        ok "$svc: $STATUS"
    fi
done
if [[ ${#DEAD_SERVICES[@]} -gt 0 ]]; then
    FIXES+=("重启异常容器: ${DEAD_SERVICES[*]}")
    FIX_CMDS+=("docker compose up -d ${DEAD_SERVICES[*]}")
fi

# -------------------- 5. HTTP 接口 --------------------
echo ""
echo "🌐 HTTP 接口"
check_http() {
    local name=$1 url=$2 expect=$3
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null || echo "000")
    if echo "$expect" | grep -q "$code"; then
        ok "$name: HTTP $code"
    else
        fail "$name: HTTP $code (期望 $expect)"
        ERRORS=$((ERRORS + 1))
    fi
}
check_http "健康检查 /_health/"  "http://localhost:8000/_health/"  "200"
check_http "首页 /"              "http://localhost:8000/"          "200|302"
check_http "API /api/"           "http://localhost:8000/api/"      "200|401"
check_http "登录页 /login"       "http://localhost:8000/login"     "200"
check_http "事件上报 /e/ (POST)" "http://localhost:8000/e/"        "200|400"

# -------------------- 6. 数据库 --------------------
echo ""
echo "🗄️ 数据库"

# PostgreSQL
PG_OK=$(docker compose exec -T db psql -U posthog -tAc "SELECT 1" 2>/dev/null | tr -d '[:space:]')
if [[ "$PG_OK" == "1" ]]; then
    PG_TABLES=$(docker compose exec -T db psql -U posthog -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'" 2>/dev/null | tr -d '[:space:]')
    ok "PostgreSQL: 连接正常, ${PG_TABLES} 张表"
else
    fail "PostgreSQL: 连接失败"
    ERRORS=$((ERRORS + 1))
fi

# Persons 迁移
PERSONS_COL=$(docker compose exec -T db psql -U posthog -tAc "SELECT count(*) FROM information_schema.columns WHERE table_name='posthog_person' AND column_name='last_seen_at'" 2>/dev/null | tr -d '[:space:]')
if [[ "$PERSONS_COL" == "1" ]]; then
    ok "Persons 迁移: 已完成"
else
    fail "Persons 迁移: last_seen_at 列缺失，需执行 apply_persons_migrations"
    ERRORS=$((ERRORS + 1))
fi

# 异步迁移
ASYNC_COUNT=$(docker compose exec -T db psql -U posthog -tAc "SELECT count(*) FROM posthog_asyncmigration WHERE status=2" 2>/dev/null | tr -d '[:space:]' || echo "0")
if [[ "$ASYNC_COUNT" -ge 10 ]]; then
    ok "异步迁移: ${ASYNC_COUNT} 条已完成"
else
    warn "异步迁移: 仅 ${ASYNC_COUNT} 条完成（需要 10 条）"
fi

# ClickHouse
CH_OK=$(docker compose exec -T clickhouse clickhouse-client --query "SELECT 1" 2>/dev/null | tr -d '[:space:]')
if [[ "$CH_OK" == "1" ]]; then
    CH_EVENTS=$(docker compose exec -T clickhouse clickhouse-client --query "SELECT count() FROM posthog.events" 2>/dev/null | tr -d '[:space:]')
    ok "ClickHouse: 连接正常, events 表 ${CH_EVENTS} 条"

    # 最近 10 分钟是否有新事件写入
    RECENT_EVENTS=$(docker compose exec -T clickhouse clickhouse-client --query "
        SELECT count() FROM posthog.events WHERE timestamp > now() - INTERVAL 10 MINUTE
    " 2>/dev/null | tr -d '[:space:]' || echo "?")
    if [[ "$RECENT_EVENTS" == "0" ]]; then
        fail "ClickHouse: 最近 10 分钟无新事件写入，数据摄入可能中断"
        ERRORS=$((ERRORS + 1))
    elif [[ "$RECENT_EVENTS" != "?" ]]; then
        ok "ClickHouse: 最近 10 分钟写入 ${RECENT_EVENTS} 条事件"
    fi
else
    fail "ClickHouse: 连接失败"
    ERRORS=$((ERRORS + 1))
fi

# -------------------- 6.1 ClickHouse Mutations --------------------
echo ""
echo "🔄 ClickHouse Mutations"
if [[ "$CH_OK" == "1" ]]; then
    PENDING_MUT=$(docker compose exec -T clickhouse clickhouse-client --query "
        SELECT count() FROM system.mutations WHERE is_done = 0 AND database = 'posthog'
    " 2>/dev/null | tr -d '[:space:]' || echo "?")
    if [[ "$PENDING_MUT" == "0" ]]; then
        ok "无进行中的 mutations"
    elif [[ "$PENDING_MUT" != "?" ]]; then
        warn "有 ${PENDING_MUT} 个进行中的 mutations（可能影响写入性能）"
        docker compose exec -T clickhouse clickhouse-client --query "
            SELECT mutation_id, table, substr(command, 1, 80) AS cmd, create_time, latest_fail_reason
            FROM system.mutations WHERE is_done = 0 AND database = 'posthog' ORDER BY create_time LIMIT 10
        " 2>/dev/null | while IFS=$'\t' read -r mid tbl cmd ctime reason; do
            echo "    - ${mid} | ${tbl} | ${ctime}"
            [[ -n "$reason" ]] && echo -e "      ${RED}失败: ${reason}${NC}"
        done
    fi

    # 失败的 mutations
    FAILED_MUT=$(docker compose exec -T clickhouse clickhouse-client --query "
        SELECT count() FROM system.mutations WHERE database = 'posthog' AND latest_fail_reason != ''
    " 2>/dev/null | tr -d '[:space:]' || echo "0")
    if [[ "$FAILED_MUT" -gt 0 ]]; then
        fail "有 ${FAILED_MUT} 个失败的 mutations"
        ERRORS=$((ERRORS + 1))
        docker compose exec -T clickhouse clickhouse-client --query "
            SELECT mutation_id, table, latest_fail_reason FROM system.mutations
            WHERE database = 'posthog' AND latest_fail_reason != '' LIMIT 5
        " 2>/dev/null | while IFS=$'\t' read -r mid tbl reason; do
            echo "    ❌ ${mid} (${tbl}): ${reason}"
        done
    else
        ok "无失败的 mutations"
    fi
fi

# -------------------- 6.2 ClickHouse 表引擎 --------------------
echo ""
echo "📊 ClickHouse 关键表"
if [[ "$CH_OK" == "1" ]]; then
    for tbl in events person person_distinct_id2 session_recording_events; do
        ENGINE=$(docker compose exec -T clickhouse clickhouse-client --query "
            SELECT engine FROM system.tables WHERE database='posthog' AND name='${tbl}'
        " 2>/dev/null | tr -d '[:space:]' || echo "?")
        ROWS=$(docker compose exec -T clickhouse clickhouse-client --query "
            SELECT count() FROM posthog.${tbl}
        " 2>/dev/null | tr -d '[:space:]' || echo "?")
        ok "${tbl}: ${ENGINE} (${ROWS} 行)"
    done
fi

# -------------------- 7. Kafka --------------------
echo ""
echo "📨 Kafka"
TOPIC_COUNT=$(docker compose exec -T kafka rpk topic list --brokers localhost:9092 2>/dev/null | wc -l | tr -d ' ')
if [[ "$TOPIC_COUNT" -gt 5 ]]; then
    ok "Kafka: ${TOPIC_COUNT} 个 topics"
else
    fail "Kafka: 仅 ${TOPIC_COUNT} 个 topics"
    ERRORS=$((ERRORS + 1))
fi

# 检查所有 consumer groups
echo ""
echo "  Consumer Groups:"
docker compose exec -T kafka rpk group list --brokers localhost:9092 2>/dev/null | tail -n +2 | while read -r group; do
    group=$(echo "$group" | awk '{print $1}')
    [[ -z "$group" ]] && continue
    GROUP_LAG=$(docker compose exec -T kafka rpk group describe "$group" --brokers localhost:9092 2>/dev/null | grep "TOTAL-LAG" | awk '{print $2}' || echo "?")
    GROUP_STATE=$(docker compose exec -T kafka rpk group describe "$group" --brokers localhost:9092 2>/dev/null | grep "STATE" | awk '{print $2}' || echo "?")
    if [[ "$GROUP_LAG" == "0" ]]; then
        ok "$group: lag=0, state=${GROUP_STATE}"
    elif [[ "$GROUP_LAG" != "?" ]] && [[ "$GROUP_LAG" -gt 1000 ]] 2>/dev/null; then
        fail "$group: lag=${GROUP_LAG}, state=${GROUP_STATE}"
        ERRORS=$((ERRORS + 1))
    elif [[ "$GROUP_LAG" != "?" ]]; then
        warn "$group: lag=${GROUP_LAG}, state=${GROUP_STATE}"
    else
        warn "$group: 无法获取 lag"
    fi
done

# 检查 ingestion consumer lag（保留原有检查）
LAG=$(docker compose exec -T kafka rpk group describe clickhouse-ingestion --brokers localhost:9092 2>/dev/null | grep "TOTAL-LAG" | awk '{print $2}' || echo "?")
if [[ "$LAG" == "0" ]]; then
    ok "Ingestion 消费: 无积压 (lag=0)"
elif [[ "$LAG" != "?" ]]; then
    warn "Ingestion 消费: lag=${LAG}"
else
    warn "Ingestion 消费: 无法获取 lag"
fi

# -------------------- 8. 服务错误日志 --------------------
echo ""
echo "📋 最近 5 分钟错误日志"
for svc in web worker plugins ingestion-general ingestion-sessionreplay capture feature-flags; do
    errors=$(docker compose logs "$svc" --since 5m 2>&1 | grep -c '"level":"error"' 2>/dev/null || true)
    errors=$(echo "$errors" | tr -d '[:space:]')
    errors=${errors:-0}
    if [[ "$errors" -gt 0 ]] 2>/dev/null; then
        fail "$svc: ${errors} 个错误"
        ERRORS=$((ERRORS + 1))
    else
        ok "$svc: 无错误"
    fi
done

# -------------------- 9. 配置 --------------------
echo ""
echo "⚙️ 配置"
if [[ -f ".env" ]]; then
    SITE_URL=$(grep '^DOMAIN=' .env | cut -d'=' -f2)
    ok "DOMAIN: $SITE_URL"
else
    fail ".env 文件不存在"
    ERRORS=$((ERRORS + 1))
fi

# -------------------- 10. 环境变量完整性 --------------------
echo ""
echo "🔧 环境变量完整性"
OVERRIDE_FILE="docker-compose.override.yml"

# 检查 plugins 服务的 Redis 相关变量（通过 docker compose config 检测实际生效值）
# PostHog Node 服务（plugins 等）缺失这些变量时会 fallback 到 127.0.0.1
REQUIRED_PLUGIN_ENVS=(
    "LOGS_REDIS_HOST"
    "LOGS_REDIS_PORT"
    "LOGS_REDIS_TLS"
    "TRACES_REDIS_HOST"
    "TRACES_REDIS_PORT"
)
MISSING_PLUGIN_ENVS=()
for key in "${REQUIRED_PLUGIN_ENVS[@]}"; do
    if docker compose config 2>/dev/null | grep -A 100 "^  plugins:" | grep -q "${key}:"; then
        ok "plugins.${key} 已配置"
    else
        if [[ "$key" == *"_TLS" ]]; then
            fail "plugins.${key} 未配置（生产环境默认开启 TLS，自托管 Redis 无 TLS 会导致连接超时）"
        else
            fail "plugins.${key} 未配置（fallback 到 127.0.0.1 会导致连接失败）"
        fi
        MISSING_PLUGIN_ENVS+=("$key")
        ERRORS=$((ERRORS + 1))
    fi
done

if [[ ${#MISSING_PLUGIN_ENVS[@]} -gt 0 ]]; then
    FIXES+=("在 ${OVERRIDE_FILE} 中为 plugins 补充缺失的 Redis 环境变量")
    # 构建修复命令：用 python3 安全地合并 YAML（避免覆盖已有配置）
    FIX_CMDS+=("python3 -c \"
import yaml, sys
path = '${OVERRIDE_FILE}'
try:
    with open(path) as f:
        data = yaml.safe_load(f) or {}
except FileNotFoundError:
    data = {}
services = data.setdefault('services', {})
plugins = services.setdefault('plugins', {})
env = plugins.setdefault('environment', {})
env.setdefault('LOGS_REDIS_HOST', 'redis7')
env.setdefault('LOGS_REDIS_PORT', '6379')
env.setdefault('LOGS_REDIS_TLS', 'false')
env.setdefault('TRACES_REDIS_HOST', 'redis7')
env.setdefault('TRACES_REDIS_PORT', '6379')
plugins.setdefault('restart', 'on-failure')
with open(path, 'w') as f:
    yaml.dump(data, f, default_flow_style=False)
print('已更新 ${OVERRIDE_FILE}')
\" && docker compose up -d --force-recreate plugins"
    )
fi

# 检查 plugins 是否有 restart 策略
PLUGINS_RESTART=$(docker compose config 2>/dev/null | grep -A 100 "^  plugins:" | grep -m1 "restart:" | awk '{print $2}' || echo "")
if [[ -z "$PLUGINS_RESTART" || "$PLUGINS_RESTART" == "no" ]]; then
    fail "plugins 无 restart 策略（Redis 偶尔超时会导致永久退出）"
    ERRORS=$((ERRORS + 1))
    # 只在上面没有已经加过修复时才追加
    if [[ ${#MISSING_PLUGIN_ENVS[@]} -eq 0 ]]; then
        FIXES+=("为 plugins 添加 restart: on-failure 策略")
        FIX_CMDS+=("python3 -c \"
import yaml
path = '${OVERRIDE_FILE}'
try:
    with open(path) as f:
        data = yaml.safe_load(f) or {}
except FileNotFoundError:
    data = {}
services = data.setdefault('services', {})
plugins = services.setdefault('plugins', {})
plugins['restart'] = 'on-failure'
with open(path, 'w') as f:
    yaml.dump(data, f, default_flow_style=False)
print('已更新 ${OVERRIDE_FILE}')
\" && docker compose up -d --force-recreate plugins"
        )
    fi
else
    ok "plugins restart 策略: ${PLUGINS_RESTART}"
fi

# -------------------- 汇总 --------------------
echo ""
echo "=========================================="
if [[ "$ERRORS" -eq 0 ]]; then
    echo -e "  ${GREEN}所有检查通过 ✅${NC}"
else
    echo -e "  ${RED}发现 ${ERRORS} 个问题 ❌${NC}"
fi
echo "=========================================="

# -------------------- 自动修复 --------------------
if [[ ${#FIXES[@]} -gt 0 ]]; then
    echo ""
    echo "🔧 可自动修复的问题："
    for i in "${!FIXES[@]}"; do
        echo "  $((i+1)). ${FIXES[$i]}"
    done

    if [[ "$AUTO_FIX" == "true" ]]; then
        echo ""
        for i in "${!FIXES[@]}"; do
            echo -e "  ${YELLOW}修复:${NC} ${FIXES[$i]}"
            eval "${FIX_CMDS[$i]}" 2>&1 | sed 's/^/    /'
            echo -e "  ${GREEN}完成${NC}"
        done
        echo ""
        echo "=========================================="
        echo -e "  ${GREEN}修复完成，建议重新运行 bash doctor.sh 验证${NC}"
        echo "=========================================="
    else
        echo ""
        echo "  运行 bash doctor.sh --fix 自动修复以上问题"
    fi
fi
echo ""
