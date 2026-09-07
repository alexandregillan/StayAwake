import Cocoa
import IOKit.pwr_mgt
import ServiceManagement

let appVersion = "1.0.0"
let repoURL = URL(string: "https://github.com/alexandregillan/StayAwake")!

// MARK: - Shell helpers

@discardableResult
func shell(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do { try p.run() } catch { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

/// Single-quotes a string for safe use as one shell argument.
func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Runs a shell command line with the standard macOS admin password dialog.
/// Returns true on success, false if it failed or the user cancelled.
func runAsAdmin(_ command: String) -> Bool {
    let literal = command
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    let source = "do shell script \"\(literal)\" with administrator privileges"
    guard let script = NSAppleScript(source: source) else { return false }
    var err: NSDictionary?
    script.executeAndReturnError(&err)
    return err == nil
}

// MARK: - Power assertions

final class PowerKeeper {
    private var systemID: IOPMAssertionID = 0
    private var displayID: IOPMAssertionID = 0
    private(set) var systemHeld = false
    private(set) var displayHeld = false

    func setSystem(_ on: Bool) {
        if on, !systemHeld {
            var id: IOPMAssertionID = 0
            let r = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "StayAwake is keeping this Mac awake" as CFString,
                &id)
            if r == kIOReturnSuccess { systemID = id; systemHeld = true }
        } else if !on, systemHeld {
            IOPMAssertionRelease(systemID)
            systemHeld = false
        }
    }

    func setDisplay(_ on: Bool) {
        if on, !displayHeld {
            var id: IOPMAssertionID = 0
            let r = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "StayAwake is keeping the display on" as CFString,
                &id)
            if r == kIOReturnSuccess { displayID = id; displayHeld = true }
        } else if !on, displayHeld {
            IOPMAssertionRelease(displayID)
            displayHeld = false
        }
    }
}

// MARK: - Screensaver

enum Screensaver {
    static let backupKey = "OriginalIdleTime"

    static func currentIdle() -> Int? {
        Int(shell("/usr/bin/defaults",
                  ["-currentHost", "read", "com.apple.screensaver", "idleTime"]))
    }

    static func disable() {
        let d = UserDefaults.standard
        if d.object(forKey: backupKey) == nil {
            d.set(currentIdle() ?? 300, forKey: backupKey)
        }
        shell("/usr/bin/defaults",
              ["-currentHost", "write", "com.apple.screensaver", "idleTime", "-int", "0"])
    }

    static func restore() {
        let d = UserDefaults.standard
        guard let original = d.object(forKey: backupKey) as? Int else { return }
        shell("/usr/bin/defaults",
              ["-currentHost", "write", "com.apple.screensaver", "idleTime",
               "-int", String(original)])
        d.removeObject(forKey: backupKey)
    }
}

// MARK: - Passwordless rule for lid mode

/// A sudoers rule scoped to exactly two commands: pmset disablesleep 1 and 0.
/// Installed by scripts/install-sudoers.sh, which is bundled into the app.
enum SudoersRule {
    static let path = "/etc/sudoers.d/stayawake"

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// Prompts for the admin password once, then never again for lid mode.
    static func install() -> Bool {
        guard let script = Bundle.main.path(forResource: "install-sudoers", ofType: "sh")
        else { return false }
        return runAsAdmin("/bin/bash \(shellQuote(script)) \(shellQuote(NSUserName()))")
    }
}

// MARK: - Lid (clamshell) sleep

enum Lid {
    /// `disablesleep` is write-only as far as `pmset -g` is concerned on recent
    /// macOS, so read the kernel's own flag instead.
    static func isDisabled() -> Bool {
        let out = shell("/usr/sbin/ioreg", ["-r", "-c", "IOPMrootDomain", "-d", "1"])
        for line in out.split(separator: "\n") where line.contains("SleepDisabled") {
            return line.contains("Yes")
        }
        return false
    }

    @discardableResult
    static func setDisabled(_ on: Bool) -> Bool {
        let value = on ? "1" : "0"

        // Fast path: the sudoers rule grants NOPASSWD for exactly this command.
        // -n makes sudo fail immediately instead of prompting.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", value]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        if (try? p.run()) != nil {
            p.waitUntilExit()
            if p.terminationStatus == 0 { return true }
        }

