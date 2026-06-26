//
//  MemoryPressureMonitor.swift
//  LocalMind
//

import Foundation
import UserNotifications

@Observable
final class MemoryPressureMonitor {
    static let shared = MemoryPressureMonitor()

    private(set) var isUnderPressure = false
    private var source: DispatchSourceMemoryPressure?

    private init() {
        requestNotificationPermission()
        startMonitoring()
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func startMonitoring() {
        source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )

        source?.setEventHandler { [weak self] in
            guard let self else { return }
            let event = self.source?.data ?? []

            if event.contains(.critical) {
                self.isUnderPressure = true
                self.sendNotification(
                    title: "LocalMind — High Memory Usage",
                    body: "System memory is critically low. Background AI polling has been paused to reduce resource usage."
                )
            } else if event.contains(.warning) {
                self.isUnderPressure = true
                self.sendNotification(
                    title: "LocalMind — Memory Warning",
                    body: "System memory is getting low. Consider closing unused conversations or other apps."
                )
            }
        }

        source?.setCancelHandler { [weak self] in
            self?.isUnderPressure = false
        }

        source?.resume()
    }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "memory-pressure-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    deinit {
        source?.cancel()
    }
}
