import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private let sensors = ThermalSensors()
    private let updates = UpdateChecker()
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var updateStatus: UpdateStatus?
    private var updating = false

    private let cpuItem = NSMenuItem(title: "CPU  —", action: nil, keyEquivalent: "")
    private let gpuItem = NSMenuItem(title: "GPU  —", action: nil, keyEquivalent: "")
    private let socItem = NSMenuItem(title: "SoC  —", action: nil, keyEquivalent: "")
    private let installItem = NSMenuItem(title: "", action: #selector(installUpdate), keyEquivalent: "")
    private let unitItem = NSMenuItem(title: "Show °F", action: #selector(toggleUnit), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")

    private var fahrenheit = UserDefaults.standard.bool(forKey: "fahrenheit") {
        didSet {
            UserDefaults.standard.set(fahrenheit, forKey: "fahrenheit")
            unitItem.state = fahrenheit ? .on : .off
            refresh()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hard requirements gate: without readable thermal sensors (Intel Macs
        // never get this far — the binary is arm64-only — but virtual machines
        // and future chips with renamed sensors can) the app is useless, so
        // explain, undo any install side effects, and stop. Never register a
        // login item for an app that can't work.
        guard sensors != nil else {
            LoginItem.setEnabled(false)
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "This Mac isn't supported"
            alert.informativeText = """
            MacTemp reads the thermal sensors of Apple Silicon Macs (M1 or \
            later). This system doesn't expose them — Intel Macs and most \
            virtual machines aren't supported.

            MacTemp will now quit.
            """
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        LoginItem.applyAtStartup()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // A chip symbol marks this as the COMPUTER's temperature — deliberately
        // not a thermometer, so it can't be mistaken for a weather widget.
        // Template rendering keeps it legible on light and dark menu bars.
        if let button = statusItem.button,
           let chip = NSImage(systemSymbolName: "cpu", accessibilityDescription: "CPU temperature")?
               .withSymbolConfiguration(.init(pointSize: 12, weight: .regular)) {
            chip.isTemplate = true
            button.image = chip
            button.imagePosition = .imageLeading
        }

        let menu = NSMenu()
        menu.delegate = self
        for item in [cpuItem, gpuItem, socItem] {
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        installItem.target = self
        installItem.isHidden = true
        menu.addItem(installItem)
        unitItem.target = self
        unitItem.state = fahrenheit ? .on : .off
        menu.addItem(unitItem)
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(makeItem("About MacTemp", #selector(showAbout)))
        menu.addItem(makeItem("Check for Updates…", #selector(checkForUpdates)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit MacTemp",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        refresh()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // .common so readings keep updating while the menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func makeItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: menu

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
        loginItem.state = LoginItem.isEnabled ? .on : .off
        loginItem.isEnabled = AppInfo.isBundled
        // Quiet, cached check so the "Install Update" item appears when relevant.
        updates.check { [weak self] status in
            self?.updateStatus = status
            self?.refreshInstallItem()
        }
    }

    private func refreshInstallItem() {
        guard !updating else { return }
        if let status = updateStatus, status.available {
            installItem.title = "⬆ Install Update v\(status.latest ?? "")…"
            installItem.isHidden = false
        } else {
            installItem.isHidden = true
        }
    }

    // MARK: actions

    @objc private func toggleUnit() {
        fahrenheit.toggle()
    }

    @objc private func toggleLogin() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
    }

    @objc private func showAbout() {
        let credits = NSMutableAttributedString(
            string: "CPU temperature in your menu bar.\n",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)])
        credits.append(NSAttributedString(
            string: "mariolonghi.com",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                         .link: AppInfo.website]))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc private func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        updates.check(force: true) { [weak self] status in
            guard let self else { return }
            self.updateStatus = status
            self.refreshInstallItem()

            let alert = NSAlert()
            if status.available {
                alert.messageText = "Update available: v\(status.latest ?? "")"
                alert.informativeText = "You have v\(status.current). The update installs and relaunches automatically."
                alert.addButton(withTitle: "Install Update")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn {
                    self.installUpdate()
                }
            } else if status.error != nil {
                alert.messageText = "Couldn't check for updates"
                alert.informativeText = "Are you offline? You can also check manually."
                alert.addButton(withTitle: "Open Releases Page")
                alert.addButton(withTitle: "OK")
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(status.releaseURL)
                }
            } else {
                alert.messageText = "You're up to date"
                alert.informativeText = "MacTemp v\(status.current) is the latest version."
                alert.runModal()
            }
        }
    }

    @objc private func installUpdate() {
        guard !updating, let status = updateStatus, status.available else { return }

        // No direct DMG or can't swap in place → hand over to the browser.
        guard let dmgURL = status.dmgURL, SelfUpdater.canSelfUpdate().ok else {
            NSWorkspace.shared.open(status.releaseURL)
            return
        }

        updating = true
        installItem.title = "Updating…"
        installItem.isEnabled = false

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try SelfUpdater.performUpdate(from: dmgURL)
                DispatchQueue.main.async {
                    NSApp.terminate(nil)   // the swap helper relaunches us
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.updating = false
                    self.installItem.isEnabled = true
                    self.refreshInstallItem()
                    NSApp.activate(ignoringOtherApps: true)
                    let alert = NSAlert()
                    alert.messageText = "Update failed"
                    alert.informativeText = error.localizedDescription
                    alert.addButton(withTitle: "Open Releases Page")
                    alert.addButton(withTitle: "OK")
                    if alert.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.open(status.releaseURL)
                    }
                }
            }
        }
    }

    // MARK: readings

    private func refresh() {
        guard let sensors else {
            setTitle("n/a")
            cpuItem.title = "Sensors unavailable"
            gpuItem.isHidden = true
            socItem.isHidden = true
            return
        }

        let reading = sensors.read()
        setTitle(reading.cpu.map(format) ?? "—")
        cpuItem.title = "CPU  " + (reading.cpu.map(format) ?? "—")
        gpuItem.title = "GPU  " + (reading.gpu.map(format) ?? "—")
        socItem.title = "SoC  " + (reading.soc.map(format) ?? "—")
    }

    private func format(_ celsius: Double) -> String {
        let value = fahrenheit ? celsius * 9 / 5 + 32 : celsius
        return "\(Int(value.rounded()))°" + (fahrenheit ? "F" : "C")
    }

    /// Monospaced digits keep the item from twitching as the reading changes.
    private func setTitle(_ text: String) {
        statusItem.button?.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)]
        )
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
