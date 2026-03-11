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
    @Published private(set) var outputListStatus = "正在读取输出列表..."
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
    private let audioListenerQueue = DispatchQueue(label: "HomePodMonitor.AudioListener")
    private let menuInteractionResumeDelay: TimeInterval = 2.5
    private var automationTask: Task<Void, Never>?
    private var pendingResumeEvaluationTask: Task<Void, Never>?
    private var isSnapshotRefreshInFlight = false
    private var lastSelectedMenuOutputName: String?
    private var lastObservedSystemOutputName = ""
    private var lastSystemResumeDate = Date.distantPast
    private var workspaceObservers = Set<AnyCancellable>()
    private var distributedObservers = [NSObjectProtocol]()
    private let postWakeRetryDelays: [TimeInterval] = [3, 6, 12, 20, 35, 55, 80]
    private let postWakeShortRetryDelays: [TimeInterval] = [3, 6, 12, 20]
    private var lastSleepDate = Date.distantPast
    /// 睡眠超过此时长视为"长时间睡眠"，使用更激进的重试策略
    private let longSleepThreshold: TimeInterval = 120

    init() {
        preferredTargetName = Self.loadPreferredTargetName()
        refreshLaunchAtLoginState()
        startMonitoring()
    }

    func startMonitoring() {
        installWorkspaceObserversIfNeeded()
        installAudioListenersIfNeeded()
        evaluateAudioRoute(
            reason: "应用已启动",
            allowsMenuInteraction: canInteractWithSoundMenu,
            refreshSnapshotBeforeEvaluation: canInteractWithSoundMenu
        )

        monitorTimer?.invalidate()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: monitorInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                self.evaluateAudioRoute(
                    reason: "定时巡检",
                    allowsMenuInteraction: self.canInteractWithSoundMenu,
                    refreshSnapshotBeforeEvaluation: false
                )
            }
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

    func refreshAccessibilityStatus() {
        accessibilityEnabled = soundOutputAccessibility.isTrusted()
    }

    func requestAccessibilityPermission() {
        let alreadyEnabled = soundOutputAccessibility.isTrusted(prompt: true)
        refreshAccessibilityStatus()

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

    func refreshAvailableTargets() {
        refreshAccessibilityStatus()

        guard accessibilityEnabled else {
            availableTargets = []
            outputListStatus = "未开启辅助功能权限"
            return
        }

        outputListStatus = "正在读取输出列表..."
        beginSnapshotRefresh()
    }

    var preferredTargetDescription: String {
        preferredTargetName
    }

    private func evaluateAudioRoute(
        reason: String,
        forceSwitch: Bool = false,
        allowsMenuInteraction: Bool,
        refreshSnapshotBeforeEvaluation: Bool = true
    ) {
        refreshAccessibilityStatus()
        let menuInteractionAllowedNow = allowsMenuInteraction && canInteractWithSoundMenu

        let systemOutput = Self.currentOutputDeviceName()
        let preferredTargetName = preferredTargetName
        let outputChanged = systemOutput != lastObservedSystemOutputName
        lastObservedSystemOutputName = systemOutput

        if accessibilityEnabled,
           menuInteractionAllowedNow,
           refreshSnapshotBeforeEvaluation,
           automationTask == nil,
           !isSnapshotRefreshInFlight {
            beginSnapshotRefresh()
        }

        let resolvedOutput = resolvedCurrentOutputName(systemOutputName: systemOutput)
        currentOutputName = resolvedOutput
        isHomePodActive = Self.isPreferredTargetName(resolvedOutput, preferredName: preferredTargetName)

        guard forceSwitch || !isHomePodActive else {
            statusMessage = "当前输出已经是目标设备 \(resolvedOutput)"
            return
        }

        if !menuInteractionAllowedNow {
            let displayedOutput = currentOutputName
            if accessibilityEnabled, !canInteractWithSoundMenu {
                statusMessage = "系统刚恢复，等待声音菜单稳定后再检查 \(preferredTargetDescription)"
                schedulePostResumeEvaluationIfNeeded(trigger: reason)
            } else {
                statusMessage = outputChanged ? "当前输出已变为 \(displayedOutput)，等待系统事件或手动切换" : "当前输出不是目标设备 \(displayedOutput)"
            }
            return
        }

        guard accessibilityEnabled else {
            availableTargets = []
            outputListStatus = "未开启辅助功能权限"
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
                        self.outputListStatus = error.errorDescription ?? "读取输出列表失败"
                    }
                    self.statusMessage = error.errorDescription ?? "切换失败"
                }
            } catch {
                await MainActor.run {
                    self.automationTask = nil
                    self.outputListStatus = "读取输出列表失败: \(error.localizedDescription)"
                    self.statusMessage = "切换失败: \(error.localizedDescription)"
                }
            }
        }
    }

    private func beginSnapshotRefresh(visibleOnly: Bool = false) {
        guard !isSnapshotRefreshInFlight else {
            return
        }

        isSnapshotRefreshInFlight = true
        let soundOutputAccessibility = soundOutputAccessibility

        Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<SoundOutputSnapshot?, Error>

            do {
                if visibleOnly {
                    result = .success(try soundOutputAccessibility.readVisibleSnapshot())
                } else {
                    result = .success(try soundOutputAccessibility.readSnapshot())
                }
            } catch {
                result = .failure(error)
            }

            Task { @MainActor [weak self, result] in
                guard let self else {
                    return
                }

                self.isSnapshotRefreshInFlight = false

                switch result {
                case let .success(snapshot?):
                    let previousOutputName = self.currentOutputName
                    let previousIsHomePodActive = self.isHomePodActive
                    self.updateSnapshotCache(snapshot)
                    self.refreshResolvedOutputState()
                    self.reconcilePostSnapshotRefresh(
                        previousOutputName: previousOutputName,
                        previousIsHomePodActive: previousIsHomePodActive
                    )
                case .success(nil):
                    break
                case let .failure(error as SoundOutputAccessibilityError):
                    self.availableTargets = []
                    self.lastSelectedMenuOutputName = nil
                    self.outputListStatus = error.errorDescription ?? "读取输出列表失败"
                case let .failure(error):
                    self.availableTargets = []
                    self.lastSelectedMenuOutputName = nil
                    self.outputListStatus = "读取输出列表失败: \(error.localizedDescription)"
                }
            }
        }
    }

    private func updateSnapshotCache(_ snapshot: SoundOutputSnapshot) {
        availableTargets = snapshot.outputs
        lastSelectedMenuOutputName = snapshot.selectedOutput
        outputListStatus = snapshot.outputs.isEmpty ? "声音菜单里暂未发现可用输出" : "已读取到 \(snapshot.outputs.count) 个输出"
    }

    private func refreshResolvedOutputState() {
        let resolvedOutput = resolvedCurrentOutputName(systemOutputName: Self.currentOutputDeviceName())
        currentOutputName = resolvedOutput
        isHomePodActive = Self.isPreferredTargetName(resolvedOutput, preferredName: preferredTargetName)
    }

    private func reconcilePostSnapshotRefresh(
        previousOutputName: String,
        previousIsHomePodActive: Bool
    ) {
        guard accessibilityEnabled,
              canInteractWithSoundMenu,
              automationTask == nil,
              !isHomePodActive else {
            return
        }

        let outputChanged = previousOutputName.caseInsensitiveCompare(currentOutputName) != .orderedSame
        guard previousIsHomePodActive || outputChanged else {
            return
        }

        evaluateAudioRoute(
            reason: "声音菜单状态已刷新",
            allowsMenuInteraction: true,
            refreshSnapshotBeforeEvaluation: false
        )
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
                audioListenerQueue
            ) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self else {
                        return
                    }

                    self.evaluateAudioRoute(
                        reason: "系统音频设备发生变化",
                        allowsMenuInteraction: self.canInteractWithSoundMenu,
                        refreshSnapshotBeforeEvaluation: false
                    )
                }
            }
        }
    }

    private func installWorkspaceObserversIfNeeded() {
        guard workspaceObservers.isEmpty else {
            return
        }

        let notificationCenter = NSWorkspace.shared.notificationCenter
        let resumeNotifications = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification
        ]

        for notification in resumeNotifications {
            notificationCenter.publisher(for: notification)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    self?.handleSystemResume(trigger: notification.rawValue)
                }
                .store(in: &workspaceObservers)
        }

        // 记录系统进入睡眠的时间，用于区分长/短睡眠
        notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.lastSleepDate = Date()
            }
            .store(in: &workspaceObservers)

        // 监听屏幕解锁（用户输入密码后），此时 AirPlay 设备才真正开始重连
        if distributedObservers.isEmpty {
            let screenUnlockObserver = DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name("com.apple.screenIsUnlocked"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleScreenUnlock()
                }
            }
            distributedObservers.append(screenUnlockObserver)
        }
    }

    private var canInteractWithSoundMenu: Bool {
        Date().timeIntervalSince(lastSystemResumeDate) >= menuInteractionResumeDelay
    }

    private func handleSystemResume(trigger: String) {
        let now = Date()
        let sleepDuration = now.timeIntervalSince(lastSleepDate)
        let isLongSleep = sleepDuration >= longSleepThreshold
        lastSystemResumeDate = now
        pendingResumeEvaluationTask?.cancel()

        // 清除可能已过期的缓存状态，避免误判
        invalidateStaleCacheOnWake(isLongSleep: isLongSleep)

        // 长时间睡眠后 Timer 可能不再触发，重建定时器确保巡检恢复
        monitorTimer?.invalidate()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: monitorInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.evaluateAudioRoute(
                    reason: "定时巡检",
                    allowsMenuInteraction: self.canInteractWithSoundMenu,
                    refreshSnapshotBeforeEvaluation: false
                )
            }
        }

        evaluateAudioRoute(
            reason: isLongSleep ? "长时间睡眠后恢复" : "系统恢复",
            allowsMenuInteraction: false,
            refreshSnapshotBeforeEvaluation: false
        )

        schedulePostResumeRetries(trigger: trigger, extendedRetries: isLongSleep)
    }

    private func handleScreenUnlock() {
        let now = Date()
        let timeSinceResume = now.timeIntervalSince(lastSystemResumeDate)

        // 如果距离上次恢复事件很近（< 5s），说明唤醒重试已在进行，不重复
        guard timeSinceResume > 5 else { return }

        // 屏幕解锁是一个独立事件；重置恢复窗口，清除过期缓存
        lastSystemResumeDate = now
        invalidateStaleCacheOnWake(isLongSleep: true)

        schedulePostResumeRetries(trigger: "屏幕解锁", extendedRetries: true)
    }

    private func invalidateStaleCacheOnWake(isLongSleep: Bool) {
        // 长睡眠后 AirPlay 设备可能已断开，旧快照不再可信
        lastSelectedMenuOutputName = nil
        isHomePodActive = false

        if isLongSleep {
            availableTargets = []
            outputListStatus = "系统刚从睡眠恢复，等待重新读取..."
        }
    }

    private func schedulePostResumeEvaluationIfNeeded(trigger: String) {
        schedulePostResumeRetries(trigger: trigger, extendedRetries: false)
    }

    /// 唤醒后按渐进式延迟多次重试，覆盖 AirPlay/HomePod 缓慢重连的场景
    private func schedulePostResumeRetries(trigger: String, extendedRetries: Bool) {
        guard accessibilityEnabled else {
            return
        }

        let delays = extendedRetries ? postWakeRetryDelays : postWakeShortRetryDelays

        pendingResumeEvaluationTask?.cancel()
        pendingResumeEvaluationTask = Task { [weak self] in
            guard let self else { return }
            for delay in delays {
                let nanoseconds = UInt64(delay * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)

                guard !Task.isCancelled else { return }

                // 先强制从 CoreAudio 刷新当前输出，再判断是否已在目标设备上
                // 避免陈旧的 isHomePodActive 缓存导致跳过重试
                self.refreshResolvedOutputState()
                if self.isHomePodActive {
                    self.statusMessage = "已确认输出在目标设备 \(self.currentOutputName)"
                    return
                }

                self.evaluateAudioRoute(
                    reason: "\(trigger)后第\(Int(delay))s重试",
                    allowsMenuInteraction: true,
                    refreshSnapshotBeforeEvaluation: true
                )

                // 切换后等待短暂时间让系统生效，再进入下一轮检查
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
            }

            guard !Task.isCancelled else { return }
            self.pendingResumeEvaluationTask = nil
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

        var name: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &name) { namePointer in
            AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, namePointer)
        }

        guard status == noErr, let name else {
            return nil
        }

        return name as String
    }

}