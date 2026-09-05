import AppKit
import UserNotifications

/// Delivers what the rule engine decided to say, to whichever surface the user picked.
///
/// Three placements, and they are not the same message at different volumes. The menu bar is
/// ambient — it changes and waits to be noticed. The notch is unmissable, so it is reserved for
/// things that are actually waiting on you. Notification Center is the one that survives you
/// being in another Space, and the only one that can carry buttons.
@MainActor
final class Notifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {

    static let shared = Notifier()
    var onOpen: ((Provider) -> Void)?

    private var authorizationTask: Task<Permission, Never>?
    private var refusedAt: Date?
    /// True once the OS has actually said no. The panel says so, because an alert that cannot
    /// be delivered anywhere still has to reach the person somehow.
    @Published private(set) var systemChannelRefused = false
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
                do {
                    // A thrown error is not an answer. Treating it as one is how an alert gets
                    // marked delivered and silently dropped, which is worse than never firing.
                    return try await center.requestAuthorization(options: [.alert, .sound])
                        ? .granted : .refused
                } catch {
                    return .unavailable
                }
            }
        }
        authorizationTask = task
        let result = await task.value
        authorizationTask = nil
        if result == .refused { refusedAt = Date() }
        systemChannelRefused = result == .refused
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

    /// Prints what the notification system actually thinks, then tries one real delivery.
    func diagnose() async {
        let center = UNUserNotificationCenter.current()
        start()
        let before = await center.notificationSettings()
        print("授权状态   \(Self.word(before.authorizationStatus))")
        print("提醒样式   \(before.alertStyle.rawValue)   通知中心 \(before.notificationCenterSetting.rawValue)")
        if before.authorizationStatus == .notDetermined {
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                print("请求授权   \(granted ? "同意" : "拒绝")")
            } catch {
                print("请求授权   抛错：\(error.localizedDescription)")
                print("           这不是拒绝。当成拒绝处理会让提醒被静静丢掉。")
            }
        }
        let after = await center.notificationSettings()
        print("现在状态   \(Self.word(after.authorizationStatus))")
        let content = UNMutableNotificationContent()
        content.title = "PWE AI Bar 自检"
        content.body = "这条能看到，说明通知这条路是通的。"
        do {
            try await center.add(UNNotificationRequest(identifier: "pwe-selftest",
                                                       content: content, trigger: nil))
            print("投递测试   系统已接受")
        } catch {
            print("投递测试   失败：\(error.localizedDescription)")
        }
    }

    static func word(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "已授权"
        case .denied: return "已拒绝"
        case .notDetermined: return "尚未询问"
        case .provisional: return "临时授权"
        case .ephemeral: return "短期授权"
        @unknown default: return "未知(\(status.rawValue))"
        }
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
