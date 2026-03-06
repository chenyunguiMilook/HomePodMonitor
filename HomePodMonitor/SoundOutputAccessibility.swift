//
//  SoundOutputAccessibility.swift
//  HomePodMonitor
//
//  Created by GitHub Copilot on 2026/3/6.
//

import AppKit
import ApplicationServices
import Foundation

struct SoundOutputSnapshot {
    let outputs: [String]
    let selectedOutput: String?
}

enum SoundOutputAccessibilityError: LocalizedError {
    case accessibilityPermissionRequired
    case controlCenterUnavailable
    case soundMenuUnavailable
    case popupUnavailable
    case targetOutputNotFound(String)
    case unableToSelectOutput(String)

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionRequired:
            return "请先为应用开启辅助功能权限。"
        case .controlCenterUnavailable:
            return "未找到控制中心进程。"
        case .soundMenuUnavailable:
            return "未找到菜单栏中的声音控件。"
        case .popupUnavailable:
            return "无法打开声音输出面板。"
        case let .targetOutputNotFound(name):
            return "声音输出列表里没有找到 \(name)。"
        case let .unableToSelectOutput(name):
            return "无法切换到 \(name)。"
        }
    }
}

final class SoundOutputAccessibility {
    private let controlCenterBundleIdentifier = "com.apple.controlcenter"
    private let soundMenuIdentifier = "com.apple.menuextra.sound"
    private let accessibilitySettingsURLs = [
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        "x-apple.systempreferences:com.apple.Settings.PrivacySecurity.extension?Privacy_Accessibility"
    ]

