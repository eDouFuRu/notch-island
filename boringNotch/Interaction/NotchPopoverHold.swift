import SwiftUI

/// Holds the island open for as long as an attached popover is on screen.
///
/// A popover draws in its own window, outside the island's hit region, so moving the
/// pointer onto it reads as leaving the island and collapses everything — taking the
/// popover with it. An `NSMenu` avoids this because the coordinator watches
/// `NSMenu.didBeginTrackingNotification`; SwiftUI popovers raise no such notification and
/// have to say so themselves.
private struct NotchPopoverHoldModifier: ViewModifier {
    @Binding var isPresented: Bool
    let releaseGrace: TimeInterval

    /// One identity per attachment point, so several open popovers cannot release each
    /// other's hold.
    @State private var reason = NotchOpenHoldReason.popover(UUID())

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { _, presented in
                if presented {
                    NotchOpenHoldCenter.shared.begin(reason)
                } else {
                    NotchOpenHoldCenter.shared.endAfterGrace(reason, grace: releaseGrace)
                }
            }
            // The binding does not always flip back — a view torn down while its popover
            // is up leaves the hold behind, and the island would never collapse again.
            .onDisappear { NotchOpenHoldCenter.shared.end(reason) }
    }
}

extension View {
    /// - Parameter releaseGrace: time allowed for the pointer to travel from the dismissed
    ///   popover back onto the island before collapse can resume.
    func notchHoldsOpenWhilePopoverPresented(_ isPresented: Binding<Bool>,
                                             releaseGrace: TimeInterval = 0.6) -> some View {
        modifier(NotchPopoverHoldModifier(isPresented: isPresented, releaseGrace: releaseGrace))
    }
}
