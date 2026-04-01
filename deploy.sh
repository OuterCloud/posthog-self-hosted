#!/usr/bin/env bash
# ============================================================
# PostHog 自托管部署脚本
# 适用系统：Rocky Linux 8.10 / CentOS 8 / RHEL 8
#
# 核心思路：复用 PostHog 官方的 docker-compose 和迁移脚本，
# 本脚本只负责环境准备（Docker、数据盘、.env）。
#
# 用法：sudo bash deploy.sh
# ============================================================

set -euo pipefail

# -------------------- 颜色输出 --------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

POSTHOG_DIR="$SCRIPT_DIR/posthog"
ENV_FILE="$SCRIPT_DIR/.env"
LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")

info "部署目录: $SCRIPT_DIR"

if [[ $EUID -ne 0 ]]; then
    error "请使用 root 用户或 sudo 执行此脚本"
fi

# ==================== 阶段一：磁盘检查 ====================
DOCKER_ROOT=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo "")
if [[ -z "$DOCKER_ROOT" ]] || [[ ! -d "$DOCKER_ROOT" ]]; then
    CHECK_PATH="/"
else
    CHECK_PATH="$DOCKER_ROOT"
fi
AVAIL_GB=$(df -BG "$CHECK_PATH" 2>/dev/null | awk 'NR==2 {gsub(/G/,"",$4); print $4}' || echo "0")

if [[ "$AVAIL_GB" -lt 10 ]]; then
    warn "磁盘可用空间不足（${AVAIL_GB}GB），可能导致部署失败"
    df -h "$CHECK_PATH" | head -2
    read -rp "是否继续？(y/N): " CONTINUE
    [[ ! "$CONTINUE" =~ ^[Yy]$ ]] && exit 1
elif [[ "$AVAIL_GB" -lt 30 ]]; then
    warn "磁盘可用空间较低（${AVAIL_GB}GB），建议 30GB 以上"
fi

# ==================== 阶段二：系统依赖 ====================
REQUIRED_PKGS=(yum-utils device-mapper-persistent-data lvm2 openssl git brotli)
MISSING_PKGS=()
for pkg in "${REQUIRED_PKGS[@]}"; do
    rpm -q "$pkg" &>/dev/null || MISSING_PKGS+=("$pkg")
done
if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
    info "安装系统依赖: ${MISSING_PKGS[*]}"
    dnf install -y "${MISSING_PKGS[@]}"
else
    info "系统依赖已就绪"
fi

# ==================== 阶段三：安装 Docker ====================
if command -v docker &>/dev/null; then
    info "Docker 已安装: $(docker --version | grep -oP '\d+\.\d+\.\d+')"
else
    info "安装 Docker..."
    dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi

# Docker 数据目录迁移到数据盘
DOCKER_DAEMON_JSON="/etc/docker/daemon.json"
CURRENT_DATA_ROOT=""
systemctl is-active --quiet docker && CURRENT_DATA_ROOT=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo "")
if [[ -z "$CURRENT_DATA_ROOT" ]] || [[ "$CURRENT_DATA_ROOT" == "/var/lib/docker" ]]; then
    if [[ -f "$DOCKER_DAEMON_JSON" ]]; then
        CONFIGURED=$(python3 -c "import json; print(json.load(open('$DOCKER_DAEMON_JSON')).get('data-root',''))" 2>/dev/null || echo "")
        [[ -n "$CONFIGURED" ]] && [[ "$CONFIGURED" != "/var/lib/docker" ]] && CURRENT_DATA_ROOT="$CONFIGURED"
    fi
fi
if [[ -z "$CURRENT_DATA_ROOT" ]] || [[ "$CURRENT_DATA_ROOT" == "/var/lib/docker" ]]; then
    DATA_MOUNT=""
    BEST_AVAIL=0
    while read -r mp ak; do
        [[ -z "$mp" || "$mp" == "/" ]] && continue
        if [[ "$mp" == /data* || "$mp" == /mnt* || "$mp" == /opt* ]]; then
            [[ "$ak" -gt "$BEST_AVAIL" ]] && BEST_AVAIL=$ak && DATA_MOUNT=$mp
        fi
    done < <(df -P | awk 'NR>1 {print $6, $4}')
    if [[ -n "$DATA_MOUNT" ]]; then
        ROOT_AVAIL=$(df -BG / | awk 'NR==2 {gsub(/G/,"",$4); print $4}')
        DATA_AVAIL=$((BEST_AVAIL / 1024 / 1024))
        if [[ "$DATA_AVAIL" -gt "$ROOT_AVAIL" ]]; then
            info "迁移 Docker 数据到 ${DATA_MOUNT}/docker（${DATA_AVAIL}GB）"
            systemctl stop docker docker.socket 2>/dev/null || true
            mkdir -p "${DATA_MOUNT}/docker"
            [[ -d "/var/lib/docker" ]] && [[ "$(ls -A /var/lib/docker 2>/dev/null)" ]] && \
                rsync -a /var/lib/docker/ "${DATA_MOUNT}/docker/" 2>/dev/null || true
            echo "{\"data-root\": \"${DATA_MOUNT}/docker\"}" > "$DOCKER_DAEMON_JSON"
            info "Docker 数据目录: ${DATA_MOUNT}/docker"
        fi
    fi
