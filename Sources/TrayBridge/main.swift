import AppKit
import ApplicationServices
import Darwin

// This path deliberately exits before NSApplication.shared is initialized. The
// parent may still be in its termination callback when this helper is launched.
if CommandLine.arguments.contains("--relaunch-helper") {
    let arguments = CommandLine.arguments
    guard arguments.count == 4, arguments[1] == "--relaunch-helper",
          let parentPID = pid_t(arguments[2]), parentPID > 1, parentPID != getpid(),
          arguments[3] == Bundle.main.bundlePath,
          Bundle.main.bundleURL.pathExtension == "app" else {
        fputs("Invalid relaunch helper arguments.\n", stderr)
        exit(64)
    }
    let deadline = ProcessInfo.processInfo.systemUptime + 8
    var parentExited = false
    repeat {
        let status = Darwin.kill(parentPID, 0)
        let statusError = errno
        if status == -1 && statusError == ESRCH {
            parentExited = true
            break
        }
        if status == -1 && statusError != EPERM {
            fputs("Cannot inspect the parent process.\n", stderr)
            exit(75)
        }
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        if remaining <= 0 { break }
        Thread.sleep(forTimeInterval: min(0.1, remaining))
    } while ProcessInfo.processInfo.systemUptime < deadline
    guard parentExited else {
        fputs("The parent did not exit before the relaunch deadline.\n", stderr)
        exit(75)
    }
    let launcher = Process()
    launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    launcher.arguments = ["-n", arguments[3]]
    do {
        try launcher.run()
        launcher.waitUntilExit()
        exit(launcher.terminationStatus)
    } catch {
        fputs("Could not relaunch the application: \(error.localizedDescription)\n", stderr)
        exit(75)
    }
}

if CommandLine.arguments.contains("--self-test") {
    do {
        let count = try runSelfTests()
        print("PASS: \(count) core assertions")
        exit(0)
    } catch {
        fputs("FAIL: \(error)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--diagnose") {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    print("TrayBridge \(version) (\(build)) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    print("Bundle path: \(Bundle.main.bundlePath)")
    print("Accessibility: \(AXIsProcessTrusted() ? "granted" : "not granted")")
    print("GUI session is checked only when launching the .app, not in CLI diagnostics.")
    print("No permissions requested, no clicks sent, no settings changed.")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
