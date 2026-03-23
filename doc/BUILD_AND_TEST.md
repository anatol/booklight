# Build And Test Guide

This document explains how to build, run, and manually verify the `Book Reader` app.

## Platforms

The app is currently configured as:

- iPhone and iPad app target
- macOS support through Mac Catalyst

The implementation intentionally targets current Apple platform releases rather than older OS versions.

## Prerequisites

You need:

- Xcode 26 or newer
- Apple platform SDKs installed with Xcode
- A machine that can build iOS apps locally

Optional but useful:

- A physical iPhone or iPad for testing folder access
- A Syncthing-shared folder for multi-device verification

## Project Files

Important files:

- [BookReader.xcodeproj](/Users/anatol/work/bachu/book-reader-app/BookReader.xcodeproj)
- [BookReader/ContentView.swift](/Users/anatol/work/bachu/book-reader-app/BookReader/ContentView.swift)
- [BookReader/LibraryController.swift](/Users/anatol/work/bachu/book-reader-app/BookReader/LibraryController.swift)
- [BookReader/PDFReaderView.swift](/Users/anatol/work/bachu/book-reader-app/BookReader/PDFReaderView.swift)
- [BookReader/EPUBReaderView.swift](/Users/anatol/work/bachu/book-reader-app/BookReader/EPUBReaderView.swift)
- [BookReader/EPUBSupport.swift](/Users/anatol/work/bachu/book-reader-app/BookReader/EPUBSupport.swift)

## Open In Xcode

1. Open [BookReader.xcodeproj](/Users/anatol/work/bachu/book-reader-app/BookReader.xcodeproj).
2. Select the `BookReader` scheme.
3. Choose a run destination:
   - an iPhone simulator
   - an iPad simulator
   - a physical iPhone or iPad
   - `My Mac (Designed for iPad)` or Mac Catalyst when available
4. Build with `Product > Build`.
5. Run with `Product > Run`.

## Command-Line Build

### iOS Generic Build

This command was used successfully in this repository:

```bash
SWIFT_MODULECACHE_PATH=/tmp/swift-module-cache \
CLANG_MODULE_CACHE_PATH=/tmp/clang-module-cache \
xcodebuild \
  -project BookReader.xcodeproj \
  -scheme BookReader \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/BookReaderDerived \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Notes:

- `-derivedDataPath /tmp/BookReaderDerived` avoids permissions problems in restricted environments.
- `CODE_SIGNING_ALLOWED=NO` is useful for CI-like local verification when you only need to compile.

### Suggested Mac Catalyst Build

If you want to verify the macOS path explicitly, use:

```bash
SWIFT_MODULECACHE_PATH=/tmp/swift-module-cache \
CLANG_MODULE_CACHE_PATH=/tmp/clang-module-cache \
xcodebuild \
  -project BookReader.xcodeproj \
  -scheme BookReader \
  -destination 'generic/platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath /tmp/BookReaderDerived-catalyst \
  CODE_SIGNING_ALLOWED=NO \
  build
```

If Xcode rejects the exact destination string on your machine, select the Catalyst destination in Xcode once and copy the resolved destination from Xcode’s build logs.

## Current Test Status

There are no automated unit tests or UI tests in the repository yet.

At the moment, validation is:

- compile-time verification with `xcodebuild`
- manual smoke testing in Xcode

If you want stronger regression protection, the next practical step is adding:

- unit tests for progress merge logic in `LibraryController`
- unit tests for EPUB package parsing in `EPUBSupport`
- UI smoke tests for library selection, search, and opening a sample book

## Manual Test Setup

Prepare a test folder like this:

```text
TestLibrary/
  Sample PDF.pdf
  Sample EPUB.epub
```

The app will create this on first use:

```text
TestLibrary/
  .book-app/
    library.json
    books/
```

## Manual Test Checklist

### 1. First Launch

1. Launch the app.
2. Confirm the empty state asks for a library folder.
3. Choose a test folder containing at least one PDF and one EPUB.
4. Confirm the app shows discovered books.

Expected result:

- The selected folder becomes the active library.
- `.book-app/library.json` is created.

### 2. Library Scan

1. Add a new `PDF` or `EPUB` file to the selected library folder.
2. Wait a few seconds or tap `Refresh`.
3. Remove a file from the library folder.
4. Wait again or tap `Refresh`.

Expected result:

- New books appear in the library.
- Deleted books disappear.
- `library.json` reflects the current folder contents.

### 3. PDF Reading Progress

1. Open a PDF.
2. Move to a later page.
3. Return to the library.
4. Reopen the same PDF.

Expected result:

- The book appears in `Active Books`.
- Progress is shown in the row.
- Reopening the PDF restores the saved page.

### 4. EPUB Reading Progress

1. Open an EPUB.
2. Scroll in the current chapter.
3. Use `Next` to move to a later chapter.
4. Return to the library.
5. Reopen the EPUB.

Expected result:

- The app restores the saved chapter and approximate scroll position.
- Progress is shown in the row.

### 5. Active Books Ordering

1. Open several books and advance each one slightly.
2. Return to the home screen after each change.

Expected result:

- Unfinished books appear in `Active Books`.
- They are ordered by most recently opened.
- Finished or unread books remain in the lower section.

### 6. Fuzzy Search

1. Type a partial title in the search field.
2. Try an inexact but similar character sequence.
3. Clear the search field.

Expected result:

- Matching titles remain visible.
- Non-matching titles are filtered out.
- Clearing search restores the full list.

Examples to try:

- Search `har pot` for `Harry Potter`
- Search `hobt` for `The Hobbit`
- Search part of a subtitle or filename stem

### 7. Cross-Device Sync With Syncthing

1. Put the same library folder under Syncthing on two devices.
2. Open the same book on device A and advance further.
3. Wait for Syncthing to sync `.book-app/`.
4. Open or refresh the library on device B.

Expected result:

- The synced progress appears on device B.
- If both devices changed progress, the furthest progress wins.

## How Progress Merge Works

The merge policy is intentionally simple:

- progress is stored per book in JSON
- when two states conflict, the app keeps the furthest progress
- `lastOpenedAt` is preserved as the latest open timestamp

Practical effect:

- If one device reads further ahead, that position wins.
- The app does not currently try to preserve “went backward on purpose” semantics.

## Known Limitations

- No automated tests yet
- EPUB rendering is intentionally minimal and uses local extraction plus `WKWebView`
- Semantic search is not implemented; search is fuzzy title matching only
- The app currently assumes a flat library directory
- Book identity is based on filename-derived ID, so renaming a book file will currently look like a new book

## Troubleshooting

### Build Fails Because of DerivedData Permissions

Use a writable derived data path:

```bash
xcodebuild ... -derivedDataPath /tmp/BookReaderDerived
```

### Build Fails Because of Code Signing

For compile-only verification, disable signing:

```bash
xcodebuild ... CODE_SIGNING_ALLOWED=NO build
```

### Library Does Not Update

Try:

- wait a few seconds for the periodic rescan
- tap the `Refresh` button
- confirm the new files are directly in the selected folder, not nested in subfolders

### EPUB Does Not Open Correctly

Possible reasons:

- malformed EPUB archive
- unsupported compression edge case
- unusual EPUB structure not covered by the current minimal parser

Check the console while running from Xcode for parser or extraction errors.

## Suggested Next Improvements

- add unit tests for scan and merge behavior
- add sample fixture books for repeatable testing
- add a dedicated Mac Catalyst build verification step
- add UI tests for selecting a library and opening books
- improve book identity to survive file renames
