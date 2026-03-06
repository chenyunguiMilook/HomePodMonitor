//
//  AudioDeviceController.swift
//  HomePodMonitor
//
//  Created by GitHub Copilot on 2026/3/6.
//

import Combine
import AppKit
import CoreAudio
import Foundation
import ServiceManagement

@MainActor
final class AudioDeviceController: ObservableObject {
    private static let defaultPreferredTargetName = "家庭影院"
    private static let preferredTargetDefaultsKey = "preferredTargetName"

    @Published private(set) var currentOutputName = "未检测到输出设备"
    @Published private(set) var availableTargets: [String] = []
    @Published private(set) var isHomePodActive = false
    @Published private(set) var statusMessage = "正在初始化..."
    @Published private(set) var accessibilityEnabled = false
    @Published private(set) var preferredTargetName: String
    @Published var launchAtLoginEnabled = false

    private let monitorInterval: TimeInterval = 8
    private var monitorTimer: Timer?
    private var hasInstalledListeners = false
    private var lastAttemptDate = Date.distantPast
    private let switchCooldown: TimeInterval = 10
    private let soundOutputAccessibility = SoundOutputAccessibility()
    private let userDefaults = UserDefaults.standard
    private var automationTask: Task<Void, Never>?
    private var lastSelectedMenuOutputName: String?
    private var lastObservedSystemOutputName = ""

    init() {
        preferredTargetName = Self.loadPreferredTargetName()
        refreshLaunchAtLoginState()
        startMonitoring()
    }

