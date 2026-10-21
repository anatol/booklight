import SwiftUI

/// A small stack of round buttons in the top-left corner: back to the library,
/// find, and (for reflowable books) text size. It stays out of the way: it only
/// appears when the pointer visits the corner or the page is tapped, never because
/// the book scrolled, and it takes no space from the text.
struct ReaderCornerControls<Engine: ReaderEngine>: View {
    let session: ReaderSession<Engine>
    let onBack: () -> Void

    var body: some View {
        let engine = session.engine
        VStack(spacing: 10) {
            Button(action: onBack) {
                RoundGlyph(systemName: "chevron.left")
            }
            .accessibilityLabel("Back to library")

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    session.openSearch()
                }
            } label: {
                RoundGlyph(systemName: "magnifyingglass")
            }
            .accessibilityLabel("Find in book")

            if engine.supportsTextSize {
                Menu {
                    Button("Larger Text", systemImage: "textformat.size.larger") {
                        engine.increaseTextSize()
                    }
                    Button("Smaller Text", systemImage: "textformat.size.smaller") {
                        engine.decreaseTextSize()
                    }
                    if let percent = engine.textSizePercent {
                        Text("Text size \(percent)%")
                    }
                } label: {
                    RoundGlyph(systemName: "textformat.size")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .accessibilityLabel("Text size")
            }
        }
        .buttonStyle(.plain)
        .padding(12)
    }
}

/// The round material button face shared by the corner controls.
private struct RoundGlyph: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.primary)
            .frame(width: 36, height: 36)
            .background(.regularMaterial, in: Circle())
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }
}

/// A vertical scrubber on the trailing edge that replaces the system scroll
/// indicator: it always shows where you are, and dragging it jumps through the
/// book with a live percentage. It is hidden until the pointer is over it (or
/// the reader bars are up, which is how touch users reveal it).
struct ReaderScrubber<Engine: ReaderEngine>: View {
    let session: ReaderSession<Engine>
    /// Current reading progress (0–1) from the reader.
    let progress: Double

    @State private var scrubValue = 0.0
    @State private var isScrubbing = false
    @State private var isHovering = false

    private let thumbHeight: CGFloat = 44
    private var isExpanded: Bool { isScrubbing || isHovering }
    private var isVisible: Bool { isExpanded || session.isChromeVisible }
    private var shownProgress: Double { isScrubbing ? scrubValue : progress.clampedToUnit }

    var body: some View {
        GeometryReader { proxy in
            let travel = max(proxy.size.height - thumbHeight, 1)

            ZStack(alignment: .topTrailing) {
                // Track
                Capsule()
                    .fill(.secondary.opacity(isExpanded ? 0.28 : 0.14))
                    .frame(width: isExpanded ? 8 : 4)
                    .frame(maxHeight: .infinity)
                    .padding(.trailing, isExpanded ? 10 : 12)

                // Thumb
                Capsule()
                    .fill(isExpanded ? Color.accentColor : Color.secondary.opacity(0.7))
                    .frame(width: isExpanded ? 8 : 4, height: thumbHeight)
                    .padding(.trailing, isExpanded ? 10 : 12)
                    .offset(y: shownProgress * travel)

                // Percentage bubble beside the thumb while dragging
                if isScrubbing {
                    Text("\(Int((shownProgress * 100).rounded()))%")
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                        .padding(.trailing, 32)
                        .offset(y: shownProgress * travel + thumbHeight / 2 - 16)
                        .transition(.opacity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topTrailing)
            // Fully transparent but still hit-testable, so hovering the edge reveals it.
            .opacity(isVisible ? 1 : 0)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isScrubbing {
                            isScrubbing = true
                            session.setChromeVisible(true)
                        }
                        // The thumb's center follows the pointer.
                        let fraction = ((value.location.y - thumbHeight / 2) / travel).clamped01
                        scrubValue = fraction
                        session.engine.seek(toProgress: fraction)
                    }
                    .onEnded { _ in
                        isScrubbing = false
                        session.scheduleChromeAutoHide()
                    }
            )
            .onHover { isHovering = $0 }
            .animation(.easeInOut(duration: 0.15), value: isExpanded)
            .animation(.easeInOut(duration: 0.2), value: isVisible)
        }
        .frame(width: 56)
        .accessibilityElement()
        .accessibilityLabel("Reading position")
        .accessibilityValue("\(Int((shownProgress * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            let step = 0.05
            let target = shownProgress + (direction == .increment ? step : -step)
            session.engine.seek(toProgress: target.clamped01)
        }
    }
}

private extension Double {
    var clamped01: Double { min(max(self, 0), 1) }
}
