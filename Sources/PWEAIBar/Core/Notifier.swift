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

    private var authorised = false

    func start() {
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            Task { @MainActor in self.authorised = ok }
        }
        c.setNotificationCategories([
            UNNotificationCategory(identifier: "attention",
                                   actions: [UNNotificationAction(identifier: "open",
                                                                  title: "去看看",
                                                                  options: [.foreground])],
                                   intentIdentifiers: [])
        ])
    }

    func deliver(_ a: RuleEngine.Alert, away: Bool) {
        let p = Prefs.shared

        // The notch only earns an interruption when something is genuinely waiting on a human.
        if p.placement == .notch, Prefs.hasNotch, a.kind == .waiting {
            NotchWindow.shared.flash(title: a.title, body: a.body)
        }

        if authorised {
            let n = UNMutableNotificationContent()
            n.title = a.title
            n.body = a.body
            n.categoryIdentifier = a.kind == .waiting ? "attention" : ""
            n.userInfo = ["provider": a.provider.rawValue]
            if p.sound && a.urgent { n.sound = .default }
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: n, trigger: nil))
        }

        // Away from the desk: the Mac's own notification is not going to reach you.
        if away, !p.pushURL.isEmpty { push(a) }
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
