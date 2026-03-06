//
//  ContentView.swift
//  HomePodMonitor
//
//  Created by chenyungui on 2026/3/6.
//

import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var controller: AudioDeviceController
    @State private var hoveredTarget: String?

    private func isCurrentOutput(_ target: String) -> Bool {
        controller.currentOutputName.caseInsensitiveCompare(target) == .orderedSame
    }

    private func isPreferredTarget(_ target: String) -> Bool {
        controller.preferredTargetName.caseInsensitiveCompare(target) == .orderedSame
    }

    private func isOutputTarget(_ target: String) -> Bool {
        controller.availableTargets.contains { candidate in
            candidate.caseInsensitiveCompare(target) == .orderedSame
        }
    }

    private func iconColor(_ target: String) -> Color {
        isCurrentOutput(target) ? .primary : .secondary
    }

    private func targetColor(_ target: String) -> Color {
        guard isOutputTarget(target) else {
            return iconColor(target)
        }

        if isPreferredTarget(target) {
            return .green
        }

        if isCurrentOutput(target) {
            return .blue
        }

        return iconColor(target)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                controller.isHomePodActive ? "当前输出为目标设备" : "当前输出不是目标设备",
                systemImage: controller.isHomePodActive ? "checkmark.circle.fill" : "speaker.slash.fill"
            )
            .foregroundStyle(controller.isHomePodActive ? .green : .orange)

            Text("目标设备：\(controller.preferredTargetDescription)")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("声音菜单中的可用输出")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if controller.availableTargets.isEmpty {
                    Text(controller.accessibilityEnabled ? "暂未读取到输出列表" : "未开启辅助功能权限")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(controller.availableTargets, id: \.self) { target in
                        HStack(spacing: 10) {
                            Image(systemName: isCurrentOutput(target) ? "checkmark" : "speaker.wave.2.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(iconColor(target))
                                .frame(width: 14)

                            Text(target)
                                .lineLimit(1)
                                .foregroundStyle(targetColor(target))

                            Spacer(minLength: 8)

                            if isPreferredTarget(target) {
                                Text("默认输出")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            } else if hoveredTarget == target {
                                Button("设为默认输出") {
                                    controller.setPreferredTargetAndSwitch(named: target)
                                }
                                .buttonStyle(.borderless)
                                .font(.caption)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(isCurrentOutput(target) ? Color.primary.opacity(0.12) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .onHover { isHovering in
                            if isHovering {
                                hoveredTarget = target
                            } else if hoveredTarget == target {
                                hoveredTarget = nil
                            }
                        }
                    }
                }
            }

            Text(controller.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)

            if !controller.accessibilityEnabled {
                Text("要自动切换家庭影院，请到“系统设置 > 隐私与安全性 > 辅助功能”里打开 HomePodMonitor。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button("打开辅助功能设置") {
                        controller.openAccessibilitySettings()
                    }

                    Button("请求权限") {
                        controller.requestAccessibilityPermission()
                    }
                }
            }

            Divider()

            Toggle(
                "开机启动",
                isOn: Binding(
                    get: { controller.launchAtLoginEnabled },
                    set: { controller.setLaunchAtLogin(enabled: $0) }
                )
            )

            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}

#Preview {
    ContentView(controller: AudioDeviceController())
}
