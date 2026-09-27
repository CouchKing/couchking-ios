import Foundation

// In-app legal text (Android Legal.kt): App Store review wants Terms + Privacy reachable
// without leaving the app. Keep in sync with couchking.app/terms and /privacy.
enum Legal {
    static let terms = """
    Terms of Service

    Last updated: September 2026

    1. The service
    CouchKing is a media tracker and player. It lets you keep a library, track what you've watched, rate titles, keep profiles for the people in your household, and play content from an addon that your account has been given by the service you sign in to. CouchKing itself does not host, provide or sell any media.

    2. Accounts
    You may use CouchKing as a guest. An account is only needed to sync your library across devices and to use an addon. You are responsible for keeping your password private and for everything done under your account. You can delete your account at any time from Settings; deletion removes your account and its synced library from the service.

    3. Addons and access
    Playback is only available when the account you sign in with has been given an addon by that service. Access may be time-limited, limited to a number of devices, or revoked by the service that provides it. CouchKing shows the status it is told and does not guarantee availability, quality or continuity of any addon.

    4. Acceptable use
    You agree not to use CouchKing to infringe anyone's rights, to attack or overload the service, to share your account with people outside your household, or to circumvent limits set by an addon provider.

    5. Content and profiles
    Ratings, watch history and library entries you create belong to you. You may remove them at any time. Profiles are for the people in your household; each profile's history is kept separate.

    6. No warranty
    CouchKing is provided "as is". To the fullest extent the law allows, we disclaim all warranties and are not liable for indirect or consequential damages arising from your use of the app.

    7. Changes
    We may update these terms; continued use after an update means you accept the new terms. Material changes will be shown in the app.

    8. Contact
    Questions about these terms: support@couchking.app
    """

    static let privacy = """
    Privacy Policy

    Last updated: September 2026

    What we collect
    • Account: your email address, a display name if you give one, and a hashed password.
    • Library: the titles you add, mark watched, rate, and your playback positions, per profile — so they sync across your devices.
    • Playback: which title, episode and position you're watching, sent to the service that provides your addon so you can resume on another device and so "For You" can learn from what you finish.
    • Diagnostics: app version and, on failure, a short error description. No advertising identifiers, no location, no contacts.

    What we don't do
    We don't sell your data. We don't show ads. We don't track you across other apps or websites.

    Guests
    Without an account, everything stays on your device. Nothing is sent to us except the requests needed to look up titles.

    Where it lives
    Account and library data is stored by the service you sign in to and is deleted when you delete your account from Settings.

    Third parties
    Title artwork and metadata come from public catalog services (for example Cinemeta). Trailers play through YouTube's embedded player, which is covered by YouTube's own privacy policy.

    Your rights
    You can export or delete your data at any time by deleting your account, or by contacting support@couchking.app.

    Children
    CouchKing is not directed at children under 13 and we do not knowingly collect data from them.

    Changes
    We'll show material changes to this policy in the app.
    """
}
