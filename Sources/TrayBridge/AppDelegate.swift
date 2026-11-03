import AppKit
import ApplicationServices
import ServiceManagement

private final class TraySelection: NSObject {
    let item: TrayItem
    init(_ item: TrayItem) { self.item = item }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu(title: "托盘展开")
    private let scanner = MenuBarScanner()
    private let activator = TrayActivator()
    private var hotKey: GlobalHotKey!
    private var snapshot: ScanSnapshot?
    private var items: [TrayItem] = []
    private var menuIsOpen = false
    private var menuHasRows = false
    private var isActivating = false
    private var lastTrusted = false
    private var pendingRefreshAt: Date?
    private var pendingRefreshPoint: NSPoint?
    private var maintenanceTimer: Timer?
    private var permissionTimer: Timer?
    private var appObservation: NSKeyValueObservation?
    private var discoveryTasks: [DispatchWorkItem] = []
    private var observers: [NSObjectProtocol] = []
    private var diagnostics: DiagnosticsWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.local.TrayBridge")
            .filter { $0.processIdentifier != getpid() && !$0.isTerminated }
        if others.isEmpty { start() } else { resolveOtherCopies(others) }
    }

    private func resolveOtherCopies(_ others: [NSRunningApplication]) {
        let alert = NSAlert()
        alert.messageText = "已有另一份托盘展开正在运行"
        alert.informativeText = "旧副本可能与当前文件具有不同的辅助功能授权。\n\n正在运行：\n" +
            others.map { $0.bundleURL?.path ?? "进程 \($0.processIdentifier)" }.joined(separator: "\n") +
            "\n\n当前打开：\n\(Bundle.main.bundlePath)"
        alert.addButton(withTitle: "退出旧副本，使用当前版本")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { NSApp.terminate(nil); return }
        others.forEach { _ = $0.terminate() }
        var attempts = 0
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] timer in
            attempts += 1
            if others.allSatisfy({ $0.isTerminated }) {
                timer.invalidate()
                self?.start()
            } else if attempts >= 20 {
                timer.invalidate()
                let warning = NSAlert()
                warning.messageText = "旧副本还没有退出"
                warning.informativeText = "请先从旧副本菜单退出托盘展开，再重新打开当前版本。"
                warning.runModal()
                NSApp.terminate(nil)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func start() {
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "TrayBridge.Main"
        statusItem.isVisible = true
        if let button = statusItem.button {
            let symbol = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "展开菜单栏项目")
            let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
            let image = symbol?.withSymbolConfiguration(configuration) ?? symbol
            image?.isTemplate = true
            button.image = image
            button.toolTip = "托盘展开 · ⌃⌥空格"
        }
        statusItem.menu = menu
        hotKey = GlobalHotKey()
        hotKey.onPress = { [weak self] in self?.showAtPointer() }
        lastTrusted = AXIsProcessTrusted()
        scanner.didUpdate = { [weak self] snapshot in self?.received(snapshot) }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didWakeNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.discoverWithRetries() })
        }
        // Workspace launch notifications exclude LSUIElement/background apps.
        appObservation = NSWorkspace.shared.observe(\.runningApplications, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.discoverWithRetries() }
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.discoverWithRetries() })
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] _ in self?.checkPermission() })
        // Also find icons registered later by an already-running helper.
        maintenanceTimer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.checkPermission()
            if AXIsProcessTrusted() && !self.isActivating { self.scanner.refresh() }
        }
        maintenanceTimer?.tolerance = 5
        RunLoop.main.add(maintenanceTimer!, forMode: .common)
        permissionTimer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.checkPermission() }
        permissionTimer?.tolerance = 1
        RunLoop.main.add(permissionTimer!, forMode: .common)
        discoverWithRetries()
        rebuildMenu()
        if !lastTrusted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.showWelcome() }
        }
    }

    private func discoverWithRetries() {
        discoveryTasks.forEach { $0.cancel() }
        discoveryTasks.removeAll()
        scanner.refresh()
        for delay in [0.6, 2.0, 5.0] {
            let work = DispatchWorkItem { [weak self] in self?.scanner.refresh() }
            discoveryTasks.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func checkPermission() {
        let trusted = AXIsProcessTrusted()
        guard trusted != lastTrusted else { return }
        lastTrusted = trusted
        discoverWithRetries()
        if menuIsOpen {
            for row in menu.items where row.representedObject is TraySelection {
                row.isEnabled = trusted && !isActivating
            }
        }
        diagnostics?.update()
    }

    private func received(_ result: ScanSnapshot) {
        snapshot = result
        items = result.items.filter {
            $0.bundleID.caseInsensitiveCompare("com.apple.TextInputMenuAgent") != .orderedSame
        }
        diagnostics?.update()
        if let requested = pendingRefreshAt, result.startedAt >= requested {
            pendingRefreshAt = nil
            let point = pendingRefreshPoint
            pendingRefreshPoint = nil
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.menuIsOpen else { return }
                self.showAtPointer(point)
            }
            return
        }
        guard menuIsOpen else { return }
        if !menuHasRows && menu.highlightedItem == nil {
            rebuildMenu()
            menuHasRows = !items.isEmpty
        } else {
            let trusted = AXIsProcessTrusted()
            let denied = deniedPIDs()
            for row in menu.items {
                if let selection = row.representedObject as? TraySelection {
                    row.isEnabled = trusted && !isActivating && !denied.contains(selection.item.pid)
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard statusItem != nil else { return false }
        checkPermission()
        showAtPointer()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        maintenanceTimer?.invalidate()
        permissionTimer?.invalidate()
        discoveryTasks.forEach { $0.cancel() }
        appObservation?.invalidate()
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func showWelcome() {
        guard !AXIsProcessTrusted() else { return }
        let alert = NSAlert()
        alert.messageText = "需要为当前运行的托盘展开授权"
        alert.informativeText = "请在系统设置的“辅助功能”中添加当前应用并打开权限。\n\n当前运行位置：\n\(Bundle.main.bundlePath)\n\n如果开关已经打开但仍提示未授权，请先重新启动；仍无效时，移除旧条目后重新添加这份应用。"
        alert.addButton(withTitle: "打开辅助功能设置")
        alert.addButton(withTitle: "查看诊断")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn { openAccessibility() }
        else if response == .alertSecondButtonReturn { showDiagnostics() }
    }

    @objc private func grantAccess() { openAccessibility() }
    private func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        checkPermission()
    }

    private func regions() -> [MenuBarRegion] {
        guard let primary = NSScreen.screens.first else { return [] }
        let originTop = primary.frame.maxY
        return NSScreen.screens.map { screen in
            let frame = screen.frame
            return MenuBarRegion(displayBounds: CGRect(x: frame.minX, y: originTop - frame.maxY, width: frame.width, height: frame.height),
                rightSafeStart: screen.safeAreaInsets.top > 0 ? screen.auxiliaryTopRightArea?.minX : nil,
                applicationMenuEnd: nil, menuBarHeight: max(screen.safeAreaInsets.top, NSStatusBar.system.thickness))
        }
    }

    @discardableResult
    private func add(_ title: String, action: Selector? = nil, key: String = "", enabled: Bool = true) -> NSMenuItem {
        let row = NSMenuItem(title: title, action: action, keyEquivalent: key)
        row.target = self
        row.isEnabled = enabled
        menu.addItem(row)
        return row
    }

    private func deniedPIDs() -> Set<pid_t> {
        Set(snapshot?.reports.filter { $0.issues.contains { $0.errorRaw == AXError.apiDisabled.rawValue } }.map(\.pid) ?? [])
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let trusted = AXIsProcessTrusted()
        if !trusted {
            menu.addItem(.sectionHeader(title: "需要辅助功能权限"))
            add("开启辅助功能权限…", action: #selector(grantAccess))
            add("重新检测权限", action: #selector(refresh))
            add("诊断…", action: #selector(showDiagnostics))
            add("重新启动托盘展开", action: #selector(restartApp))
            menu.addItem(.separator())
        }
        let regions = regions()
        let sorted = items.sorted { a, b in
            if let af = a.frame, let bf = b.frame {
                if af.minY != bf.minY { return af.minY < bf.minY }
                if af.minX != bf.minX { return af.minX < bf.minX }
            } else if (a.frame == nil) != (b.frame == nil) { return b.frame == nil }
            let order = a.appName.localizedStandardCompare(b.appName)
            if order != .orderedSame { return order == .orderedAscending }
            return a.pid == b.pid ? a.ordinal < b.ordinal : a.pid < b.pid
        }
        let denied = deniedPIDs()
        var rowIndex = 0
        for (placement, title) in [(ItemPlacement.obscured, "可能被遮挡或溢出"), (.visible, "菜单栏项目"), (.unknown, "其他菜单栏项目")] {
            let group = sorted.filter { MenuBarGeometry.placement(of: $0.frame, regions: regions) == placement }
            guard !group.isEmpty else { continue }
            if placement != .visible || group.count != sorted.count {
                menu.addItem(.sectionHeader(title: title))
            }
            for entry in group {
                let row = add(entry.appName, action: #selector(openItem(_:)), enabled: trusted && !isActivating && !denied.contains(entry.pid))
                row.representedObject = TraySelection(entry)
                if rowIndex < 9 { row.keyEquivalent = String(rowIndex + 1); row.keyEquivalentModifierMask = [] }
                rowIndex += 1
                if let icon = entry.icon?.copy() as? NSImage { icon.size = NSSize(width: 16, height: 16); row.image = icon }
                row.toolTip = entry.label
            }
        }
        if items.isEmpty && trusted {
            add(scanner.isScanning ? "正在读取…" : "暂无菜单栏项目", enabled: false)
        }
        menu.addItem(.separator())
        add("刷新项目", action: #selector(refresh), key: "r")
        if trusted {
            add("诊断…", action: #selector(showDiagnostics))
            add("重新启动托盘展开", action: #selector(restartApp))
        }
        let login = add("登录时启动", action: #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        if SMAppService.mainApp.status == .requiresApproval { login.title = "允许登录时启动…" }
        add("使用说明…", action: #selector(showHelp))
        if !hotKey.registered { add("⌃⌥空格已被占用，可点击菜单栏图标", enabled: false) }
        add("退出托盘展开", action: #selector(quit), key: "q")
    }

    func menuWillOpen(_ menu: NSMenu) {
        checkPermission()
        menuIsOpen = true
        menuHasRows = !items.isEmpty
        scanner.refresh()
        rebuildMenu()
    }
    func menuDidClose(_ menu: NSMenu) { menuIsOpen = false }

    private func showAtPointer(_ point: NSPoint? = nil) {
        if menuIsOpen { menu.cancelTracking(); return }
        rebuildMenu()
        menu.popUp(positioning: nil, at: point ?? NSEvent.mouseLocation, in: nil)
    }

    @objc private func refresh() {
        pendingRefreshAt = Date()
        pendingRefreshPoint = NSEvent.mouseLocation
        menu.cancelTracking()
        scanner.refresh()
    }

    @objc private func openItem(_ sender: NSMenuItem) {
        guard !isActivating, let selection = sender.representedObject as? TraySelection else { return }
        guard AXIsProcessTrusted() else { showDiagnostics(); return }
        let item = selection.item
        let contextMenu = NSEvent.modifierFlags.contains(.option)
        isActivating = true
        menu.cancelTracking()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            self.activator.activate(item, contextMenu: contextMenu) { [weak self] result in
                guard let self else { return }
                self.isActivating = false
                switch result {
                case .accepted, .unconfirmed: break
                case .failed(let code): self.showActionFailure(item: item, contextMenu: contextMenu, code: code)
                }
            }
        }
    }

    private func showActionFailure(item: TrayItem, contextMenu: Bool, code: Int32) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "未能打开“\(item.appName)”的\(contextMenu ? "右键菜单" : "菜单栏项目")"
        if code == AXError.invalidUIElement.rawValue { alert.informativeText = "该项目可能已退出或重新创建。请刷新列表后再试。" }
        else if code == AXError.apiDisabled.rawValue { alert.informativeText = "系统拒绝了当前进程的辅助功能访问。请从“诊断”检查运行位置与实际授权状态。" }
        else { alert.informativeText = "目标应用可能不支持对应的辅助功能动作，部分 Electron 应用存在此限制。\(contextMenu ? "可以不按 Option，再尝试普通打开。" : "可尝试更新目标应用。")\n\n系统错误代码：\(code)" }
        alert.addButton(withTitle: "知道了")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        scanner.refresh()
    }

    @objc private func showDiagnostics() {
        menu.cancelTracking()
        if diagnostics == nil {
            let panel = DiagnosticsWindow()
            panel.report = { [weak self] in self?.diagnosticReport() ?? "" }
            panel.onRefresh = { [weak self] in self?.checkPermission(); self?.scanner.refresh() }
            panel.onSettings = { [weak self] in self?.openAccessibility() }
            panel.onRestart = { [weak self] in self?.restartApp() }
            diagnostics = panel
        }
        diagnostics?.show()
        scanner.refresh()
    }

    private func diagnosticReport() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        var lines = ["托盘展开 \(version) (\(build))", "PID: \(getpid())", "运行位置: \(Bundle.main.bundlePath)",
            "可执行文件: \(Bundle.main.executablePath ?? "未知")", "本进程辅助功能信任: \(AXIsProcessTrusted() ? "已获得" : "未获得")",
            "正在扫描: \(scanner.isScanning ? "是" : "否")", "已排队重扫: \(scanner.isRefreshQueued ? "是" : "否")"]
        if let snapshot {
            lines += ["最近完成: \(snapshot.completedAt.formatted(date: .numeric, time: .standard))",
                      "扫描用时: \(String(format: "%.2f", snapshot.completedAt.timeIntervalSince(snapshot.startedAt))) 秒",
                      "项目总数: \(snapshot.items.count)", "扫描进程: \(snapshot.reports.count)", "", "各进程实际读取结果:"]
            for report in snapshot.reports.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                lines.append("[\(report.pid)] \(report.name): \(report.state.rawValue), 读取\(report.itemCount), 缓存\(report.cachedItemCount), 来源\(report.source)")
                for issue in report.issues { lines.append("  \(issue.stage): \(issue.errorRaw)") }
            }
        } else { lines.append("尚未完成首次扫描。") }
        lines += ["", "错误代码：-25211=系统拒绝辅助功能访问；-25204=读取超时/目标忙；-25205=不支持该属性；-25212=没有对应值。",
                  "系统设置的开关与当前进程身份可能不一致。若开关已开但本进程未获信任：先重新启动；仍无效时，退出旧副本，在固定位置移除并重新添加这份应用的辅助功能授权。",
                  "诊断仅在本机显示，复制按钮由你操作，不会自动上传。"]
        return lines.joined(separator: "\n")
    }

    @objc private func restartApp() {
        guard let executable = Bundle.main.executableURL else { return }
        let helper = Process()
        helper.executableURL = executable
        helper.arguments = ["--relaunch-helper", String(getpid()), Bundle.main.bundlePath]
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        do { try helper.run(); NSApp.terminate(nil) }
        catch {
            let alert = NSAlert()
            alert.messageText = "无法自动重新启动"
            alert.informativeText = "请先退出，再双击当前应用。\n\n\(error.localizedDescription)"
            alert.runModal()
        }
    }

    @objc private func toggleLogin() {
        do {
            switch SMAppService.mainApp.status {
            case .enabled: try SMAppService.mainApp.unregister()
            case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
            default: try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法更改登录启动设置"
            alert.informativeText = "请先将 TrayBridge.app 放入“应用程序”文件夹，再重试。\n\n\(error.localizedDescription)"
            alert.runModal()
        }
    }

    @objc private func showHelp() {
        let alert = NSAlert()
        alert.messageText = "托盘展开 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")"
        alert.informativeText = "点击项目打开它原有的菜单或面板。\n\n• ⌃⌥空格：在鼠标旁打开列表\n• 方向键 / 回车：选择项目\n• 1–9：打开前九项\n• 按住 Option 选择：尝试右键菜单\n• 刷新项目：读取完成后自动重新打开列表\n\n新启动的后台应用会自动重扫；程序稍后才创建的图标，也会由低频检查补上。\n\n已开启权限仍读不到时，请在“诊断”中确认正在运行的版本和位置。部分应用不支持辅助功能动作。无需录屏权限。"
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
