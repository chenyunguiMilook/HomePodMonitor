//
//  HomePodMonitorApp.swift
//  HomePodMonitor
//
//  Created by chenyungui on 2026/3/6.
//

import SwiftUI

@main
struct HomePodMonitorApp: App {
    @StateObject private var controller = AudioDeviceController()

    var body: some Scene {
        MenuBarExtra {
            ContentView(controller: controller)
        } label: {
            Label(
                "HomePod Monitor",
                systemImage: controller.isHomePodActive ? "homepod.fill" : "homepod"
            )
        }
        .menuBarExtraStyle(.window)
    }
}
