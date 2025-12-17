//
//  Settings.swift
//  ClaudeIsland
//
//  App settings manager using UserDefaults
//

import Foundation

/// Available notification sounds
enum NotificationSound: String, CaseIterable {
    case none = "None"
    case pop = "Pop"
    case ping = "Ping"
    case tink = "Tink"
    case glass = "Glass"
    case blow = "Blow"
    case bottle = "Bottle"
    case frog = "Frog"
    case funk = "Funk"
    case hero = "Hero"
    case morse = "Morse"
    case purr = "Purr"
    case sosumi = "Sosumi"
    case submarine = "Submarine"
    case basso = "Basso"

    /// The system sound name to use with NSSound, or nil for no sound
    var soundName: String? {
        self == .none ? nil : rawValue
    }
}

/// Modifier keys for keyboard shortcuts
struct KeyboardModifiers: OptionSet, Codable {
    let rawValue: Int

    static let command = KeyboardModifiers(rawValue: 1 << 0)
    static let shift = KeyboardModifiers(rawValue: 1 << 1)
    static let option = KeyboardModifiers(rawValue: 1 << 2)
    static let control = KeyboardModifiers(rawValue: 1 << 3)

    var displayString: String {
        var parts: [String] = []
        if contains(.control) { parts.append("^") }
        if contains(.option) { parts.append("⌥") }
        if contains(.shift) { parts.append("⇧") }
        if contains(.command) { parts.append("⌘") }
        return parts.joined()
    }
}

/// Keyboard shortcut configuration
struct KeyboardShortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: KeyboardModifiers
    var keyChar: String

    var displayString: String {
        "\(modifiers.displayString)\(keyChar.uppercased())"
    }

    /// Default: Cmd+Shift+C
    static let defaultShortcut = KeyboardShortcut(
        keyCode: 8,  // 'C' key
        modifiers: [.command, .shift],
        keyChar: "C"
    )
}

enum AppSettings {
    private static let defaults = UserDefaults.standard

    // MARK: - Keys

    private enum Keys {
        static let notificationSound = "notificationSound"
        static let analyticsEnabled = "analyticsEnabled"
        static let globalHotkey = "globalHotkey"
        static let hotkeyEnabled = "hotkeyEnabled"
    }

    // MARK: - Notification Sound

    /// The sound to play when Claude finishes and is ready for input
    static var notificationSound: NotificationSound {
        get {
            guard let rawValue = defaults.string(forKey: Keys.notificationSound),
                  let sound = NotificationSound(rawValue: rawValue) else {
                return .pop // Default to Pop
            }
            return sound
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.notificationSound)
        }
    }

    // MARK: - Analytics (Privacy)

    /// Whether analytics tracking is enabled (defaults to false for privacy)
    static var analyticsEnabled: Bool {
        get {
            // Default to false (opt-out by default for better privacy)
            if defaults.object(forKey: Keys.analyticsEnabled) == nil {
                return false
            }
            return defaults.bool(forKey: Keys.analyticsEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.analyticsEnabled)
        }
    }

    // MARK: - Global Hotkey

    /// Whether global hotkey is enabled (defaults to true)
    static var hotkeyEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.hotkeyEnabled) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.hotkeyEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.hotkeyEnabled)
            NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
        }
    }

    /// The configured global hotkey
    static var globalHotkey: KeyboardShortcut {
        get {
            guard let data = defaults.data(forKey: Keys.globalHotkey),
                  let shortcut = try? JSONDecoder().decode(KeyboardShortcut.self, from: data) else {
                return .defaultShortcut
            }
            return shortcut
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.globalHotkey)
                NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
            }
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let hotkeySettingsChanged = Notification.Name("hotkeySettingsChanged")
}
