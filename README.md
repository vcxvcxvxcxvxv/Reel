# Reel

<p align="center">
  <img src="Resources/AppIcon.png" width="128" alt="Reel app icon">
</p>

<h1 align="center">Reel</h1>

<p align="center">
  A fast, fluid macOS wallpaper picker built around a cinematic carousel.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-111111?style=flat-square">
  <img src="https://img.shields.io/badge/Apple%20Silicon-arm64-111111?style=flat-square">
  <img src="https://img.shields.io/badge/Swift-5-111111?style=flat-square">
  <img src="https://img.shields.io/badge/release-v1.1.0-111111?style=flat-square">
</p>

## What is Reel?

Reel is a lightweight menu-bar utility for browsing and applying wallpapers with a smooth, responsive carousel. It is designed to feel immediate during trackpad swipes and repeated arrow-key navigation while staying quiet when the picker is closed.

### Highlights

- Fluid trackpad momentum and continuous keyboard navigation
- Display-link animation that sleeps when the picker is settled
- Bounded thumbnail cache with on-demand decoding
- Immediate thumbnail-work cancellation and memory purge when the picker closes
- Apple-silicon arm64 release builds
- Display-only labels: `01`, source filename, or hidden
- macOS-friendly low-background-work design

## UI preview

This repository includes a visual design preview in [docs/preview.svg](docs/preview.svg). It is a design preview rather than a captured runtime screenshot.

## Install

Download the latest **Reel.dmg** from **Releases**, open it, and drag **Reel.app** into **Applications**.

The release build targets Apple-silicon Macs (arm64).

## Build locally

On an Apple-silicon Mac with Xcode Command Line Tools installed:

```sh
./build.sh --dmg
```

The prepared release is **v1.1.0**.

## Source

The complete release source is provided as [Reel-1.1.0-source.tar.gz](Reel-1.1.0-source.tar.gz). The app icon is kept separately in `Resources/AppIcon.png` so the build can reproduce the branded app bundle.

## Release automation

GitHub Actions contains the arm64 macOS build pipeline. Versioned tags use the form `vMAJOR.MINOR.PATCH`.

## License

Private project.
