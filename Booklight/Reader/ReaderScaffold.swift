import SwiftUI

/// Shared chrome around a format-specific reader: the floating find bar,
/// keyboard shortcuts, and Space / Shift+Space paging.
struct ReaderScaffold<Engine: ReaderEngine, Content: View>: View {
    @Bindable var session: ReaderSession<Engine>
    /// Reading progress (0–1) shown on the scrubber.
    let progress: Double?
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let engine = session.engine
        ZStack(alignment: .topTrailing) {
            content

            // The scrubber is the one scroll control: it replaces the system scroll
            // indicator and stays visible so you always know where you are.
            ReaderScrubber(session: session, progress: progress ?? 0)
                .frame(maxHeight: .infinity)
                .padding(.top, 64)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)

            // Corner controls. The find bar takes over the top while it is open.
            // One hover region covers the hot corner and the buttons, so moving
            // between them can't momentarily count as leaving.
            ZStack(alignment: .topLeading) {
                Color.clear
                    .frame(width: 64, height: 64)

                if session.isChromeVisible && !session.isSearchVisible {
                    ReaderCornerControls(session: session) { dismiss() }
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    session.setChromeVisible(true)
                } else {
                    session.scheduleChromeAutoHide(after: .seconds(1.5))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if session.isSearchVisible {
                ReaderSearchBar(
                    searchText: Binding(get: { session.searchText }, set: { session.searchText = $0 }),
                    matchCount: engine.searchMatchCount,
                    currentMatchIndex: engine.searchCurrentIndex,
                    isSearching: engine.isSearchInProgress,
                    hasActiveSearch: session.hasActiveSearch,
                    onSearchOrNext: { session.searchOrNext() },
                    onNext: { engine.nextSearchMatch() },
                    onPrevious: { engine.previousSearchMatch() },
                    onDismiss: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            session.dismissSearch()
                        }
                    }
                )
                .padding(.top, 8)
                .padding(.trailing, 16)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Cmd+F toggle button — invisible, uses .keyboardShortcut so it
            // works regardless of which view currently has focus (unlike
            // .onKeyPress which requires the view to be focused, and breaks
            // on Mac Catalyst after the search bar is dismissed).
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    session.toggleSearch()
                }
            } label: {
                EmptyView()
            }
            .keyboardShortcut("f", modifiers: .command)
            .hidden()
            // Standard back-navigation shortcuts.
            Button {
                engine.jumpBack()
            } label: {
                EmptyView()
            }
            .keyboardShortcut("[", modifiers: .command)
            .hidden()
            Button {
                engine.jumpBack()
            } label: {
                EmptyView()
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .hidden()
        }
        .focusable()
        .onKeyPress(.space, phases: .down) { keyPress in
            // Don't intercept Space when search bar is active (user is typing).
            guard !session.isSearchVisible else { return .ignored }
            // Space scrolls down, Shift+Space scrolls up (like macOS Preview).
            if keyPress.modifiers.contains(.shift) {
                engine.scrollPageUp()
            } else {
                engine.scrollPageDown()
            }
            return .handled
        }
        // Shift+"+" increases text size, Shift+"-" decreases it.
        .onKeyPress(characters: .init(charactersIn: "+="), phases: .down) { keyPress in
            guard engine.supportsTextSize, keyPress.modifiers.contains(.shift) else { return .ignored }
            engine.increaseTextSize()
            return .handled
        }
        .onKeyPress(characters: .init(charactersIn: "-_"), phases: .down) { keyPress in
            guard engine.supportsTextSize, keyPress.modifiers.contains(.shift) else { return .ignored }
            engine.decreaseTextSize()
            return .handled
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $session.isTableOfContentsVisible) {
            ReaderTableOfContentsView(session: session)
        }
    }
}
