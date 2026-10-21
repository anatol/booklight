import SwiftUI

/// The reading surface colors, shared by PDF and EPUB and remembered app-wide.
enum ReaderTheme: String, CaseIterable, Identifiable {
    case light
    case sepia
    case dark

    var id: String { rawValue }

    static let storageKey = "Booklight.readerTheme"

    var title: String {
        switch self {
        case .light: "Light"
        case .sepia: "Sepia"
        case .dark: "Dark"
        }
    }

    var systemImage: String {
        switch self {
        case .light: "sun.max"
        case .sepia: "book"
        case .dark: "moon"
        }
    }

    /// Page color; also used behind the document so overscroll matches.
    var background: Color {
        switch self {
        case .light: Color(uiColor: .secondarySystemBackground)
        case .sepia: Color(red: 0.957, green: 0.925, blue: 0.847)
        case .dark: Color(red: 0.11, green: 0.11, blue: 0.118)
        }
    }

    var uiBackground: UIColor { UIColor(background) }

    /// Forces the reader's own controls (and sheets) dark when reading in the dark theme.
    var colorScheme: ColorScheme? { self == .dark ? .dark : nil }
}

/// A picker for the corner controls' menu.
struct ReaderThemePicker: View {
    @AppStorage(ReaderTheme.storageKey) private var theme: ReaderTheme = .light

    var body: some View {
        Picker("Theme", selection: $theme) {
            ForEach(ReaderTheme.allCases) { option in
                Label(option.title, systemImage: option.systemImage).tag(option)
            }
        }
        // Inline so the options show directly in the corner menu instead of
        // behind a "Theme" submenu.
        .pickerStyle(.inline)
    }
}

extension View {
    /// Recolors a rendered page (used for PDF, whose pages are drawn by PDFKit).
    /// Every theme applies the same modifier chain with different values so
    /// switching themes doesn't change the view's identity and reload the document.
    func readerPageTheme(_ theme: ReaderTheme) -> some View {
        let isDark = theme == .dark
        return
            self
            // Sepia: tint the white paper. Light and dark leave it white.
            .colorMultiply(theme == .sepia ? ReaderTheme.sepia.background : .white)
            // Dark: contrast -1 inverts every channel; rotating the hue by 180°
            // then restores the original hues so pictures keep natural colors.
            .contrast(isDark ? -1 : 1)
            .hueRotation(.degrees(isDark ? 180 : 0))
    }
}
