import SwiftUI

struct ReaderContainerView: View {
    @ObservedObject var controller: LibraryController
    let bookID: String

    private var book: Book? {
        controller.books.first(where: { $0.id == bookID })
    }

    var body: some View {
        Group {
            if let book, let bookURL = controller.absoluteURL(for: book) {
                switch book.format {
                case .pdf:
                    PDFBookView(book: book, bookURL: bookURL, controller: controller)
                case .epub:
                    EPUBBookView(book: book, bookURL: bookURL, controller: controller)
                }
            } else {
                ContentUnavailableView("Book Missing", systemImage: "exclamationmark.triangle", description: Text("This book is no longer present in the library."))
            }
        }
    }
}