        // No rule installed, so fall back to the admin password prompt.
        return runAsAdmin("/usr/bin/pmset -a disablesleep \(value)")
    }
}

// MARK: - Preferences

enum Prefs {
    private static let d = UserDefaults.standard

    static var hasLaunchedBefore: Bool {
        get { d.bool(forKey: "hasLaunchedBefore") }
        set { d.set(newValue, forKey: "hasLaunchedBefore") }
    }

    /// User chose "Ask Each Time" instead of installing the passwordless rule.
    static var lidAskEachTime: Bool {
        get { d.bool(forKey: "lidAskEachTime") }
        set { d.set(newValue, forKey: "lidAskEachTime") }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let keeper = PowerKeeper()
    private var ticker: Timer?

    private var isOn = false
    private var keepDisplayOn = true
    private var killScreensaver = true
    private var lidMode = false
    private var expiry: Date?

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // A previous run may have crashed mid-session; pick up its leftovers.
        if Lid.isDisabled() || UserDefaults.standard.object(forKey: Screensaver.backupKey) != nil {
            lidMode = Lid.isDisabled()
            isOn = lidMode
            if isOn { keeper.setSystem(true); keeper.setDisplay(keepDisplayOn) }
        }

        refreshIcon()
        ticker = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.tick()
        }

        if !Prefs.hasLaunchedBefore {
            Prefs.hasLaunchedBefore = true
            showWelcome()
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        turnOff(promptForLid: true)
    }

    // MARK: State

    private func turnOn(duration: TimeInterval?) {
        expiry = duration.map { Date().addingTimeInterval($0) }
        isOn = true
        keeper.setSystem(true)
        keeper.setDisplay(keepDisplayOn)
        if killScreensaver { Screensaver.disable() }
        refreshIcon()
    }

    private func turnOff(promptForLid: Bool) {
        isOn = false
        expiry = nil
        keeper.setSystem(false)
        keeper.setDisplay(false)
        Screensaver.restore()
        if lidMode, promptForLid {
            Lid.setDisabled(false)
            lidMode = false
        }
        refreshIcon()
    }

