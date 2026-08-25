import Combine
import Foundation
import SwiftUI

enum AppLanguage: String {
    case zh
    case en

    static func resolve(setting: String) -> AppLanguage {
        switch setting.lowercased() {
        case "zh", "zh-cn", "zh-hans": return .zh
        case "en", "en-us", "en-gb": return .en
        default:
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
            return preferred.hasPrefix("zh") ? .zh : .en
        }
    }
}

struct Copy {
    let resolvedLanguage: AppLanguage

    func text(_ zh: String, _ en: String) -> String { resolvedLanguage == .zh ? zh : en }

    var settings: String { text("设置", "Settings") }
    var general: String { text("常规", "General") }
    var providers: String { text("运营商", "Providers") }
    var imageGeneration: String { text("图片生成", "Image Generation") }
    var skills: String { text("技能", "Skills") }
    var sessions: String { text("会话", "Sessions") }
    var allSessions: String { text("所有会话", "All sessions") }
    var allSessionsSubtitle: String { text("查看和删除 mothx 中的全部会话", "View and delete all mothx sessions") }
    var noSessions: String { text("暂无会话", "No sessions") }
    var unassignedSession: String { text("未归属项目", "No project") }
    var projectSession: String { text("已归属项目", "Assigned to a project") }
    var unassignedProject: String { text("未归属项目", "Unassigned") }
    var globalDefaults: String { text("全局默认", "Global defaults") }
    var defaultProvider: String { text("默认运营商", "Default provider") }
    var defaultModel: String { text("默认模型", "Default model") }
    var thinkingLevel: String { text("思考级别", "Thinking level") }
    var mode: String { text("模式", "Mode") }
    var language: String { text("语言", "Language") }
    var save: String { text("保存", "Save") }
    var saved: String { text("已保存", "Saved") }
    var providerListSubtitle: String { text("选择一个运营商查看连接属性和模型", "Select a provider to view connection settings and models") }
    var allProviders: String { text("所有运营商", "All providers") }
    var addProvider: String { text("添加运营商", "Add provider") }
    var provider: String { text("运营商", "Provider") }
    var models: String { text("模型", "Models") }
    var configuredModels: String { text("已配置模型", "Configured models") }
    var addModel: String { text("添加模型", "Add model") }
    var discoverFromAPI: String { text("从 API 获取", "Discover from API") }
    var providerID: String { text("运营商 ID", "Provider ID") }
    var vendor: String { text("厂商", "Vendor") }
    var apiProtocol: String { text("API 协议", "API protocol") }
    var baseURL: String { "Base URL" }
    var apiKey: String { text("API 密钥", "API key") }
    var imageGenerationEnabled: String { text("启用图片生成", "Enable image generation") }
    var imageGenerationProvider: String { text("图片生成 Provider", "Image generation provider") }
    var imageGenerationAPIType: String { text("图片生成 API 类型", "Image generation API type") }
    var imageGenerationToken: String { text("图片生成 Token", "Image generation token") }
    var imageGenerationModel: String { text("图片生成模型", "Image generation model") }
    var imageGenerationSubtitle: String { text("对应 settings.json 的 imageGeneration", "settings.json imageGeneration") }
    var imageGenerationSave: String { text("保存图片生成设置", "Save image generation settings") }
    var imageGenerationAPIImages: String { "openai-images" }
    var imageGenerationAPIResponses: String { "openai-responses" }
    var httpProxy: String { "HTTP proxy" }
    var thinkingFormat: String { text("思考格式", "Thinking format") }
    var modelID: String { text("模型 ID", "Model ID") }
    var name: String { text("名称", "Name") }
    var contextWindow: String { text("上下文窗口", "Context window") }
    var maxTokens: String { text("最大输出 token", "Max output tokens") }
    var reasoning: String { text("推理模型", "Reasoning") }
    var skillsDirectory: String { text("Skills 目录", "Skills directory") }
    var sessionDirectory: String { text("会话目录", "Session directory") }
    var deleteTitle: String { text("确认删除", "Confirm deletion") }
    var delete: String { text("删除", "Delete") }
    var cancel: String { text("取消", "Cancel") }
    var searchProviders: String { text("搜索运营商", "Search providers") }
    var searchModels: String { text("搜索模型", "Search models") }
    var noProvidersFound: String { text("没有匹配的运营商", "No matching providers") }
    var noModelsFound: String { text("没有匹配的模型", "No matching models") }
    func deleteProjectMessage(_ name: String) -> String { text("删除项目 \(name)？项目及其关联关系将在确认后删除。", "Delete project \(name)? The project and its associations will be removed after confirmation.") }
    func deleteSessionMessage(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return text("删除此会话？会话记录将在确认后删除。", "Delete this session? Its conversation history will be removed after confirmation.") }
        return text("删除会话 \(id)？会话记录将在确认后删除。", "Delete session \(id)? Its conversation history will be removed after confirmation.")
    }
    func deleteProviderMessage(_ name: String) -> String { text("删除运营商 \(name)？其配置将在确认后删除。", "Delete provider \(name)? Its configuration will be removed after confirmation.") }
    func deleteModelMessage(_ name: String) -> String { text("删除模型 \(name)？它将在确认后从当前运营商中移除。", "Delete model \(name)? It will be removed from the current provider after confirmation.") }
    var projects: String { text("项目", "Projects") }
    var addProject: String { text("添加项目", "Add project") }
    var addSession: String { text("添加会话", "Add session") }
    var editProject: String { text("编辑项目", "Edit project") }
    var moveToProject: String { text("移入项目", "Move to project") }
    var showMore: String { text("更多", "More") }
    var showRecent: String { text("最近会话", "Recent") }
    var newProject: String { text("新建项目", "New project") }
    var projectName: String { text("项目名称", "Project name") }
    var workDirectory: String { text("工作目录", "Working directory") }
    var chooseDirectory: String { text("选择目录", "Choose directory") }
    var create: String { text("创建", "Create") }
    var recentTasks: String { text("最近任务", "Recent tasks") }
    var settingsLabel: String { text("设置", "Settings") }
    var connected: String { text("mothx 已连接", "mothx connected") }
    var connecting: String { text("正在连接…", "Connecting…") }
    var workspace: String { text("mothx 工作区", "mothx workspace") }
    var building: String { text("我们要构建什么？", "What are we building?") }
    var workspaceHint: String { text("让 mothx 在项目中探索、编辑和运行代码。", "Ask mothx to explore, edit, and run code in your project.") }
    var explainProject: String { text("解释这个项目", "Explain this project") }
    var runTests: String { text("运行测试", "Run the tests") }
    var findBug: String { text("查找问题", "Find a bug") }
    var askAnything: String { text("请输入任务…", "Ask anything…") }
    var cacheHitRate: String { text("命中率", "Cache hit rate") }
    var attach: String { text("附件", "Attach") }
    var defaultMode: String { text("Agent 模式", "Agent mode") }
    var selectProvider: String { text("选择运营商", "Select provider") }
    var selectModel: String { text("选择模型", "Select model") }
    var saveDefaults: String { text("保存默认配置", "Save defaults") }
    var selectProviderHint: String { text("选择一个运营商查看连接属性和模型", "Select a provider to view connection settings and models") }
    var discover: String { text("从 API 获取", "Discover from API") }
    var noModels: String { text("暂无模型，请先填写 Base URL 后从 API 获取。", "No models. Enter a Base URL to discover models from the API.") }
    var backToProviders: String { text("运营商", "Providers") }
    var saveProvider: String { text("保存运营商", "Save provider") }
    var modelsCount: (Int) -> String { { count in text("\(count) 个模型", "\(count) models") } }
    var configuration: String { text("配置", "Configuration") }
    var defaultProviderStatus: String { text("默认运营商", "Default provider") }
    var defaultThinkingLevelLabel: String { text("默认（跟随运营商）", "Default") }
    var off: String { text("关闭", "Off") }
    var minimal: String { text("最低", "Minimal") }
    var low: String { text("低", "Low") }
    var medium: String { text("中", "Medium") }
    var high: String { text("高", "High") }
    var xhigh: String { text("极高", "XHigh") }
    var agent: String { "Agent" }
    var plan: String { "Plan" }
    var yolo: String { "YOLO" }
    var saveSkills: String { text("保存 Skills 设置", "Save skills settings") }
    var saveSessions: String { text("保存会话设置", "Save session settings") }
    var skillHubHint: String { text("SkillHub 市场配置将在后续版本提供可视化编辑。", "SkillHub marketplace configuration will be available in a later version.") }
    var defaultSkillsDir: String { text("默认 Skills 目录", "Default skills directory") }
    var defaultSessionDir: String { text("默认 ~/.mothx/sessions", "Default ~/.mothx/sessions") }
    var providerSubtitle: String { text("对应 providers.<providerId>", "providers.<providerId>") }
    var modelsSubtitle: String { text("对应 providers.<providerId>.models", "providers.<providerId>.models") }
    var newModel: String { text("新模型", "New model") }
    var discovering: String { text("获取中…", "Discovering…") }
    var reasoningLabel: String { text("推理", "Reasoning") }
    var inputLabel: String { text("输入", "Input") }
    var backProviders: String { text("运营商", "Providers") }
    var modelCount: String { text("个模型", "models") }
    var forceHTTP11: String { "Force HTTP/1.1" }
    var noModelsHint: String { text("暂无模型，请先填写 Base URL 后从 API 获取。", "No models. Enter a Base URL to discover models from the API.") }

    // MARK: - Run / service status
    var statusQueued: String { text("排队中", "Queued") }
    var statusRunning: String { text("处理中", "Running") }
    var statusCompleted: String { text("已完成", "Completed") }
    var statusFailed: String { text("失败", "Failed") }
    var statusCancelled: String { text("已取消", "Cancelled") }
    var statusTimeout: String { text("超时", "Timed out") }
    var statusWaitingApproval: String { text("等待确认", "Waiting for approval") }
    var statusWaitingQuestion: String { text("等待回答", "Waiting for answer") }
    var runRowRunning: String { text("模型处理中", "Model is processing") }
    var runRowFailed: String { text("处理失败", "Failed") }
    var runRowTimeout: String { text("等待超时", "Timed out waiting") }
    var thinking: String { text("思考中…", "Thinking…") }
    var thinkingLabel: String { text("思考中", "Thinking") }
    var process: String { text("过程", "Process") }

    // MARK: - Plan card
    var taskPlan: String { text("任务计划", "Task plan") }
    var planRunning: String { text("执行中", "Running") }

    // MARK: - Service log
    var serviceLogTitle: String { text("运行日志", "Service log") }
    var close: String { text("关闭", "Close") }
    var noServiceLog: String { text("暂无运行日志", "No log output yet") }

    // MARK: - Stats view
    var statsTitle: String { text("统计数据", "Stats") }
    var statsSubtitle: String { text("查看请求、Token、模型和 Provider 使用情况", "View request, token, model, and provider usage") }
    var statsTimeRange: String { text("时间范围", "Time range") }
    var statsRangeSeven: String { text("最近 7 天", "Last 7 days") }
    var statsRangeThirty: String { text("最近 30 天", "Last 30 days") }
    var statsRangeAll: String { text("全部时间", "All time") }
    var statsLoading: String { text("加载中…", "Loading…") }
    var statsRefresh: String { text("刷新", "Refresh") }
    var statsRequests: String { text("请求数", "Requests") }
    var statsTotalTokens: String { text("总 Token", "Total tokens") }
    var statsInputTokens: String { text("输入 Token", "Input tokens") }
    var statsOutputTokens: String { text("输出 Token", "Output tokens") }
    var statsProviderRanking: String { text("Provider 排行", "Provider ranking") }
    var statsModelRanking: String { text("模型排行", "Model ranking") }
    var statsUsageTrend: String { text("使用趋势", "Usage trend") }
    var statsTotalTokenLabel: (String) -> String { { v in self.text("总 Token: \(v)", "Total tokens: \(v)") } }
    var statsNoData: String { text("暂无数据", "No data") }
    var statsDate: String { text("日期", "Date") }
    var statsItemsCount: (Int) -> String { { n in self.text("\(n) 个", "\(n) items") } }
    var statsRecentRequests: String { text("最近请求", "Recent requests") }
    var statsColTime: String { text("时间", "Time") }
    var statsColModel: String { text("模型", "Model") }
    var statsColInput: String { text("输入", "Input") }
    var statsColOutput: String { text("输出", "Output") }
    var statsColDuration: String { text("耗时", "Duration") }
    var statsPageLabel: (Int, Int) -> String { { page, total in self.text("第 \(page) / \(total) 页", "Page \(page) of \(total)") } }

    // MARK: - Sidebar
    var refreshProjectsHelp: String { text("刷新项目和会话列表", "Refresh projects and sessions") }
    var restartService: String { text("重启服务", "Restart service") }
    var startService: String { text("启动服务", "Start service") }
    var openWebUI: String { text("打开 WebUI", "Open WebUI") }
    var appearanceHelp: String { text("界面主题", "Appearance") }
    var appearanceLight: String { text("日间", "Light") }
    var appearanceDark: String { text("夜间", "Dark") }
    var appearanceAuto: String { text("自动", "Auto") }
    var closeSettings: String { text("关闭设置", "Close settings") }

    // MARK: - TUI terminal
    var openInTUI: String { text("在 TUI 中打开", "Open in TUI") }
    var terminal: String { text("终端", "Terminal") }
    var terminalCloseHelp: String { text("关闭终端", "Close terminal") }
    var terminalMode: String { text("终端模式", "Terminal mode") }
    var openTerminalHelp: String { text("在终端中打开当前会话", "Open current session in terminal") }
    var switchStopTaskTitle: String { text("停止当前任务？", "Stop current task?") }
    var switchStopTaskMessage: String { text("当前有任务正在运行，切换会话或模式将停止该任务。确定要切换吗？", "A task is still running. Switching sessions or modes will stop it. Switch anyway?") }
    var stopAndSwitch: String { text("停止并切换", "Stop and switch") }
    func terminalExited(_ code: Int32) -> String { text("TUI 已退出（代码 \(code)）", "TUI exited (code \(code))") }
    var terminalLaunchFailed: String { text("未找到 mothx，无法启动 TUI", "mothx not found; unable to start TUI") }

    // MARK: - About
    var about: String { text("关于软件", "About") }
    var advancedSettings: String { text("高级设置", "Advanced settings") }
    var advancedSettingsSubtitle: String { text("打开 mothx WebUI 的高级设置页面", "Open mothx WebUI advanced settings") }
    var openAdvancedSettings: String { text("打开高级设置", "Open advanced settings") }
    var aboutSubtitle: String { text("Mothx UI for MacOS 的版本信息与更新", "Version info and updates for Mothx UI for MacOS") }
    var appNameLabel: String { text("应用名称", "App Name") }
    var appVersionLabel: String { text("App 版本", "App Version") }
    var mothxVersionLabel: String { text("mothx 版本", "mothx Version") }
    var latestVersionLabel: String { text("最新版本（npm）", "Latest Version (npm)") }
    var versionUnknown: String { text("未知", "Unknown") }
    var refreshVersion: String { text("刷新", "Refresh") }
    var updateAvailableHint: String { text("发现新版本，可点击下方按钮在线更新", "A new version is available") }
    var upToDateHint: String { text("已是最新版本", "You're up to date") }
    var npmUnavailableHint: String { text("未能获取最新版本，请确认已安装 npm", "Couldn't check the latest version. Make sure npm is installed.") }
    var updateButton: String { text("在线更新", "Update") }
    var updating: String { text("更新中…", "Updating…") }
    var updateSucceeded: String { text("更新成功，请重启 mothx 服务以生效", "Update succeeded. Restart the mothx service to apply it.") }
    var updateFailedPrefix: (String) -> String { { detail in self.text("更新失败：\(detail)", "Update failed: \(detail)") } }
    var updateProgressTitle: String { text("在线更新", "Online Update") }
    var updateWaitingForOutput: String { text("等待输出…", "Waiting for output…") }
    var updateStageStoppingService: String { text("正在停止 mothx 服务…", "Stopping mothx service…") }
    var updateStageInstalling: String { text("正在执行 npm install -g mothx-installer…", "Running npm install -g mothx-installer…") }
    var updateStageRestartingService: String { text("正在重启 mothx 服务…", "Restarting mothx service…") }
    var updateStageSucceeded: String { text("更新完成", "Update complete") }
    var updateStageFailed: String { text("更新失败", "Update failed") }
    var updateLogStoppingService: String { text("[步骤] 停止 mothx 服务", "[Step] Stopping mothx service") }
    var updateLogExternalServiceSkipped: String { text("[步骤] 检测到外部启动的 mothx 服务，跳过停止（避免终止非本应用进程）", "[Step] Detected an externally-started mothx service, skipping stop (won't terminate a process this app doesn't own)") }
    var updateLogRunningNpmInstall: String { text("[步骤] 执行 npm install -g mothx-installer", "[Step] Running npm install -g mothx-installer") }
    var updateLogRestartingService: String { text("[步骤] 重启 mothx 服务", "[Step] Restarting mothx service") }
    var updateLogSucceeded: String { text("[完成] 更新成功，服务已重启", "[Done] Update succeeded, service restarted") }
    var updateLogFailedPrefix: (Int32) -> String { { code in self.text("[失败] npm install 退出码 \(code)", "[Failed] npm install exited with code \(code)") } }
    var updateLogFailedDetail: (String) -> String { { detail in self.text("[失败] \(detail)", "[Failed] \(detail)") } }
    var updateLogNeedsAdmin: String { text("[提示] npm 全局目录需要管理员权限，可选择以管理员身份重试或复制 sudo 命令手动安装", "[Info] npm's global install directory needs admin rights. Retry as administrator or copy the sudo command.") }
    var updateNeedsAdminHint: String { text("更新失败：npm 的全局安装目录归 root 所有，需要管理员权限", "Update failed: npm's global install directory is owned by root and needs admin rights.") }
    var updateStageInstallingAdmin: String { text("正在以管理员权限执行 npm install…", "Running npm install as administrator…") }
    var updateStageNeedsAdmin: String { text("更新需要管理员权限", "Update requires admin rights") }
    var updatePromptTitle: (String) -> String { { version in self.text("发现新版本 v\(version)，是否现在更新？", "New version v\(version) available. Update now?") } }
    var updatePromptMessage: String { text("mothx 有可用更新。您可以稍后处理，也可以忽略此版本。", "mothx has an available update. You can handle it later, or ignore this version.") }
    var updatePromptNow: String { text("现在更新", "Update Now") }
    var updatePromptLater: String { text("稍后再说", "Later") }
    var updatePromptIgnore: String { text("忽略此版本", "Ignore this version") }

    // MARK: - Environment check
    var envCheckTitle: String { text("环境检查", "Environment Check") }
    var envCheckSubtitle: String { text("首次进入前检查运行环境", "Checking your environment before launch") }
    var envCheckChecking: String { text("正在检测…", "Checking…") }
    var envCheckNodeLabel: String { text("Node.js", "Node.js") }
    var envCheckMothxLabel: String { text("mothx", "mothx") }
    var envCheckSyncLabel: String { text("同步项目与会话", "Sync projects and sessions") }
    var envCheckSyncFailed: String { text("项目与会话同步失败，请重试。", "Project and session sync failed. Please retry.") }
    var envCheckPassed: String { text("环境检查通过", "Environment check passed") }
    var envCheckExit: String { text("退出", "Quit") }
    var installNodeMissingTitle: String { text("未检测到 Node.js", "Node.js not found") }
    var installNodeMissingMessage: String { text("mothx 通过 npm 分发，需要先安装 Node.js（其中包含 npm）才能继续。", "mothx is distributed via npm, which requires Node.js. Install Node.js first to continue.") }
    var installOpenNodeSite: String { text("打开 Node.js 官网下载安装包", "Open nodejs.org to download the installer") }
    var installUseHomebrew: String { text("使用 Homebrew 安装 Node.js", "Install Node.js with Homebrew") }
    var installRecheck: String { text("我已安装，重新检测", "I've installed it — recheck") }
    var installStageInstallingBrewNode: String { text("正在执行 brew install node…", "Running brew install node…") }
    var installStageInstallingMothx: String { text("正在执行 npm install -g mothx-installer…", "Running npm install -g mothx-installer…") }
    var installStageConnecting: String { text("正在启动 mothx 服务…", "Starting the mothx service…") }
    var installRetry: String { text("重试", "Retry") }
    var installBrewFailedPrefix: (Int32) -> String { { code in self.text("brew install node 失败（退出码 \(code)）", "brew install node failed (exit code \(code))") } }
    var installMothxFailedPrefix: (Int32) -> String { { code in self.text("npm install -g mothx-installer 失败（退出码 \(code)）", "npm install -g mothx-installer failed (exit code \(code))") } }
    var installStillNotFoundAfterInstall: String { text("已执行安装，但仍未检测到 mothx，请重试", "Installation ran, but mothx still wasn't detected. Please retry.") }
    var installWaitingForOutput: String { text("等待输出…", "Waiting for output…") }
    var installNodePkgWarning: String { text("提示：官网安装包会把 Node.js 装到系统目录（属主为 root），之后安装 mothx 需要输入管理员密码。推荐使用 Homebrew 安装，后续无需管理员权限。", "Tip: the official installer places Node.js in a root-owned system location, so installing mothx later requires an administrator password. Homebrew installs it under your home folder and needs no admin rights afterwards.") }
    var installMothxPermissionTitle: String { text("安装需要管理员权限", "Administrator permission required") }
    var installMothxPermissionMessage: String { text("npm 的全局安装目录归 root 所有（常见于使用官网安装包安装的 Node.js）。请选择以下任一方式完成安装：", "npm's global install directory is owned by root (common with the official Node.js installer). Complete the installation with one of the options below:") }
    var installUseAdminPassword: String { text("使用管理员密码安装", "Install with administrator password") }
    var installCopySudoCommand: String { text("复制 sudo 命令", "Copy sudo command") }
    var installOpenTerminal: String { text("打开终端", "Open Terminal") }
    var installPrefixHint: String { text("或者把 npm 全局目录改到用户目录（仅需执行一次，之后无需管理员权限）：npm config set prefix ~/.npm-global，并把 ~/.npm-global/bin 加入 PATH。", "Or move npm's global directory into your home folder (run once, then no admin rights are needed): npm config set prefix ~/.npm-global, and add ~/.npm-global/bin to your PATH.") }
    var installCopyPrefixCommand: String { text("复制 npm prefix 命令", "Copy npm prefix command") }
    var installAdminCanceled: String { text("已取消安装（未执行）", "Canceled — nothing was installed") }
    var installAdminFailedPrefix: (String) -> String { { detail in self.text("管理员安装失败：\(detail)", "Admin install failed: \(detail)") } }

    // MARK: - Workspace
    var ok: String { text("确定", "OK") }
    var attachmentsInstruction: (String) -> String { { names in self.text("请处理工作目录中的附件：\(names)", "Please process the attachments in the working directory: \(names)") } }
    var noWorkDirForAttachment: String { text("当前会话没有可用的项目工作目录", "This session has no available project working directory") }
    var addAttachmentFailedPrefix: (String) -> String { { detail in self.text("添加附件失败：\(detail)", "Failed to add attachment: \(detail)") } }
    var noWorkDir: String { text("无工作目录", "No working directory") }
    var noAppsForDirectory: String { text("没有找到可打开此目录的应用", "No apps found to open this directory") }
    var attachmentsCountLabel: (Int) -> String { { n in self.text("附件 \(n) 个", "\(n) attachments") } }
    var moreOptionsHelp: String { text("更多选项", "More options") }
    var noModelsForProvider: String { text("当前运营商没有可用模型", "No models available for the current provider") }
    var stop: String { text("停止", "Stop") }
    var send: String { text("发送", "Send") }
    var skillsActivatedLabel: (Int) -> String { { n in self.text("技能（已激活 \(n) 个）", "Skills (\(n) active)") } }
    var toolsLabel: String { text("工具", "Tools") }
    var noInstalledSkills: String { text("暂无已安装技能", "No installed skills") }
    var scrollRunningHelp: String { text("正在输出，滚动到底部", "Streaming output, scroll to bottom") }
    var scrollBottomHelp: String { text("滚动到底部", "Scroll to bottom") }

    // MARK: - Service manager errors
    var runtimeNotFound: String { text("未找到系统安装的 mothx 命令，请先执行 npm install -g mothx-installer", "mothx command not found on this system. Run npm install -g mothx-installer first.") }
    var workDirCreateFailedPrefix: (String) -> String { { detail in self.text("无法创建 mothx 工作目录：\(detail)", "Failed to create the mothx working directory: \(detail)") } }
    var mothxLaunchFailedPrefix: (String) -> String { { detail in self.text("无法启动 mothx：\(detail)", "Failed to launch mothx: \(detail)") } }
    var serveStartFailedWithOutput: (String) -> String { { output in self.text("mothx serve 启动失败：\n\(output)", "mothx serve failed to start:\n\(output)") } }
    var serveStartTimeout: String { text("mothx serve 启动超时（端口 127.0.0.1:7872）", "mothx serve start timed out (port 127.0.0.1:7872)") }
    var serveExited: (Int32) -> String { { status in self.text("mothx serve 已退出（状态码 \(status)）", "mothx serve exited (status code \(status))") } }
    var loadSettingsFailedPrefix: (String) -> String { { detail in self.text("读取配置失败：\(detail)", "Failed to load settings: \(detail)") } }
    var loadLocalProjectsFailedPrefix: (String) -> String { { detail in self.text("读取本地项目失败：\(detail)", "Failed to load local projects: \(detail)") } }
    var loadSessionsFailedPrefix: (String) -> String { { detail in self.text("读取会话失败：\(detail)", "Failed to load sessions: \(detail)") } }
    var loadActiveSessionFailedPrefix: (String) -> String { { detail in self.text("读取当前会话失败：\(detail)", "Failed to load the current session: \(detail)") } }
    var loadStatsFailedPrefix: (String) -> String { { detail in self.text("读取统计数据失败：\(detail)", "Failed to load stats: \(detail)") } }
    var createProjectFailedPrefix: (String) -> String { { detail in self.text("创建本地项目失败：\(detail)", "Failed to create local project: \(detail)") } }
    var updateProjectFailedPrefix: (String) -> String { { detail in self.text("更新本地项目失败：\(detail)", "Failed to update local project: \(detail)") } }
    var deleteProjectFailedPrefix: (String) -> String { { detail in self.text("删除本地项目失败：\(detail)", "Failed to delete local project: \(detail)") } }
    var saveSessionProjectLinkFailedPrefix: (String) -> String { { detail in self.text("保存会话项目关系失败：\(detail)", "Failed to save the session-project link: \(detail)") } }
    var deleteSessionProjectLinkFailedPrefix: (String) -> String { { detail in self.text("删除会话项目关系失败：\(detail)", "Failed to remove the session-project link: \(detail)") } }
    var deleteSessionFailedPrefix: (String) -> String { { detail in self.text("删除会话失败：\(detail)", "Failed to delete session: \(detail)") } }
    var forkSessionFailedPrefix: (String) -> String { { detail in self.text("会话分叉失败：\(detail)", "Fork session failed: \(detail)") } }
    var loadMessagesFailedPrefix: (String) -> String { { detail in self.text("读取会话消息失败：\(detail)", "Failed to load session messages: \(detail)") } }
    var noRunIDReturned: String { text("服务端未返回 run ID", "The server did not return a run ID") }
    var submitRunFailedPrefix: (String) -> String { { detail in self.text("提交会话失败：\(detail)", "Failed to submit the session: \(detail)") } }
    var stopRunFailedPrefix: (String) -> String { { detail in self.text("停止运行失败：\(detail)", "Failed to stop the run: \(detail)") } }
    var waitReplyTimeout: String { text("等待模型回复超时", "Timed out waiting for the model's reply") }
    var runFailedFallback: String { text("Agent 运行失败", "Agent run failed") }
    var updateSessionFailedPrefix: (String) -> String { { detail in self.text("更新会话失败：\(detail)", "Failed to update session: \(detail)") } }
    var saveGlobalSettingsFailedPrefix: (String) -> String { { detail in self.text("保存全局配置失败：\(detail)", "Failed to save global settings: \(detail)") } }
    var deleteProviderFailedPrefix: (String) -> String { { detail in self.text("删除 Provider 失败：\(detail)", "Failed to delete provider: \(detail)") } }
    var saveProviderFailedPrefix: (String) -> String { { detail in self.text("保存配置失败：\(detail)", "Failed to save configuration: \(detail)") } }
    var discoverModelsFailedPrefix: (String) -> String { { detail in self.text("获取模型失败：\(detail)", "Failed to discover models: \(detail)") } }
    var projectResponseInvalid: String { text("项目创建接口返回的数据无效", "The project creation API returned invalid data") }
    var settingsInvalidResponse: String { text("mothx /api/settings 返回格式无效", "mothx /api/settings returned an invalid format") }
    var settingsNoProvidersDecoded: String { text("mothx /api/settings 中存在 providers，但客户端无法解析", "mothx /api/settings contains providers but the client could not parse them") }
    var localDatabaseUnavailable: String { text("本地项目数据库无法访问", "Local project database is unavailable") }
}

