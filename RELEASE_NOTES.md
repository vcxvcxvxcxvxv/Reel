# Reel 1.1.1

## Highlights

- Fixed normal left/right arrow presses being interpreted as short holds, which could skip every other wallpaper.
- Normal taps advance exactly one wallpaper.
- Genuine arrow-key holds still glide continuously and settle to the nearest wallpaper on release.
- Thumbnail preloading is limited to the starting neighbourhood instead of decoding an entire small library at once.
- Late thumbnail results are invalidated when the picker closes so idle memory cannot be repopulated by already-running work.
- Wallpaper transitions respect the display selection in Settings.
- Apple-silicon (arm64) release target.
- Display-only wallpaper labels: number, filename, or hidden.

## Distribution

The GitHub Actions release workflow builds an Apple-silicon DMG from the historical complete source snapshot and applies the 1.1.1 source fixes before compiling.

## Verification note

Swift syntax, release scripts, workflow YAML, SVG rendering inputs, keyboard regression behaviour, cache invalidation guards, and the display-selection patch were checked in the development environment. Final AppKit compilation and interactive UI testing must be performed on macOS on an Apple-silicon Mac.
