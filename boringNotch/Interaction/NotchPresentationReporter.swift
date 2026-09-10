// Custom changes for 工位充电岛: report SwiftUI's interpolated contour to AppKit.
import SwiftUI

struct NotchPresentationReporter: AnimatableModifier {
    var width: CGFloat
    var height: CGFloat
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    weak var coordinator: NotchPointerCoordinator?

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(width, height), .init(topRadius, bottomRadius)) }
        set {
            width = newValue.first.first
            height = newValue.first.second
            topRadius = newValue.second.first
            bottomRadius = newValue.second.second
            report()
        }
    }

    func body(content: Content) -> some View {
        content.background {
            NonanimatedPresentationSeed(width: width, height: height, topRadius: topRadius,
                                        bottomRadius: bottomRadius, pointerCoordinator: coordinator)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func report() {
        coordinator?.enqueuePresentation(size: CGSize(width: width, height: height),
                                         topRadius: topRadius, bottomRadius: bottomRadius)
    }
}

/// Model-value onChange callbacks can deliver the final target while an animation is
/// still presenting intermediate values. Only seed initial/no-animation layout here;
/// animated geometry has one source of truth: the modifier's animatableData setter.
private struct NonanimatedPresentationSeed: NSViewRepresentable {
    let width: CGFloat
    let height: CGFloat
    let topRadius: CGFloat
    let bottomRadius: CGFloat
    weak var pointerCoordinator: NotchPointerCoordinator?

    final class Coordinator { var seeded = false }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
    func updateNSView(_ nsView: NSView, context: Context) {
        let initialLayout = !context.coordinator.seeded
        context.coordinator.seeded = true
        guard initialLayout || context.transaction.animation == nil || context.transaction.disablesAnimations else { return }
        pointerCoordinator?.enqueuePresentation(size: CGSize(width: width, height: height),
                                                topRadius: topRadius, bottomRadius: bottomRadius)
    }
}
