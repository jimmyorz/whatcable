import Foundation
import Combine
import UserNotifications
import os.log
import WhatCableCore

/// Posts user notifications when USB-C cables / power sources connect or
/// disconnect, gated by the user's `AppSettings.notifyOnChanges` preference.
@MainActor
final class NotificationManager {
    static let shared = NotificationManager()

    private nonisolated static let log = Logger(subsystem: "uk.whatcable.whatcable", category: "notifications")

    private var cancellables = Set<AnyCancellable>()

    private var knownDeviceIDs: Set<UInt64> = []
    private var knownChargerPortKeys: Set<String> = []
    private var didPrimeBaseline = false

    private init() {}

    func start() {
        // Prime baseline on the next runloop tick so we don't fire a flurry
        // of "connected" notifications for things already plugged in at launch.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.knownDeviceIDs = Set(WatcherHub.shared.deviceWatcher.devices.map(\.id))
            self.knownChargerPortKeys = Set(WatcherHub.shared.powerWatcher.sources.map(\.portKey))
            self.didPrimeBaseline = true
        }

        WatcherHub.shared.deviceWatcher.$devices
            .sink { [weak self] devices in self?.diffDevices(devices) }
            .store(in: &cancellables)

        WatcherHub.shared.powerWatcher.$sources
            .sink { [weak self] sources in self?.diffSources(sources) }
            .store(in: &cancellables)
    }

    /// Request notification permission. Call when the user enables the toggle.
    func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error {
                        Self.log.error("Notification auth failed: \(error.localizedDescription, privacy: .public)")
                    } else {
                        Self.log.info("Notification auth granted: \(granted)")
                    }
                }
            default:
                break
            }
        }
    }

    private func diffDevices(_ current: [USBDevice]) {
        guard didPrimeBaseline else { return }
        let currentIDs = Set(current.map(\.id))
        let added = current.filter { !knownDeviceIDs.contains($0.id) }
        let removedCount = knownDeviceIDs.subtracting(currentIDs).count
        knownDeviceIDs = currentIDs

        guard AppSettings.shared.notifyOnChanges else { return }

        for device in added {
            let name = device.productName ?? String(localized: "USB device", bundle: _appLocalizedBundle)
            postNotification(
                title: String(localized: "Connected: \(name)", bundle: _appLocalizedBundle),
                body: "\(device.speedLabel)\(device.vendorName.map { " · \($0)" } ?? "")"
            )
        }
        if removedCount > 0 {
            postNotification(
                title: String(localized: "USB device disconnected", bundle: _appLocalizedBundle),
                body: String(localized: "\(removedCount) devices removed", bundle: _appLocalizedBundle)
            )
        }
    }

    private func diffSources(_ current: [PowerSource]) {
        guard didPrimeBaseline else { return }
        // Notify once per charger, i.e. once per port. A single charger
        // advertises several power-source entries on the same port (USB-PD,
        // Brick ID, TypeC), so keying on the port collapses them into one
        // notification instead of one per entry (#227 follow-up). Keying on
        // the port (not the volatile registry id, and not port+name) also
        // means a recycled or renegotiating charger does not re-fire.
        let currentPortKeys = Set(current.map(\.portKey))
        let addedPortKeys = currentPortKeys.subtracting(knownChargerPortKeys)
        let removedPortKeys = knownChargerPortKeys.subtracting(currentPortKeys)
        knownChargerPortKeys = currentPortKeys

        guard AppSettings.shared.notifyOnChanges else { return }

        for portKey in addedPortKeys {
            let portSources = current.filter { $0.portKey == portKey }
            let preferred = PowerSource.preferredChargingSource(in: portSources) ?? portSources.first
            let body = preferred?.winning.map { String(localized: "\($0.wattsLabel) negotiated", bundle: _appLocalizedBundle) }
                ?? String(localized: "PD source", bundle: _appLocalizedBundle)
            postNotification(title: String(localized: "Charger connected", bundle: _appLocalizedBundle), body: body)
        }
        for _ in removedPortKeys {
            postNotification(title: String(localized: "Charger disconnected", bundle: _appLocalizedBundle), body: "")
        }
    }

    private func postNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        if !body.isEmpty { content.body = body }
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Self.log.error("Post failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

