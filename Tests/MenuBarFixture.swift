import AppKit

/// Deliberately separate from the product. Launch this .app through LaunchServices
/// so it has the same kind of AXExtrasMenuBar as an ordinary menu bar application.
final class FixtureDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var items: [NSStatusItem] = []
    private var feedbackWindow: NSWindow?
    private let crowded = ProcessInfo.processInfo.arguments.contains("--crowded")
    private let registrationDelay: TimeInterval = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--delay-seconds"),
              index + 1 < arguments.count,
              let value = Double(arguments[index + 1]), value.isFinite,
              (0...30).contains(value) else { return 0 }
        return value
    }()

    private var logURL: URL {
        Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("events.log")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        record("waiting crowded=\(crowded) delaySeconds=\(registrationDelay) statusItems=0")
        DispatchQueue.main.asyncAfter(deadline: .now() + registrationDelay) { [weak self] in
            self?.registerStatusItems()
        }
    }

    private func registerStatusItems() {
        guard items.isEmpty else { return }
        addMenuItem()
        addCallbackItem(title: "测试回调", label: "测试回调按钮", tag: 1)
        addCallbackItem(title: nil, label: nil, tag: 2)
        if crowded {
            for index in 1...20 {
                let number = String(format: "%02d", index)
                addCallbackItem(title: "溢出\(number)", label: "独立溢出测试 \(number)", tag: 100 + index)
            }
        }
        record("registered crowded=\(crowded) statusItems=\(items.count)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        record("terminated")
    }

    private func addMenuItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "Fixture.NativeMenu"
        item.button?.title = "测试菜单"
        item.button?.setAccessibilityLabel("测试原生菜单按钮")
        item.button?.setAccessibilityIdentifier("Fixture.NativeMenu")
        let menu = NSMenu(title: "Fixture.NativeMenu")
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "记录菜单点击", action: #selector(menuAction), keyEquivalent: ""))
        menu.items.last?.target = self
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出测试宿主", action: #selector(quit), keyEquivalent: "q"))
        menu.items.last?.target = self
        item.menu = menu
        items.append(item)
    }

    private func addCallbackItem(title: String?, label: String?, tag: Int) {
        let length = title == nil ? NSStatusItem.squareLength : NSStatusItem.variableLength
        let item = NSStatusBar.system.statusItem(withLength: length)
        item.autosaveName = "Fixture.Callback.\(tag)"
        if let button = item.button {
            button.title = title ?? ""
            if title == nil {
                button.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
                button.toolTip = nil
                // Exercise the scanner's app-name/ordinal fallback. AppKit may
                // still synthesize a role description; the fixture sets none.
                button.setAccessibilityLabel(nil)
                button.setAccessibilityIdentifier(nil)
            } else {
                button.setAccessibilityLabel(label)
                button.setAccessibilityIdentifier("Fixture.Callback.\(tag)")
            }
            button.tag = tag
            button.target = self
            button.action = #selector(callback(_:))
        }
        items.append(item)
    }

    func menuWillOpen(_ menu: NSMenu) {
        record("native-menu opened")
    }

    func menuDidClose(_ menu: NSMenu) {
        record("native-menu closed")
    }

    @objc private func menuAction() {
        record("native-menu action selected")
        showFeedback("原生菜单的操作已收到。")
    }

    @objc private func callback(_ sender: NSStatusBarButton) {
        let event: String
        switch sender.tag {
        case 1: event = "named-button clicked"
        case 2: event = "unnamed-button clicked"
        default: event = String(format: "crowded-%02d clicked", sender.tag - 100)
        }
        record(event)
        showFeedback(event)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func closeFeedback() {
        feedbackWindow?.close()
    }

    private func showFeedback(_ message: String) {
        feedbackWindow?.close()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 130),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "TrayBridge 测试宿主"
        window.isReleasedWhenClosed = false
        let text = NSTextField(wrappingLabelWithString: "已收到操作：\n\(message)\n事件已写入 events.log。")
        text.frame = NSRect(x: 20, y: 50, width: 320, height: 60)
        window.contentView?.addSubview(text)
        let close = NSButton(title: "关闭", target: self, action: #selector(closeFeedback))
        close.frame = NSRect(x: 265, y: 12, width: 75, height: 28)
        close.bezelStyle = .rounded
        close.keyEquivalent = "\r"
        window.contentView?.addSubview(close)
        window.center()
        feedbackWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func record(_ event: String) {
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: Date())) \(event)\n"
        guard let data = line.data(using: .utf8) else { return }
        do {
            try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            fputs("Fixture log error: \(error)\n", stderr)
        }
    }
}

let fixtureApp = NSApplication.shared
let fixtureDelegate = FixtureDelegate()
fixtureApp.setActivationPolicy(.accessory)
fixtureApp.delegate = fixtureDelegate
fixtureApp.run()
