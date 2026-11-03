import Foundation

struct DiscoveryProcessIdentity: Hashable {
    let pid: Int32
    let launchDate: Date?
}

enum DiscoveryReadState: String {
    case read
    case absent
    case transient
    case unavailable
}

struct DiscoveryUpdate<Value> {
    let identity: DiscoveryProcessIdentity
    let state: DiscoveryReadState
    let items: [Value]
}

/// Keeps a transient AX read failure from looking like an app removed its icon.
/// A different launch date is a different process, even if macOS reused its PID.
struct DiscoveryCache<Value> {
    private var values: [DiscoveryProcessIdentity: [Value]] = [:]
    private var states: [DiscoveryProcessIdentity: DiscoveryReadState] = [:]

    func items(for identity: DiscoveryProcessIdentity) -> [Value] { values[identity] ?? [] }
    func state(for identity: DiscoveryProcessIdentity) -> DiscoveryReadState? { states[identity] }

    @discardableResult
    mutating func reconcile(live: [DiscoveryProcessIdentity], updates: [DiscoveryUpdate<Value>]) -> [Value] {
        let liveSet = Set(live)
        values = values.filter { liveSet.contains($0.key) }
        states = states.filter { liveSet.contains($0.key) }
        for update in updates where liveSet.contains(update.identity) {
            states[update.identity] = update.state
            switch update.state {
            case .read:
                values[update.identity] = update.items
            case .absent:
                values.removeValue(forKey: update.identity)
            case .transient, .unavailable:
                // Retain only this exact process's known items. The UI must
                // separately consult the current report and permission state.
                if values[update.identity] == nil && !update.items.isEmpty {
                    values[update.identity] = update.items
                }
            }
        }
        return live.flatMap { values[$0] ?? [] }
    }
}
