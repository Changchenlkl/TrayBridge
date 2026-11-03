import AppKit
import ApplicationServices

// All cross-process AX calls run on worker queues, never in NSMenu's tracking loop.
enum AXAccess {
    struct ReadResult {
        let value: CFTypeRef?
        let error: AXError
    }

    static func read(_ element: AXUIElement, _ name: String) -> ReadResult {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return ReadResult(value: value, error: error == .success && value == nil ? .noValue : error)
    }

    static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        let result = read(element, name)
        return result.error == .success ? result.value : nil
    }

    static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = value(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        guard let value = value(element, kAXChildrenAttribute), CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        return (value as? [AnyObject] ?? []).compactMap {
            guard CFGetTypeID($0) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast($0, to: AXUIElement.self)
        }
    }

    static func text(_ element: AXUIElement, _ name: String) -> String {
        (value(element, name) as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = value(element, kAXPositionAttribute), let s = value(element, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        let position = unsafeBitCast(p, to: AXValue.self)
        let size = unsafeBitCast(s, to: AXValue.self)
        guard AXValueGetType(position) == .cgPoint, AXValueGetType(size) == .cgSize else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
        guard point.x.isFinite, point.y.isFinite, dimensions.width.isFinite,
              dimensions.height.isFinite, dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    static func extras(for pid: pid_t) -> [AXUIElement] {
        extrasResult(for: pid).elements
    }

    static func extrasResult(for pid: pid_t, timeout: Float = 0.6) -> AXExtrasResult {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        let direct = read(app, kAXExtrasMenuBarAttribute)
        if direct.error == .success {
            guard let value = direct.value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
                return AXExtrasResult(elements: [], state: .unavailable, source: "AXExtrasMenuBar",
                                      issues: [.init(stage: "AXExtrasMenuBar type", errorRaw: AXError.illegalArgument.rawValue)])
            }
            let bar = unsafeBitCast(value, to: AXUIElement.self)
            AXUIElementSetMessagingTimeout(bar, timeout)
            let result = childRead(bar, stage: "AXExtrasMenuBar.AXChildren")
            return AXExtrasResult(elements: result.elements, state: result.issue.map { state(for: $0.errorRaw) } ?? .read,
                                  source: "AXExtrasMenuBar", issues: result.issue.map { [$0] } ?? [])
        }
        let directIssue = AXScanIssue(stage: "AXExtrasMenuBar", errorRaw: direct.error.rawValue)
        // Access denied/timeouts are not evidence that a different tree is correct.
        guard direct.error == .attributeUnsupported || direct.error == .noValue else {
            return AXExtrasResult(elements: [], state: state(for: direct.error.rawValue),
                                  source: "AXExtrasMenuBar", issues: [directIssue])
        }

        // Fallback is deliberately narrow: the regular application's menu bar
        // must never turn File/Edit/View into supposed status-item entries.
        let fallbackStarted = ProcessInfo.processInfo.systemUptime
        let mainBarRead = read(app, kAXMenuBarAttribute)
        let mainBar: AXUIElement? = mainBarRead.error == .success
            && mainBarRead.value.map { CFGetTypeID($0) == AXUIElementGetTypeID() } == true
            ? unsafeBitCast(mainBarRead.value!, to: AXUIElement.self) : nil
        if let mainBar { AXUIElementSetMessagingTimeout(mainBar, timeout) }
        let mainChildrenRead = mainBar.map { childRead($0, stage: "AXMenuBar exclusion.AXChildren") }
        let mainChildren = mainChildrenRead?.elements ?? []
        if let issue = mainChildrenRead?.issue,
           issue.errorRaw != AXError.noValue.rawValue && issue.errorRaw != AXError.attributeUnsupported.rawValue {
            return AXExtrasResult(elements: [], state: state(for: issue.errorRaw),
                                  source: "AXChildren fallback", issues: [directIssue, issue])
        }
        let appChildren = childRead(app, stage: "AXChildren fallback")
        var issues = [directIssue]
        if let issue = appChildren.issue { issues.append(issue) }
        if mainBarRead.error != .success && mainBarRead.error != .attributeUnsupported && mainBarRead.error != .noValue {
            issues.append(.init(stage: "AXMenuBar exclusion", errorRaw: mainBarRead.error.rawValue))
        }
        var found: [AXUIElement] = []
        var inspectedNodes = 0
        var exhaustedBudget = false
        func canInspect(_ stage: String) -> Bool {
            guard inspectedNodes < 64,
                  ProcessInfo.processInfo.systemUptime - fallbackStarted < 3 else {
                if !exhaustedBudget {
                    issues.append(.init(stage: stage + " budget exhausted (64 nodes / 3s)",
                                        errorRaw: AXError.cannotComplete.rawValue))
                }
                exhaustedBudget = true
                return false
            }
            inspectedNodes += 1
            return true
        }
        func appendUnique(_ candidate: AXUIElement) {
            guard !mainChildren.contains(where: { CFEqual($0, candidate) }),
                  !found.contains(where: { CFEqual($0, candidate) }) else { return }
            found.append(candidate)
        }
        fallbackNodes: for child in appChildren.elements {
            guard canInspect("AXChildren fallback") else { break }
            AXUIElementSetMessagingTimeout(child, timeout)
            let roleRead = read(child, kAXRoleAttribute)
            guard roleRead.error == .success, let role = roleRead.value as? String else {
                let error = roleRead.error == .success ? AXError.illegalArgument : roleRead.error
                issues.append(.init(stage: "AXChildren.AXRole fallback", errorRaw: error.rawValue))
                if error == .cannotComplete || error == .apiDisabled || error == .failure { break }
                continue
            }
            if role == kAXMenuBarItemRole {
                appendUnique(child)
            } else if role == kAXMenuBarRole, let mainBar, !CFEqual(mainBar, child) {
                let secondary = childRead(child, stage: "secondary AXMenuBar.AXChildren")
                if let issue = secondary.issue {
                    issues.append(issue)
                    if issue.errorRaw == AXError.cannotComplete.rawValue || issue.errorRaw == AXError.apiDisabled.rawValue || issue.errorRaw == AXError.failure.rawValue {
                        break fallbackNodes
                    }
                }
                for item in secondary.elements {
                    guard canInspect("secondary AXMenuBar fallback") else { break fallbackNodes }
                    AXUIElementSetMessagingTimeout(item, timeout)
                    let role = read(item, kAXRoleAttribute)
                    if role.error == .success, role.value as? String == kAXMenuBarItemRole {
                        appendUnique(item)
                    } else if role.error != .success {
                        issues.append(.init(stage: "secondary AXMenuBar item.AXRole", errorRaw: role.error.rawValue))
                        if role.error == .cannotComplete || role.error == .apiDisabled || role.error == .failure { break fallbackNodes }
                    }
                }
            }
        }
        let failure = issues.first { $0.errorRaw != AXError.attributeUnsupported.rawValue && $0.errorRaw != AXError.noValue.rawValue }
        // Preserve a known process's full cache when only part of its fallback
        // tree was readable. A later successful read will replace that cache.
        let disposition: DiscoveryReadState = exhaustedBudget ? .transient
            : failure.map { state(for: $0.errorRaw) } ?? (found.isEmpty ? .absent : .read)
        return AXExtrasResult(elements: found, state: disposition, source: "AXChildren fallback", issues: issues)
    }

    private static func state(for errorRaw: Int32) -> DiscoveryReadState {
        switch errorRaw {
        case AXError.cannotComplete.rawValue, AXError.invalidUIElement.rawValue: return .transient
        case AXError.attributeUnsupported.rawValue, AXError.noValue.rawValue: return .absent
        default: return .unavailable
        }
    }

    private static func childRead(_ element: AXUIElement, stage: String) -> (elements: [AXUIElement], issue: AXScanIssue?) {
        let result = read(element, kAXChildrenAttribute)
        guard result.error == .success else {
            return ([], .init(stage: stage, errorRaw: result.error.rawValue))
        }
        guard let value = result.value, CFGetTypeID(value) == CFArrayGetTypeID(), let array = value as? [AnyObject] else {
            return ([], .init(stage: stage + " type", errorRaw: AXError.illegalArgument.rawValue))
        }
        let children = array.compactMap { item -> AXUIElement? in
            guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(item, to: AXUIElement.self)
        }
        return (children, nil)
    }
}

struct AXScanIssue: Equatable {
    let stage: String
    let errorRaw: Int32
}

struct AXExtrasResult {
    let elements: [AXUIElement]
    let state: DiscoveryReadState
    let source: String
    let issues: [AXScanIssue]
}

struct ProcessScanReport {
    let pid: pid_t
    let name: String
    let launchDate: Date?
    let itemCount: Int
    var cachedItemCount: Int
    let state: DiscoveryReadState
    let source: String
    let issues: [AXScanIssue]

    var identity: DiscoveryProcessIdentity { .init(pid: pid, launchDate: launchDate) }
}

struct ScanSnapshot {
    let items: [TrayItem]
    let trusted: Bool
    let reports: [ProcessScanReport]
    let startedAt: Date
    let completedAt: Date
    let scanID: Int
}

struct TrayItem {
    let element: AXUIElement
    let pid: pid_t
    let launchDate: Date?
    let appName: String
    let bundleID: String
    let ordinal: Int
    let totalItems: Int
    let identifier: String
    let fingerprint: String
    let detail: String
    let frame: CGRect?
    let icon: NSImage?

    var label: String {
        let base = detail.isEmpty || detail.localizedCaseInsensitiveCompare(appName) == .orderedSame
            ? appName : "\(appName) · \(detail.prefix(90))"
        return totalItems > 1 ? "\(base)（\(ordinal + 1)）" : base
    }

    static func fingerprint(of element: AXUIElement) -> String {
        [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
            .map { AXAccess.text(element, $0) }.joined(separator: "\u{1f}")
    }
}

enum ActionResult: Equatable {
    case accepted
    case unconfirmed
    case failed(Int32)
}

// A modal menu may open successfully but keep AXPress's IPC waiting until timeout.
// Never retry cannotComplete: a second press could close the menu just opened.
func performTrayAction(element: AXUIElement,
                       press: (AXUIElement) -> AXError,
                       revalidate: () -> AXUIElement?) -> ActionResult {
    var error = press(element)
    if error == .invalidUIElement, let replacement = revalidate() {
        error = press(replacement)
    }
    switch error {
    case .success: return .accepted
    case .cannotComplete: return .unconfirmed
    default: return .failed(error.rawValue)
    }
}

final class TrayActivator {
    private let queue = DispatchQueue(label: "TrayBridge.activate", qos: .userInitiated)

    func activate(_ item: TrayItem, contextMenu: Bool, completion: @escaping (ActionResult) -> Void) {
        queue.async {
            guard let app = NSRunningApplication(processIdentifier: item.pid),
                  !app.isTerminated, app.launchDate == item.launchDate else {
                DispatchQueue.main.async { completion(.failed(AXError.invalidUIElement.rawValue)) }
                return
            }
            let action = contextMenu ? kAXShowMenuAction : kAXPressAction
            let result = performTrayAction(element: item.element, press: { element in
                AXUIElementSetMessagingTimeout(element, 0.8)
                return AXUIElementPerformAction(element, action as CFString)
            }, revalidate: {
                let current = AXAccess.extras(for: item.pid)
                // Re-identify only an unambiguous item; never guess by an old array index.
                let matches = current.filter { element in
                    AXUIElementSetMessagingTimeout(element, 0.25)
                    if !item.identifier.isEmpty {
                        return AXAccess.text(element, kAXIdentifierAttribute) == item.identifier
                    }
                    return TrayItem.fingerprint(of: element) == item.fingerprint
                }
                return matches.count == 1 ? matches[0] : nil
            })
            DispatchQueue.main.async { completion(result) }
        }
    }
}

final class MenuBarScanner {
    private struct Candidate {
        let pid: pid_t
        let launchDate: Date?
        let name: String
        let bundleID: String
        let icon: NSImage?
    }

    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "TrayBridge.scan"
        queue.maxConcurrentOperationCount = 6
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private final class ScanCollection {
        let lock = NSLock()
        var items: [TrayItem] = []
        var reports: [ProcessScanReport] = []
    }

    private(set) var isScanning = false
    private var refreshAgain = false
    var isRefreshQueued: Bool { refreshAgain }
    private var nextScanID = 0
    private var cache = DiscoveryCache<TrayItem>()
    var didUpdate: ((ScanSnapshot) -> Void)?

    func refresh() {
        precondition(Thread.isMainThread)
        if isScanning { refreshAgain = true; return }
        isScanning = true
        nextScanID += 1
        let scanID = nextScanID
        let startedAt = Date()
        let excluded: Set<String> = ["com.apple.controlcenter", "com.apple.systemuiserver",
                                     "com.apple.spotlight", "com.apple.notificationcenterui"]
        let candidates = NSWorkspace.shared.runningApplications.compactMap { app -> Candidate? in
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  !app.isTerminated, !excluded.contains((app.bundleIdentifier ?? "").lowercased()) else { return nil }
            return Candidate(pid: app.processIdentifier, launchDate: app.launchDate,
                             name: app.localizedName ?? app.bundleIdentifier ?? "应用 \(app.processIdentifier)",
                             bundleID: app.bundleIdentifier ?? "", icon: app.icon)
        }
        // No early AXIsProcessTrusted gate: an actual bounded AX read reports
        // the difference between denied access and an application without extras.
        let collection = ScanCollection()
        let group = DispatchGroup()
        for candidate in candidates {
            group.enter()
            queue.addOperation {
                defer { group.leave() }
                let extras = AXAccess.extrasResult(for: candidate.pid)
                let elements = extras.elements
                var result: [TrayItem] = []
                var issues = extras.issues
                var state = extras.state
                let metadataStarted = ProcessInfo.processInfo.systemUptime
                var exhaustedMetadataBudget = false
                func metadataBudgetAvailable() -> Bool {
                    guard ProcessInfo.processInfo.systemUptime - metadataStarted < 3 else {
                        if !exhaustedMetadataBudget {
                            issues.append(.init(stage: "item metadata budget exhausted (3s)",
                                                errorRaw: AXError.cannotComplete.rawValue))
                        }
                        exhaustedMetadataBudget = true
                        state = .transient
                        return false
                    }
                    return true
                }
                for (index, element) in elements.enumerated() {
                    guard metadataBudgetAvailable() else { break }
                    AXUIElementSetMessagingTimeout(element, 0.4)
                    var abortMetadata = false
                    func metadata(_ attribute: String) -> String {
                        guard !abortMetadata else { return "" }
                        guard metadataBudgetAvailable() else { abortMetadata = true; return "" }
                        let read = AXAccess.read(element, attribute)
                        if read.error == .cannotComplete || read.error == .invalidUIElement || read.error == .apiDisabled || read.error == .failure {
                            issues.append(.init(stage: "item[\(index)].\(attribute)", errorRaw: read.error.rawValue))
                            state = read.error == .cannotComplete || read.error == .invalidUIElement ? .transient : .unavailable
                            abortMetadata = true
                        }
                        return (read.value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    let title = metadata(kAXTitleAttribute)
                    let description = metadata(kAXDescriptionAttribute)
                    let help = metadata(kAXHelpAttribute)
                    let role = metadata(kAXRoleAttribute)
                    let identifier = metadata(kAXIdentifierAttribute)
                    // One unresponsive element must not multiply the IPC
                    // timeout by every optional field of every remaining item.
                    if abortMetadata { break }
                    let frame = AXAccess.frame(element)
                    guard metadataBudgetAvailable() else { break }
                    let detail = [title, description, help].first { !$0.isEmpty } ?? ""
                    result.append(TrayItem(element: element, pid: candidate.pid,
                        launchDate: candidate.launchDate, appName: candidate.name,
                        bundleID: candidate.bundleID, ordinal: index, totalItems: elements.count,
                        identifier: identifier,
                        fingerprint: [role, title, description, help].joined(separator: "\u{1f}"), detail: detail,
                        frame: frame, icon: candidate.icon))
                }
                let report = ProcessScanReport(pid: candidate.pid, name: candidate.name, launchDate: candidate.launchDate,
                    itemCount: result.count, cachedItemCount: 0, state: state, source: extras.source, issues: issues)
                collection.lock.lock()
                collection.items.append(contentsOf: result)
                collection.reports.append(report)
                collection.lock.unlock()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            collection.lock.lock()
            let scannedItems = collection.items
            var reports = collection.reports
            collection.lock.unlock()
            // Recheck liveness after slow AX IPC: do not resurrect an app that
            // exited while this scan's worker queue was still running.
            let live = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.map {
                DiscoveryProcessIdentity(pid: $0.processIdentifier, launchDate: $0.launchDate)
            }
            let updates = reports.map { report in
                DiscoveryUpdate(identity: report.identity, state: report.state,
                                items: scannedItems.filter { $0.pid == report.pid && $0.launchDate == report.launchDate })
            }
            let result = self.cache.reconcile(live: live, updates: updates)
            for index in reports.indices {
                reports[index].cachedItemCount = self.cache.items(for: reports[index].identity).count
            }
            let needsFollowUp = self.refreshAgain
            self.refreshAgain = false
            self.isScanning = false
            self.didUpdate?(ScanSnapshot(items: result, trusted: AXIsProcessTrusted(), reports: reports,
                                         startedAt: startedAt, completedAt: Date(), scanID: scanID))
            if needsFollowUp && !self.isScanning {
                self.refresh()
            }
        }
    }
}
