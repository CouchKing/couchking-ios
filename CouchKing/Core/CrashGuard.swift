import Foundation

// iOS CrashGuard (Android CrashGuard.kt parity): capture uncaught exceptions + fatal
// signals, stash the trace on disk, and POST it to /tvapp/crash on the NEXT launch —
// nobody can attach a debugger to AJ's phone, so the app phones the stack home and the
// server pings Telegram (💥 alert, deduped on model + first trace line).
enum CrashGuard {
    private static let key = "ckPendingCrash"
    /// Precomputed at install() — the C signal handler can't capture context, and the TG
    /// crash line carried no BUILD number so "which build crashed" was guesswork (AJ Oct 5).
    static var buildTag = ""

    /// Tiny breadcrumb — CrashGuard appends the last one to the trace so an unsymbolicated
    /// stack still says WHICH phase died (profile-pick, home-load, …).
    static func crumb(_ t: String) {
        UserDefaults.standard.set(t + " @" + String(Int(Date().timeIntervalSince1970)), forKey: "ckCrumb")
    }

    static func install() {
        buildTag = "b" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")
        // ship any trace captured on the previous run
        if let t = UserDefaults.standard.string(forKey: key), !t.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
            Task {
                let model = API.deviceModel + " " + ProcessInfo.processInfo.operatingSystemVersionString
                _ = try? await API.postJSON("/tvapp/crash",
                                            body: ["v": Session.appVer + " " + buildTag, "model": model, "trace": t])
            }
        }
        NSSetUncaughtExceptionHandler { ex in
            let t = "\(CrashGuard.buildTag) crumb=\(UserDefaults.standard.string(forKey: "ckCrumb") ?? "-")\n\(ex.name.rawValue): \(ex.reason ?? "")\n" + ex.callStackSymbols.prefix(25).joined(separator: "\n")
            CrashGuard.stash(t)
        }
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(sig) { s in
                let t = "\(CrashGuard.buildTag) crumb=\(UserDefaults.standard.string(forKey: "ckCrumb") ?? "-")\nsignal \(s)\n" + Thread.callStackSymbols.prefix(25).joined(separator: "\n")
                CrashGuard.stash(t)
                exit(s)
            }
        }
    }

    /// UserDefaults may not persist during a crash — write the plist synchronously.
    private static func stash(_ trace: String) {
        UserDefaults.standard.set(trace, forKey: key)
        UserDefaults.standard.synchronize()
    }
}
