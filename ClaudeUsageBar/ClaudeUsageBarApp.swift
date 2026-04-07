import SwiftUI
import ServiceManagement

@main
struct ClaudeUsageBarApp: App {
    @StateObject private var usageManager = UsageManager()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(usageManager: usageManager)
        } label: {
            Text(usageManager.menuBarText)
        }
    }
}

struct LaunchAtLoginToggle: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Toggle("Launch at Login", isOn: $launchAtLogin)
            .onChange(of: launchAtLogin) { newValue in
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }
            }
    }
}

struct MenuContent: View {
    @ObservedObject var usageManager: UsageManager

    var body: some View {
        if let error = usageManager.errorMessage {
            Text("Error: \(error)")
                .foregroundColor(.red)
        }

        if let usage = usageManager.usage {
            let h5 = Int(usage.fiveHour.utilization.rounded())
            let d7 = Int(usage.sevenDay.utilization.rounded())

            Text("5-hour session: \(h5)% \u{2014} \(usageManager.relativeReset(from: usage.fiveHour.resetsAt))")
            Text("7-day weekly: \(d7)% \u{2014} \(usageManager.relativeReset(from: usage.sevenDay.resetsAt))")

            if let opus = usage.sevenDayOpus, opus.utilization > 0 {
                let opusVal = Int(opus.utilization.rounded())
                Text("7-day Opus: \(opusVal)%")
            }
        } else if usageManager.errorMessage == nil {
            Text("Loading...")
        }

        Divider()

        LaunchAtLoginToggle()

        Button("Refresh Now") {
            Task { await usageManager.refresh() }
        }
        .keyboardShortcut("r")

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
