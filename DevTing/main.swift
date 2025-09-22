//
//  main.swift
//  MenuBarUSB
//

import Cocoa
import IOKit
import IOKit.usb
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Sound choice

/// Represents how a sound was chosen.
enum SoundChoice: Codable, Equatable {
    case builtin              // App's bundled default sounds (connect.aiff, disconnect.aiff)
    case system(name: String) // A sound found in the system sound directories
    case userFile(path: String) // A custom file chosen by the user

    func description() -> String {
        switch self {
        case .builtin: return "Default – BuiltIn"
        case .system(let name): return name
        case .userFile(let path): return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        }
    }
}

// MARK: - Settings

/// Stores user preferences for sound playback.
struct SoundSettings: Codable {
    var enabled: Bool = true
    var connectEnabled: Bool = true
    var disconnectEnabled: Bool = true
    var connectSound: SoundChoice = .builtin
    var disconnectSound: SoundChoice = .builtin
}

enum SoundType { case connect, disconnect }

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var notifyPort: IONotificationPortRef?
    var addedIterator: io_iterator_t = 0
    var removedIterator: io_iterator_t = 0
    var player: AVAudioPlayer?
    var settings = SoundSettings()

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadSettings()

        // Add a menu bar icon - TODO: Fix this to load proper icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: "USB")
            button.image?.isTemplate = true
        }

        buildMenu()
        setupUSBNotifications()
    }

    @objc func quit() { NSApp.terminate(nil) }

    // MARK: - Playback

    /// Plays the given sound choice if global and per-event settings are enabled.
    func playSoundIfEnabled(_ choice: SoundChoice, type: SoundType, enabled: Bool) {
        guard settings.enabled, enabled else { return }

        switch choice {
        case .builtin:
            // Try to load app-bundled sound (connect.aiff / disconnect.aiff)
            let fileName = (type == .connect ? "connect" : "disconnect")
            if let url = Bundle.main.url(forResource: fileName, withExtension: "aiff") {
                player = try? AVAudioPlayer(contentsOf: url)
                player?.play()
            }

        case .system(let name):
            // Plays a system-provided NSSound
            NSSound(named: NSSound.Name(name))?.play()

        case .userFile(let path):
            // Play user-selected file, or fall back to builtin if missing
            if FileManager.default.fileExists(atPath: path) {
                let url = URL(fileURLWithPath: path)
                player = try? AVAudioPlayer(contentsOf: url)
                player?.play()
            } else {
                if type == .connect { settings.connectSound = .builtin }
                else { settings.disconnectSound = .builtin }
                saveSettings()
                buildMenu()
            }
        }
    }

    // MARK: - Persistence

    /// Save settings to UserDefaults.
    func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "SoundSettings")
        }
    }

    /// Load settings from UserDefaults.
    func loadSettings() {
        if let data = UserDefaults.standard.data(forKey: "SoundSettings"),
           let decoded = try? JSONDecoder().decode(SoundSettings.self, from: data) {
            settings = decoded
        }
    }

    // MARK: - Menu

    /// Build the menu bar structure, including submenus for connect/disconnect sounds.
    func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let globalToggle = NSMenuItem(title: "Enable Sounds", action: #selector(toggleGlobal), keyEquivalent: "")
        globalToggle.state = settings.enabled ? .on : .off
        menu.addItem(globalToggle)

        menu.addItem(.separator())

        // Connect submenu
        let connectMenu = NSMenu()
        connectMenu.delegate = self
        let connectToggle = NSMenuItem(title: "Enable Connect Sound", action: #selector(toggleConnect), keyEquivalent: "")
        connectToggle.state = settings.connectEnabled ? .on : .off
        connectMenu.addItem(connectToggle)
        connectMenu.addItem(.separator())
        addSoundChoices(to: connectMenu, for: .connect)
        let connectItem = NSMenuItem(title: "USB Connect Sound", action: nil, keyEquivalent: "")
        connectItem.submenu = connectMenu
        connectItem.tag = 1   // tag 1 = connect
        menu.addItem(connectItem)

        // Disconnect submenu
        let disconnectMenu = NSMenu()
        disconnectMenu.delegate = self
        let disconnectToggle = NSMenuItem(title: "Enable Disconnect Sound", action: #selector(toggleDisconnect), keyEquivalent: "")
        disconnectToggle.state = settings.disconnectEnabled ? .on : .off
        disconnectMenu.addItem(disconnectToggle)
        disconnectMenu.addItem(.separator())
        addSoundChoices(to: disconnectMenu, for: .disconnect)
        let disconnectItem = NSMenuItem(title: "USB Disconnect Sound", action: nil, keyEquivalent: "")
        disconnectItem.submenu = disconnectMenu
        disconnectItem.tag = 2   // tag 2 = disconnect
        menu.addItem(disconnectItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu
        updateMenuChecks()
    }

    /// Scan common system directories for available sound names.
    func systemSoundNames() -> [String] {
        let fm = FileManager.default
        let searchPaths = [
            "/System/Library/Sounds",
            "/Library/Sounds",
            "\(NSHomeDirectory())/Library/Sounds"
        ]
        var results: [String] = []
        for path in searchPaths {
            if let files = try? fm.contentsOfDirectory(atPath: path) {
                for f in files {
                    let base = (f as NSString).deletingPathExtension
                    results.append(base)
                }
            }
        }
        return Array(Set(results)).sorted()
    }

    /// Add sound choice items to a submenu.
    func addSoundChoices(to menu: NSMenu, for type: SoundType) {
        let defaultItem = NSMenuItem(title: "Default – BuiltIn",
                                     action: (type == .connect ? #selector(selectConnectSound(_:)) : #selector(selectDisconnectSound(_:))),
                                     keyEquivalent: "")
        defaultItem.representedObject = SoundChoice.builtin
        menu.addItem(defaultItem)

        // Add system sounds dynamically from filesystem
        for sysName in systemSoundNames() {
            let item = NSMenuItem(title: sysName,
                                  action: (type == .connect ? #selector(selectConnectSound(_:)) : #selector(selectDisconnectSound(_:))),
                                  keyEquivalent: "")
            item.representedObject = SoundChoice.system(name: sysName)
            menu.addItem(item)
        }

        // Add user custom sound entry if it exists
        let customSound: SoundChoice = (type == .connect ? settings.connectSound : settings.disconnectSound)
        if case let .userFile(path) = customSound {
            if FileManager.default.fileExists(atPath: path) {
                let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                let item = NSMenuItem(title: name,
                                      action: (type == .connect ? #selector(selectConnectSound(_:)) : #selector(selectDisconnectSound(_:))),
                                      keyEquivalent: "")
                item.representedObject = SoundChoice.userFile(path: path)
                menu.addItem(.separator())
                menu.addItem(item)
            } else {
                // File missing → revert to builtin
                if type == .connect { settings.connectSound = .builtin }
                else { settings.disconnectSound = .builtin }
                saveSettings()
            }
        }

        menu.addItem(.separator())
        let customItem = NSMenuItem(title: "Choose Custom…",
                                    action: (type == .connect ? #selector(chooseConnectCustomSound) : #selector(chooseDisconnectCustomSound)),
                                    keyEquivalent: "")
        menu.addItem(customItem)
    }

    @objc func selectConnectSound(_ sender: NSMenuItem) {
        if let choice = sender.representedObject as? SoundChoice {
            settings.connectSound = choice
            saveSettings()
            updateMenuChecks()
        }
    }

    @objc func selectDisconnectSound(_ sender: NSMenuItem) {
        if let choice = sender.representedObject as? SoundChoice {
            settings.disconnectSound = choice
            saveSettings()
            updateMenuChecks()
        }
    }

    @objc func chooseConnectCustomSound() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        if panel.runModal() == .OK, let url = panel.url {
            settings.connectSound = .userFile(path: url.path)
            saveSettings()
            buildMenu()
        }
    }

    @objc func chooseDisconnectCustomSound() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        if panel.runModal() == .OK, let url = panel.url {
            settings.disconnectSound = .userFile(path: url.path)
            saveSettings()
            buildMenu()
        }
    }

    // MARK: - Toggles

    @objc func toggleGlobal(_ sender: NSMenuItem) {
        settings.enabled.toggle()
        saveSettings()
        updateMenuChecks()
    }

    @objc func toggleConnect(_ sender: NSMenuItem) {
        settings.connectEnabled.toggle()
        saveSettings()
        updateMenuChecks()
    }

    @objc func toggleDisconnect(_ sender: NSMenuItem) {
        settings.disconnectEnabled.toggle()
        saveSettings()
        updateMenuChecks()
    }

    /// Ensure menu checkmarks reflect current settings.
    func updateMenuChecks() {
        guard let items = statusItem.menu?.items else { return }
        for parent in items {
            if parent.title == "Enable Sounds" {
                parent.state = settings.enabled ? .on : .off
            }
            if let submenu = parent.submenu {
                for item in submenu.items {
                    if let choice = item.representedObject as? SoundChoice {
                        if parent.title.contains("Connect") {
                            item.state = (choice == settings.connectSound) ? .on : .off
                        } else if parent.title.contains("Disconnect") {
                            item.state = (choice == settings.disconnectSound) ? .on : .off
                        }
                    } else if parent.title.contains("Connect"),
                              item.title == "Enable Connect Sound" {
                        item.state = settings.connectEnabled ? .on : .off
                    } else if parent.title.contains("Disconnect"),
                              item.title == "Enable Disconnect Sound" {
                        item.state = settings.disconnectEnabled ? .on : .off
                    }
                }
            }
        }
    }

    // MARK: - NSMenuDelegate

    /// Called when hovering over an item: previews the sound.
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        guard let choice = item?.representedObject as? SoundChoice else { return }

        // Find parent menu to determine connect/disconnect
        if let parentItem = statusItem.menu?.items.first(where: { $0.submenu === menu }) {
            let type: SoundType = (parentItem.tag == 1 ? .connect : .disconnect)
            playSoundIfEnabled(choice, type: type, enabled: true)
        }
    }

    // MARK: - USB notifications

    /// Registers for USB connect/disconnect notifications via IOKit.
    func setupUSBNotifications() {
        notifyPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let notifyPort = notifyPort else { return }
        let runLoopSource = IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .defaultMode)

        let addedDict = IOServiceMatching("IOUSBHostDevice")
        IOServiceAddMatchingNotification(
            notifyPort, kIOFirstMatchNotification, addedDict,
            usbDeviceAdded, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()), &addedIterator
        )
        while case let device = IOIteratorNext(addedIterator), device != IO_OBJECT_NULL {
            IOObjectRelease(device)
        }

        let removedDict = IOServiceMatching("IOUSBHostDevice")
        IOServiceAddMatchingNotification(
            notifyPort, kIOTerminatedNotification, removedDict,
            usbDeviceRemoved, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()), &removedIterator
        )
        while case let device = IOIteratorNext(removedIterator), device != IO_OBJECT_NULL {
            IOObjectRelease(device)
        }
    }
}

// MARK: - USB callbacks

private let usbDeviceAdded: IOServiceMatchingCallback = { (refcon, iterator) in
    let mySelf = Unmanaged<AppDelegate>.fromOpaque(refcon!).takeUnretainedValue()
    while case let device = IOIteratorNext(iterator), device != IO_OBJECT_NULL {
        print("USB device connected")
        DispatchQueue.main.async {
            mySelf.playSoundIfEnabled(mySelf.settings.connectSound, type: .connect, enabled: mySelf.settings.connectEnabled)
        }
        IOObjectRelease(device)
    }
}

private let usbDeviceRemoved: IOServiceMatchingCallback = { (refcon, iterator) in
    let mySelf = Unmanaged<AppDelegate>.fromOpaque(refcon!).takeUnretainedValue()
    while case let device = IOIteratorNext(iterator), device != IO_OBJECT_NULL {
        print("USB device disconnected")
        DispatchQueue.main.async {
            mySelf.playSoundIfEnabled(mySelf.settings.disconnectSound, type: .disconnect, enabled: mySelf.settings.disconnectEnabled)
        }
        IOObjectRelease(device)
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
