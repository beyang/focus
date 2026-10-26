//
//  ContentView.swift
//  Focus
//
//  Created by Beyang Liu on 7/19/25.
//

import SwiftUI
import WebKit
import Foundation
import AppKit

struct StyledTextField: View {
    let placeholder: String
    @Binding var text: String
    let font: Font
    let onSubmit: () -> Void

    init(
        placeholder: String,
        text: Binding<String>,
        font: Font = .system(.body, design: .monospaced),
        onSubmit: @escaping () -> Void
    ) {
        self.placeholder = placeholder
        self._text = text
        self.font = font
        self.onSubmit = onSubmit
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(font)
            .padding(8)
            .background(Color.black.opacity(0.1))
            .cornerRadius(4)
            .onSubmit {
                onSubmit()
            }
    }
}

struct WebView: NSViewRepresentable {
    let url: URL
    let reloadToken: Int
    let volume: Double
    let onTitleChange: (String?) -> Void

    class Coordinator: NSObject, WKNavigationDelegate {
        var lastReloadToken: Int
        var lastVolume: Double
        var lastRequestedURL: URL
        var onTitleChange: (String?) -> Void

        init(reloadToken: Int, volume: Double, url: URL, onTitleChange: @escaping (String?) -> Void) {
            self.lastReloadToken = reloadToken
            self.lastVolume = volume
            self.lastRequestedURL = url
            self.onTitleChange = onTitleChange
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            WebView.applyVolume(lastVolume, to: webView)
            onTitleChange(webView.title)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(reloadToken: reloadToken, volume: volume, url: url, onTitleChange: onTitleChange)
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        print("WebView created")
        let request = URLRequest(url: url)
        webView.load(request)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Reload for navigation changes, or explicit refresh requests.
        if context.coordinator.lastRequestedURL != url {
            let request = URLRequest(url: url)
            print("Loading URL: \(url)")
            nsView.load(request)
        } else if context.coordinator.lastReloadToken != reloadToken {
            nsView.reload()
        }

        if context.coordinator.lastVolume != volume {
            Self.applyVolume(volume, to: nsView)
        }

        context.coordinator.lastReloadToken = reloadToken
        context.coordinator.lastVolume = volume
        context.coordinator.lastRequestedURL = url
        context.coordinator.onTitleChange = onTitleChange
    }

    private static func applyVolume(_ volume: Double, to webView: WKWebView) {
        let normalizedVolume = min(max(volume, 0), 1)
        let volumeString = String(format: "%.3f", normalizedVolume)

        let script = """
        (function() {
            const targetVolume = \(volumeString);
            window.__focusTargetVolume = targetVolume;

            const applyVolume = (mediaElement) => {
                if (!mediaElement || typeof mediaElement.volume !== 'number') {
                    return;
                }
                mediaElement.volume = targetVolume;
            };

            document.querySelectorAll('audio, video').forEach(applyVolume);

            if (!window.__focusVolumeHooksInstalled) {
                document.addEventListener('play', function(event) {
                    const mediaElement = event.target;
                    if (mediaElement && (mediaElement.tagName === 'AUDIO' || mediaElement.tagName === 'VIDEO')) {
                        const currentVolume = typeof window.__focusTargetVolume === 'number' ? window.__focusTargetVolume : targetVolume;
                        mediaElement.volume = currentVolume;
                    }
                }, true);

                const observer = new MutationObserver(function(mutations) {
                    const currentVolume = typeof window.__focusTargetVolume === 'number' ? window.__focusTargetVolume : targetVolume;
                    mutations.forEach(function(mutation) {
                        mutation.addedNodes.forEach(function(node) {
                            if (!node || node.nodeType !== Node.ELEMENT_NODE) {
                                return;
                            }
                            if (node.matches && (node.matches('audio') || node.matches('video'))) {
                                node.volume = currentVolume;
                            }
                            if (node.querySelectorAll) {
                                node.querySelectorAll('audio, video').forEach(function(mediaElement) {
                                    mediaElement.volume = currentVolume;
                                });
                            }
                        });
                    });
                });

                observer.observe(document.documentElement, { childList: true, subtree: true });
                window.__focusVolumeHooksInstalled = true;
            }
        })();
        """

        webView.evaluateJavaScript(script)
    }
}

struct ContentView: View {
    @Environment(FocusModel.self) private var model
    @State private var escPressCount = 0
    @State private var escResetTimer: Foundation.Timer?

