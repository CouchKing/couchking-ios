import Foundation
#if os(iOS)
import UIKit
import UserNotifications

/// The app is portrait by default; the player asks for landscape via Platform.lockLandscape,
/// which flips this mask and the AppDelegate reports it. Without an app-level delegate the
/// scene geometry request is ignored, so a plain SwiftUI @main needs this adaptor.
enum OrientationGate { static var mask: UIInterfaceOrientationMask = .all }

final class CKAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // REAL PUSH (Oct 22): foreground banners + registration (no-op when signed out)
        UNUserNotificationCenter.current().delegate = self
        Push.register()
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Push.upload(tokenHex: deviceToken.map { String(format: "%02x", $0) }.joined())
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // was invisible — now a device that never registers tells us WHY (Oct 23)
        Push.reportRegisterFailure(error)
    }

    /// pushes show as banners even while the app is open (game starting = you want it NOW)
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationGate.mask
    }
}
#endif
