# Book Reader

`Book Reader` is a lightweight SwiftUI reading application for Apple platforms. It is designed around a user-selected folder that acts as the entire library, with book progress stored alongside the books so Syncthing can move state across devices.

## What It Does

- **Active Book Tracking:** Reading progress and actively read books are copied to a single tracking directory (e.g. synced via Syncthing).
- **Multiple Local Libraries:** Add many read-only "Local Library" folders that the app scans without modifying.
- **Robust Book Deduplication:** Books are identified and deduplicated using content hashes (SHA-256), combining the tracking directory and local libraries.
- **Efficient Caching:** Extracted artwork and computed file hashes are aggressively cached on disk (`~/Library/Caches`) to keep library scans instant.
- **First-Class iPad/Mac UI:** Clean sidebar layouts, keyboard navigation, dark mode support.
- **Privacy-First:** No analytics, no cloud accounts, no network calls. Works 100% offline.
- Stores library metadata in `.book-app/` inside the selected folder.
- Detects added and removed books during periodic rescans.
- Merges progress by keeping the furthest reading position.
- Supports fuzzy title search on the library screen.

## Library Layout

The app expects a flat library directory:

```text
<Library>/
  Book 1.pdf
  Book 2.epub
  .book-app/
    library.json
    books/
      <book-id>.json
```

- `library.json` tracks the discovered books in the folder.
- `.book-app/books/*.json` stores per-book reading state.
- These files are intended to sync via Syncthing with the rest of the library.

## Project Layout

```text
BookReader.xcodeproj
BookReader/
  BookReaderApp.swift
  ContentView.swift
  LibraryController.swift
  Models.swift
  ReaderContainerView.swift
  PDFReaderView.swift
  EPUBReaderView.swift
  EPUBSupport.swift
doc/
  BUILD_AND_TEST.md
```

## Core Design Notes

- The app uses one SwiftUI target.
- The iPhone/iPad build is primary; macOS is handled through Mac Catalyst.
- `PDF` reading uses `PDFKit`.
- `EPUB` reading uses a small built-in ZIP extractor plus `WKWebView`.
- Sync is file-based JSON, not SQLite, to keep the data easy for Syncthing to replicate.

## Build And Test

See [doc/BUILD_AND_TEST.md](/Users/anatol/work/bachu/book-reader-app/doc/BUILD_AND_TEST.md) for setup, build commands, manual test steps, and troubleshooting.
