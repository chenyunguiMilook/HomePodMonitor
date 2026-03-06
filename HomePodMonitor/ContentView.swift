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
                Text("当前输出")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(controller.currentOutputName)
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("声音菜单中的可用输出")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if controller.availableTargets.isEmpty {
                    Text(controller.accessibilityEnabled ? "暂未读取到输出列表" : "未开启辅助功能权限")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(controller.availableTargets, id: \.self) { target in
                        Text(target)
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

            Button("立即切换到目标设备") {
                controller.forceSwitchToHomePod()
            }
            .disabled(!controller.accessibilityEnabled)

            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

#Preview {
    ContentView(controller: AudioDeviceController())
}
