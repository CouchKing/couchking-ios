import Foundation
#if os(iOS)
import UIKit

/// The app is portrait by default; the player asks for landscape via Platform.lockLandscape,
/// which flips this mask and the AppDelegate reports it. Without an app-level delegate the
/// scene geometry request is ignored, so a plain SwiftUI @main needs this adaptor.
enum OrientationGate { static var mask: UIInterfaceOrientationMask = .all }

final class CKAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationGate.mask
    }
}
#endif
