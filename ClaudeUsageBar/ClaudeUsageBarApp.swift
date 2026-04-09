import Cocoa
import Combine
import ServiceManagement

@main
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var usageManager: UsageManager!
    private var cancellables = Set<AnyCancellable>()

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        usageManager = UsageManager()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusItem()

        usageManager.$usage
            .combineLatest(usageManager.$errorMessage, usageManager.$lastUpdated)
            .combineLatest(usageManager.$isStale)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.updateStatusItem()
            }
            .store(in: &cancellables)
    }

    private func updateStatusItem() {
        statusItem.button?.title = usageManager.menuBarText
        buildMenu()
    }

    private func buildMenu() {
        let menu = statusItem.menu ?? NSMenu()
        menu.removeAllItems()

        if let error = usageManager.errorMessage {
            let item = NSMenuItem(title: "Error: \(error)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        if usageManager.isStale {
            let staleItem = NSMenuItem(title: "Stale data (updated \(usageManager.lastUpdatedText), rate limited)", action: nil, keyEquivalent: "")
            staleItem.isEnabled = false
            menu.addItem(staleItem)
        }

        if let usage = usageManager.usage {
            let h5 = Int(usage.fiveHour.utilization.rounded())
            let d7 = Int(usage.sevenDay.utilization.rounded())

            let h5Item = NSMenuItem(title: "5-hour session: \(h5)% \u{2014} \(usageManager.relativeReset(from: usage.fiveHour.resetsAt))", action: nil, keyEquivalent: "")
            h5Item.isEnabled = false
            menu.addItem(h5Item)

            let d7Item = NSMenuItem(title: "7-day weekly: \(d7)% \u{2014} \(usageManager.relativeReset(from: usage.sevenDay.resetsAt))", action: nil, keyEquivalent: "")
            d7Item.isEnabled = false
            menu.addItem(d7Item)

            if let opus = usage.sevenDayOpus, opus.utilization > 0 {
                let opusVal = Int(opus.utilization.rounded())
                let opusItem = NSMenuItem(title: "7-day Opus: \(opusVal)%", action: nil, keyEquivalent: "")
                opusItem.isEnabled = false
                menu.addItem(opusItem)
            }
        } else if usageManager.errorMessage == nil {
            let item = NSMenuItem(title: "Loading...", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        let updatedItem = NSMenuItem(title: "Last updated: \(usageManager.lastUpdatedText)", action: nil, keyEquivalent: "")
        updatedItem.isEnabled = false
        menu.addItem(updatedItem)

        menu.addItem(NSMenuItem.separator())

        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        launchItem.target = self
        launchItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launchItem)

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        buildMenu()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {}
    }

    @objc private func refreshNow() {
        Task { await usageManager.refresh() }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
