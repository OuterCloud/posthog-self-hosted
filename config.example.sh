#!/usr/bin/env bash
# ============================================================
# PostHog 本地配置（示例文件）
#
# 使用方式：
#   1. 复制本文件为 config.local.sh
#   2. 填入实际值
#   3. config.local.sh 不会被提交到 Git
#
#   cp config.example.sh config.local.sh
# ============================================================

# PostHog 部署地址（浏览器访问地址）
POSTHOG_HOST="https://your-posthog-host.example.com"

# PostHog Project API Key（控制台 Settings → Project → Project API Key）
POSTHOG_API_KEY="phc_YOUR_PROJECT_API_KEY"

# Personal API Key（用于 cleanup.sh 等管理脚本）
# 获取方式：PostHog → 左下角头像 → Settings → Personal API Keys
POSTHOG_PERSONAL_API_KEY=""

# 公司邮箱域名（cleanup.sh 用于过滤保留用户）
COMPANY_DOMAIN="your-domain.com"
