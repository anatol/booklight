import QuickLookThumbnailing
import SwiftUI
import WebKit

struct BooklightIconView: View {
    var size: CGFloat

    var body: some View {
        SVGResourceView(resourceName: "booklight-icon", fileExtension: "svg")
            .frame(width: size, height: size)
    }
}

struct BookThumbnailView: View {
    @Environment(\.displayScale) private var displayScale

    let bookID: String
    let fileURL: URL?
    let format: BookFormat

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(uiColor: .secondarySystemBackground), Color(uiColor: .tertiarySystemBackground)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14))
        }
        .task(id: fileURL?.path()) {
            await loadThumbnail()
        }
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: format.symbolName)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.secondary)

            Text(format == .pdf ? "PDF" : "EPUB")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private func loadThumbnail() async {
        guard let fileURL else {
            await MainActor.run {
                image = nil
            }
            return
        }

        let nsCacheKey = bookID as NSString

        if let cached = await MainActor.run(body: {
            BookThumbnailCache.cache.object(forKey: nsCacheKey)
        }) {
            await MainActor.run {
                image = cached
            }
            return
        }

        let urls = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        let thumbnailsDir = urls[0].appending(path: "com.anatol.bookreader/thumbnails", directoryHint: .isDirectory)
        let diskURL = thumbnailsDir.appending(path: "\(bookID).png")

        if let data = try? Data(contentsOf: diskURL), let uiImage = UIImage(data: data) {
            await MainActor.run {
                BookThumbnailCache.cache.setObject(uiImage, forKey: nsCacheKey)
                image = uiImage
            }
            return
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: fileURL,
            size: CGSize(width: 520, height: 760),
            scale: displayScale,
            representationTypes: .all
        )
        request.iconMode = false
        request.minimumDimension = 260

        do {
            let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            let generatedImage = representation.uiImage

            if let pngData = generatedImage.pngData() {
                try? FileManager.default.createDirectory(at: thumbnailsDir, withIntermediateDirectories: true)
                try? pngData.write(to: diskURL, options: .atomic)
            }

            await MainActor.run {
                BookThumbnailCache.cache.setObject(generatedImage, forKey: nsCacheKey)
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                image = generatedImage
            }
        } catch {
            guard !Task.isCancelled else { return }
            await MainActor.run {
                image = nil
            }
        }
    }
}

@MainActor
private enum BookThumbnailCache {
    static let cache = NSCache<NSString, UIImage>()
}

private struct SVGResourceView: UIViewRepresentable {
    let resourceName: String
    let fileExtension: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.backgroundColor = .clear
        webView.isUserInteractionEnabled = false
        if #available(iOS 15.0, *) {
            webView.underPageBackgroundColor = .clear
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard let resourceURL = Bundle.main.url(forResource: resourceName, withExtension: fileExtension) else {
            return
        }

        guard context.coordinator.loadedURL != resourceURL else {
            return
        }

        context.coordinator.loadedURL = resourceURL

        guard let svg = try? String(contentsOf: resourceURL, encoding: .utf8) else {
            return
        }

        let html = """
            <!DOCTYPE html>
            <html>
            <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0">
            <style>
            html, body {
                margin: 0;
                padding: 0;
                width: 100%;
                height: 100%;
                overflow: hidden;
                background: transparent;
            }
            body {
                display: flex;
                align-items: center;
                justify-content: center;
            }
            svg {
                width: 100%;
                height: 100%;
                display: block;
            }
            </style>
            </head>
            <body>
            \(svg)
            </body>
            </html>
            """

        webView.loadHTMLString(html, baseURL: resourceURL.deletingLastPathComponent())
    }

    final class Coordinator {
        var loadedURL: URL?
    }
}
