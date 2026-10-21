import SwiftUI

/// The bars drawn over a reader. They make every reader function reachable by
/// touch (the keyboard shortcuts only help on a Mac or iPad with a keyboard),
/// and show reading progress, which is otherwise only in the Mac title bar.
struct ReaderTopBar<Engine: ReaderEngine>: View {
    let session: ReaderSession<Engine>
    let title: String
    let onBack: () -> Void

    var body: some View {
        let engine = session.engine
        HStack(spacing: 4) {
            Button(action: onBack) {
                Label("Library", systemImage: "chevron.left")
                    .labelStyle(.titleAndIcon)
                    .font(.body.weight(.semibold))
            }
            .accessibilityLabel("Back to library")

            Spacer(minLength: 12)

            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 420)

            Spacer(minLength: 12)

            if engine.supportsTextSize {
                Button {
                    engine.decreaseTextSize()
                } label: {
                    Image(systemName: "textformat.size.smaller")
                }
                .accessibilityLabel("Smaller text")

                if let percent = engine.textSizePercent {
                    Text("\(percent)%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 40)
                }

                Button {
                    engine.increaseTextSize()
                } label: {
                    Image(systemName: "textformat.size.larger")
                }
                .accessibilityLabel("Larger text")
            }

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    session.openSearch()
                }
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .accessibilityLabel("Find in book")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// A vertical scrubber on the trailing edge that replaces the system scroll
/// indicator: it always shows where you are, and dragging it jumps through the
/// book with a live percentage. It stays slim until the pointer is over it.
struct ReaderScrubber<Engine: ReaderEngine>: View {
    let session: ReaderSession<Engine>
    /// Current reading progress (0–1) from the reader.
    let progress: Double

    @State private var scrubValue = 0.0
    @State private var isScrubbing = false
    @State private var isHovering = false

    private let thumbHeight: CGFloat = 44
    private var isExpanded: Bool { isScrubbing || isHovering }
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
