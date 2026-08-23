import Cocoa
import Combine
import ServiceManagement

@main
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var accounts: [(label: String, manager: UsageManager)] = []
    private var cancellables = Set<AnyCancellable>()

    private static let accountPKey = "AccountPService"
    private static let accountWKey = "AccountWService"

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        rebuildManagers()
    }

    // MARK: - Account configuration

    private var serviceP: String {
        UserDefaults.standard.string(forKey: Self.accountPKey) ?? KeychainHelper.defaultService
    }

    private var serviceW: String? {
        UserDefaults.standard.string(forKey: Self.accountWKey)
    }

    private func rebuildManagers() {
        cancellables.removeAll()
        accounts = [(label: "P", manager: UsageManager(service: serviceP))]
        if let w = serviceW {
            accounts.append((label: "W", manager: UsageManager(service: w)))
        }
        for account in accounts {
            account.manager.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.updateStatusItem()
                }
                .store(in: &cancellables)
        }
        updateStatusItem()
    }

    /// Short display name for a credential service: the ~/.claude-* profile
    /// dir name when one matches, otherwise the raw hash suffix.
    private func shortName(for service: String) -> String {
        if let name = KeychainHelper.profileNames()[service] { return name }
        if service == KeychainHelper.defaultService { return "default" }
        return String(service.dropFirst(KeychainHelper.defaultService.count + 1))
    }

    // MARK: - Menu bar title

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        if accounts.count > 1 {
            // NSStatusBarButton's cell is single-line and truncates at "\n", so
            // stacked rows are drawn into an image instead of a title.
            button.title = ""
            button.image = twoRowImage()
            button.imagePosition = .imageOnly
        } else {
            button.image = nil
            button.imagePosition = .noImage
            button.attributedTitle = compactTitle()
        }
        buildMenu()
    }

    private func twoRowImage() -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        let lines = accounts.map { compactLine(for: $0, font: font) }
        let lineHeight = ceil(lines.map { $0.size().height }.max() ?? 11)
        let width = ceil(lines.map { $0.size().width }.max() ?? 10)
        let height: CGFloat = 22

        // Draw lazily so dynamic colors resolve against the menu bar's current
        // light/dark appearance at draw time.
        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            var y = (height - lineHeight * CGFloat(lines.count)) / 2
            for line in lines {
                line.draw(at: NSPoint(x: 0, y: y))
                y += lineHeight
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private func color(for percent: Double) -> NSColor {
        switch percent {
        case ..<50: return .systemGreen
        case 50..<80: return .systemOrange
        default: return .systemRed
        }
    }

    private func compactTitle() -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        return compactLine(for: accounts[0], font: font)
    }

    private func compactLine(for account: (label: String, manager: UsageManager), font: NSFont) -> NSAttributedString {
        let line = NSMutableAttributedString()
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]

        if accounts.count > 1 {
            line.append(NSAttributedString(string: "\(account.label) ", attributes: labelAttrs))
        }

        let metrics = account.manager.metrics
        if metrics.isEmpty {
            if account.manager.errorMessage != nil {
                line.append(NSAttributedString(string: "!", attributes: [
                    .font: font, .foregroundColor: NSColor.systemRed
                ]))
            } else {
                line.append(NSAttributedString(string: "--", attributes: labelAttrs))
            }
            return line
        }

        for (index, metric) in metrics.enumerated() {
            if index > 0 {
                line.append(NSAttributedString(string: "\u{00B7}", attributes: [
                    .font: font, .foregroundColor: NSColor.tertiaryLabelColor
                ]))
            }
            line.append(NSAttributedString(string: "\(Int(metric.percent.rounded()))", attributes: [
                .font: font, .foregroundColor: color(for: metric.percent)
            ]))
        }

        if account.manager.isStale {
            line.append(NSAttributedString(string: " \u{29D6}", attributes: labelAttrs))
        }
        return line
    }

    // MARK: - Menu

    private func buildMenu() {
        let menu = statusItem.menu ?? NSMenu()
        menu.removeAllItems()

        for (index, account) in accounts.enumerated() {
            if index > 0 {
                menu.addItem(NSMenuItem.separator())
            }
            addAccountSection(account, to: menu)
        }

        menu.addItem(NSMenuItem.separator())
        for item in buildAccountsConfigItems() {
            menu.addItem(item)
        }
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

    private func addAccountSection(_ account: (label: String, manager: UsageManager), to menu: NSMenu) {
        let manager = account.manager

        var headerText = "Account \(account.label) \u{2014} \(shortName(for: manager.service))"
        if manager.lastUpdated != nil {
            headerText += " \u{00B7} updated \(manager.lastUpdatedText.lowercased())"
        }
        let header = NSMenuItem(title: headerText, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if let error = manager.errorMessage {
            let item = NSMenuItem(title: "Error: \(error)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        if manager.isStale {
            let staleItem = NSMenuItem(title: "Stale data (updated \(manager.lastUpdatedText), rate limited)", action: nil, keyEquivalent: "")
            staleItem.isEnabled = false
            menu.addItem(staleItem)
        }

        if let usage = manager.usage {
            let h5 = Int(usage.fiveHour.utilization.rounded())
            let d7 = Int(usage.sevenDay.utilization.rounded())

            let h5Item = NSMenuItem(title: "5-hour session: \(h5)% \u{2014} \(manager.relativeReset(from: usage.fiveHour.resetsAt))", action: nil, keyEquivalent: "")
            h5Item.isEnabled = false
            menu.addItem(h5Item)

            let d7Item = NSMenuItem(title: "7-day weekly: \(d7)% \u{2014} \(manager.relativeReset(from: usage.sevenDay.resetsAt))", action: nil, keyEquivalent: "")
            d7Item.isEnabled = false
            menu.addItem(d7Item)

            if let opus = usage.sevenDayOpus, opus.utilization > 0 {
                let opusVal = Int(opus.utilization.rounded())
                let opusItem = NSMenuItem(title: "7-day Opus: \(opusVal)%", action: nil, keyEquivalent: "")
                opusItem.isEnabled = false
                menu.addItem(opusItem)
            }

            for limit in usage.scopedModelLimits {
                guard let name = limit.scope?.model?.displayName, let percent = limit.percent else { continue }
                let val = Int(percent.rounded())
                let item = NSMenuItem(title: "7-day \(name): \(val)% \u{2014} \(manager.relativeReset(from: limit.resetsAt))", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        } else if manager.errorMessage == nil {
            let item = NSMenuItem(title: "Loading...", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
    }

    private func buildAccountsConfigItems() -> [NSMenuItem] {
        let services = KeychainHelper.discoverServices()

        let pMenu = NSMenu()
        for service in services {
            let item = NSMenuItem(title: shortName(for: service), action: #selector(selectAccountP(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = service
            item.state = service == serviceP ? .on : .off
            pMenu.addItem(item)
        }
        let pItem = NSMenuItem(title: "Account P: \(shortName(for: serviceP))", action: nil, keyEquivalent: "")
        pItem.submenu = pMenu

        let wMenu = NSMenu()
        let noneItem = NSMenuItem(title: "None", action: #selector(selectAccountW(_:)), keyEquivalent: "")
        noneItem.target = self
        noneItem.state = serviceW == nil ? .on : .off
        wMenu.addItem(noneItem)
        for service in services {
            let item = NSMenuItem(title: shortName(for: service), action: #selector(selectAccountW(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = service
            item.state = service == serviceW ? .on : .off
            wMenu.addItem(item)
        }
        let wItem = NSMenuItem(title: "Account W: \(serviceW.map(shortName(for:)) ?? "none")", action: nil, keyEquivalent: "")
        wItem.submenu = wMenu

        return [pItem, wItem]
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        buildMenu()
    }

    // MARK: - Actions

    @objc private func selectAccountP(_ sender: NSMenuItem) {
        guard let service = sender.representedObject as? String, service != serviceP else { return }
        UserDefaults.standard.set(service, forKey: Self.accountPKey)
        rebuildManagers()
    }

    @objc private func selectAccountW(_ sender: NSMenuItem) {
        let service = sender.representedObject as? String
        guard service != serviceW else { return }
        if let service {
            UserDefaults.standard.set(service, forKey: Self.accountWKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.accountWKey)
        }
        rebuildManagers()
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
        for account in accounts {
            Task { await account.manager.refresh() }
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
