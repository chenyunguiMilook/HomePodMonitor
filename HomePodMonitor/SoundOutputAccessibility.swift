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

struct BackgroundSoundsAutomationResult {
    let alreadyEnabled: Bool
}

enum SoundOutputAccessibilityError: LocalizedError {
    case accessibilityPermissionRequired
    case controlCenterUnavailable
    case soundMenuUnavailable
    case popupUnavailable
    case targetOutputNotFound(String)
    case unableToSelectOutput(String)
    case systemSettingsUnavailable
    case accessibilityCategoryUnavailable
    case audioCategoryUnavailable
    case backgroundSoundsToggleUnavailable
    case unableToToggleBackgroundSounds

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
        case .systemSettingsUnavailable:
            return "无法打开或定位系统设置窗口。"
        case .accessibilityCategoryUnavailable:
            return "在系统设置中未找到“辅助功能”页面。"
        case .audioCategoryUnavailable:
            return "在辅助功能设置中未找到“音频”页面。"
        case .backgroundSoundsToggleUnavailable:
            return "在“辅助功能 > 音频”中未找到“背景音”开关。"
        case .unableToToggleBackgroundSounds:
            return "无法切换“背景音”开关。"
        }
    }
}

final class SoundOutputAccessibility: @unchecked Sendable {
    private let controlCenterBundleIdentifier = "com.apple.controlcenter"
    private let systemSettingsBundleIdentifiers = ["com.apple.systempreferences"]
    private let switchRole = "AXSwitch"
    private let closeAction = "AXClose"
    private let frameAttribute = "AXFrame"
    private let soundMenuIdentifier = "com.apple.menuextra.sound"
    private let soundMenuKeywords = ["sound", "声音", "扬声器", "音频", "speaker"]
    private let accessibilitySettingsURLs = [
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        "x-apple.systempreferences:com.apple.Settings.PrivacySecurity.extension?Privacy_Accessibility"
    ]
    private let generalSystemSettingsURLs = [
        "x-apple.systempreferences:com.apple.preference.universalaccess",
        "x-apple.systempreferences:com.apple.Settings.Accessibility.extension",
        "x-apple.systempreferences:"
    ]
    private let accessibilityKeywords = ["辅助功能", "accessibility"]
    private let audioKeywords = ["音频", "audio"]
    private let backgroundSoundsKeywords = ["背景音", "background sounds", "background sound"]