    func isTrusted(prompt: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    func openAccessibilitySettings() -> Bool {
        for rawURL in accessibilitySettingsURLs {
            guard let url = URL(string: rawURL) else {
                continue
            }

            if NSWorkspace.shared.open(url) {
                return true
            }
        }

        return false
    }

    func readSnapshot() throws -> SoundOutputSnapshot {
        try withSoundPopup { window in
            parseSnapshot(from: window)
        }
    }

    func ensurePreferredOutputSelected(preferredNames: [String]) throws -> SoundOutputSnapshot {
        try withSoundPopup { window in
            var snapshot = parseSnapshot(from: window)
            if let selectedOutput = snapshot.selectedOutput,
               preferredNames.contains(where: { $0.caseInsensitiveCompare(selectedOutput) == .orderedSame }) {
                return snapshot
            }

            guard let targetName = preferredNames.first(where: { preferred in
                snapshot.outputs.contains(where: { $0.caseInsensitiveCompare(preferred) == .orderedSame })
            }) else {
                throw SoundOutputAccessibilityError.targetOutputNotFound(preferredNames.joined(separator: "、"))
            }

            guard let checkbox = findOutputCheckbox(named: targetName, in: window) else {
                throw SoundOutputAccessibilityError.targetOutputNotFound(targetName)
            }

            guard AXUIElementPerformAction(checkbox, kAXPressAction as CFString) == .success else {
                throw SoundOutputAccessibilityError.unableToSelectOutput(targetName)
            }

            Thread.sleep(forTimeInterval: 1.0)
            snapshot = parseSnapshot(from: window)
            return snapshot
        }
    }

    private func withSoundPopup<T>(_ action: (AXUIElement) throws -> T) throws -> T {
        guard isTrusted() else {
            throw SoundOutputAccessibilityError.accessibilityPermissionRequired
        }

        guard let controlCenterApp = NSRunningApplication.runningApplications(withBundleIdentifier: controlCenterBundleIdentifier).first else {
            throw SoundOutputAccessibilityError.controlCenterUnavailable
        }

        let applicationElement = AXUIElementCreateApplication(controlCenterApp.processIdentifier)
        guard let soundMenuItem = findSoundMenuItem(in: applicationElement) else {
            throw SoundOutputAccessibilityError.soundMenuUnavailable
        }

        let popupWasOpen = currentPopupWindow(in: applicationElement) != nil
        if !popupWasOpen {
            _ = AXUIElementPerformAction(soundMenuItem, kAXPressAction as CFString)
        }

        guard let popupWindow = waitForPopup(in: applicationElement) else {
            if !popupWasOpen {
                _ = AXUIElementPerformAction(soundMenuItem, kAXPressAction as CFString)
            }
            throw SoundOutputAccessibilityError.popupUnavailable
        }

        defer {
            if !popupWasOpen {
                _ = AXUIElementPerformAction(soundMenuItem, kAXPressAction as CFString)
            }
        }

        return try action(popupWindow)
    }

    private func waitForPopup(in applicationElement: AXUIElement) -> AXUIElement? {
        for _ in 0..<12 {
            if let popup = currentPopupWindow(in: applicationElement) {
                return popup
            }

            Thread.sleep(forTimeInterval: 0.1)
        }

        return nil
    }

    private func currentPopupWindow(in applicationElement: AXUIElement) -> AXUIElement? {
        guard let windows = copyAttribute(kAXWindowsAttribute, from: applicationElement) as? [AXUIElement] else {
            return nil
        }

        return windows.first
    }

    private func findSoundMenuItem(in applicationElement: AXUIElement) -> AXUIElement? {
        guard let extrasMenuBarObject = copyAttribute("AXExtrasMenuBar", from: applicationElement) else {
            return nil
        }

        let extrasMenuBar = extrasMenuBarObject as! AXUIElement
        guard let children = copyAttribute(kAXChildrenAttribute, from: extrasMenuBar) as? [AXUIElement] else {
            return nil
        }

        return children.first { element in
            let identifier = stringValue(of: kAXIdentifierAttribute, from: element)
            let description = stringValue(of: kAXDescriptionAttribute, from: element)
            return identifier == soundMenuIdentifier || description == "声音"
        }
    }

    private func findOutputCheckbox(named name: String, in window: AXUIElement) -> AXUIElement? {
        allDescendants(of: window).first { element in
            guard stringValue(of: kAXRoleAttribute, from: element) == kAXCheckBoxRole else {
                return false
            }

            let identifier = stringValue(of: kAXIdentifierAttribute, from: element) ?? ""
            let description = stringValue(of: kAXDescriptionAttribute, from: element) ?? ""
            return identifier == "sound-device-\(name)" || description.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    private func parseSnapshot(from window: AXUIElement) -> SoundOutputSnapshot {
        let outputCheckboxes = allDescendants(of: window).filter { element in
            guard stringValue(of: kAXRoleAttribute, from: element) == kAXCheckBoxRole else {
                return false
            }

            let identifier = stringValue(of: kAXIdentifierAttribute, from: element) ?? ""
            return identifier.hasPrefix("sound-device-")
        }

        let outputs = outputCheckboxes.compactMap { checkbox in
            stringValue(of: kAXDescriptionAttribute, from: checkbox)
        }

        let selectedOutput = outputCheckboxes.first { checkbox in
            intValue(of: kAXValueAttribute, from: checkbox) == 1
        }.flatMap { checkbox in
            stringValue(of: kAXDescriptionAttribute, from: checkbox)
        }

        return SoundOutputSnapshot(outputs: outputs, selectedOutput: selectedOutput)
    }

    private func allDescendants(of root: AXUIElement) -> [AXUIElement] {
        var results: [AXUIElement] = []
        var queue: [AXUIElement] = [root]

        while !queue.isEmpty {
            let current = queue.removeFirst()
            results.append(current)

            if let children = copyAttribute(kAXChildrenAttribute, from: current) as? [AXUIElement] {
                queue.append(contentsOf: children)
            }
        }

        return results
    }

    private func copyAttribute(_ attribute: String, from element: AXUIElement) -> AnyObject? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success else {
            return nil
        }

        return value
    }

    private func stringValue(of attribute: String, from element: AXUIElement) -> String? {
        if let string = copyAttribute(attribute, from: element) as? String {
            return string
        }

        if let number = copyAttribute(attribute, from: element) as? NSNumber {
            return number.stringValue
        }

        return nil
    }

    private func intValue(of attribute: String, from element: AXUIElement) -> Int {
        if let number = copyAttribute(attribute, from: element) as? NSNumber {
            return number.intValue
        }

        if let string = copyAttribute(attribute, from: element) as? String {
            return Int(string) ?? 0
        }

        return 0
    }
}