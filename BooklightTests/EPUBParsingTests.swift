import XCTest
@testable import Booklight

final class EPUBParsingTests: XCTestCase {
    private let container = """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """

    private func chapter(_ title: String, extra: String = "") -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>\(title)</title>
        <link rel="stylesheet" href="../css/book.css"/></head>
        <body><h1 id="top">\(title)</h1><p>Text of \(title).</p>\(extra)</body></html>
        """
    }

    /// Extracts a fixture into a fresh folder and returns it.
    private func extractedFixture(_ build: (inout ZipBuilder) -> Void) throws -> URL {
        var zip = ZipBuilder()
        zip.add("mimetype", "application/epub+zip")
        zip.add("META-INF/container.xml", container)
        build(&zip)
        let work = try TestSupport.makeTempDirectory()
        let zipURL = work.appending(path: "book.epub")
        try zip.build().write(to: zipURL)
        let root = work.appending(path: "x", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try EPUBArchiveExtractor.extractArchive(at: zipURL, to: root)
        return root
    }

    func testEPUB3WithNavDocument() throws {
        let root = try extractedFixture { zip in
            zip.add(
                "OEBPS/content.opf",
                """
                <?xml version="1.0"?>
                <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
                  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>  Fixture Book </dc:title></metadata>
                  <manifest>
                    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                    <item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
                    <item id="c2" href="text/ch%202.xhtml" media-type="application/xhtml+xml"/>
                    <item id="css" href="css/book.css" media-type="text/css"/>
                  </manifest>
                  <spine><itemref idref="c1"/><itemref idref="c2"/></spine>
                </package>
                """)
            zip.add(
                "OEBPS/nav.xhtml",
                """
                <?xml version="1.0" encoding="utf-8"?>
                <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body>
                <nav epub:type="toc"><ol>
                  <li><a href="text/ch1.xhtml">One</a>
                    <ol><li><a href="text/ch1.xhtml#top">One point one</a></li></ol></li>
                  <li><a href="text/ch%202.xhtml">  Two
                     spaced </a></li>
                  <li><a href="missing.xhtml">Not in the spine</a></li>
                </ol></nav>
                <nav epub:type="landmarks"><ol><li><a href="text/ch2.xhtml">Landmark</a></li></ol></nav>
                </body></html>
                """)
            zip.add("OEBPS/text/ch1.xhtml", self.chapter("Chapter One"), deflate: true)
            zip.add("OEBPS/text/ch 2.xhtml", self.chapter("Chapter Two"))
            zip.add("OEBPS/css/book.css", "p { color: red; }")
        }

        let document = try EPUBPreparation.parseExtractedBook(at: root, fallbackTitle: "Fallback")

        XCTAssertEqual(document.title, "Fixture Book")
        XCTAssertEqual(document.spine.map(\.href), ["text/ch1.xhtml", "text/ch 2.xhtml"])
        XCTAssertEqual(document.spine.map(\.index), [0, 1])
        XCTAssertEqual(
            document.tableOfContents,
            [
                .init(title: "One", level: 0, spineIndex: 0, fragment: nil),
                .init(title: "One point one", level: 1, spineIndex: 0, fragment: "top"),
                .init(title: "Two spaced", level: 0, spineIndex: 1, fragment: nil),
            ])

        let combined = try String(contentsOf: document.combinedHTMLURL, encoding: .utf8)
        XCTAssertTrue(combined.contains("Text of Chapter One."))
        XCTAssertTrue(combined.contains("Text of Chapter Two."))
        XCTAssertTrue(combined.contains("data-chapter-path=\"OEBPS/text/ch 2.xhtml\""))
        XCTAssertTrue(combined.contains("OEBPS/text/../css/book.css"))
    }

    func testEPUB2WithNCX() throws {
        let root = try extractedFixture { zip in
            zip.add(
                "OEBPS/content.opf",
                """
                <?xml version="1.0"?>
                <package xmlns="http://www.idpf.org/2007/opf" version="2.0">
                  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>NCX Book</dc:title></metadata>
                  <manifest>
                    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
                    <item id="a" href="a.html" media-type="text/html"/>
                    <item id="b" href="b.html" media-type="application/xhtml+xml"/>
                  </manifest>
                  <spine toc="ncx"><itemref idref="a"/><itemref idref="b"/></spine>
                </package>
                """)
            zip.add(
                "OEBPS/toc.ncx",
                """
                <?xml version="1.0"?>
                <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
                  <docTitle><text>Ignored title</text></docTitle>
                  <navMap>
                    <navPoint id="p1"><navLabel><text>Part A</text></navLabel><content src="a.html"/>
                      <navPoint id="p2"><navLabel><text>Part A.1</text></navLabel><content src="a.html#s1"/></navPoint>
                    </navPoint>
                    <navPoint id="p3"><navLabel><text>Part B</text></navLabel><content src="b.html"/></navPoint>
                  </navMap>
                  <pageList><navTarget id="t"><navLabel><text>Page 1</text></navLabel><content src="a.html#pg1"/></navTarget></pageList>
                </ncx>
                """)
            zip.add("OEBPS/a.html", self.chapter("A"))
            zip.add("OEBPS/b.html", self.chapter("B"))
        }

        let document = try EPUBPreparation.parseExtractedBook(at: root, fallbackTitle: "Fallback")

        XCTAssertEqual(document.title, "NCX Book")
        XCTAssertEqual(document.spine.count, 2)
        XCTAssertEqual(
            document.tableOfContents,
            [
                .init(title: "Part A", level: 0, spineIndex: 0, fragment: nil),
                .init(title: "Part A.1", level: 1, spineIndex: 0, fragment: "s1"),
                .init(title: "Part B", level: 0, spineIndex: 1, fragment: nil),
            ])
    }

    func testMissingTitleFallsBackAndMissingTOCIsEmpty() throws {
        let root = try extractedFixture { zip in
            zip.add(
                "OEBPS/content.opf",
                """
                <?xml version="1.0"?>
                <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
                  <metadata/>
                  <manifest><item id="a" href="a.xhtml" media-type="application/xhtml+xml"/></manifest>
                  <spine><itemref idref="a"/></spine>
                </package>
                """)
            zip.add("OEBPS/a.xhtml", self.chapter("A"))
        }

        let document = try EPUBPreparation.parseExtractedBook(at: root, fallbackTitle: "Fallback")

        XCTAssertEqual(document.title, "Fallback")
        XCTAssertTrue(document.tableOfContents.isEmpty)
    }

    func testBookWithoutReadableSpineThrows() throws {
        let root = try extractedFixture { zip in
            zip.add(
                "OEBPS/content.opf",
                """
                <?xml version="1.0"?>
                <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
                  <metadata/><manifest><item id="i" href="i.png" media-type="image/png"/></manifest>
                  <spine><itemref idref="i"/></spine>
                </package>
                """)
        }

        XCTAssertThrowsError(try EPUBPreparation.parseExtractedBook(at: root, fallbackTitle: "x"))
    }

    func testMissingContainerThrows() throws {
        let root = try TestSupport.makeTempDirectory()
        XCTAssertThrowsError(try EPUBPreparation.parseExtractedBook(at: root, fallbackTitle: "x"))
    }
}
