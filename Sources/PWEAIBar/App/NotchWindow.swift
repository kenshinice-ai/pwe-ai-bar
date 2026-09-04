import AppKit
import SwiftUI

/// A banner that hangs either side of the camera housing.
///
/// Only exists on hardware that has a housing to hang off. `NSScreen.safeAreaInsets.top` is the
/// honest test — on a machine without a notch it is zero, the settings option greys out, and
/// this window is never built. Better a visibly unavailable choice than one that silently
/// does nothing.
@MainActor
final class NotchWindow {
    static let shared = NotchWindow()
    private var window: NSWindow?
    private var hideTask: Task<Void, Never>?

    func flash(title: String, body: String, seconds: Double = 6) {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
        else { return }

        let size = NSSize(width: 420, height: screen.safeAreaInsets.top + 14)
        let frame = NSRect(x: screen.frame.midX - size.width / 2,
                           y: screen.frame.maxY - size.height,
                           width: size.width, height: size.height)

        let w = window ?? {
            let win = NSWindow(contentRect: frame, styleMask: [.borderless],
                               backing: .buffered, defer: false)
            win.isOpaque = false
            win.backgroundColor = .clear
            win.level = .statusBar
            win.ignoresMouseEvents = true
            win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            window = win
            return win
        }()

        w.setFrame(frame, display: false)
        w.contentView = NSHostingView(rootView: NotchBanner(title: title, subtitle: body))
        w.orderFrontRegardless()

        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.window?.orderOut(nil)
        }
    }
}

private struct NotchBanner: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: Theme.s2) {
            WingView(channels: [], solid: true)
                .frame(width: 22, height: 22 / BrandMark.aspect)
                .foregroundStyle(Theme.hex(Theme.amber))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.sans(11.5, 600)).foregroundStyle(Theme.hex(Theme.textDark))
                Text(subtitle).font(Theme.sans(10.5)).foregroundStyle(Theme.hex(Theme.textDark2))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.s3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .clipShape(.rect(bottomLeadingRadius: 14, bottomTrailingRadius: 14))
    }
}
