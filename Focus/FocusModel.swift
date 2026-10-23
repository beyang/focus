//
//  FocusModel.swift
//  Focus
//

import Foundation
import Observation
import UserNotifications

struct ActiveTimer: Identifiable {
    let id: String
    let originalInput: String
    let endTime: Date
    let message: String?
}

@MainActor
@Observable
final class BrowserTab: Identifiable {
    let id = UUID()
    var urlString: String
    var url: URL
    var reloadToken = 0
    var title: String?

    init(url: URL) {
        self.url = url
        self.urlString = url.absoluteString
    }

    var displayTitle: String {
        if let title, !title.isEmpty {
            return title
        }
        return url.host() ?? url.absoluteString
    }
}

enum FocusTab: Hashable {
    case timers
    case browser(UUID)
}

/// State shared by the command bar and the tabbed content below it.
@MainActor
@Observable
final class FocusModel {
    static let defaultURL = URL(string: "https://www.google.com")!

    var browserTabs: [BrowserTab]
    var selectedTab: FocusTab
    var activeTimers: [ActiveTimer]
    var webVolume: Double {
        didSet { saveBrowserState() }
    }
    /// Error shown under the command bar.
    var errorMessage = ""

    @ObservationIgnored private let persistence = PersistenceController.shared
    @ObservationIgnored private var pruneTimer: Timer?

