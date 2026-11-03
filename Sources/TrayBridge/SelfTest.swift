import Foundation
import ApplicationServices

private struct SelfTestError: Error, CustomStringConvertible {
    let description: String
}

func runSelfTests() throws -> Int {
    var count = 0
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw SelfTestError(description: message) }
        count += 1
    }
    let element = AXUIElementCreateApplication(getpid())
    var calls = 0
    var revalidations = 0
    let success = performTrayAction(element: element, press: { _ in calls += 1; return .success }, revalidate: {
        revalidations += 1; return element
    })
    try check(success == .accepted && calls == 1 && revalidations == 0, "successful press is never duplicated")

    calls = 0; revalidations = 0
    let timeout = performTrayAction(element: element, press: { _ in calls += 1; return .cannotComplete }, revalidate: {
        revalidations += 1; return element
    })
    try check(timeout == .unconfirmed && calls == 1 && revalidations == 0, "modal timeout must not trigger a second press")

    calls = 0; revalidations = 0
    let recovered = performTrayAction(element: element, press: { _ in calls += 1; return calls == 1 ? .invalidUIElement : .success }, revalidate: {
        revalidations += 1; return element
    })
    try check(recovered == .accepted && calls == 2 && revalidations == 1, "stale item gets one revalidated retry")

    calls = 0
    let missing = performTrayAction(element: element, press: { _ in calls += 1; return .invalidUIElement }, revalidate: { nil })
    try check(missing == .failed(AXError.invalidUIElement.rawValue) && calls == 1, "ambiguous or missing replacement is never pressed")

    calls = 0
    let unsupported = performTrayAction(element: element, press: { _ in calls += 1; return .actionUnsupported }, revalidate: { element })
    try check(unsupported == .failed(AXError.actionUnsupported.rawValue) && calls == 1, "unsupported action surfaces a failure")

    let screen = MenuBarRegion(displayBounds: CGRect(x: 0, y: 0, width: 1512, height: 982),
                               rightSafeStart: 830, applicationMenuEnd: nil, menuBarHeight: 37)
    try check(MenuBarGeometry.placement(of: CGRect(x: 760, y: 0, width: 24, height: 37), regions: [screen]) == .obscured, "notch item is prioritized")
    try check(MenuBarGeometry.placement(of: CGRect(x: 1400, y: 0, width: 24, height: 37), regions: [screen]) == .visible, "right-side item remains available")
    try check(MenuBarGeometry.placement(of: nil, regions: [screen]) == .unknown, "missing geometry is kept")
    return count
}