    private func tick() {
        if let e = expiry, Date() >= e {
            turnOff(promptForLid: true)
            alert("StayAwake timer finished",
                  "Normal sleep, screensaver and lid behaviour have been restored.")
        }
        refreshIcon()
    }

    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        let name = isOn ? "cup.and.saucer.fill" : "cup.and.saucer"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "StayAwake")
        img?.isTemplate = true
        button.image = img
        button.toolTip = isOn ? "StayAwake: on" : "StayAwake: off"
    }

    private func remainingText() -> String {
        guard isOn else { return "Off" }
        guard let e = expiry else { return "On, no time limit" }
        let secs = max(0, Int(e.timeIntervalSinceNow))
        let h = secs / 3600, m = (secs % 3600) / 60
        return h > 0 ? "On, \(h)h \(m)m left" : "On, \(m)m left"
    }

    // MARK: Dialogs

    private func alert(_ title: String, _ body: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    private func showWelcome() {
        alert("StayAwake is in your menu bar",
              """
              Look for the coffee cup next to the clock. Click it to keep your Mac \
              awake, keep the screen on, or keep working with the lid closed.

              Tip: turn on Launch at Login so it is always there.
              """)
    }

    private enum LidSetupChoice { case setUp, askEachTime, cancel }

    private func offerPasswordlessSetup() -> LidSetupChoice {
        let a = NSAlert()
        a.messageText = "Keep working with the lid closed"
        a.informativeText = """
            macOS only allows this with administrator rights.

            Set Up Once installs a small rule so StayAwake can switch it on and off \
            without asking again. The rule is limited to exactly two commands \
            (turning lid sleep off and back on) and nothing else.

            Ask Each Time means a password prompt on every toggle.
            """
        a.alertStyle = .informational
        a.addButton(withTitle: "Set Up Once")
        a.addButton(withTitle: "Ask Each Time")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        switch a.runModal() {
        case .alertFirstButtonReturn: return .setUp
        case .alertSecondButtonReturn: return .askEachTime
        default: return .cancel
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: remainingText(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: isOn ? "Turn Off" : "Turn On",
                                action: #selector(toggleMain), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())

        add(menu, "Keep Display On", #selector(toggleDisplay), keepDisplayOn)
        add(menu, "Disable Screensaver", #selector(toggleScreensaver), killScreensaver)
        let lid = add(menu, "Stay Awake with Lid Closed", #selector(toggleLid), lidMode)
        lid.toolTip = SudoersRule.isInstalled
            ? "Uses pmset disablesleep. No password needed."
            : "Needs administrator rights. Uses pmset disablesleep."
        if !SudoersRule.isInstalled {
            let setup = NSMenuItem(title: "Set Up Passwordless Lid Mode…",
                                   action: #selector(setUpPasswordless), keyEquivalent: "")
            setup.target = self
            setup.indentationLevel = 1
            menu.addItem(setup)
        }
        menu.addItem(.separator())

        let durations = NSMenu()
        let opts: [(String, TimeInterval?)] = [
            ("No time limit", nil), ("1 hour", 3600), ("2 hours", 7200),
            ("4 hours", 14400), ("8 hours", 28800), ("Until 9 AM", secondsUntil9AM())
        ]
        for (label, secs) in opts {
            let item = NSMenuItem(title: label, action: #selector(pickDuration(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = secs.map { NSNumber(value: $0) }
            durations.addItem(item)
        }
        let dur = NSMenuItem(title: "Turn On For", action: nil, keyEquivalent: "")
        menu.setSubmenu(durations, for: dur)
        menu.addItem(dur)
        menu.addItem(.separator())

        add(menu, "Launch at Login", #selector(toggleLogin), launchAtLoginEnabled())
        let about = NSMenuItem(title: "About StayAwake \(appVersion)",
                               action: #selector(openAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        let quit = NSMenuItem(title: "Quit StayAwake", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ checked: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = checked ? .on : .off
        menu.addItem(item)
        return item
    }

    private func secondsUntil9AM() -> TimeInterval {
        let cal = Calendar.current
        let now = Date()
        var next = cal.date(bySettingHour: 9, minute: 0, second: 0, of: now)!
        if next <= now { next = cal.date(byAdding: .day, value: 1, to: next)! }
        return next.timeIntervalSince(now)
    }

    // MARK: Actions

    @objc private func toggleMain() {
        isOn ? turnOff(promptForLid: true) : turnOn(duration: nil)
    }

    @objc private func toggleDisplay() {
        keepDisplayOn.toggle()
        if isOn { keeper.setDisplay(keepDisplayOn) }
    }

    @objc private func toggleScreensaver() {
        killScreensaver.toggle()
        if isOn { killScreensaver ? Screensaver.disable() : Screensaver.restore() }
    }

    @objc private func toggleLid() {
        let want = !lidMode

        // First time turning it on without the rule: offer to set it up once.
        if want, !SudoersRule.isInstalled, !Prefs.lidAskEachTime {
            switch offerPasswordlessSetup() {
            case .setUp:
                guard SudoersRule.install() else { return }
            case .askEachTime:
                Prefs.lidAskEachTime = true
            case .cancel:
                return
            }
        }

        guard Lid.setDisabled(want) else { return }   // cancelled the password prompt
        lidMode = want
        if want, !isOn { turnOn(duration: nil) }
        refreshIcon()
    }

    @objc private func setUpPasswordless() {
        if SudoersRule.install() {
            Prefs.lidAskEachTime = false
            alert("All set", "Lid mode will no longer ask for your password.")
        }
    }

    @objc private func pickDuration(_ sender: NSMenuItem) {
        turnOn(duration: (sender.representedObject as? NSNumber)?.doubleValue)
    }

    private func launchAtLoginEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func toggleLogin() {
        if launchAtLoginEnabled() {
            try? SMAppService.mainApp.unregister()
        } else {
            try? SMAppService.mainApp.register()
        }
    }

    @objc private func openAbout() {
        NSWorkspace.shared.open(repoURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
