//
//  HookInstaller.swift
//  ClaudeIsland
//
//  Auto-installs Claude Code hooks on app launch
//

import Foundation
import os.log

/// Logger for hook installation
private let logger = Logger(subsystem: "com.claudeisland", category: "HookInstaller")

/// Errors that can occur during hook installation
enum HookInstallerError: Error, LocalizedError {
    case directoryCreationFailed(URL, Error)
    case bundleResourceMissing
    case scriptCopyFailed(Error)
    case permissionSetFailed(Error)
    case settingsReadFailed(URL, Error)
    case settingsWriteFailed(URL, Error)
    case jsonSerializationFailed(Error)
    case pythonNotFound

    var errorDescription: String? {
        switch self {
        case .directoryCreationFailed(let url, let error):
            return "Failed to create hooks directory at \(url.path): \(error.localizedDescription)"
        case .bundleResourceMissing:
            return "Hook script not found in app bundle"
        case .scriptCopyFailed(let error):
            return "Failed to copy hook script: \(error.localizedDescription)"
        case .permissionSetFailed(let error):
            return "Failed to set script permissions: \(error.localizedDescription)"
        case .settingsReadFailed(let url, let error):
            return "Failed to read settings at \(url.path): \(error.localizedDescription)"
        case .settingsWriteFailed(let url, let error):
            return "Failed to write settings at \(url.path): \(error.localizedDescription)"
        case .jsonSerializationFailed(let error):
            return "Failed to serialize settings JSON: \(error.localizedDescription)"
        case .pythonNotFound:
            return "Python interpreter not found"
        }
    }
}

/// Result of hook installation
struct HookInstallResult {
    let success: Bool
    let warnings: [String]
    let errors: [HookInstallerError]
}

struct HookInstaller {