    init() {
        let state = persistence.loadBrowserState()
        let tabs = state.tabURLs.compactMap(URL.init(string:)).map(BrowserTab.init(url:))
        let initialTabs = tabs.isEmpty ? [BrowserTab(url: Self.defaultURL)] : tabs
        browserTabs = initialTabs
        selectedTab = .browser(initialTabs[0].id)
        webVolume = state.webVolume
        activeTimers = persistence.loadTimers()

        pruneTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pruneExpiredTimers()
            }
        }
    }

    // MARK: - Browser tabs

    func newTab(_ input: String = "") {
        let url: URL
        if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            url = Self.defaultURL
        } else if let parsed = Self.url(from: input) {
            url = parsed
        } else {
            errorMessage = "Invalid URL: '\(input)'"
            return
        }

        let tab = BrowserTab(url: url)
        browserTabs.append(tab)
        selectedTab = .browser(tab.id)
        saveBrowserState()
    }

    func closeTab(_ id: UUID) {
        guard browserTabs.count > 1, let index = browserTabs.firstIndex(where: { $0.id == id }) else {
            return
        }

        browserTabs.remove(at: index)
        if selectedTab == .browser(id) {
            selectedTab = .browser(browserTabs[min(index, browserTabs.count - 1)].id)
        }
        saveBrowserState()
    }

    func navigate(_ tab: BrowserTab) {
        var processedURL = tab.urlString.trimmingCharacters(in: .whitespacesAndNewlines)

        // Add https:// if no scheme is provided, and show the complete URL.
        if !processedURL.contains("://") {
            processedURL = "https://" + processedURL
            tab.urlString = processedURL
        }

        if let url = URL(string: processedURL) {
            if tab.url.absoluteString == url.absoluteString {
                tab.reloadToken += 1
            } else {
                tab.url = url
            }
        }
        saveBrowserState()
    }

    private static func url(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: trimmed.contains("://") ? trimmed : "https://" + trimmed)
    }

    private func saveBrowserState() {
        persistence.saveBrowserState(tabURLs: browserTabs.map(\.url.absoluteString), webVolume: webVolume)
    }

    // MARK: - Notifications and timers

    func requestNotificationPermission() {
        Task {
            _ = await notificationsAllowed()
        }
    }

    func notify(_ message: String) {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            errorMessage = "notify command requires a message"
            return
        }

        let content = UNMutableNotificationContent()
        content.title = message
        content.body = "Triggered from Focus command bar"
        content.sound = UNNotificationSound.default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)

        Task {
            guard await notificationsAllowed() else { return }
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                print("Notification error: \(error)")
            }
        }
    }

    func addTimer(_ arguments: String) {
        let components = arguments.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let timeComponent = components.first else {
            errorMessage = "timer command requires a time specification"
            return
        }

        let timeString = String(timeComponent)
        let message = components.count > 1 ? String(components[1]) : nil
        guard let timeInterval = Self.parseTimeString(timeString) else {
            errorMessage = "Invalid time format. Use: 5s, 5m, 5h, 8:00, 16:00, 5pm, or 4:30pm"
            return
        }

        scheduleTimer(timeInterval: timeInterval, originalInput: timeString, message: message)
    }

    func cancelTimer(_ timer: ActiveTimer) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [timer.id])
        activeTimers.removeAll { $0.id == timer.id }
        persistence.saveTimers(activeTimers)
    }

    private func notificationsAllowed() async -> Bool {
        let center = UNUserNotificationCenter.current()

        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                print("Notification permission granted: \(granted)")
                return granted
            } catch {
                print("Notification permission error: \(error)")
                return false
            }
        case .denied:
            errorMessage = "Notifications are disabled for Focus. Enable notifications in System Settings to use timer/notify commands."
            return false
        @unknown default:
            return false
        }
    }

    private func scheduleTimer(timeInterval: TimeInterval, originalInput: String, message: String?) {
        guard timeInterval >= 1 else {
            errorMessage = "Timer must be at least 1 second"
            return
        }

        let timerId = UUID().uuidString
        let content = UNMutableNotificationContent()
        content.title = "Timer"
        if let message, !message.isEmpty {
            content.body = "\(message) (Timer: \(originalInput))"
        } else {
            content.body = "Timer set for \(originalInput) has finished!"
        }
        content.sound = UNNotificationSound.default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: timeInterval, repeats: false)
        let request = UNNotificationRequest(identifier: timerId, content: content, trigger: trigger)

        Task {
            guard await notificationsAllowed() else { return }
            do {
                try await UNUserNotificationCenter.current().add(request)
                let endTime = Date().addingTimeInterval(timeInterval)
                activeTimers.append(ActiveTimer(id: timerId, originalInput: originalInput, endTime: endTime, message: message))
                persistence.saveTimers(activeTimers)
                print("Timer scheduled for \(timeInterval) seconds")
            } catch {
                let nsError = error as NSError
                if nsError.domain == UNErrorDomain && nsError.code == UNError.Code.notificationsNotAllowed.rawValue {
                    errorMessage = "Notifications are disabled for Focus. Enable notifications in System Settings to use timers."
                } else {
                    errorMessage = "Failed to schedule timer: \(error.localizedDescription)"
                }
            }
        }
    }

    private func pruneExpiredTimers() {
        let now = Date()
        guard activeTimers.contains(where: { $0.endTime <= now }) else { return }
        activeTimers.removeAll { $0.endTime <= now }
        persistence.saveTimers(activeTimers)
    }

    private static func parseTimeString(_ timeString: String) -> TimeInterval? {
        let input = timeString.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Handle duration formats (5s, 5m, 5h)
        if input.hasSuffix("s") {
            if let seconds = Double(String(input.dropLast())) {
                return seconds
            }
        } else if input.hasSuffix("m") {
            if let minutes = Double(String(input.dropLast())) {
                return minutes * 60
            }
        } else if input.hasSuffix("h") {
            if let hours = Double(String(input.dropLast())) {
                return hours * 3600
            }
        }

        // Handle absolute time formats (8:00, 16:00, 5pm)
        let now = Date()
        let calendar = Calendar.current

        // Handle PM times (5pm, 12pm, 4:30pm, 12:15pm)
        if input.hasSuffix("pm") {
            let timeStr = String(input.dropLast(2))
            if timeStr.contains(":") {
                let components = timeStr.split(separator: ":")
                if components.count == 2,
                   let hour = Int(components[0]),
                   let minute = Int(components[1]) {
                    let adjustedHour = hour == 12 ? 12 : hour + 12
                    if let targetDate = calendar.date(bySettingHour: adjustedHour, minute: minute, second: 0, of: now) {
                        let interval = targetDate.timeIntervalSince(now)
                        return interval > 0 ? interval : interval + 24 * 3600 // Next day if time has passed
                    }
                }
            } else if let hour = Int(timeStr) {
                let adjustedHour = hour == 12 ? 12 : hour + 12
                if let targetDate = calendar.date(bySettingHour: adjustedHour, minute: 0, second: 0, of: now) {
                    let interval = targetDate.timeIntervalSince(now)
                    return interval > 0 ? interval : interval + 24 * 3600 // Next day if time has passed
                }
            }
        }

        // Handle AM times (5am, 12am, 8:15am, 12:30am)
        if input.hasSuffix("am") {
            let timeStr = String(input.dropLast(2))
            if timeStr.contains(":") {
                let components = timeStr.split(separator: ":")
                if components.count == 2,
                   let hour = Int(components[0]),
                   let minute = Int(components[1]) {
                    let adjustedHour = hour == 12 ? 0 : hour
                    if let targetDate = calendar.date(bySettingHour: adjustedHour, minute: minute, second: 0, of: now) {
                        let interval = targetDate.timeIntervalSince(now)
                        return interval > 0 ? interval : interval + 24 * 3600 // Next day if time has passed
                    }
                }
            } else if let hour = Int(timeStr) {
                let adjustedHour = hour == 12 ? 0 : hour
                if let targetDate = calendar.date(bySettingHour: adjustedHour, minute: 0, second: 0, of: now) {
                    let interval = targetDate.timeIntervalSince(now)
                    return interval > 0 ? interval : interval + 24 * 3600 // Next day if time has passed
                }
            }
        }

        // Handle 24-hour format (8:00, 16:30)
        if input.contains(":") {
            let components = input.split(separator: ":")
            if components.count == 2,
               let hour = Int(components[0]),
               let minute = Int(components[1]) {
                if let targetDate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) {
                    let interval = targetDate.timeIntervalSince(now)
                    return interval > 0 ? interval : interval + 24 * 3600 // Next day if time has passed
                }
            }
        }

        return nil
    }
}
