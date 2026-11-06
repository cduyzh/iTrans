import AppKit
import SwiftUI
import ServiceManagement

/// 状态栏右键悬浮面板控制器：管理 NSPopover 的生命周期、点外关闭、键盘导航与全链路状态同步。
@MainActor
public final class StatusPanelController: NSObject, NSPopoverDelegate {
    public static let shared = StatusPanelController()

    private let popover = NSPopover()
    private let model = StatusPanelModel()
    private var refreshTimer: Timer?
    private var keyMonitor: Any?
    private weak var currentStatusBarButton: NSStatusBarButton?
    private var previousActiveApp: NSRunningApplication?

    public override init() {
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self

        let content = NSHostingController(
            rootView: StatusPanelContent(model: model) { [weak self] action in
                self?.perform(action)
            }
        )
        popover.contentViewController = content
        popover.contentSize = content.view.fittingSize
    }

    // MARK: - Presentation & Dismissal

    public func toggle(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            close()
        } else {
            show(relativeTo: button)
        }
    }

    public func show(relativeTo button: NSStatusBarButton) {
        currentStatusBarButton = button
        if popover.isShown {
            refresh()
            return
        }

        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousActiveApp = front
        }

        refresh()
        model.isMoreExpanded = false
        model.focusedAction = .quickTranslate
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
        installObservers()
    }

    public func close() {
        popover.performClose(nil)
        stopObserving()
    }

    public nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in
            self.stopObserving()
            self.model.isMoreExpanded = false
            self.model.focusedAction = nil
            self.currentStatusBarButton = nil
        }
    }

    // MARK: - 状态刷新 (从底层单例读取最新系统与服务数据)

    public func refresh() {
        var state = model.snapshot
        let settings = AppSettings.shared
        let hotkey = GlobalHotkeyManager.shared

        // 版本与构建号
        let bundle = Bundle.main
        let ver = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2.0"
        let bld = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap { Int($0) } ?? 9
        state.version = ver
        state.build = bld

        // 辅助功能权限与监听状态
        state.isAccessibilityGranted = hotkey.hasAccessibilityPermission
        state.isHotkeyMonitoring = hotkey.isMonitoring
        state.hotkeyDisplay = settings.hotkeyMode.displayName

        // 当前引擎与配置状态
        state.engineType = settings.selectedEngine
        state.engineName = settings.selectedEngine.displayName
        state.hasApiKey = !settings.deepSeekApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch settings.selectedEngine {
        case .deepseek:
            state.engineSummary = state.hasApiKey ? "\(settings.selectedModel) · 已配密钥" : "未配 API Key · 点击配置"
        case .google:
            state.engineSummary = "Google 翻译 · 免密直连"
        }

        // 记忆库与知识库词条数
        state.memoryCount = PersonalTranslationMemoryManager.shared.items.count + DomainKnowledgeBaseManager.shared.items.count

        // 用量统计
        let stats = UsageStatisticsManager.shared.stats
        state.totalRequests = stats.totalRequests
        state.totalTokens = stats.totalTokens

        // 缓存大小
        let storageInfo = CacheStorageManager.shared.refreshUsage()
        state.cacheSizeFormatted = storageInfo.formattedTotalSize

        // 本地 Agent 网关服务
        state.isAgentGatewayRunning = AgentGatewayServer.shared.isRunning
        state.agentGatewayPort = AgentGatewayServer.shared.port

        // 开机自启动
        state.autoStartAtLogin = isLaunchAtLoginEnabled()

        // 发现新版本标识
        state.hasUnreadUpdate = settings.hasNewUpdateAvailable

        if state != model.snapshot {
            model.snapshot = state
        }
    }

    // MARK: - 动作路由执行

    public func perform(_ action: StatusPanelAction) {
        switch action {
        case .settings:
            close()
            AppDelegate.shared?.openSettingsAction()

        case .engineCapsule:
            close()
            AppDelegate.shared?.openSettings(tab: 0)

        case .quickTranslate:
            close()
            let pasteboardText = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !pasteboardText.isEmpty {
                AppDelegate.shared?.showPopoverWithText(pasteboardText)
            } else {
                AppDelegate.shared?.openPanelAction()
            }

        case .openTranslatePanel:
            close()
            AppDelegate.shared?.openPanelAction()

        case .switchEngine:
            let engines: [TranslationEngineType] = [.deepseek, .google]
            if let idx = engines.firstIndex(of: AppSettings.shared.selectedEngine) {
                let next = engines[(idx + 1) % engines.count]
                AppSettings.shared.selectedEngine = next
            } else {
                AppSettings.shared.selectedEngine = .deepseek
            }
            refresh()

        case .personalMemory:
            close()
            AppDelegate.shared?.openSettings(tab: 3)

        case .usageStatistics:
            close()
            AppDelegate.shared?.openSettings(tab: 5)

        case .accessibilityPerm:
            if !GlobalHotkeyManager.shared.hasAccessibilityPermission {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            } else {
                close()
                AppDelegate.shared?.openSettings(tab: 2)
            }

        case .agentGateway:
            close()
            AppDelegate.shared?.openSettings(tab: 6)

        case .more:
            withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                model.isMoreExpanded.toggle()
            }

        case .toggleAutoStart:
            if #available(macOS 13.0, *) {
                let service = SMAppService.mainApp
                if service.status == .enabled {
                    try? service.unregister()
                } else {
                    try? service.register()
                }
            }
            refresh()

        case .clearCache:
            AppDelegate.shared?.cleanupSpaceAction()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.refresh()
            }

        case .reloadHotkeys:
            AppDelegate.shared?.reloadHotkeyAction()
            refresh()

        case .restartApp:
            close()
            AppDelegate.shared?.restartAppAction()

        case .checkUpdates:
            close()
            AppDelegate.shared?.openUpdateAction()

        case .releaseNotes:
            close()
            AppDelegate.shared?.openSettings(tab: 7)

        case .quit:
            close()
            NSApp.terminate(nil)
        }
    }

    private func isLaunchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    // MARK: - 键盘导航与快捷键监听

    private func installObservers() {
        stopObserving()

        // 0.5s 定时刷新
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer

        // 键盘监听：Esc 关闭/收起、⌘, 打开设置、⌥E 切换引擎、⌥M 记忆库、⌥S 统计、Tab / 箭头遍历
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            guard self.popover.isShown,
                  event.window === self.popover.contentViewController?.view.window else {
                return event
            }
            return self.handleKey(event) ? nil : event
        }
    }

    private func stopObserving() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        if let keyMonitor = keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    private var focusOrder: [StatusPanelAction] {
        if model.isMoreExpanded {
            return [
                .settings,
                .toggleAutoStart,
                .reloadHotkeys,
                .restartApp,
                .clearCache,
                .checkUpdates,
                .releaseNotes,
                .more,
                .quit
            ]
        } else {
            return [
                .settings,
                .quickTranslate,
                .openTranslatePanel,
                .switchEngine,
                .personalMemory,
                .usageStatistics,
                .more,
                .quit
            ]
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])

        // ⌘, 打开设置
        if modifiers == .command, event.charactersIgnoringModifiers == "," {
            perform(.settings)
            return true
        }

        // ⌥E 快捷轮换引擎
        if modifiers == .option, event.charactersIgnoringModifiers?.lowercased() == "e" {
            perform(.switchEngine)
            return true
        }

        // ⌥M 记忆库
        if modifiers == .option, event.charactersIgnoringModifiers?.lowercased() == "m" {
            perform(.personalMemory)
            return true
        }

        // ⌥S 用量统计
        if modifiers == .option, event.charactersIgnoringModifiers?.lowercased() == "s" {
            perform(.usageStatistics)
            return true
        }

        // Esc 键：优先收起更多展开面板，未展开时关闭浮窗
        if event.keyCode == 53 {
            if model.isMoreExpanded {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                    model.isMoreExpanded = false
                }
                return true
            }
            close()
            return true
        }

        // 方向键与 Tab 键焦点切换
        if modifiers.isEmpty || (event.keyCode == 48 && modifiers == .shift) {
            switch event.keyCode {
            case 48, 123, 124, 125, 126: // Tab, Left, Right, Down, Up
                let order = focusOrder
                let backward = event.keyCode == 123 || event.keyCode == 126 || modifiers == .shift
                if let selected = model.focusedAction, let index = order.firstIndex(of: selected) {
                    model.focusedAction = order[(index + (backward ? -1 : 1) + order.count) % order.count]
                } else {
                    model.focusedAction = backward ? order.last : order.first
                }
                return true

            case 36, 76, 49: // Return, Enter, Space
                if let action = model.focusedAction {
                    perform(action)
                    return true
                }

            default:
                break
            }
        }

        return false
    }
}
