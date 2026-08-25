# mothxOS

mothxOS 是一个 macOS 桌面的 mothx 客户端，使用 SwiftUI 开发，界面风格参考 Codex。

客户端通过 HTTP / WebSocket 调用本地运行的 mothx `serve` 服务，负责界面、交互和状态展示；mothx 负责 Agent、Provider、模型、工具、Session、Run、MCP 和沙箱执行。

## 最低系统版本

- **macOS 14.0（Sonoma）及以上**

代码使用了 macOS 13 / 14 才提供的 API（`ContentUnavailableView`、`Charts`、双参数 `onChange`、`Task.sleep(for:)`、`.tracking` 等），因此最低部署目标为 macOS 14.0。Apple Silicon（arm64）原生运行。

## 架构概览

```text
┌───────────────────────── SwiftUI 客户端 (mothxOS) ─────────────────────────┐
│                                                                           │
│  Views/           界面的所有视图（Sidebar / Workspace / Settings / Stats） │
│  Models/          消息、Provider、Model、Project、Session、Skill 等模型    │
│  Utilities/       通用视图修饰与主题色                                     │
│  Localization.swift  中英文文案与语言状态                                  │
│                                                                           │
│  MothxServiceManager.swift   唯一服务状态中心（连接、HTTP、WS、Run 状态）  │
│  LocalProjectStore.swift     本地 SQLite（项目 / 项目-会话关系 / 偏好）    │
└─────────────────────────────────┬─────────────────────────────────────────┘
                                  │ HTTP + WebSocket
                                  ▼
                 http://127.0.0.1:7872   (mothx serve)
┌───────────────────────────────────────────────────────────────────────────┐
│                            mothx 后端                                      │
│  Agent · Provider · Model · Tool · Session · Run · MCP · 沙箱执行          │
└───────────────────────────────────────────────────────────────────────────┘
```

### 主要组件

- `MothxServiceManager.swift` — 项目唯一的服务状态中心，负责连接管理、HTTP 请求、WebSocket 事件、Session/Run 状态、设置读写、项目、技能、统计。
- `LocalProjectStore.swift` — 客户端本地 SQLite，存放项目、项目-会话归属和会话模型偏好，路径为 `Application Support/mothxOS/projects.sqlite`。
- `Localization.swift` — 应用语言状态与中英文文案。
- `Views/` — 全部 SwiftUI 界面：侧边栏、会话工作区、设置、统计、服务日志、启动预检等。
- `Models/` — 与服务端 JSON 对应的数据模型。

### 数据流

```text
mothxOSApp
  └─ ContentView
      ├─ EnvironmentCheckSheet ── 检查/安装环境 ── connectAtLaunch
      ├─ Sidebar ── 选择项目 / Session
      ├─ WorkspaceView
      │   └─ PromptComposer ── POST /api/sessions/{id}/runs
      │       └─ 轮询 + /ws/runs ── 消息 / Plan / Run 状态
      └─ SettingsView ── GET/PUT /api/settings、provider models

MothxServiceManager
  ├─ GET /health ── 健康检查，必要时启动 mothx serve --port 127.0.0.1:7872
  ├─ HTTP ── settings / sessions / messages / runs / stats / skills
  ├─ WebSocket ── /ws/logs、/ws/runs
  └─ LocalProjectStore ── Application Support/mothxOS/projects.sqlite
```

## 运行环境要求

> **mothx 最低版本：1.2.95 及以上**（main 分支要求）。
>
> 客户端现在按运行直接向 `POST /api/sessions/{id}/runs` 提交 `provider` + `model` 字段（v1.2.95 新增的 per-run 厂商/模型指定），不再通过改写全局 `defaultProvider/defaultModel` 切换；低于 1.2.95 的 mothx 会忽略 `provider` 字段，会话将无法按运行指定厂商/模型（回退到全局默认）。

应用本身不含 mothx 可执行文件，运行时依赖：

- **Node.js**（用于安装和解析全局 mothx）
- 全局 **mothx-installer**：

  ```bash
  npm install -g mothx-installer
  ```