    var body: some View {
        VStack(spacing: 0) {
            TabBar()

            Divider()

            ZStack {
                // Keep every browser tab alive so pages and media keep running in the background.
                ForEach(model.browserTabs) { tab in
                    let isSelected = model.selectedTab == .browser(tab.id)
                    BrowserTabView(tab: tab)
                        .opacity(isSelected ? 1 : 0)
                        .allowsHitTesting(isSelected)
                }

                if model.selectedTab == .timers {
                    HStack(spacing: 0) {
                        TimersView()
                        Divider()
                        TodoView()
                    }
                }
            }
        }
        .onAppear {
            model.requestNotificationPermission()
        }
        .onDisappear {
            escResetTimer?.invalidate()
        }
        .onKeyPress(.escape) {
            handleEscapePress()
            return .handled
        }
    }

    private func handleEscapePress() {
        escPressCount += 1
        escResetTimer?.invalidate()

        if escPressCount >= 2 {
            NSApplication.shared.keyWindow?.close()
            escPressCount = 0
        } else {
            escResetTimer = Foundation.Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
                self.escPressCount = 0
            }
        }
    }
}

struct TabBar: View {
    @Environment(FocusModel.self) private var model

    var body: some View {
        HStack(spacing: 4) {
            TabButton(
                title: model.activeTimers.isEmpty ? "Timers & Todos" : "Timers & Todos (\(model.activeTimers.count))",
                systemImage: "timer",
                isSelected: model.selectedTab == .timers,
                onSelect: { model.selectedTab = .timers }
            )

            Divider()
                .frame(height: 16)
                .padding(.horizontal, 4)

            ForEach(model.browserTabs) { tab in
                TabButton(
                    title: tab.displayTitle,
                    systemImage: "globe",
                    isSelected: model.selectedTab == .browser(tab.id),
                    onSelect: { model.selectedTab = .browser(tab.id) },
                    onClose: model.browserTabs.count > 1 ? { model.closeTab(tab.id) } : nil
                )
            }

            Button {
                model.newTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New tab")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

struct TabButton: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let onSelect: () -> Void
    var onClose: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)

            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)

            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close tab")
            }
        }
        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: 220, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.black.opacity(0.04))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

struct BrowserTabView: View {
    @Environment(FocusModel.self) private var model
    @Bindable var tab: BrowserTab

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                StyledTextField(
                    placeholder: "Enter URL",
                    text: $tab.urlString,
                    font: .body,
                    onSubmit: { model.navigate(tab) }
                )

                Button("Go") {
                    model.navigate(tab)
                }
                .buttonStyle(.borderedProminent)

                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(.secondary)

                Slider(value: Bindable(model).webVolume, in: 0...1, step: 0.01)
                    .frame(width: 140)

                Text("\(Int(model.webVolume * 100))%")
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 40, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(NSColor.controlBackgroundColor))

            WebView(url: tab.url, reloadToken: tab.reloadToken, volume: model.webVolume) { title in
                tab.title = title
            }
            .background(Color.white)
        }
    }
}

struct TimersView: View {
    @Environment(FocusModel.self) private var model
    @State private var now = Date()

    var body: some View {
        Group {
            if model.activeTimers.isEmpty {
                VStack(spacing: 6) {
                    Text("No active timers")
                        .font(.headline)
                    Text("Add one from the command bar, e.g. timer 25m stretch")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.activeTimers.sorted { $0.endTime < $1.endTime }) { timer in
                            timerRow(timer)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { date in
            now = date
        }
    }

    private func timerRow(_ timer: ActiveTimer) -> some View {
        HStack(spacing: 12) {
            Text(formatRemainingTime(timer.endTime.timeIntervalSince(now)))
                .font(.system(.title2, design: .monospaced))
                .frame(minWidth: 110, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                if let message = timer.message, !message.isEmpty {
                    Text(message)
                }
                Text("timer \(timer.originalInput) · ends \(timer.endTime.formatted(date: .omitted, time: .shortened))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                model.cancelTimer(timer)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Cancel timer")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }

    private func formatRemainingTime(_ timeInterval: TimeInterval) -> String {
        if timeInterval <= 0 {
            return "00:00"
        }

        let totalSeconds = Int(timeInterval)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}

#Preview {
    ContentView()
        .environment(FocusModel())
}