else
    info "Docker 数据目录: $CURRENT_DATA_ROOT"
fi

systemctl is-active --quiet docker || systemctl start docker
systemctl is-enabled --quiet docker || systemctl enable docker
info "Docker Compose: $(docker compose version --short 2>/dev/null || echo '未安装')"

# ==================== 阶段四：系统参数优化 ====================
SYSCTL_CONF="/etc/sysctl.d/99-posthog.conf"
if [[ "$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)" -lt 262144 ]]; then
    cat > "$SYSCTL_CONF" <<EOF
vm.max_map_count=262144
net.core.somaxconn=65535
EOF
    sysctl --system > /dev/null 2>&1
    info "系统参数已优化"
else
    info "系统参数已就绪"
fi

# ==================== 阶段五：Clone PostHog 官方仓库 ====================
if [[ -d "$POSTHOG_DIR/.git" ]]; then
    info "更新 PostHog 仓库..."
    git -C "$POSTHOG_DIR" fetch origin 2>/dev/null
    git -C "$POSTHOG_DIR" reset --hard origin/master 2>/dev/null
else
    info "克隆 PostHog 仓库..."
    git clone --filter=blob:none https://github.com/PostHog/posthog.git "$POSTHOG_DIR"
fi

# ==================== 阶段六：生成 .env ====================
if [[ -f "$ENV_FILE" ]]; then
    warn ".env 文件已存在"
    read -rp "是否覆盖？(y/N): " OVERWRITE
    if [[ "$OVERWRITE" =~ ^[Yy]$ ]]; then
        warn "⚠️  覆盖会重新生成密码，现有数据将被清除！"
        read -rp "输入 YES 确认: " CONFIRM
        if [[ "$CONFIRM" != "YES" ]]; then
            info "取消覆盖"
            SKIP_ENV=true
        else
            docker compose -f docker-compose.yml down -v 2>/dev/null || true
        fi
    else
        SKIP_ENV=true
    fi
fi

if [[ "${SKIP_ENV:-}" != "true" ]]; then
    echo ""
    echo "=========================================="
    echo "  PostHog 环境配置"
    echo "=========================================="
    echo ""
    echo "  ⚠️  域名必须与浏览器访问地址一致，否则会 CSRF 错误"
    read -rp "访问域名 [默认: ${LOCAL_IP}]: " INPUT_DOMAIN
    DOMAIN="${INPUT_DOMAIN:-$LOCAL_IP}"

    POSTHOG_SECRET=$(openssl rand -hex 32)
    ENCRYPTION_SALT_KEYS=$(openssl rand -hex 16)

    cat > "$ENV_FILE" <<EOF
POSTHOG_SECRET=${POSTHOG_SECRET}
ENCRYPTION_SALT_KEYS=${ENCRYPTION_SALT_KEYS}
DOMAIN=${DOMAIN}
TLS_BLOCK=
REGISTRY_URL=posthog/posthog
CADDY_TLS_BLOCK=
CADDY_HOST="${DOMAIN}, http://, https://"
POSTHOG_APP_TAG=latest
POSTHOG_NODE_TAG=latest
OPT_OUT_CAPTURE=true
EOF
    chmod 600 "$ENV_FILE"
    info ".env 已生成，DOMAIN=${DOMAIN}"
fi

# 补全 .env 中可能缺失的变量（幂等：已存在则跳过）
ensure_env_var() {
    local key=$1 default=$2
    if ! grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
        echo "${key}=${default}" >> "$ENV_FILE"
        info ".env 补充: ${key}=${default}"
    fi
}
ensure_env_var "POSTHOG_NODE_TAG" "latest"
ensure_env_var "ENCRYPTION_SALT_KEYS" "$(openssl rand -hex 16)"

# ==================== 阶段七：准备启动文件（复用官方脚本）====================
# 下载 GeoIP 数据库
mkdir -p "$SCRIPT_DIR/share"
if [[ ! -f "$SCRIPT_DIR/share/GeoLite2-City.mmdb" ]]; then
    info "下载 GeoIP 数据库..."
    curl -sL 'https://mmdbcdn.posthog.net/' --http1.1 | brotli --decompress > "$SCRIPT_DIR/share/GeoLite2-City.mmdb" 2>/dev/null || \
    warn "GeoIP 下载失败，地理位置分析将不可用"
fi

# 创建 compose/start 脚本（官方 deploy-hobby 的做法）
rm -rf "$SCRIPT_DIR/compose"
mkdir -p "$SCRIPT_DIR/compose"

cat > "$SCRIPT_DIR/compose/start" <<'EOF'
#!/bin/bash
./compose/wait
./bin/migrate
./bin/docker-server
EOF
chmod +x "$SCRIPT_DIR/compose/start"

cat > "$SCRIPT_DIR/compose/temporal-django-worker" <<'EOF'
#!/bin/bash
./bin/temporal-django-worker
EOF
chmod +x "$SCRIPT_DIR/compose/temporal-django-worker"

