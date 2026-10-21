import SwiftUI
import UIKit

extension View {
    /// Sets the Mac Catalyst title bar text of the window hosting this view.
    /// SwiftUI's `.navigationTitle` on a pushed view does not update the title
    /// bar, and `UIApplication.connectedScenes.first` may be a different window.
    func sceneTitle(_ title: String) -> some View {
        background(SceneTitleSetter(title: title))
    }
}

private struct SceneTitleSetter: UIViewRepresentable {
    let title: String

    func makeUIView(context: Context) -> SceneTitleView {
        let view = SceneTitleView()
        view.isUserInteractionEnabled = false
        view.title = title
        return view
    }

    func updateUIView(_ view: SceneTitleView, context: Context) {
        view.title = title
    }
}

/// Invisible view that applies its title to its own window's scene once it is
/// attached to a window, and again whenever the title changes.
private final class SceneTitleView: UIView {
    var title = "" {
        didSet { applyTitle() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyTitle()
    }

    private func applyTitle() {
        #if targetEnvironment(macCatalyst)
            window?.windowScene?.title = title
        #endif
    }
}
