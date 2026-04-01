/**
 * PostHog SDK 初始化
 *
 * 使用方式：在 HTML <head> 中引入，或通过打包工具集成到主入口文件
 * 依赖：posthog-js（npm install posthog-js 或直接使用 CDN）
 */

// ============================================================
// 方式一：NPM 包引入（推荐，适合 SPA / 打包项目）
// ============================================================
// import posthog from 'posthog-js';

// ============================================================
// 方式二：CDN 片段（直接粘贴到 <head> 中）
// ============================================================
// !function(t,e){var o,n,p,r;e.__SV||(window.posthog=e,e._i=[],
// e.init=function(i,s,a){...}, e.__SV=1)}(document,window.posthog||[]);

// ============================================================
// 初始化配置
// ============================================================

const POSTHOG_HOST = "https://your-posthog-host.example.com"; // PostHog 部署地址，见 config.local.sh
const POSTHOG_API_KEY = "phc_YOUR_PROJECT_API_KEY"; // 从 PostHog 控制台获取，见 config.local.sh

posthog.init(POSTHOG_API_KEY, {
  api_host: POSTHOG_HOST,

  // 自动捕获页面浏览、点击等基础事件
  autocapture: true,

  // 页面离开时刷新队列，减少事件丢失
  capture_pageview: true,

  // 会话录制（可按需关闭）
  session_recording: {
    maskAllInputs: true, // 屏蔽所有输入框内容，保护隐私
    maskInputOptions: {
      password: true,
    },
  },

  // 本地存储模式（cookie / localStorage / memory）
  persistence: "localStorage+cookie",

  // 加载完成回调
  loaded: function (ph) {
    if (process.env.NODE_ENV === "development") {
      ph.opt_out_capturing(); // 开发环境不上报数据
    }
  },
});

// ============================================================
// 用户标识（登录后调用）
// ============================================================

/**
 * 用户登录后关联身份
 * @param {string} userId   - 系统内部用户 ID
 * @param {object} userProps - 用户属性（邮箱、角色等非敏感信息）
 */
export function identifyUser(userId, userProps = {}) {
  posthog.identify(userId, userProps);
}

// 示例调用：
// identifyUser('user_123', { email: 'user@company.com', role: 'admin' });

// ============================================================
// 自定义事件上报
// ============================================================

/**
 * 上报自定义事件
 * @param {string} eventName - 事件名称（见 tracking-plan.md）
 * @param {object} props     - 事件属性
 */
export function trackEvent(eventName, props = {}) {
  posthog.capture(eventName, props);
}

// 示例调用：
// trackEvent('button_clicked', { button_name: 'signup', page: '/home' });

// ============================================================
// 功能开关（Feature Flags）
// ============================================================

/**
 * 检查功能开关是否启用
 * @param {string} flagKey - Feature Flag 键名
 * @returns {boolean}
 */
export function isFeatureEnabled(flagKey) {
  return posthog.isFeatureEnabled(flagKey);
}

// ============================================================
// 用户退出
// ============================================================

export function resetUser() {
  posthog.reset();
}
