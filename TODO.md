# TODO

## EPUB

- Explore libxml2 (ships with the iOS/macOS SDKs) as the HTML parser/generator
  for the combined EPUB document. Chapters are XHTML, but `EPUBCombiner`
  concatenates them into an HTML document using regexps: extracting `<body>`,
  rewriting `src`/`href`, adding `loading="lazy"`, and expanding self-closing
  non-void tags like `<div/>` (which the HTML parser treats as unclosed opening
  tags). Parsing each chapter as XML (`xmlReadMemory` with `XML_PARSE_RECOVER`)
  and serializing as HTML would handle all of this structurally, along with
  entities, CDATA and namespaces. Needs a module map or bridging header for C
  interop; keep the current regexp path as a fallback for chapters that fail
  to parse.
