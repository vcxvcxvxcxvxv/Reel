import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let library = WallpaperLibrary()
    private lazy var picker = PickerController(library: library)
    private lazy var settings = SettingsWindowController(actions: SettingsActions(
        preview: { [weak self] in self?.openPicker() },
        rebuildThumbnails: { [weak self] in self?.rebuildThumbnails() }
    ))
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let firstRun = UserDefaults.standard.object(forKey: "launchedBefore") == nil
        UserDefaults.standard.set(true, forKey: "launchedBefore")
        Prefs.register()
        setUpStatusItem()
        registerHotKey()
        SpaceSync.shared.start()
        SpaceSync.shared.catchUp()
        let center = NotificationCenter.default
        _ = center.addObserver(forName: .reelHotKeyChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in (NSApp.delegate as? AppDelegate)?.registerHotKey() }
        }
        _ = center.addObserver(forName: .reelHotKeyPaused, object: nil, queue: .main) { _ in
            Task { @MainActor in (NSApp.delegate as? AppDelegate)?.hotKey = nil }
        }
        if firstRun { settings.show() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        picker.toggle()
        return false
    }

    private func registerHotKey() {
        hotKey = nil
        hotKey = HotKey(combo: Config().hotKey) { [weak self] in self?.picker.toggle() }
    }

    private func warmThumbnails() {
        let config = Config()
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let items = library.scan(config.folder)
        let spec = Metrics(config: config, screen: screen).thumbSpec(config: config, backingScale: screen.backingScaleFactor)
        library.warm(items, spec: spec)
    }

    private func rebuildThumbnails() {
        library.clearCache()
        warmThumbnails()
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "photo.stack", accessibilityDescription: "Reel")
            image?.isTemplate = true
            button.image = image
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let open = NSMenuItem(title: "Open Picker", action: #selector(openPicker), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        if hotKey != nil {
            let hint = NSMenuItem(title: Config().hotKey.display, action: nil, keyEquivalent: "")
            hint.isEnabled = false
            hint.indentationLevel = 1
            menu.addItem(hint)
        } else {
            let warn = NSMenuItem(title: "Shortcut unavailable — pick another in Settings", action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)
        }
        menu.addItem(.separator())
        let prefs = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Reel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func openPicker() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            self?.picker.open()
        }
    }

    @objc private func openSettings() { settings.show() }
}