    /// Install hook script and update settings.json on app launch
    /// Returns a result indicating success/failure with any warnings or errors
    @discardableResult
    static func installIfNeeded() -> HookInstallResult {
        var warnings: [String] = []
        var errors: [HookInstallerError] = []

        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
        let hooksDir = claudeDir.appendingPathComponent("hooks")
        let pythonScript = hooksDir.appendingPathComponent("claude-island-state.py")
        let settings = claudeDir.appendingPathComponent("settings.json")

        // Create hooks directory
        do {
            try FileManager.default.createDirectory(
                at: hooksDir,
                withIntermediateDirectories: true
            )
            logger.info("Hooks directory ready at \(hooksDir.path, privacy: .public)")
        } catch {
            logger.error("Failed to create hooks directory: \(error.localizedDescription, privacy: .public)")
            errors.append(.directoryCreationFailed(hooksDir, error))
            return HookInstallResult(success: false, warnings: warnings, errors: errors)
        }

        // Copy Python script from bundle
        guard let bundled = Bundle.main.url(forResource: "claude-island-state", withExtension: "py") else {
            logger.error("Hook script not found in app bundle")
            errors.append(.bundleResourceMissing)
            return HookInstallResult(success: false, warnings: warnings, errors: errors)
        }

        do {
            // Remove existing script if present
            if FileManager.default.fileExists(atPath: pythonScript.path) {
                try FileManager.default.removeItem(at: pythonScript)
            }

            // Copy new script
            try FileManager.default.copyItem(at: bundled, to: pythonScript)
            logger.info("Hook script copied to \(pythonScript.path, privacy: .public)")
        } catch {
            logger.error("Failed to copy hook script: \(error.localizedDescription, privacy: .public)")
            errors.append(.scriptCopyFailed(error))
            return HookInstallResult(success: false, warnings: warnings, errors: errors)
        }

        // Set executable permissions
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: pythonScript.path
            )
            logger.debug("Script permissions set to 755")
        } catch {
            logger.warning("Failed to set script permissions: \(error.localizedDescription, privacy: .public)")
            warnings.append("Could not set script permissions - hook may not execute")
            // Continue anyway - the script might still work
        }

        // Update settings.json
        let settingsResult = updateSettings(at: settings)
        warnings.append(contentsOf: settingsResult.warnings)
        errors.append(contentsOf: settingsResult.errors)

        let success = errors.isEmpty
        if success {
            logger.info("Hook installation completed successfully")
        } else {
            logger.error("Hook installation completed with \(errors.count) error(s)")
        }

        return HookInstallResult(success: success, warnings: warnings, errors: errors)
    }

    private static func updateSettings(at settingsURL: URL) -> (warnings: [String], errors: [HookInstallerError]) {
        var warnings: [String] = []
        var errors: [HookInstallerError] = []
        var json: [String: Any] = [:]

        // Read existing settings if present
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            do {
                let data = try Data(contentsOf: settingsURL)
                if let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    json = existing
                    logger.debug("Loaded existing settings")
                }
            } catch {
                logger.warning("Could not read existing settings (will create new): \(error.localizedDescription, privacy: .public)")
                warnings.append("Existing settings.json could not be read - using defaults")
            }
        }

        let python = detectPython()
        let command = "\(python) ~/.claude/hooks/claude-island-state.py"
        let hookEntry: [[String: Any]] = [["type": "command", "command": command]]
        let hookEntryWithTimeout: [[String: Any]] = [["type": "command", "command": command, "timeout": 86400]]
        let withMatcher: [[String: Any]] = [["matcher": "*", "hooks": hookEntry]]
        let withMatcherAndTimeout: [[String: Any]] = [["matcher": "*", "hooks": hookEntryWithTimeout]]
        let withoutMatcher: [[String: Any]] = [["hooks": hookEntry]]
        let preCompactConfig: [[String: Any]] = [
            ["matcher": "auto", "hooks": hookEntry],
            ["matcher": "manual", "hooks": hookEntry]
        ]

        var hooks = json["hooks"] as? [String: Any] ?? [:]

        let hookEvents: [(String, [[String: Any]])] = [
            ("UserPromptSubmit", withoutMatcher),
            ("PreToolUse", withMatcher),
            ("PostToolUse", withMatcher),
            ("PermissionRequest", withMatcherAndTimeout),
            ("Notification", withMatcher),
            ("Stop", withoutMatcher),
            ("SubagentStop", withoutMatcher),
            ("SessionStart", withoutMatcher),
            ("SessionEnd", withoutMatcher),
            ("PreCompact", preCompactConfig),
        ]

        for (event, config) in hookEvents {
            if var existingEvent = hooks[event] as? [[String: Any]] {
                let hasOurHook = existingEvent.contains { entry in
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        return entryHooks.contains { h in
                            let cmd = h["command"] as? String ?? ""
                            return cmd.contains("claude-island-state.py")
                        }
                    }
                    return false
                }
                if !hasOurHook {
                    existingEvent.append(contentsOf: config)
                    hooks[event] = existingEvent
                }
            } else {
                hooks[event] = config
            }
        }

        json["hooks"] = hooks

        // Write settings
        do {
            let data = try JSONSerialization.data(
                withJSONObject: json,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: settingsURL)
            logger.info("Settings updated at \(settingsURL.path, privacy: .public)")
        } catch let error as NSError where error.domain == NSCocoaErrorDomain {
            logger.error("Failed to write settings: \(error.localizedDescription, privacy: .public)")
            errors.append(.settingsWriteFailed(settingsURL, error))
        } catch {
            logger.error("Failed to serialize settings JSON: \(error.localizedDescription, privacy: .public)")
            errors.append(.jsonSerializationFailed(error))
        }

        return (warnings, errors)
    }

    /// Check if hooks are currently installed
    static func isInstalled() -> Bool {
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
        let settings = claudeDir.appendingPathComponent("settings.json")

        guard let data = try? Data(contentsOf: settings),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }

        for (_, value) in hooks {
            if let entries = value as? [[String: Any]] {
                for entry in entries {
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        for hook in entryHooks {
                            if let cmd = hook["command"] as? String,
                               cmd.contains("claude-island-state.py") {
                                return true
                            }
                        }
                    }
                }
            }
        }
        return false
    }

    /// Uninstall hooks from settings.json and remove script
    static func uninstall() {
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
        let hooksDir = claudeDir.appendingPathComponent("hooks")
        let pythonScript = hooksDir.appendingPathComponent("claude-island-state.py")
        let settings = claudeDir.appendingPathComponent("settings.json")

        // Remove script
        do {
            try FileManager.default.removeItem(at: pythonScript)
            logger.info("Hook script removed")
        } catch {
            logger.debug("Could not remove hook script (may not exist): \(error.localizedDescription, privacy: .public)")
        }

        // Update settings
        guard let data = try? Data(contentsOf: settings),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = json["hooks"] as? [String: Any] else {
            logger.debug("No settings to update during uninstall")
            return
        }

        for (event, value) in hooks {
            if var entries = value as? [[String: Any]] {
                entries.removeAll { entry in
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        return entryHooks.contains { hook in
                            let cmd = hook["command"] as? String ?? ""
                            return cmd.contains("claude-island-state.py")
                        }
                    }
                    return false
                }

                if entries.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = entries
                }
            }
        }

        if hooks.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = hooks
        }

        if let data = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            do {
                try data.write(to: settings)
                logger.info("Hooks removed from settings")
            } catch {
                logger.error("Failed to write settings during uninstall: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func detectPython() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["python3"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                logger.debug("Detected python3")
                return "python3"
            }
        } catch {
            logger.debug("python3 detection failed: \(error.localizedDescription, privacy: .public)")
        }

        logger.warning("python3 not found, falling back to python")
        return "python"
    }
}
