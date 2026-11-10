# Paperreads

A minimalist native macOS reader for research papers. Papers open as clean text with real
LaTeX math by default (⌘⇧P switches to the original PDF). You can highlight, take notes, and ask
Claude questions grounded in the paper and its cited works.

## Run
    xcodegen generate
    xcodebuild -project Paperreads.xcodeproj -scheme Paperreads -derivedDataPath build CODE_SIGN_IDENTITY=- build
    open build/Build/Products/Debug/Paperreads.app

Add your Anthropic API key in Settings (⌘,), or set `ANTHROPIC_API_KEY`.

## Use
⌘L paste an arXiv id/URL or DOI · ⌘O or drag in a PDF · ⌘J Ask/Notes panel ·
select text → Highlight / Explain / Ask · ⌘E explain selection · ⌘⇧H highlight.

Design and module contract: `docs/ARCHITECTURE.md`.

## Secrets
The API key is stored outside the repo (`~/Library/Application Support/Paperreads/config.json`, mode 0600) or read from `ANTHROPIC_API_KEY`. After cloning, run `git config core.hooksPath .githooks` to enable the pre-commit secret check.
