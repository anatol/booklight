import SwiftUI

/// Floating search bar for in-document search, styled similarly to macOS Preview.
/// Appears at the top-trailing corner of the reader with a material background.
///
/// Search is triggered only when the user presses Enter (via `onSearchOrNext`).
/// The up/down buttons navigate between existing matches.
/// When opened with pre-filled text from a previous search, the text is selected
/// so typing immediately replaces it, or arrow keys deselect for editing.
struct ReaderSearchBar: View {
    @Binding var searchText: String
    let matchCount: Int
    /// Zero-based index of the currently highlighted match.
    let currentMatchIndex: Int
    /// Whether a search has been performed for the current text (controls status label).
    let hasActiveSearch: Bool
    /// Called when Enter is pressed — performs search if text changed, or navigates to next match.
    let onSearchOrNext: () -> Void
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onDismiss: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.subheadline)

            TextField("Find in document", text: $searchText)
                .textFieldStyle(.plain)
                .focused($isFocused)
                // Enter performs search or navigates to next match.
                // Re-focus after a brief delay because PDFView's go(to:)
                // steals first responder via UIKit.
                .onSubmit {
                    onSearchOrNext()
                    refocusAfterDelay()
                }
                .frame(minWidth: 120, maxWidth: 200)

            // Only show match count after a search has been performed.
            if hasActiveSearch && !searchText.isEmpty {
                Text(matchCount > 0
                    ? "\(currentMatchIndex + 1) of \(matchCount)"
                    : "No matches")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }

            Button {
                onPrevious()
                refocusAfterDelay()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.plain)
            .disabled(matchCount == 0)

            Button {
                onNext()
                refocusAfterDelay()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.plain)
            .disabled(matchCount == 0)

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
            .buttonStyle(.plain)
            // Escape dismisses the search bar. Uses .keyboardShortcut
            // instead of .onKeyPress because on Mac Catalyst the UITextField
            // consumes the Escape key before SwiftUI's .onKeyPress fires.
            // .keyboardShortcut operates at the window/menu level, bypassing focus.
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        .onAppear {
            // Focus the text field on appear. On Mac Catalyst this also
            // selects all text, so the user can immediately start typing
            // to replace the previous search term, or press arrow keys to edit it.
            isFocused = true
        }
    }

    /// Re-focuses the search TextField after a brief delay.
    /// Needed because PDFView's go(to:) steals first responder
    /// through UIKit, which happens asynchronously after our
    /// SwiftUI action handlers return.
    private func refocusAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isFocused = true
        }
    }
}
