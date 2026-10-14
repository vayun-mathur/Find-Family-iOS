import SwiftUI
import UIKit
import CoreLocation
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate {
    var isLaunchedFromLocationEvent = false

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        isLaunchedFromLocationEvent = launchOptions?[.location] != nil
        UIDevice.current.isBatteryMonitoringEnabled = true

        // Request notification permission early (best-effort).
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }

        Task { @MainActor in
            // Kick off the network / identity layer.
            await Networking.shared.start()
            // Begin location updates — this is the iOS analog of LocationTrackingService on Android.
            LocationsHandler.shared.startLocationUpdates()
            // Publish latest-location snapshots into the shared App Group container
            // for sibling extensions/apps (mirrors Android FamilyLocationService).
            // No-op without the matching provisioning profile (see .entitlements).
            FamilyLocationBridge.start()
        }
        return true
    }
}
