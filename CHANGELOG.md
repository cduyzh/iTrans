# Changelog

Release history for iTrans (MacTranslate AI). Downloadable assets for each release are available on the [GitHub Releases](https://github.com/cduyzh/iTrans/releases) page.

## 1.0.0 — 2026-11-06: Initial Official Release

- **Native Architecture & High Performance**: Ultra-fast native macOS menu bar translation utility written in pure Swift/AppKit/SwiftUI with sub-200ms cold start and minimal memory footprint (~25MB).
- **Dual Translation Engines**: Deep integration of Google Web RPC (zero-configuration, fast direct translation) and DeepSeek reasoning models (`deepseek-chat` and `deepseek-reasoner`).
- **Deep Linguistic Disambiguation & Slang Support**: Leverages DeepSeek AI to accurately decipher informal acronyms, internet slang (e.g. "wtf"), and contextual idioms with comprehensive explanations of tone, usage, and alternative terms.
- **Global Instant Shortcuts**: Double-tap `Command+C+C` or press `Option+Z` anywhere to translate selected text instantly across Safari, Xcode, PDFs, and developer tools.
- **Plateau & Liquid Glass Status Panel**: Compact macOS menu bar HUD with quick engine cycling (`Option+E`), active model status indicators, and zero clumsy system popups.
- **Native Secondary Action Drawer**: Fluid SwiftUI action drawer supporting interactive login item toggle, dynamic cache cleanup, hotkey reload, and application restart.
- **Personal Translation Memory & Glossary**: Local-first terminology repository preserving custom corrections and technical domain dictionaries.
- **Local Agent Gateway & CLI**: Loopback API (`127.0.0.1:11899`) and CLI utility for seamless integration with terminal scripts, Raycast, and automated AI agents.
- **Privacy by Design**: Direct communication with official provider endpoints, local 0600 file permission credential storage, and zero third-party telemetry.