启动时，客户端通过 `npm root -g` 定位 `mothx-installer` 包内的平台原生 `mothx` 可执行文件，并执行：

```bash
mothx serve --port 127.0.0.1:7872
```

## 构建

```bash
xcodebuild -project mothxOS.xcodeproj \
  -scheme mothxOS \
  -sdk macosx \
  -configuration Release \
  -derivedDataPath ./build \
  CODE_SIGNING_ALLOWED=NO build
```

产物位于 `./build/Build/Products/Release/mothxOS.app`。

如需生成便于分发的 dmg：

```bash
hdiutil create -volname "mothxOS" \
  -srcfolder ./build/Build/Products/Release/mothxOS.app \
  -ov -format UDZO mothxOS.dmg
```

## 目录结构

```text
mothxOS/
├── mothxOSApp.swift            # @main；注入服务与语言状态
├── ContentView.swift           # 顶层布局与项目创建
├── MothxServiceManager.swift   # 服务状态中心
├── LocalProjectStore.swift     # 本地 SQLite
├── Localization.swift          # 中英文文案
├── Models/                     # 数据模型
├── Views/                      # SwiftUI 视图
├── Utilities/                  # 视图修饰、运行时安装辅助（RuntimeInstall）
├── mothxOS.entitlements        # App Sandbox / 网络客户端 / 用户目录读写
└── mothxOS.xcodeproj/          # Xcode 工程
```

## 调试环境变量（仅 Debug 构建生效）

以下环境变量用于在本机复现启动环境检查与在线更新的各个分支。代码中以 `#if DEBUG` 包裹，Release 构建不包含。设置方式：Xcode 中 Product → Scheme → Edit Scheme… → Run → Arguments → Environment Variables，变量值设为 `1` 即生效。

| 变量 | 作用 |
| --- | --- |
| `MOTHXOS_SIMULATE_MISSING_NODE` | 让环境检查认为 Node.js 缺失，进入 node 安装引导页（Homebrew 推荐 + 官网 pkg 警示） |
| `MOTHXOS_SIMULATE_MOTHX_MISSING` | 让 `isMothxInstalled()` 返回 false，强制走进 mothx 安装分支 |
| `MOTHXOS_SIMULATE_MOTHX_INSTALL_EACCES` | 模拟 `npm install -g mothx-installer` 权限错误（EACCES），进入“安装需要管理员权限”页 |
| `MOTHXOS_SIMULATE_UPDATE_AVAILABLE` | 强制显示设置页“在线更新”按钮（本机已是最新版本时用于测试） |
| `MOTHXOS_SIMULATE_UPDATE_EACCES` | 模拟更新时 `npm install -g` 权限错误，进入“更新需要管理员权限”页 |
| `MOTHXOS_SIMULATE_UPDATE_PROMPT` | 启动后强制弹出“发现新版本”提示（内容固定为 v1.2.96），用于测试启动更新提示 |

常用组合：

```text
# 环境检查 → node 缺失引导页
MOTHXOS_SIMULATE_MISSING_NODE=1

# 环境检查 → 管理员权限安装页
MOTHXOS_SIMULATE_MOTHX_MISSING=1
MOTHXOS_SIMULATE_MOTHX_INSTALL_EACCES=1

# 设置 → 更新权限页
MOTHXOS_SIMULATE_UPDATE_AVAILABLE=1
MOTHXOS_SIMULATE_UPDATE_EACCES=1

# 启动 → 发现新版本提示
MOTHXOS_SIMULATE_UPDATE_PROMPT=1
```

> 注意：测试结束后请移除这些环境变量，否则每次启动都会进入对应模拟分支。
## Build方法
```text
xcodebuild -project mothxOS.xcodeproj \
  -scheme mothxOS \
  -configuration Release \
  -derivedDataPath ./build \
  CODE_SIGNING_ALLOWED=NO build
  
hdiutil create -volname "mothxOS" \                                                         
  -srcfolder ./build/Build/Products/Release/mothxOS.app \
  -ov -format UDZO mothxOS.dmg
```