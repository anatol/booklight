import XCTest
@testable import Booklight

final class EPUBCombinerTests: XCTestCase {
    func testSelfClosingNonVoidTagsAreExpanded() {
        let html = #"<div class="a"/><span/><a id="x"/><br/><img src="p.png"/><p>kept</p>"#
        let result = EPUBCombiner.expandSelfClosingTags(in: html)

        XCTAssertEqual(
            result, #"<div class="a"></div><span></span><a id="x"></a><br/><img src="p.png"/><p>kept</p>"#)
    }

    func testExtractBodyReturnsInnerContent() {
        let html = "<html><head><title>t</title></head><BODY class='x'><p>hi</p></BODY></html>"
        XCTAssertEqual(EPUBCombiner.extractBody(from: html).trimmingCharacters(in: .whitespacesAndNewlines), "<p>hi</p>")
        XCTAssertEqual(EPUBCombiner.extractBody(from: "<p>no body</p>"), "<p>no body</p>")
    }

    func testRewriteResourcePathsMakesPathsRootRelative() {
        let html = ##"<img src="../images/a.png"><a href="ch2.xhtml#s">x</a><a href='http://example.com/x'>y</a><a href="#local">z</a>"##
        let result = EPUBCombiner.rewriteResourcePaths(in: html, chapterDir: "OEBPS/text/")

        // `..` is left for the web view to resolve.
        XCTAssertTrue(result.contains(#"src="OEBPS/text/../images/a.png""#), result)
        XCTAssertTrue(result.contains(#"href="OEBPS/text/ch2.xhtml#s""#), result)
        // External links and in-page fragments are left alone.
        XCTAssertTrue(result.contains("http://example.com/x"), result)
        XCTAssertTrue(result.contains(##"href="#local""##), result)
    }

    func testRewriteIsANoOpForChaptersAtTheRoot() {
        let html = #"<img src="a.png">"#
        XCTAssertEqual(EPUBCombiner.rewriteResourcePaths(in: html, chapterDir: ""), html)
    }

    func testStylesheetsAreCollectedOnceInOrder() {
        var paths: [String] = []
        EPUBCombiner.collectStylesheets(
            from: #"<link rel="stylesheet" href="../css/a.css"/><link href='b.css' rel='stylesheet' type='text/css'><link rel="icon" href="i.png">"#,
            chapterDir: "OEBPS/text/", into: &paths)
        EPUBCombiner.collectStylesheets(
            from: #"<link rel="stylesheet" href="../css/a.css"/>"#, chapterDir: "OEBPS/text/", into: &paths)

        XCTAssertEqual(paths, ["OEBPS/text/../css/a.css", "OEBPS/text/b.css"])
    }

    func testImagesGetLazyLoadingUnlessAlreadySet() {
        let result = EPUBCombiner.addLazyLoading(to: #"<img src="a.png"><img src="b.png" loading="eager">"#)

        XCTAssertTrue(result.contains(#"<img loading="lazy" src="a.png">"#) || result.contains("loading=\"lazy\""), result)
        XCTAssertEqual(result.components(separatedBy: "loading=").count - 1, 2, result)
        XCTAssertTrue(result.contains(#"loading="eager""#))
    }

    func testAttributeEscaping() {
        XCTAssertEqual(EPUBCombiner.escapeHTMLAttribute(#"a&b"<c>"#), "a&amp;b&quot;&lt;c&gt;")
    }
}
