//
//  FocusApp.swift
//  Focus
//
//  Created by Beyang Liu on 7/19/25.
//

import SwiftUI
import AppKit
import CoreData
import Carbon.HIToolbox
import Combine
import UserNotifications

extension Notification.Name {
    static let spotlightPanelDidShow = Notification.Name("spotlightPanelDidShow")
}

final class SpotlightPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum CommandArguments {
    case none
    case optional(String)
    case required(String)
}

struct SpotlightCommand: Identifiable {
    let id = UUID()
    let name: String
    var aliases: [String] = []
    var arguments: CommandArguments = .none
    let summary: String
    var hidesPanel = false
    let action: (String) -> Void

    var searchableTerms: [String] {
        [name] + aliases
    }

    var usage: String {
        switch arguments {
        case .none:
            return name
        case .optional(let hint), .required(let hint):
            return "\(name) \(hint)"
        }
    }
}

final class CommandRegistry {
    private(set) var commands: [SpotlightCommand] = []

    func register(_ command: SpotlightCommand) {
        commands.append(command)
    }

    /// Finds a command typed by name and followed by its arguments, such as "timer 5m tea".
    func invocation(for input: String) -> (command: SpotlightCommand, arguments: String)? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()

        for command in commands {
            if case .none = command.arguments { continue }
            for term in command.searchableTerms.map({ $0.lowercased() })
            where lowercased == term || lowercased.hasPrefix(term + " ") {
                let arguments = String(trimmed.dropFirst(term.count)).trimmingCharacters(in: .whitespaces)
                return (command, arguments)
            }
        }
        return nil
    }

    func matchingCommands(for input: String) -> [SpotlightCommand] {
        let query = normalize(input)
        return commands
            .compactMap { command -> (SpotlightCommand, Int)? in
                let bestScore = command.searchableTerms
                    .compactMap { fuzzyScore(query: query, candidate: normalize($0)) }
                    .max()

                guard let bestScore, bestScore > 0 else {
                    return nil
                }

                return (command, bestScore)
            }
            .sorted { lhs, rhs in
                lhs.1 == rhs.1 ? lhs.0.name < rhs.0.name : lhs.1 > rhs.1
            }
            .map(\.0)
    }

    private func normalize(_ input: String) -> String {
        input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func fuzzyScore(query: String, candidate: String) -> Int? {
        guard !query.isEmpty, !candidate.isEmpty else {
            return nil
        }

        let queryChars = Array(query)
        let candidateChars = Array(candidate)
        var queryIndex = 0
        var candidateIndex = 0
        var score = 0
        var previousMatchIndex: Int?

        while queryIndex < queryChars.count {
            let target = queryChars[queryIndex]
            var foundIndex: Int?

            while candidateIndex < candidateChars.count {
                if candidateChars[candidateIndex] == target {
                    foundIndex = candidateIndex
                    candidateIndex += 1
                    break
                }
                candidateIndex += 1
            }

            guard let matchIndex = foundIndex else {
                return nil
            }

            score += 10

            if let previousMatchIndex {
                if matchIndex == previousMatchIndex + 1 {
                    score += 7
                } else {
                    score -= (matchIndex - previousMatchIndex - 1)
                }
            }

            if matchIndex == 0 {
                score += 6
            } else {
                let previousChar = candidateChars[matchIndex - 1]
                if previousChar == " " || previousChar == "-" || previousChar == "_" {
                    score += 4
                }
            }

            previousMatchIndex = matchIndex
            queryIndex += 1
        }

        score -= max(0, candidateChars.count - queryChars.count)
        return score
    }
}

struct SpotlightPanelContentView: View {
    @Environment(FocusModel.self) private var model
    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var commandFieldFocused: Bool

    let registry: CommandRegistry
    let onExecute: (SpotlightCommand, String) -> Void

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleCommands: [SpotlightCommand] {
        if trimmedQuery == "?" {
            return registry.commands
        }
        if let invocation = registry.invocation(for: trimmedQuery) {
            return [invocation.command]
        }
        return Array(registry.matchingCommands(for: trimmedQuery).prefix(6))
    }