/// Shared short elapsed-time formatter for run status views (StatusInline, RunStatusRow).
func formatElapsedShort(_ elapsed: TimeInterval, language: AppLanguage) -> String {
    if elapsed < 60 {
        return language == .zh ? String(format: "%.1f 秒", elapsed) : String(format: "%.1fs", elapsed)
    }
    let minutes = floor(elapsed / 60)
    let seconds = elapsed.truncatingRemainder(dividingBy: 60)
    return language == .zh
        ? String(format: "%.0f 分 %.0f 秒", minutes, seconds)
        : String(format: "%.0fm %.0fs", minutes, seconds)
}


@MainActor
final class LanguageStore: ObservableObject {
    @Published private(set) var setting: String
    @Published private(set) var language: AppLanguage
    private(set) var hasStoredSetting: Bool

    private static let localSettingsURL: URL = {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mothxOS", isDirectory: true)
        return directory.appendingPathComponent("app-settings.json")
    }()

    init() {
        let storedSetting = Self.readStoredSetting()
        let initialSetting = storedSetting ?? "auto"
        setting = initialSetting
        language = AppLanguage.resolve(setting: initialSetting)
        hasStoredSetting = storedSetting != nil
    }

    var copy: Copy { Copy(resolvedLanguage: language) }

    func update(setting: String) {
        let value = setting.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "auto" : setting
        self.setting = value
        self.language = AppLanguage.resolve(setting: value)
        self.hasStoredSetting = true
        Self.writeStoredSetting(value)
    }

    /// Imports the server setting only for an existing installation that has
    /// no local language copy yet. After this, the local copy is authoritative
    /// for the app's startup UI.
    func adoptServerSettingIfNeeded(_ serverSetting: String) {
        guard !hasStoredSetting else { return }
        guard !serverSetting.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        update(setting: serverSetting)
    }

    private static func readStoredSetting() -> String? {
        guard let data = try? Data(contentsOf: localSettingsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["tuilang"] as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private static func writeStoredSetting(_ value: String) {
        do {
            let directory = localSettingsURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: ["tuilang": value], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: localSettingsURL, options: .atomic)
        } catch {
            // The service settings remain the source of truth for persistence
            // failures; a local file failure must not block the UI.
        }
    }
}
