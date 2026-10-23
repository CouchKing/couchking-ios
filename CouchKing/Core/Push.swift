import Foundation
#if os(iOS)
import UIKit
import UserNotifications

/// REAL PUSH (Oct 22): APNs registration + token upload. The server (addon /tvapp/push-register
/// + the 60s fan-out) is already live — this is the device half. Notifications follow the same
/// per-profile rules as Android: your profile's game reminders + followed shows ring YOUR devices.
enum Push {
    /// Ask for permission (first time) and register with APNs. Safe to call repeatedly —
    /// signed-out users are skipped, iOS dedups the system prompt itself.
    static func register() {
        let e = UserDefaults.standard.string(forKey: "email") ?? ""
        guard !e.isEmpty else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { ok, err in
            guard ok else {
                // denied / undetermined — beacon it instead of dying silently here. The whole
                // fleet showed ZERO APNs tokens (Oct 23) and a device that was never granted
                // looked identical to one simply signed out. Now it's diagnosable.
                beacon("authorization not granted (err=\(err?.localizedDescription ?? "none"))")
                return
            }
            DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    /// APNs registration failed outright (didFailToRegisterForRemoteNotificationsWithError).
    /// Was invisible before — a device that never got a token looked like a signed-out one. */
    static func reportRegisterFailure(_ error: Error) {
        beacon("APNs register failed: \(error.localizedDescription)")
    }

    /// One [push-fail] beacon → /tvapp/crash → server dedups 6h/model and pings ops TG.
    private static func beacon(_ why: String) {
        let model = UIDevice.current.model
        let v = "ios-" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
        Task {
            _ = try? await API.postJSON("/tvapp/crash",
                body: ["v": v, "model": model, "trace": "[push-fail] \(why)"])
        }
    }

    /// APNs handed us a device token — tie it to the account + profile on the server.
    static func upload(tokenHex: String) {
        let e = UserDefaults.standard.string(forKey: "email") ?? ""
        let t = UserDefaults.standard.string(forKey: "token") ?? ""
        var pid = UserDefaults.standard.string(forKey: "curProfile") ?? ""
        if pid.isEmpty { pid = "any" }
        guard !e.isEmpty, !t.isEmpty, !tokenHex.isEmpty else { return }
        Task {
            _ = try? await API.postJSON("/tvapp/push-register", body: [
                "e": e, "t": t, "pid": pid,
                "platform": "apns", "token": tokenHex,
                "model": UIDevice.current.model])
        }
    }
}
#endif
