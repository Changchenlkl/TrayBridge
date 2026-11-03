import Foundation

private struct DiscoveryTestFailure: Error, CustomStringConvertible {
    let description: String
}

@discardableResult
func runDiscoveryTests() throws -> Int {
    var count = 0
    func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw DiscoveryTestFailure(description: message) }
        count += 1
    }
    let first = DiscoveryProcessIdentity(pid: 20, launchDate: Date(timeIntervalSince1970: 100))
    let second = DiscoveryProcessIdentity(pid: 21, launchDate: Date(timeIntervalSince1970: 101))
    let reused = DiscoveryProcessIdentity(pid: 20, launchDate: Date(timeIntervalSince1970: 200))
    var cache = DiscoveryCache<String>()
    var result = cache.reconcile(live: [first], updates: [.init(identity: first, state: .read, items: ["first icon"])])
    try expect(result == ["first icon"], "initial registered icon is cached")

    result = cache.reconcile(live: [first], updates: [.init(identity: first, state: .transient, items: [])])
    try expect(result == ["first icon"], "timeout does not delete a known icon")
    try expect(cache.state(for: first) == .transient, "timeout remains visible as a current error")

    result = cache.reconcile(live: [first], updates: [.init(identity: first, state: .unavailable, items: [])])
    try expect(result == ["first icon"], "permission loss preserves identity but not successful status")
    try expect(cache.state(for: first) == .unavailable, "permission loss replaces the old successful status")

    result = cache.reconcile(live: [first], updates: [.init(identity: first, state: .read, items: ["recovered icon"])])
    try expect(result == ["recovered icon"], "successful reauthorization replaces old cache")
    try expect(cache.state(for: first) == .read, "successful reauthorization clears the old denied status")

    result = cache.reconcile(live: [first, second], updates: [.init(identity: second, state: .absent, items: [])])
    try expect(result == ["recovered icon"], "new process with no status item is not invented")
    result = cache.reconcile(live: [first, second], updates: [.init(identity: second, state: .read, items: ["late icon"])])
    try expect(result == ["recovered icon", "late icon"], "late status-item registration is discovered")

    result = cache.reconcile(live: [second], updates: [])
    try expect(result == ["late icon"], "exited process is removed even without another AX result")
    try expect(cache.state(for: first) == nil, "exited process report is removed")

    _ = cache.reconcile(live: [first, second], updates: [.init(identity: first, state: .read, items: ["old process icon"])])
    result = cache.reconcile(live: [reused, second], updates: [.init(identity: reused, state: .transient, items: [])])
    try expect(result == ["late icon"], "PID reuse never revives the old process's icon")
    try expect(cache.items(for: first).isEmpty, "PID-reused old identity is removed")

    result = cache.reconcile(live: [second], updates: [.init(identity: second, state: .read, items: [])])
    try expect(result.isEmpty, "successful empty extras bar removes the icon")
    _ = cache.reconcile(live: [second], updates: [.init(identity: second, state: .read, items: ["another icon"])])
    result = cache.reconcile(live: [second], updates: [.init(identity: second, state: .absent, items: [])])
    try expect(result.isEmpty, "confirmed absent extras removes a previously registered icon")

    result = cache.reconcile(live: [], updates: [.init(identity: first, state: .read, items: ["late stale result"])])
    try expect(result.isEmpty, "late worker result for an exited process is ignored")
    return count
}
