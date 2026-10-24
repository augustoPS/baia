# App icons

Run `swift Icon/make-icon.swift` from the repository root to regenerate both ICNS files with native AppKit and `iconutil`.

Both apps use the angular **b** approved on 2026-10-20. The tall divider and short, low chevron form a terminal-derived letter. The owner supplied the name's origin: Kimbundu *ribaia*, a compartment made by dividers. The divider and command notation form the letter together.

The Obsidian treatments approved on 2026-10-24 distinguish the installed apps:

- `baia.icns` (Release): lavender `#C2A0F0` on ink `#0F0D15`. A broad lavender light at 10% maximum opacity lifts the tile's upper left. An ivory highlight at 20% maximum opacity fades down the mark, clipped to its original silhouette. There is no bolt, badge, shadow, or change to the geometry.
- `baia-dev.icns` (Debug): ink `#0F0D15` on lavender `#C2A0F0`, with flat fills.

The 16px and 32px representations keep the separately approved optical geometry and flat fills in both apps. Larger Release slices carry the subtle lighting. The 1024px master has an 824px tile inset by 100px, with a 181px corner radius. Master mark coordinates are transformed into that tile. All ten standard macOS iconset slices are rendered at their actual pixel size.

`Info.plist` selects the matching file through `CFBundleIconFile = $(PRODUCT_NAME)`. Both icon files ship in both bundles.