cat > "$SCRIPT_DIR/compose/wait" <<'EOF'
#!/usr/bin/env python3
import socket, time
def loop():
    print("Waiting for ClickHouse and Postgres to be ready")
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.connect(('clickhouse', 9000))
        print("ClickHouse is ready")
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.connect(('db', 5432))
        print("Postgres is ready")
    except ConnectionRefusedError:
        time.sleep(5)
        loop()
loop()
EOF
chmod +x "$SCRIPT_DIR/compose/wait"

# 复制官方 docker-compose 文件
cp "$POSTHOG_DIR/docker-compose.base.yml" "$SCRIPT_DIR/docker-compose.base.yml"
cp "$POSTHOG_DIR/docker-compose.hobby.yml" "$SCRIPT_DIR/docker-compose.yml"
cp "$POSTHOG_DIR/dev-services.env" "$SCRIPT_DIR/dev-services.env" 2>/dev/null || true

# 创建 override 文件（公司网关转发到 8000 端口）
cat > "$SCRIPT_DIR/docker-compose.override.yml" <<'EOF'
services:
  proxy:
    ports:
      - "8000:80"
EOF

info "已复制官方 docker-compose 配置（8000 端口已映射）"

# ==================== 阶段八：启动服务 ====================
info "拉取镜像（含 Node 服务镜像 posthog/posthog-node）..."
docker compose pull 2>&1 | tail -10

info "启动所有服务（首次启动需要 5~10 分钟）..."
docker compose up -d 2>&1 | tail -20

# 确保 override 端口映射生效
docker compose up -d proxy --force-recreate 2>/dev/null

# ---- 检查 plugins 容器（Plugin server · Node）----
sleep 10
PLUGINS_STATUS=$(docker compose ps plugins --format "{{.Status}}" 2>/dev/null | head -1)
if echo "$PLUGINS_STATUS" | grep -qi "restarting\|exited\|dead\|error"; then
    warn "plugins 容器异常: $PLUGINS_STATUS"
    warn "尝试重启 plugins 及相关 Node 服务..."
    docker compose up -d plugins ingestion-general ingestion-sessionreplay recording-api ingestion-error-tracking ingestion-logs ingestion-traces --force-recreate 2>/dev/null
    sleep 15
    PLUGINS_STATUS=$(docker compose ps plugins --format "{{.Status}}" 2>/dev/null | head -1)
    if echo "$PLUGINS_STATUS" | grep -qi "restarting\|exited\|dead\|error"; then
        warn "plugins 仍然异常，查看日志: docker compose logs plugins --tail 30"
    else
        info "plugins 已恢复: $PLUGINS_STATUS"
    fi
elif [[ -z "$PLUGINS_STATUS" ]]; then
    warn "plugins 容器未运行，尝试启动..."
    docker compose up -d plugins 2>/dev/null
else
    info "plugins 容器状态: $PLUGINS_STATUS"
fi

# ==================== 阶段九：等待健康检查 ====================
info "等待 PostHog 启动..."
MAX_WAIT=600
ELAPSED=0
INTERVAL=10

while [[ $ELAPSED -lt $MAX_WAIT ]]; do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://localhost:8000/_health/ 2>/dev/null || echo "000")
    if [[ "$HTTP_CODE" == "200" ]]; then
        break
    fi
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
    printf "\r  等待中... %ds / %ds (HTTP: %s)   " "$ELAPSED" "$MAX_WAIT" "$HTTP_CODE"
done
echo ""

if [[ "$ELAPSED" -ge "$MAX_WAIT" ]]; then
    warn "PostHog 未能在 ${MAX_WAIT}s 内就绪"
    echo "  检查日志: docker compose logs web --tail 20"
else
    info "PostHog 已启动"
fi

# ==================== 阶段十：验证 ====================
echo ""
info "验证服务状态..."
check_endpoint() {
    local name=$1 url=$2
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null || echo "000")
    if [[ "$code" == "200" || "$code" == "302" || "$code" == "401" ]]; then
        echo "  ✅ ${name}: ${code}"
    else
        echo "  ❌ ${name}: ${code}"
    fi
}
check_endpoint "健康检查"  "http://localhost:8000/_health/"
check_endpoint "首页"      "http://localhost:8000/"
check_endpoint "API"       "http://localhost:8000/api/"
check_endpoint "登录页"    "http://localhost:8000/login"

DOMAIN=$(grep '^DOMAIN=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 || echo "$LOCAL_IP")
TLS_CONFIGURED=$(grep '^TLS_BLOCK=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2-)
if [[ -n "$TLS_CONFIGURED" ]]; then
    PROTOCOL="https"
else
    PROTOCOL="http"
fi

echo ""
echo "========================================================"
info "PostHog 部署完成"
echo "========================================================"
echo ""
echo "  访问地址:  ${PROTOCOL}://${DOMAIN}"
echo "  首次访问请按页面引导创建管理员账号"
echo ""
echo "  常用命令:"
echo "    查看状态:  docker compose ps"
echo "    查看日志:  docker compose logs -f web"
echo "    升级版本:  git -C posthog pull && docker compose up -d --pull always"
echo ""
