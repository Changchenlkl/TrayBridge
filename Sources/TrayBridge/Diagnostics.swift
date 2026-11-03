import AppKit

/// A local, read-only view of the running application's diagnostic report.
/// Reading or refreshing never writes to disk or the pasteboard.
final class DiagnosticsWindow: NSObject {
    var report: (() -> String)?
    var onRefresh: (() -> Void)?
    var onSettings: (() -> Void)?
    var onRestart: (() -> Void)?

    private let window: NSWindow
    private let textView = NSTextView(frame: .zero)

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 540),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "托盘展开 · 诊断"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 680, height: 380)
        window.center()
        window.setFrameAutosaveName("TrayBridge.Diagnostics")
        configureContents()
    }

    func show() {
        update()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func update() {
        let oldSelection = textView.selectedRange()
        textView.string = report?() ?? "暂无诊断信息。"
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        let length = (textView.string as NSString).length
        let location = min(oldSelection.location, length)
        textView.setSelectedRange(NSRange(location: location, length: min(oldSelection.length, length - location)))
    }

    private func configureContents() {
        guard let content = window.contentView else { return }
        let description = NSTextField(wrappingLabelWithString: "查看权限与菜单栏读取结果。可选择文字，或点击“复制诊断”复制全部内容。")
        description.textColor = .secondaryLabelColor

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.backgroundColor = .textBackgroundColor
        scroll.documentView = textView

        let refresh = makeButton("重新检测", #selector(refreshClicked))
        let settings = makeButton("辅助功能设置…", #selector(settingsClicked))
        let restart = makeButton("重新启动", #selector(restartClicked))
        let copy = makeButton("复制诊断", #selector(copyClicked))
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 1), for: .horizontal)
        let buttons = NSStackView(views: [refresh, settings, restart, spacer, copy])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.distribution = .fill
        buttons.spacing = 8

        for view in [description, scroll, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            description.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            description.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            description.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: description.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
    }

    private func makeButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    @objc private func refreshClicked() {
        onRefresh?()
        update()
    }

    @objc private func settingsClicked() { onSettings?() }

    @objc private func restartClicked() { onRestart?() }

    @objc private func copyClicked() {
        update()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(textView.string, forType: .string)
    }
}
