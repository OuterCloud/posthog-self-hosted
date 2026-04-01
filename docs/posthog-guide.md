# PostHog 产品分析平台使用指南

本文档面向团队成员，介绍 PostHog 平台的核心功能和日常使用方法。

> 平台地址：见 `config.local.sh` 中的 `POSTHOG_HOST`（公司内网访问）

---

## 一、平台概览

PostHog 是我们自托管的产品分析平台，所有数据存储在公司内网，不经过任何第三方。它集成了以下能力：

| 功能          | 说明                                       |
| ------------- | ------------------------------------------ |
| 事件分析      | 追踪用户行为（页面浏览、点击、自定义事件） |
| 漏斗分析      | 分析转化路径，定位流失节点                 |
| 留存分析      | 衡量用户回访率                             |
| 用户路径      | 可视化用户在产品中的行为路径               |
| 会话录制      | 回放用户操作过程，快速定位体验问题         |
| Feature Flags | 功能开关，支持灰度发布和 A/B 测试          |
| 用户画像      | 查看单个用户的完整行为轨迹和属性           |

---

## 二、登录与首页

1. 浏览器访问平台地址
2. 使用管理员分配的账号登录
3. 登录后进入首页，左侧导航栏是所有功能入口

---

## 三、核心功能使用

### 3.1 Activity（实时事件流）

**位置**：左侧导航 → Activity

用途：实时查看所有上报的事件，常用于：

- 验证埋点是否正确上报
- 排查某个用户的行为轨迹
- 确认新功能的事件是否正常触发

每条事件显示：事件名、用户标识（distinct_id）、来源页面、时间。

点击单条事件可以展开查看完整属性。

### 3.2 Insights（数据分析）

**位置**：左侧导航 → Product analytics → 点击 + New insight

这是最常用的分析功能，支持多种分析类型：

#### Trends（趋势）

查看事件随时间的变化趋势。

示例：查看过去 7 天每天的页面浏览量

- 选择事件：`$pageview`
- 时间范围：Last 7 days
- 可按属性分组（如按浏览器、页面路径）

#### Funnels（漏斗）

分析多步骤转化率，定位流失节点。

示例：注册转化漏斗

1. 步骤 1：`$pageview`（访问注册页）
2. 步骤 2：`user_signed_up`（注册成功）
3. 步骤 3：`project_created`（创建首个项目）

漏斗会显示每一步的转化率和流失人数。

#### Retention（留存）

衡量用户在首次操作后是否持续回访。

示例：注册后 7 日留存

- 初始事件：`user_signed_up`
- 回访事件：`$pageview`
- 查看 Day 1 ~ Day 7 的留存曲线

#### User Paths（用户路径）

可视化用户在产品中的行为流向，发现常见路径和异常跳出。

### 3.3 Session Replay（会话录制）

**位置**：左侧导航 → Session replay

回放用户的真实操作过程，包括页面滚动、点击、输入（密码等敏感内容已自动屏蔽）。

常用场景：

- 用户反馈 bug 时，找到对应录制快速复现
- 分析用户在某个页面的操作习惯
- 验证新功能的交互是否符合预期

可以按用户、页面、时间范围筛选录制。

### 3.4 Feature Flags（功能开关）

**位置**：左侧导航 → Feature flags

用于灰度发布和 A/B 测试，无需发版即可控制功能的开启/关闭。

#### 创建 Feature Flag

1. 点击 New feature flag
2. 填写 Key（如 `new-dashboard-v2`）
3. 设置发布条件：
   - 按百分比：如 10% 的用户看到新功能
   - 按属性：如只对 `role = admin` 的用户开启
   - 按用户列表：指定特定用户
4. 保存后立即生效

#### 前端使用

```js
if (posthog.isFeatureEnabled("new-dashboard-v2")) {
  // 展示新版仪表盘
} else {
  // 展示旧版
}
```

### 3.5 Persons & Groups（用户画像）

**位置**：左侧导航 → People & groups → Persons

查看单个用户的完整画像：

- 用户属性（邮箱、角色、注册时间等）
- 完整事件时间线
- 关联的会话录制
- 所属的 Cohort（用户分群）

可以通过邮箱、distinct_id 或属性搜索用户。

### 3.6 Dashboards（仪表盘）

**位置**：左侧导航 → Dashboards

将多个 Insight 组合到一个仪表盘中，方便日常查看关键指标。

建议创建以下仪表盘：

