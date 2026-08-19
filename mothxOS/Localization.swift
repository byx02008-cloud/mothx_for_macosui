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
    var skills: String { text("技能", "Skills") }
    var sessions: String { text("会话", "Sessions") }
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
    var projects: String { text("项目", "Projects") }
    var addProject: String { text("添加项目", "Add project") }
    var addSession: String { text("添加会话", "Add session") }
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
}


@MainActor
final class LanguageStore: ObservableObject {
    @Published private(set) var setting = "auto"
    @Published private(set) var language: AppLanguage = .en

    var copy: Copy { Copy(resolvedLanguage: language) }

    func update(setting: String) {
        self.setting = setting
        self.language = AppLanguage.resolve(setting: setting)
    }
}
