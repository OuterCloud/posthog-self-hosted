# Tigo 发布平台 — PostHog 埋点需求文档（Tracking Plan）

本文档定义需要采集的用户行为数据，用于平台使用分析与体验优化。

> 事件命名规范：`对象_动作`，全小写，下划线分隔。如 `ticket_created`、`release_published`。

---

## 一、采集目标

| 目标             | 说明                               |
| ---------------- | ---------------------------------- |
| 了解平台使用情况 | 各功能模块的使用频率和活跃度       |
| 优化操作体验     | 通过会话录制和用户路径发现体验问题 |
| 衡量功能采用率   | 新功能上线后的使用趋势             |
| 转化路径分析     | （待定义，后续补充）               |

---

## 二、自动采集（无需代码）

PostHog 默认自动采集以下数据，无需额外开发：

| 事件           | 说明                                      |
| -------------- | ----------------------------------------- |
| `$pageview`    | 每次路由变化自动记录                      |
| `$pageleave`   | 用户离开页面                              |
| `$autocapture` | 带有 `data-attr` 属性的元素点击、表单提交 |
| 会话录制       | 用户操作回放（已屏蔽密码等敏感输入）      |
| Web Vitals     | 页面性能指标（LCP、FID、CLS）             |

自动采集已经能覆盖大部分页面级分析需求。以下自定义事件用于追踪更精确的业务操作。

---

## 三、自定义事件清单

### 3.1 用户登录 & 退出

| 事件名            | 触发时机 | 属性                       |
| ----------------- | -------- | -------------------------- |
| `user_logged_in`  | 登录成功 | `method`（sso / password） |
| `user_logged_out` | 退出登录 | —                          |

```js
posthog.capture("user_logged_in", { method: "sso" });
posthog.identify(user.id, {
  email: user.email,
  name: user.name,
  role: user.role,
});
```

### 3.2 工单 / Ticket

| 事件名            | 触发时机     | 属性                         |
| ----------------- | ------------ | ---------------------------- |
| `ticket_created`  | 创建工单     | `ticket_type`, `env`         |
| `ticket_viewed`   | 查看工单详情 | `ticket_id`, `ticket_type`   |
| `ticket_approved` | 审批通过     | `ticket_id`, `approver_role` |
| `ticket_rejected` | 审批驳回     | `ticket_id`, `reject_reason` |
| `ticket_closed`   | 关闭工单     | `ticket_id`                  |

### 3.3 发布 / Release

| 事件名                | 触发时机     | 属性                                 |
| --------------------- | ------------ | ------------------------------------ |
| `release_created`     | 创建发布记录 | `app_name`, `env`, `version`         |
| `release_published`   | 执行发布     | `app_name`, `env`, `version`         |
| `release_rolled_back` | 回滚         | `app_name`, `env`, `rollback_reason` |
| `release_viewed`      | 查看发布详情 | `release_id`, `app_name`             |

### 3.4 环境管理

| 事件名               | 触发时机     | 属性                 |
| -------------------- | ------------ | -------------------- |
| `env_switched`       | 切换环境     | `from_env`, `to_env` |
| `env_config_updated` | 修改环境配置 | `env`, `config_key`  |

### 3.5 变更记录 / 日志

| 事件名             | 触发时机     | 属性             |
| ------------------ | ------------ | ---------------- |
| `changelog_viewed` | 查看变更记录 | `app_name`       |
| `log_searched`     | 搜索日志     | `keyword`, `env` |

### 3.6 通用操作

| 事件名             | 触发时机 | 属性                      |
| ------------------ | -------- | ------------------------- |
| `search_performed` | 全局搜索 | `keyword`, `result_count` |
| `page_error_shown` | 页面报错 | `error_type`, `page`      |

> 以上事件为初始版本，根据实际功能逐步补充。新增事件请更新本文档并通知相关同学。

---

## 四、用户属性（Person Properties）

登录后通过 `posthog.identify` 设置：

| 属性名  | 类型   | 说明                                   |
| ------- | ------ | -------------------------------------- |
| `email` | string | 用户邮箱                               |
| `name`  | string | 用户名称                               |
| `role`  | string | 用户角色（admin / developer / viewer） |
| `team`  | string | 所属团队                               |

---

## 五、转化路径（待定义）

后续根据业务需求补充，可能的方向：

- 工单创建 → 审批 → 发布 的完成率
- 新用户首次登录 → 首次创建工单 的激活率
- 发布失败 → 回滚 → 重新发布 的恢复路径

---

## 六、隐私 & 合规

- 密码、Token 等敏感字段已通过 `maskAllInputs` 屏蔽，不会进入录制
- 不采集服务器密钥、数据库密码等基础设施敏感信息
- 开发环境通过 `opt_out_capturing()` 禁止上报
- 所有数据存储在公司内网

---

## 七、埋点验证

上线前通过 PostHog 控制台验证：

1. 打开 PostHog → Activity
2. 在 tigo 平台触发对应操作
3. 确认事件名称和属性与本文档一致
4. 检查 Persons 页面用户属性是否正确
