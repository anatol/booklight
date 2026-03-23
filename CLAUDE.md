# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

**iOS (compile-only verification):**
```bash
xcodebuild -project BookReader.xcodeproj -scheme BookReader -destination 'generic/platform=iOS' -derivedDataPath /tmp/BookReaderDerived CODE_SIGNING_ALLOWED=NO build
```

**Mac Catalyst:**
```bash
xcodebuild -project BookReader.xcodeproj -scheme BookReader -destination 'generic/platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/BookReaderDerived-catalyst CODE_SIGNING_ALLOWED=NO build
```

Use `-derivedDataPath /tmp/...` to avoid permissions issues. `CODE_SIGNING_ALLOWED=NO` for CI-like builds.

## Tests

No automated tests exist yet. Validation is compile-time only via `xcodebuild`. Manual test checklist is in `doc/BUILD_AND_TEST.md`.

## Architecture

Single-target SwiftUI app (iPadOS/macOS via Mac Catalyst). ~2,200 lines of Swift.

**Key components:**
- `LibraryController` — core library management: folder scanning, book discovery, progress tracking, and state persistence. Largest file (~650 lines).
- `Models` — data types: `Book`, `LibraryBookRecord`, `BookProgressState`, `LibraryDatabase`, `BookFormat` (PDF/EPUB)
- `ContentView` — main library UI with search and Active Books / All Books sections
- `PDFReaderView` — PDF reading via PDFKit
- `EPUBReaderView` + `EPUBSupport` — EPUB reading via built-in ZIP extraction + WKWebView

**Data persistence:** JSON files stored in `.book-app/` inside the user's library folder (not app sandbox). This design enables cross-device sync via Syncthing.

**Progress merge policy:** When two devices have conflicting progress for the same book, the furthest reading position wins. `lastOpenedAt` keeps the latest timestamp.

**Book identity:** Based on filename-derived ID. File renames are detected and handled (see recent commit history).
