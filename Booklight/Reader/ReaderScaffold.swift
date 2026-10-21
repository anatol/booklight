import SwiftUI

/// Shared chrome around a format-specific reader: the floating find bar,
/// keyboard shortcuts, and Space / Shift+Space paging.
struct ReaderScaffold<Engine: ReaderEngine, Content: View>: View {
    let session: ReaderSession<Engine>
    @ViewBuilder let content: Content

    var body: some View {
        let engine = session.engine
        ZStack(alignment: .topTrailing) {
            content

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
    }
}
