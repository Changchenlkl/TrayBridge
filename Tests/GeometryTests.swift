import Foundation
import CoreGraphics

struct GeometryTestFailure: Error, CustomStringConvertible {
    let description: String
}

/// No window server or permissions required. The caller supplies the executable
/// entry point, allowing the same checks to run from a command-line test target.
@discardableResult
func runGeometryTests() throws -> Int {
    let notched = MenuBarRegion(
        displayBounds: CGRect(x: 0, y: 0, width: 1512, height: 982),
        rightSafeStart: 830, applicationMenuEnd: nil, menuBarHeight: 37
    )
    let plain = MenuBarRegion(
        displayBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        rightSafeStart: nil, applicationMenuEnd: 460, menuBarHeight: 24
    )
    let leftDisplay = MenuBarRegion(
        displayBounds: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
        rightSafeStart: nil, applicationMenuEnd: -1500, menuBarHeight: 24
    )
    let aboveDisplay = MenuBarRegion(
        displayBounds: CGRect(x: 0, y: -1080, width: 1920, height: 1080),
        rightSafeStart: nil, applicationMenuEnd: 420, menuBarHeight: 24
    )
    var checks = 0
    func expect(_ label: String, _ frame: CGRect?, _ regions: [MenuBarRegion], _ expected: ItemPlacement) throws {
        checks += 1
        let actual = MenuBarGeometry.placement(of: frame, regions: regions)
        if actual != expected {
            throw GeometryTestFailure(description: "\(label): expected \(expected.rawValue), got \(actual.rawValue)")
        }
    }

    try expect("right of notch", CGRect(x: 1000, y: 0, width: 24, height: 37), [notched], .visible)
    try expect("touch safe boundary", CGRect(x: 830, y: 0, width: 24, height: 37), [notched], .visible)
    try expect("cross notch boundary", CGRect(x: 829.5, y: 0, width: 24, height: 37), [notched], .obscured)
    try expect("left side of notch", CGRect(x: 700, y: 0, width: 24, height: 37), [notched], .obscured)
    try expect("last icon", CGRect(x: 1488, y: 0, width: 24, height: 37), [notched], .visible)
    try expect("cross right edge", CGRect(x: 1500, y: 0, width: 24, height: 37), [notched], .obscured)
    try expect("fully off left", CGRect(x: -100, y: 0, width: 24, height: 37), [notched], .obscured)
    try expect("cross left edge", CGRect(x: -1, y: 0, width: 24, height: 37), [notched], .obscured)
    try expect("small vertical AX offset", CGRect(x: 1000, y: 2, width: 24, height: 37), [notched], .visible)
    try expect("window below menu", CGRect(x: 1000, y: 70, width: 24, height: 37), [notched], .unknown)
    try expect("oversize regular window", CGRect(x: 1000, y: 0, width: 300, height: 400), [notched], .unknown)

    try expect("plain visible", CGRect(x: 600, y: 0, width: 24, height: 24), [plain], .visible)
    try expect("over application menus", CGRect(x: 450, y: 0, width: 24, height: 24), [plain], .obscured)
    try expect("touch application boundary", CGRect(x: 460, y: 0, width: 24, height: 24), [plain], .visible)
    try expect("negative external coordinates", CGRect(x: -200, y: 0, width: 24, height: 24), [notched, leftDisplay], .visible)
    try expect("external application menus", CGRect(x: -1600, y: 0, width: 24, height: 24), [notched, leftDisplay], .obscured)
    try expect("across adjacent displays", CGRect(x: -12, y: 0, width: 24, height: 24), [notched, leftDisplay], .obscured)
    try expect("screen above primary", CGRect(x: 900, y: -1080, width: 24, height: 24), [notched, aboveDisplay], .visible)
    try expect("below other screen top", CGRect(x: 900, y: -1000, width: 24, height: 24), [notched, aboveDisplay], .unknown)

    try expect("missing frame", nil, [notched], .unknown)
    try expect("zero width", CGRect(x: 1000, y: 0, width: 0, height: 37), [notched], .unknown)
    try expect("negative dimensions", CGRect(x: 1000, y: 0, width: -24, height: 37), [notched], .unknown)
    try expect("nonfinite position", CGRect(x: CGFloat.nan, y: 0, width: 24, height: 37), [notched], .unknown)
    try expect("nonfinite size", CGRect(x: 1000, y: 0, width: CGFloat.infinity, height: 37), [notched], .unknown)
    try expect("no displays", CGRect(x: 1000, y: 0, width: 24, height: 37), [], .unknown)
    let invalid = MenuBarRegion(displayBounds: notched.displayBounds, rightSafeStart: .nan, applicationMenuEnd: nil, menuBarHeight: 37)
    try expect("invalid display geometry", CGRect(x: 1000, y: 0, width: 24, height: 37), [invalid], .unknown)
    let mirrored = MenuBarRegion(displayBounds: notched.displayBounds, rightSafeStart: nil, applicationMenuEnd: 400, menuBarHeight: 37)
    try expect("mirrored display conservative result", CGRect(x: 700, y: 0, width: 24, height: 37), [mirrored, notched], .obscured)
    return checks
}
