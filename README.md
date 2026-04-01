# PostHog 内部部署

公司内网自托管的 PostHog 产品分析平台。基于官方 hobby 部署方案，使用 Docker Compose。

## 环境要求

- 系统：Rocky Linux 8 / CentOS 8 / RHEL 8
- Docker >= 24.0
- 内存 >= 16GB（建议 32GB）
- 磁盘 >= 50GB（建议数据盘 300GB+）

## 快速部署

```bash
# 1. 创建本地配置
cp config.example.sh config.local.sh
# 编辑 config.local.sh 填入实际的域名、API Key 等

# 2. 执行部署
sudo bash deploy.sh
```

一条命令完成所有操作：安装 Docker、迁移数据盘、clone PostHog 官方仓库、生成配置、启动服务、执行迁移。

脚本只问一个问题：访问域名。其余全部自动处理。

> 注意：域名必须与浏览器访问地址一致，否则会 CSRF 错误。

## 升级

```bash
# 更新官方代码并重启
git -C posthog pull
docker compose up -d --pull always
```

## 健康检查

```bash
bash doctor.sh          # 检查所有服务状态
bash doctor.sh --fix    # 检查并自动修复
```

检查项包括：磁盘空间、容器状态、HTTP 接口、数据库连接、ClickHouse mutations、Kafka consumer lag、环境变量完整性等。

## 数据清理

```bash
bash cleanup.sh
```

通过 PostHog 官方 Persons API 清理非指定邮箱域名的用户及其事件数据，同时支持清理匿名事件。需要 Personal API Key。

> ⚠️ 此操作不可恢复，执行前请确认。

## 常用命令

```bash
docker compose ps              # 查看服务状态
docker compose logs -f web     # 查看 web 日志
docker compose stop            # 停止服务
docker compose down -v         # 清除所有数据（危险）
```

## 备份

```bash
docker compose exec db pg_dump -U posthog posthog > backup_$(date +%Y%m%d).sql
```

## 前端集成

Project API Key 在 PostHog 控制台 Settings → Project → Project API Key 获取。

## 相关文档

- 技术选型报告
- 埋点需求文档
- 前端 SDK 初始化示例
- PostHog 平台使用指南