    private var selectedCommand: SpotlightCommand? {
        guard !visibleCommands.isEmpty else { return nil }
        let safeIndex = min(max(selectedIndex, 0), visibleCommands.count - 1)
        return visibleCommands[safeIndex]
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Type a command, or ? for help", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.black.opacity(0.08))
                    )
                    .focused($commandFieldFocused)
                    .onSubmit {
                        submit()
                    }
                    .onChange(of: query) {
                        selectedIndex = 0
                        model.errorMessage = ""
                    }
                    .onKeyPress(.upArrow) {
                        guard !visibleCommands.isEmpty else { return .handled }
                        selectedIndex = max(selectedIndex - 1, 0)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        guard !visibleCommands.isEmpty else { return .handled }
                        selectedIndex = min(selectedIndex + 1, visibleCommands.count - 1)
                        return .handled
                    }

                if !model.errorMessage.isEmpty {
                    Text(model.errorMessage)
                        .foregroundColor(.red)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(4)
                }

                if !visibleCommands.isEmpty {
                    suggestionList
                }
            }
            .padding(12)

            Divider()

            ContentView()
        }
        // The command bar plus 1000pt of tab content. Suggestions and errors shrink the tab
        // content instead of growing the panel.
        .frame(minWidth: 1400, minHeight: 1065)
        .onAppear {
            commandFieldFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .spotlightPanelDidShow)) { _ in
            DispatchQueue.main.async {
                commandFieldFocused = true
            }
        }
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(visibleCommands.enumerated()), id: \.element.id) { index, command in
                let isSelected = index == selectedIndex
                HStack(spacing: 12) {
                    Text(command.usage)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)

                    Spacer()

                    Text(command.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isSelected ? Color.accentColor : Color.black.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedIndex = index
                    submit()
                }
            }
        }
    }

    private func submit() {
        if let invocation = registry.invocation(for: trimmedQuery) {
            run(invocation.command, arguments: invocation.arguments)
        } else if let selectedCommand {
            run(selectedCommand, arguments: "")
        } else if !trimmedQuery.isEmpty {
            model.errorMessage = "Unknown command: '\(trimmedQuery.split(separator: " ").first ?? "")'. Type ? to see all commands."
        }
    }

    private func run(_ command: SpotlightCommand, arguments: String) {
        if case .required = command.arguments, arguments.isEmpty {
            // Complete the command name so the user can type its arguments.
            query = command.name + " "
            commandFieldFocused = true
            return
        }

        model.errorMessage = ""
        onExecute(command, arguments)
        if model.errorMessage.isEmpty {
            query = ""
            selectedIndex = 0
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var hotKeyRef: EventHotKeyRef?
    private var spotlightPanel: SpotlightPanel?
    private let commandRegistry = CommandRegistry()
    private lazy var model = FocusModel()
    static var shared: AppDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppDelegate.shared = self
        UNUserNotificationCenter.current().delegate = self
        registerCommands()
        registerGlobalHotKey()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
    }
    
    func registerGlobalHotKey() {
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x464F4355) // "FOCU"
        hotKeyID.id = 1
        
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        
        let handler: EventHandlerUPP = { _, event, _ -> OSStatus in
            print("[Focus] Hotkey pressed!")
            DispatchQueue.main.async {
                AppDelegate.shared?.toggleSpotlightInput()
            }
            return noErr
        }
        
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, nil, nil)
        print("[Focus] InstallEventHandler status: \(installStatus)")
        
        // Ctrl+Shift+Space: kVK_Space = 49, controlKey = 4096, shiftKey = 512
        let modifiers: UInt32 = UInt32(controlKey | shiftKey)
        let registerStatus = RegisterEventHotKey(UInt32(kVK_Space), modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        print("[Focus] RegisterEventHotKey status: \(registerStatus), hotKeyRef: \(String(describing: hotKeyRef))")
    }
    
    func toggleSpotlightInput() {
        if let spotlightPanel, spotlightPanel.isVisible {
            spotlightPanel.orderOut(nil)
            return
        }

        showSpotlightInput()
    }

    func showSpotlightInput() {
        let panel = spotlightPanel ?? makeSpotlightPanel()
        spotlightPanel = panel

        positionSpotlightPanel(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        NotificationCenter.default.post(name: .spotlightPanelDidShow, object: nil)
    }

    private func makeSpotlightPanel() -> SpotlightPanel {
        let panel = SpotlightPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 1000),
            styleMask: [.titled, .fullSizeContentView, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isOpaque = true
        panel.backgroundColor = .windowBackgroundColor
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.title = "Focus"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.contentView = NSHostingView(rootView: makeSpotlightRootView())
        return panel
    }

    private func makeSpotlightRootView() -> some View {
        SpotlightPanelContentView(
            registry: commandRegistry,
            onExecute: { [weak self] command, arguments in
                command.action(arguments)
                if command.hidesPanel {
                    self?.spotlightPanel?.orderOut(nil)
                }
            }
        )
        .environment(model)
        .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
    }

    private func positionSpotlightPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSApplication.shared.keyWindow?.screen ?? NSScreen.screens.first else {
            return
        }

        let frame = screen.visibleFrame
        let panelSize = panel.frame.size
        let origin = NSPoint(
            x: frame.midX - panelSize.width / 2,
            y: frame.midY - panelSize.height / 2
        )
        panel.setFrameOrigin(origin)
    }

    private func registerCommands() {
        commandRegistry.register(
            SpotlightCommand(
                name: "timer",
                arguments: .required("<time> [message]"),
                summary: "Set a timer (5s, 10m, 2h, 16:00, 5pm, 4:30pm)",
                action: { [model] arguments in
                    model.addTimer(arguments)
                }
            )
        )
        commandRegistry.register(
            SpotlightCommand(
                name: "notify",
                aliases: ["notif"],
                arguments: .required("<message>"),
                summary: "Show a notification now",
                action: { [model] arguments in
                    model.notify(arguments)
                }
            )
        )
        commandRegistry.register(
            SpotlightCommand(
                name: "new tab",
                aliases: ["tab", "open tab"],
                arguments: .optional("[url]"),
                summary: "Open a new browser tab",
                action: { [model] arguments in
                    model.newTab(arguments)
                }
            )
        )
        commandRegistry.register(
            SpotlightCommand(
                name: "new chrome window",
                aliases: ["chrome", "open chrome", "create chrome window", "google chrome"],
                summary: "Open a Google Chrome window in this Space",
                hidesPanel: true,
                action: { [weak self] _ in
                    self?.openGoogleChromeWindow()
                }
            )
        )
    }

    private func openGoogleChromeWindow() {
        let trusted = AXIsProcessTrusted()
        if !trusted {
            let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            return
        }

        let bundleID = "com.google.Chrome"

        let chrome = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }
        if chrome == nil {
            NSWorkspace.shared.launchApplication("Google Chrome")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.selectChromeNewWindow()
            }
            return
        }

        // Do not activate Chrome before creating the window. Activating an app can make
        // macOS switch to the Space containing its most recently used window; invoking
        // the menu item through Accessibility keeps the current Space active instead.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.selectChromeNewWindow()
        }
    }

    private func selectChromeNewWindow(retryCount: Int = 0) {
        let bundleID = "com.google.Chrome"
        guard let chrome = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) else {
            NSSound.beep()
            return
        }

        let pid = chrome.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        var menuBarRef: CFTypeRef?
        let menuBarResult = AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &menuBarRef)
        guard menuBarResult == .success else {
            if retryCount < 5 {
                let delay = 0.3 * Double(retryCount + 1)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.selectChromeNewWindow(retryCount: retryCount + 1)
                }
            } else {
                NSSound.beep()
            }
            return
        }

        let menuBar = menuBarRef as! AXUIElement
        guard let menuItem = findMenuItemByPath(in: menuBar, path: ["File", "New Window"]) else {
            NSSound.beep()
            return
        }

        let result = AXUIElementPerformAction(menuItem, kAXPressAction as CFString)
        if result != .success {
            NSSound.beep()
        }
    }

    private func findMenuItemByPath(in element: AXUIElement, path: [String]) -> AXUIElement? {
        var current = element
        for component in path {
            guard let child = findAXChild(named: component, in: current) else {
                return nil
            }
            current = child
        }
        return current
    }

    private func findAXChild(named name: String, in element: AXUIElement) -> AXUIElement? {
        var count: CFIndex = 0
        AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count)
        guard count > 0 else { return nil }

        var childrenRef: CFArray?
        guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, count, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return nil
        }

        for child in children {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
            let role = (roleRef as? String) ?? ""

            if role == (kAXMenuRole as String) {
                if let found = findAXChild(named: name, in: child) { return found }
                continue
            }

            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleRef)
            if (titleRef as? String) == name {
                return child
            }
        }
        return nil
    }
}

@main
struct FocusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("Focus", image: "MenuBarIcon") {
            VStack(alignment: .leading, spacing: 8) {
                Button("Open Focus Panel") {
                    appDelegate.showSpotlightInput()
                }

                Divider()

                Button("Quit Focus") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(12)
            .frame(minWidth: 180)
        }
        .menuBarExtraStyle(.window)
    }
}