    func startMonitoring() {
        installAudioListenersIfNeeded()
        evaluateAudioRoute(reason: "应用已启动", allowsMenuInteraction: true)

        monitorTimer?.invalidate()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: monitorInterval, repeats: true) { [weak self] _ in
            self?.evaluateAudioRoute(reason: "定时巡检", allowsMenuInteraction: false)
        }
    }

    func forceSwitchToHomePod() {
        evaluateAudioRoute(reason: "用户手动触发", forceSwitch: true, allowsMenuInteraction: true)
    }

    func setPreferredTarget(named name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return
        }

        preferredTargetName = trimmedName
        userDefaults.set(trimmedName, forKey: Self.preferredTargetDefaultsKey)
        lastSelectedMenuOutputName = nil
        isHomePodActive = Self.isPreferredTargetName(currentOutputName, preferredName: trimmedName)
        statusMessage = "已将 \(trimmedName) 设为默认检测设备"
    }

    func setPreferredTargetAndSwitch(named name: String) {
        setPreferredTarget(named: name)
        evaluateAudioRoute(reason: "用户更新默认输出", forceSwitch: true, allowsMenuInteraction: true)
    }

    func setLaunchAtLogin(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }

            refreshLaunchAtLoginState()
            statusMessage = enabled ? "已开启开机启动" : "已关闭开机启动"
        } catch {
            refreshLaunchAtLoginState()
            statusMessage = "更新开机启动失败: \(error.localizedDescription)"
        }
    }

    func refreshLaunchAtLoginState() {
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    func requestAccessibilityPermission() {
        let alreadyEnabled = soundOutputAccessibility.isTrusted(prompt: true)
        accessibilityEnabled = alreadyEnabled

        if alreadyEnabled {
            statusMessage = "辅助功能权限已开启"
        } else {
            statusMessage = "请在系统设置中为 HomePodMonitor 开启辅助功能权限"
        }
    }

    func openAccessibilitySettings() {
        if soundOutputAccessibility.openAccessibilitySettings() {
            statusMessage = "已打开系统设置，请在“隐私与安全性 > 辅助功能”中启用 HomePodMonitor"
        } else {
            statusMessage = "无法打开辅助功能设置，请手动前往“系统设置 > 隐私与安全性 > 辅助功能”"
        }
    }

    var preferredTargetDescription: String {
        preferredTargetName
    }

    private func evaluateAudioRoute(reason: String, forceSwitch: Bool = false, allowsMenuInteraction: Bool) {
        accessibilityEnabled = soundOutputAccessibility.isTrusted()

        let systemOutput = Self.currentOutputDeviceName()
        let preferredTargetName = preferredTargetName
        let outputChanged = systemOutput != lastObservedSystemOutputName
        lastObservedSystemOutputName = systemOutput

        if accessibilityEnabled,
           allowsMenuInteraction,
           automationTask == nil {
            refreshOutputSnapshotCache()
        }

        let resolvedOutput = resolvedCurrentOutputName(systemOutputName: systemOutput)
        currentOutputName = resolvedOutput
        isHomePodActive = Self.isPreferredTargetName(resolvedOutput, preferredName: preferredTargetName)

        guard forceSwitch || !isHomePodActive else {
            statusMessage = "当前输出已经是目标设备 \(resolvedOutput)"
            return
        }

        if !allowsMenuInteraction {
            updateAvailableTargetsFromVisibleSnapshotIfNeeded()
            let displayedOutput = currentOutputName
            statusMessage = outputChanged ? "当前输出已变为 \(displayedOutput)，等待系统事件或手动切换" : "当前输出不是目标设备 \(displayedOutput)"
            return
        }

        guard accessibilityEnabled else {
            statusMessage = "需要开启辅助功能权限后，才能自动切换到 \(preferredTargetDescription)"
            return
        }

        let now = Date()
        if automationTask != nil {
            statusMessage = "正在检查声音输出列表..."
            return
        }

        if !forceSwitch, now.timeIntervalSince(lastAttemptDate) < switchCooldown {
            statusMessage = "等待下一次切换重试..."
            return
        }

        lastAttemptDate = now
        statusMessage = "正在尝试切换到 \(preferredTargetDescription)..."

        automationTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else {
                return
            }

            do {
                let snapshot = try self.soundOutputAccessibility.ensurePreferredOutputSelected(
                    preferredNames: [preferredTargetName]
                )

                await MainActor.run {
                    self.automationTask = nil
                    self.updateSnapshotCache(snapshot)

                    if let selectedOutput = snapshot.selectedOutput,
                       Self.isPreferredTargetName(selectedOutput, preferredName: preferredTargetName) {
                        self.currentOutputName = selectedOutput
                        self.isHomePodActive = true
                        self.statusMessage = "已切换到 \(selectedOutput) · \(reason)"
                    } else {
                        self.isHomePodActive = false
                        self.statusMessage = "已发起切换，但系统尚未确认目标输出"
                    }
                }
            } catch let error as SoundOutputAccessibilityError {
                let snapshot = try? self.soundOutputAccessibility.readSnapshot()

                await MainActor.run {
                    self.automationTask = nil
                    if let snapshot {
                        self.updateSnapshotCache(snapshot)
                    } else {
                        self.lastSelectedMenuOutputName = nil
                        self.availableTargets = []
                    }
                    self.statusMessage = error.errorDescription ?? "切换失败"
                }
            } catch {
                await MainActor.run {
                    self.automationTask = nil
                    self.statusMessage = "切换失败: \(error.localizedDescription)"
                }
            }
        }
    }

    private func updateAvailableTargetsFromVisibleSnapshotIfNeeded() {
        guard accessibilityEnabled else {
            return
        }

        guard automationTask == nil else {
            return
        }

        if let snapshot = try? soundOutputAccessibility.readVisibleSnapshot() {
            updateSnapshotCache(snapshot)
        }
    }

    private func refreshOutputSnapshotCache() {
        guard let snapshot = try? soundOutputAccessibility.readSnapshot() else {
            return
        }

        updateSnapshotCache(snapshot)
    }

    private func updateSnapshotCache(_ snapshot: SoundOutputSnapshot) {
        availableTargets = snapshot.outputs
        lastSelectedMenuOutputName = snapshot.selectedOutput
    }

    private func resolvedCurrentOutputName(systemOutputName: String) -> String {
        let normalizedSystemOutput = systemOutputName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSystemOutput.isEmpty else {
            return lastSelectedMenuOutputName ?? systemOutputName
        }

        if availableTargets.contains(where: { $0.caseInsensitiveCompare(normalizedSystemOutput) == .orderedSame }) {
            return normalizedSystemOutput
        }

        if let lastSelectedMenuOutputName,
           !lastSelectedMenuOutputName.isEmpty {
            return lastSelectedMenuOutputName
        }

        return normalizedSystemOutput
    }

    private func installAudioListenersIfNeeded() {
        guard !hasInstalledListeners else {
            return
        }

        hasInstalledListeners = true

        let properties = [
            AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        ]

        for property in properties {
            var property = property
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &property,
                .main
            ) { [weak self] _, _ in
                self?.evaluateAudioRoute(reason: "系统音频设备发生变化", allowsMenuInteraction: true)
            }
        }
    }

    private static func isPreferredTargetName(_ name: String, preferredName: String) -> Bool {
        preferredName.caseInsensitiveCompare(name) == .orderedSame
    }

    private static func loadPreferredTargetName() -> String {
        let storedName = UserDefaults.standard.string(forKey: preferredTargetDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let storedName, !storedName.isEmpty {
            return storedName
        }

        return defaultPreferredTargetName
    }

    private static func fetchOutputDevices() -> [(id: AudioDeviceID, name: String)] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )

        guard status == noErr else {
            return []
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = Array(repeating: AudioDeviceID(0), count: deviceCount)

        let readStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )

        guard readStatus == noErr else {
            return []
        }

        return deviceIDs.compactMap { deviceID in
            guard hasOutputStreams(deviceID), let name = deviceName(for: deviceID) else {
                return nil
            }

            return (id: deviceID, name: name)
        }
    }

    private static func currentOutputDeviceName() -> String {
        let outputDevices = fetchOutputDevices().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let currentOutputID = defaultOutputDeviceID()
        return outputDevices.first(where: { $0.id == currentOutputID })?.name ?? deviceName(for: currentOutputID) ?? "未检测到输出设备"
    }

    private static func hasOutputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize)
        guard status == noErr else {
            return false
        }

        return Int(dataSize) / MemoryLayout<AudioStreamID>.size > 0
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        return status == noErr ? deviceID : AudioDeviceID(0)
    }

    private static func deviceName(for deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var name: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &name)
        guard status == noErr else {
            return nil
        }

        return name as String
    }

}