- **产品概览**：DAU、页面浏览量、核心功能使用率
- **转化漏斗**：注册 → 激活 → 付费的转化率
- **功能采用率**：新功能上线后的使用趋势

### 3.7 Cohorts（用户分群）

**位置**：左侧导航 → People & groups → Cohorts

按条件创建用户分群，用于分析和 Feature Flags 的定向发布。

示例：

- "活跃用户"：过去 7 天有 `$pageview` 事件的用户
- "付费用户"：`plan` 属性为 `pro` 或 `enterprise` 的用户
- "流失风险"：过去 30 天无任何事件的用户

---

## 四、前端集成

### 4.1 SDK 初始化

项目中引入 `posthog-js`：

```bash
npm install posthog-js
```

初始化代码核心配置：

```js
posthog.init("phc_YOUR_PROJECT_API_KEY", {
  api_host: "https://your-posthog-host.example.com",
  autocapture: true,
  session_recording: { maskAllInputs: true },
});
```

- `api_host`：PostHog 部署地址
- `autocapture`：自动采集点击、表单提交等事件
- `maskAllInputs`：录制时屏蔽所有输入框内容

Project API Key 在 PostHog 控制台 Settings → Project → Project API Key 获取。

### 4.2 用户标识

用户登录后调用 `identify`，将匿名事件与用户身份关联：

```js
posthog.identify(user.id, {
  email: user.email,
  name: user.name,
  role: user.role,
});
```

用户退出时调用 `reset`：

```js
posthog.reset();
```

### 4.3 自定义事件

按埋点需求文档中定义的事件名和属性上报：

```js
// 用户注册
posthog.capture("user_signed_up", { method: "email" });

// 创建项目
posthog.capture("project_created", { project_id: "123", template: "blank" });

// 导出数据
posthog.capture("data_exported", { format: "csv", row_count: 1500 });
```

### 4.4 Feature Flags

```js
// 检查功能开关
if (posthog.isFeatureEnabled("new-dashboard-v2")) {
  renderNewDashboard();
}

// 获取 Flag 的 payload（用于多变体测试）
const variant = posthog.getFeatureFlag("checkout-flow");
```

### 4.5 开发环境

开发环境自动禁止上报（SDK 初始化的 `loaded` 回调中处理），避免污染生产数据。

如需在开发环境临时开启上报进行调试：

```js
posthog.opt_in_capturing();
```

---

## 五、埋点验证

新增埋点后，上线前务必验证：

1. 打开 PostHog 控制台 → Activity
2. 在目标页面触发操作
3. 确认事件名称和属性与埋点需求文档一致
4. 检查用户属性是否正确设置（Persons 页面查看）

---

## 六、数据隐私

- 所有数据存储在公司内网服务器，不传输至第三方
- 会话录制自动屏蔽密码等敏感输入（`maskAllInputs: true`）
- 不采集支付卡号、身份证等金融敏感信息
- 开发环境默认不上报数据
- 支持通过 API 删除指定用户的所有数据（GDPR 合规）

---

## 七、运维相关

### 健康检查

```bash
bash doctor.sh          # 检查所有服务状态
bash doctor.sh --fix    # 检查并自动修复
```

### 数据清理

```bash
bash cleanup.sh         # 通过官方 API 清理非保留域名的用户数据
```

### 常用命令

```bash
docker compose ps              # 查看服务状态
docker compose logs -f web     # 查看 web 日志
docker compose restart web     # 重启 web 服务
```

---

## 八、常见问题

**Q：事件上报了但 Activity 里看不到？**
检查 `api_host` 是否配置正确，浏览器控制台是否有网络错误。开发环境默认禁止上报，确认没有调用 `opt_out_capturing()`。

**Q：会话录制没有内容？**
确认 `session_recording` 配置已开启。录制数据量较大，可能需要几分钟才能在控制台中出现。

**Q：Feature Flag 不生效？**
Flag 的值在 SDK 初始化时拉取，页面刷新后才会更新。确认 Flag 的发布条件是否匹配当前用户。

**Q：如何查看某个用户的所有行为？**
Persons 页面搜索用户邮箱或 ID，点击进入可以看到完整的事件时间线和会话录制。

---

## 九、相关文档

| 文档             | 说明                     |
| ---------------- | ------------------------ |
| 技术选型报告     | 为什么选择 PostHog       |
| 埋点需求文档     | 事件定义和属性规范       |
| SDK 初始化示例   | 前端集成代码             |
| PostHog 官方文档 | https://posthog.com/docs |
