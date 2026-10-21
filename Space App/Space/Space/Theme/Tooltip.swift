import SwiftUI
import Observation
#if os(macOS)
import AppKit
#endif

/// Hover hints for the app's buttons: a small dark label under the button, shown quickly (the system's
/// help tags come late and not at all for some plain buttons). Once one is showing, moving to the next
/// button shows its hint at once, as in Finder's toolbar.
@MainActor
@Observable
final class TipCenter {
    static let shared = TipCenter()

    private(set) var text: String?
    private(set) var anchor: CGRect = .zero
    @ObservationIgnored private var owner: UUID?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var lastHidden = Date.distantPast
    #if os(macOS)
    @ObservationIgnored private var monitor: Any?
    #endif

    func enter(_ id: UUID, text: String, frame: CGRect) {
        owner = id
        pending?.cancel()
        let quick = self.text != nil || Date().timeIntervalSince(lastHidden) < 0.6
        pending = Task { [weak self] in
            if !quick { try? await Task.sleep(for: .milliseconds(450)) }
            guard let self, !Task.isCancelled, self.owner == id else { return }
            self.anchor = frame
            self.text = text
        }
    }

    func leave(_ id: UUID) {
        guard owner == id else { return }
        owner = nil
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard let self, !Task.isCancelled, self.owner == nil else { return }
            self.hide()
        }
    }

    /// The button moved while its hint shows (the panel folded, the list scrolled).
    func move(_ id: UUID, frame: CGRect) {
        if owner == id, text != nil { anchor = frame }
    }

    func hide() {
        pending?.cancel()
        if text != nil { lastHidden = Date() }
        text = nil
    }

    /// A click, a key or scrolling puts the hint away, like the system's help tags.
    func installMonitor() {
        #if os(macOS)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) { event in
            MainActor.assumeIsolated {
                TipCenter.shared.owner = nil
                TipCenter.shared.hide()
            }
            return event
        }
        #endif
    }
}

private struct TipModifier: ViewModifier {
    let text: String
    @State private var id = UUID()
    @State private var frame: CGRect = .zero
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { f in
                frame = f
                if hovering { TipCenter.shared.move(id, frame: f) }
            }
            .onHover { on in
                hovering = on
                guard !text.isEmpty else { return }
                if on { TipCenter.shared.enter(id, text: text, frame: frame) } else { TipCenter.shared.leave(id) }
            }
            .onDisappear { if hovering { hovering = false; TipCenter.shared.leave(id) } }
            .accessibilityHint(text)
    }
}

extension View {
    /// What this button does, shown when the pointer rests on it.
    func tip(_ text: String) -> some View { modifier(TipModifier(text: text)) }
}

/// Draws the current hint over the whole window. Put once at the top of the window's view.
struct TipLayer: View {
    private let center = TipCenter.shared
    @State private var size: CGSize = .zero

    var body: some View {
        GeometryReader { g in
            if let text = center.text {
                let origin = g.frame(in: .global).origin
                let a = center.anchor.offsetBy(dx: -origin.x, dy: -origin.y)
                let below = a.maxY + 8 + size.height <= g.size.height - 4
                let y = below ? a.maxY + 6 + size.height / 2 : a.minY - 6 - size.height / 2
                let half = size.width / 2
                let x = min(max(a.midX, half + 8), g.size.width - half - 8)
                Text(text)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 280, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(white: 0.11).opacity(0.96)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                    .fixedSize()
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
                    .position(x: x, y: y)
                    .transition(.opacity)
                    .id(text)
            }
        }
        .animation(.easeOut(duration: 0.12), value: center.text)
        .allowsHitTesting(false)
        .onAppear { center.installMonitor() }
    }
}
