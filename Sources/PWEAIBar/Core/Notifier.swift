import AppKit
import UserNotifications

/// Delivers what the rule engine decided to say, to whichever surface the user picked.
///
/// Three placements, and they are not the same message at different volumes. The menu bar is
/// ambient — it changes and waits to be noticed. The notch is unmissable, so it is reserved for
/// things that are actually waiting on you. Notification Center is the one that survives you
/// being in another Space, and the only one that can carry buttons.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {

    static let shared = Notifier()
    var onOpen: ((Provider) -> Void)?

    private var authorizationTask: Task<Permission, Never>?
    private var refusedAt: Date?
    private var auxiliaryAttempts: [String: Date] = [:]

    /// Refused is not the same as failed. Notification permission is asked for the first time we
    /// actually have something to say — not at launch, when the app has not yet shown anyone that
    /// it is worth trusting — and once someone has said no, asking again is not on the table.
    enum Permission { case granted, refused, unavailable }

    private func ensureAuthorised() async -> Permission {
        if let refused = refusedAt, Date().timeIntervalSince(refused) < 3600 { return .refused }
        if let task = authorizationTask { return await task.value }
        let task = Task { @MainActor () -> Permission in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: return .granted
            case .denied: return .refused
            default:
                return (try? await center.requestAuthorization(options: [.alert, .sound])) == true
                    ? .granted : .refused
            }
        }
        authorizationTask = task
        let result = await task.value
        authorizationTask = nil
        if result == .refused { refusedAt = Date() }
        return result
    }

    func start() {
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.setNotificationCategories([
            UNNotificationCategory(identifier: "attention",
                                   actions: [UNNotificationAction(identifier: "open",
                                                                  title: "去看看",
                                                                  options: [.foreground])],
                                   intentIdentifiers: [])
        ])
    }

    /// Returning false leaves the alert queued. A stable identifier makes retries idempotent.
    func deliver(_ a: RuleEngine.Alert, away: Bool) async -> Bool {
        let p = Prefs.shared
        // These surfaces remain independent of Notification Center permission. Retrying the
        // OS delivery must not repeatedly flash the notch or resend the same webhook.
        auxiliaryAttempts = auxiliaryAttempts.filter { Date().timeIntervalSince($0.value) < 86400 }
        if auxiliaryAttempts[a.id] == nil {
            auxiliaryAttempts[a.id] = Date()
            if p.placement == .notch, Prefs.hasNotch, a.kind == .waiting {
                NotchWindow.shared.flash(title: a.title, body: a.body)
            }
            if away, !p.pushURL.isEmpty { push(a) }
        }
        switch await ensureAuthorised() {
        case .granted: break
        // Nothing will ever accept this one. Keeping it queued for a day of one-minute retries
        // buys nothing; the notch and the push above are what this person actually gets.
        case .refused: return true
        case .unavailable: return false
        }
        let n = UNMutableNotificationContent()
        n.title = a.title; n.body = a.body
        n.categoryIdentifier = a.kind == .waiting ? "attention" : ""
        n.userInfo = ["provider": a.provider.rawValue]
        if p.sound && a.urgent { n.sound = .default }
        do {
            try await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: a.id, content: n, trigger: nil))
        } catch { return false }
        return true
    }

    /// A plain POST to whatever endpoint the user configured — ntfy, Bark, a webhook. No account
    /// of ours, no service in the middle, and nothing is sent unless they typed a URL in.
    private func push(_ a: RuleEngine.Alert) {
        guard let url = URL(string: Prefs.shared.pushURL) else { return }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("PWE AI Bar", forHTTPHeaderField: "X-Title")
        r.setValue(a.urgent ? "high" : "default", forHTTPHeaderField: "X-Priority")
        r.httpBody = "\(a.title) — \(a.body)".data(using: .utf8)
        r.timeoutInterval = 10
        URLSession.shared.dataTask(with: r).resume()
    }

    nonisolated func userNotificationCenter(_ c: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let raw = response.notification.request.content.userInfo["provider"] as? String
        await MainActor.run {
            self.onOpen?(Provider(rawValue: raw ?? "") ?? .claude)
        }
    }

    nonisolated func userNotificationCenter(_ c: UNUserNotificationCenter,
                                            willPresent n: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound] }
}