    nonisolated func isTrusted(prompt: Bool = false) -> Bool {
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

    @discardableResult
    nonisolated func openGeneralAccessibilitySettings() -> Bool {
        for rawURL in generalSystemSettingsURLs {
            guard let url = URL(string: rawURL) else {
                continue
            }

            if NSWorkspace.shared.open(url) {
                return true
            }
        }

        return false
    }

    nonisolated func readSnapshot() throws -> SoundOutputSnapshot {
        try withSoundPopup { window in
            parseSnapshot(from: window)
        }
    }

    nonisolated func readVisibleSnapshot() throws -> SoundOutputSnapshot? {
        guard isTrusted() else {
            throw SoundOutputAccessibilityError.accessibilityPermissionRequired
        }

        let applicationElement = try controlCenterApplicationElement()
        guard let popupWindow = currentPopupWindow(in: applicationElement) else {
            return nil
        }

        return parseSnapshot(from: popupWindow)
    }

    nonisolated func ensurePreferredOutputSelected(preferredNames: [String]) throws -> SoundOutputSnapshot {
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

    nonisolated func ensureBackgroundSoundsEnabled() throws -> BackgroundSoundsAutomationResult {
        guard isTrusted() else {
            throw SoundOutputAccessibilityError.accessibilityPermissionRequired
        }

        guard openGeneralAccessibilitySettings() else {
            throw SoundOutputAccessibilityError.systemSettingsUnavailable
        }

        let applicationElement = try systemSettingsApplicationElement()
        guard let window = waitForSystemSettingsWindow(in: applicationElement) else {
            throw SoundOutputAccessibilityError.systemSettingsUnavailable
        }

        guard navigateSidebarCategory(matching: accessibilityKeywords, in: window) else {
            throw SoundOutputAccessibilityError.accessibilityCategoryUnavailable
        }

        Thread.sleep(forTimeInterval: 0.5)

        guard navigateSidebarCategory(matching: audioKeywords, in: window) else {
            throw SoundOutputAccessibilityError.audioCategoryUnavailable
        }

        guard let toggle = waitForElement(in: window, timeout: 2.5, matching: { [backgroundSoundsKeywords] element in
            findBackgroundSoundsToggle(in: element, keywords: backgroundSoundsKeywords) != nil
        }).flatMap({ [backgroundSoundsKeywords] element in
            findBackgroundSoundsToggle(in: element, keywords: backgroundSoundsKeywords)
        }) ?? findBackgroundSoundsToggle(in: window, keywords: backgroundSoundsKeywords) else {
            throw SoundOutputAccessibilityError.backgroundSoundsToggleUnavailable
        }

        if isToggleEnabled(toggle) {
            closeWindowIfPossible(window)
            return BackgroundSoundsAutomationResult(alreadyEnabled: true)
        }

        guard pressElement(toggle) else {
            throw SoundOutputAccessibilityError.unableToToggleBackgroundSounds
        }

        Thread.sleep(forTimeInterval: 0.4)

        if isToggleEnabled(toggle) {
            return BackgroundSoundsAutomationResult(alreadyEnabled: false)
        }

        guard let refreshedToggle = findBackgroundSoundsToggle(in: window, keywords: backgroundSoundsKeywords),
              isToggleEnabled(refreshedToggle) else {
            throw SoundOutputAccessibilityError.unableToToggleBackgroundSounds
        }

                closeWindowIfPossible(window)
        return BackgroundSoundsAutomationResult(alreadyEnabled: false)
    }

    private nonisolated func withSoundPopup<T>(_ action: (AXUIElement) throws -> T) throws -> T {
        guard isTrusted() else {
            throw SoundOutputAccessibilityError.accessibilityPermissionRequired
        }

        let applicationElement = try controlCenterApplicationElement()
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

    private nonisolated func controlCenterApplicationElement() throws -> AXUIElement {
        guard let controlCenterApp = NSRunningApplication.runningApplications(withBundleIdentifier: controlCenterBundleIdentifier).first else {
            throw SoundOutputAccessibilityError.controlCenterUnavailable
        }

        return AXUIElementCreateApplication(controlCenterApp.processIdentifier)
    }

    private nonisolated func systemSettingsApplicationElement() throws -> AXUIElement {
        for bundleIdentifier in systemSettingsBundleIdentifiers {
            if let application = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
                application.activate()
                return AXUIElementCreateApplication(application.processIdentifier)
            }
        }

        for _ in 0..<30 {
            Thread.sleep(forTimeInterval: 0.1)

            for bundleIdentifier in systemSettingsBundleIdentifiers {
                if let application = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
                    application.activate()
                    return AXUIElementCreateApplication(application.processIdentifier)
                }
            }
        }

        throw SoundOutputAccessibilityError.systemSettingsUnavailable
    }

    private nonisolated func waitForPopup(in applicationElement: AXUIElement) -> AXUIElement? {
        for _ in 0..<12 {
            if let popup = currentPopupWindow(in: applicationElement) {
                return popup
            }

            Thread.sleep(forTimeInterval: 0.1)
        }

        return nil
    }

    private nonisolated func waitForSystemSettingsWindow(in applicationElement: AXUIElement) -> AXUIElement? {
        for _ in 0..<40 {
            if let popup = currentPopupWindow(in: applicationElement) {
                return popup
            }

            Thread.sleep(forTimeInterval: 0.15)
        }

        return nil
    }

    private nonisolated func currentPopupWindow(in applicationElement: AXUIElement) -> AXUIElement? {
        guard let windows = copyAttribute(kAXWindowsAttribute, from: applicationElement) as? [AXUIElement] else {
            return nil
        }

        return windows.first
    }

    private nonisolated func findSoundMenuItem(in applicationElement: AXUIElement) -> AXUIElement? {
        guard let extrasMenuBarObject = copyAttribute("AXExtrasMenuBar", from: applicationElement) else {
            return nil
        }

        let extrasMenuBar = extrasMenuBarObject as! AXUIElement
        return allDescendants(of: extrasMenuBar).first { element in
            let identifier = stringValue(of: kAXIdentifierAttribute, from: element)?.lowercased() ?? ""
            let description = stringValue(of: kAXDescriptionAttribute, from: element)?.lowercased() ?? ""
            let title = stringValue(of: kAXTitleAttribute, from: element)?.lowercased() ?? ""

            if identifier == soundMenuIdentifier {
                return true
            }

            if identifier.contains(".sound") || identifier.contains("audio") {
                return true
            }

            return soundMenuKeywords.contains { keyword in
                description.contains(keyword) || title.contains(keyword)
            }
        }
    }

    private nonisolated func findOutputCheckbox(named name: String, in window: AXUIElement) -> AXUIElement? {
        allDescendants(of: window).first { element in
            guard stringValue(of: kAXRoleAttribute, from: element) == kAXCheckBoxRole else {
                return false
            }

            let identifier = stringValue(of: kAXIdentifierAttribute, from: element) ?? ""
            let description = stringValue(of: kAXDescriptionAttribute, from: element) ?? ""
            return identifier == "sound-device-\(name)" || description.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    private nonisolated func parseSnapshot(from window: AXUIElement) -> SoundOutputSnapshot {
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

    private nonisolated func allDescendants(of root: AXUIElement) -> [AXUIElement] {
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

    private nonisolated func waitForElement(
        in root: AXUIElement,
        timeout: TimeInterval,
        matching predicate: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let match = allDescendants(of: root).first(where: predicate) {
                return match
            }

            Thread.sleep(forTimeInterval: 0.1)
        }

        return nil
    }

    private nonisolated func navigateSidebarCategory(matching keywords: [String], in window: AXUIElement) -> Bool {
        guard let targetElement = waitForElement(in: window, timeout: 2.5, matching: { element in
            self.matchesSidebarCategory(element, keywords: keywords)
        }) else {
            return false
        }

        if pressElement(targetElement) {
            return true
        }

        if let parent = parentElement(of: targetElement) {
            return pressElement(parent)
        }

        return false
    }

    private nonisolated func matchesSidebarCategory(_ element: AXUIElement, keywords: [String]) -> Bool {
        let role = stringValue(of: kAXRoleAttribute, from: element)?.lowercased() ?? ""
        guard role == kAXRowRole.lowercased() ||
                role == kAXStaticTextRole.lowercased() ||
                role == kAXButtonRole.lowercased() ||
                role == kAXOutlineRole.lowercased() else {
            return false
        }

        let values = searchableStrings(of: element)
        guard values.contains(where: { value in keywords.contains(where: value.contains) }) else {
            return false
        }

        return role != kAXOutlineRole.lowercased() || values.count == 1
    }

    private nonisolated func matchesBackgroundSoundsToggle(_ element: AXUIElement, keywords: [String]) -> Bool {
        let role = stringValue(of: kAXRoleAttribute, from: element)?.lowercased() ?? ""
        guard role == switchRole.lowercased() || role == kAXCheckBoxRole.lowercased() || role == kAXButtonRole.lowercased() else {
            return false
        }

        let values = searchableStrings(of: element)
        if values.contains(where: { value in keywords.contains(where: value.contains) }) {
            return true
        }

        guard let parent = parentElement(of: element) else {
            return false
        }

        let parentValues = searchableStrings(of: parent)
        return parentValues.contains(where: { value in keywords.contains(where: value.contains) })
    }

    private nonisolated func findBackgroundSoundsToggle(in root: AXUIElement, keywords: [String]) -> AXUIElement? {
        if matchesBackgroundSoundsToggle(root, keywords: keywords) {
            return root
        }

        let labelCandidates = allDescendants(of: root).filter { element in
            matchesBackgroundSoundsLabel(element, keywords: keywords)
        }

        for label in labelCandidates {
            for container in ancestorElements(of: label, maxDepth: 4) {
                if let toggle = nearestToggle(around: label, in: container) {
                    return toggle
                }
            }
        }

        return nearestToggleInWindow(near: labelCandidates, within: root)
    }

    private nonisolated func matchesBackgroundSoundsLabel(_ element: AXUIElement, keywords: [String]) -> Bool {
        let role = stringValue(of: kAXRoleAttribute, from: element)?.lowercased() ?? ""
        guard role == kAXStaticTextRole.lowercased() || role == kAXButtonRole.lowercased() || role == kAXGroupRole.lowercased() else {
            return false
        }

        let values = searchableStrings(of: element)
        return values.contains(where: { value in keywords.contains(where: value.contains) })
    }

    private nonisolated func nearestToggle(around label: AXUIElement, in container: AXUIElement) -> AXUIElement? {
        let toggles = allDescendants(of: container).filter { element in
            isToggleElement(element)
        }

        guard !toggles.isEmpty else {
            return nil
        }

        if toggles.count == 1 {
            return toggles[0]
        }

        let labelFrame = cgRectValue(of: frameAttribute, from: label)
        return toggles.min { lhs, rhs in
            toggleDistance(from: labelFrame, to: lhs) < toggleDistance(from: labelFrame, to: rhs)
        }
    }

    private nonisolated func nearestToggleInWindow(near labels: [AXUIElement], within root: AXUIElement) -> AXUIElement? {
        let toggles = allDescendants(of: root).filter { element in
            isToggleElement(element)
        }

        guard !labels.isEmpty, !toggles.isEmpty else {
            return nil
        }

        var bestToggle: AXUIElement?
        var bestScore = CGFloat.greatestFiniteMagnitude

        for label in labels {
            let labelFrame = cgRectValue(of: frameAttribute, from: label)
            for toggle in toggles {
                let score = toggleDistance(from: labelFrame, to: toggle)
                if score < bestScore {
                    bestScore = score
                    bestToggle = toggle
                }
            }
        }

        return bestToggle
    }

    private nonisolated func ancestorElements(of element: AXUIElement, maxDepth: Int) -> [AXUIElement] {
        var ancestors: [AXUIElement] = []
        var currentElement = parentElement(of: element)
        var depth = 0

        while let current = currentElement, depth < maxDepth {
            ancestors.append(current)
            depth += 1
            currentElement = parentElement(of: current)
        }

        return ancestors
    }

    private nonisolated func isToggleElement(_ element: AXUIElement) -> Bool {
        let role = stringValue(of: kAXRoleAttribute, from: element)?.lowercased() ?? ""
        return role == switchRole.lowercased() || role == kAXCheckBoxRole.lowercased() || role == kAXButtonRole.lowercased()
    }

    private nonisolated func toggleDistance(from labelFrame: CGRect?, to toggle: AXUIElement) -> CGFloat {
        guard let labelFrame,
              let toggleFrame = cgRectValue(of: frameAttribute, from: toggle) else {
            return .greatestFiniteMagnitude
        }

        let deltaX = toggleFrame.midX - labelFrame.maxX
        let deltaY = abs(toggleFrame.midY - labelFrame.midY)
        let rightSidePenalty: CGFloat = deltaX >= -8 ? 0 : 800
        let rowPenalty: CGFloat = deltaY <= max(labelFrame.height * 1.2, 24) ? 0 : 600
        let horizontalPenalty = deltaX >= 0 ? deltaX : abs(deltaX) * 2
        return rightSidePenalty + rowPenalty + horizontalPenalty + (deltaY * 3)
    }

    private nonisolated func searchableStrings(of element: AXUIElement) -> [String] {
        [
            stringValue(of: kAXIdentifierAttribute, from: element),
            stringValue(of: kAXTitleAttribute, from: element),
            stringValue(of: kAXDescriptionAttribute, from: element),
            stringValue(of: kAXValueAttribute, from: element),
            stringValue(of: kAXHelpAttribute, from: element)
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        .filter { !$0.isEmpty }
    }

    private nonisolated func pressElement(_ element: AXUIElement) -> Bool {
        let pressStatus = AXUIElementPerformAction(element, kAXPressAction as CFString)
        if pressStatus == .success {
            return true
        }

        if let parent = parentElement(of: element) {
            return AXUIElementPerformAction(parent, kAXPressAction as CFString) == .success
        }

        return false
    }

    private nonisolated func closeWindowIfPossible(_ window: AXUIElement) {
        if AXUIElementPerformAction(window, closeAction as CFString) == .success {
            return
        }

        if let closeButton = allDescendants(of: window).first(where: { element in
            let subrole = stringValue(of: kAXSubroleAttribute, from: element)?.lowercased() ?? ""
            let identifier = stringValue(of: kAXIdentifierAttribute, from: element)?.lowercased() ?? ""
            return subrole == "axclosebutton" || identifier.contains("close")
        }) {
            _ = pressElement(closeButton)
        }
    }

    private nonisolated func parentElement(of element: AXUIElement) -> AXUIElement? {
        guard let parentObject = copyAttribute(kAXParentAttribute, from: element) else {
            return nil
        }

        return unsafeBitCast(parentObject, to: AXUIElement.self)
    }

    private nonisolated func isToggleEnabled(_ element: AXUIElement) -> Bool {
        intValue(of: kAXValueAttribute, from: element) == 1
    }

    private nonisolated func copyAttribute(_ attribute: String, from element: AXUIElement) -> AnyObject? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success else {
            return nil
        }

        return value
    }

    private nonisolated func stringValue(of attribute: String, from element: AXUIElement) -> String? {
        if let string = copyAttribute(attribute, from: element) as? String {
            return string
        }

        if let number = copyAttribute(attribute, from: element) as? NSNumber {
            return number.stringValue
        }

        return nil
    }

    private nonisolated func intValue(of attribute: String, from element: AXUIElement) -> Int {
        if let number = copyAttribute(attribute, from: element) as? NSNumber {
            return number.intValue
        }

        if let string = copyAttribute(attribute, from: element) as? String {
            return Int(string) ?? 0
        }

        return 0
    }

    private nonisolated func cgRectValue(of attribute: String, from element: AXUIElement) -> CGRect? {
        guard let rawValue = copyAttribute(attribute, from: element) else {
            return nil
        }

        let axValue = unsafeBitCast(rawValue, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgRect else {
            return nil
        }

        var rect = CGRect.zero
        return AXValueGetValue(axValue, .cgRect, &rect) ? rect : nil
    }
}