import Cocoa
import IOKit.pwr_mgt
import ServiceManagement

let appVersion = "1.1.0"
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

    /// Uses the sudoers rule, which grants NOPASSWD for exactly this command.
    /// Never shows UI: `sudo -n` fails immediately instead of prompting.
    static func setSilently(_ on: Bool) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Tries the passwordless rule, then falls back to the admin password prompt.
    @discardableResult
    static func setDisabled(_ on: Bool) -> Bool {
        setSilently(on) || runAsAdmin("/usr/bin/pmset -a disablesleep \(on ? "1" : "0")")
    }
}

// MARK: - Durations

enum Duration: String, CaseIterable {
    case unlimited, oneHour, twoHours, fourHours, eightHours, until9AM

    var title: String {
        switch self {
        case .unlimited: return "No time limit"
        case .oneHour: return "1 hour"
        case .twoHours: return "2 hours"
        case .fourHours: return "4 hours"
        case .eightHours: return "8 hours"
        case .until9AM: return "Until 9 AM"
        }
    }

    /// Seconds from now, or nil for no limit. Evaluated at turn-on time so
    /// "Until 9 AM" always means the next 9 AM.
    var seconds: TimeInterval? {
        switch self {
        case .unlimited: return nil
        case .oneHour: return 3600
        case .twoHours: return 7200
        case .fourHours: return 14400
        case .eightHours: return 28800
        case .until9AM:
            let cal = Calendar.current
            let now = Date()
            var next = cal.date(bySettingHour: 9, minute: 0, second: 0, of: now)!
            if next <= now { next = cal.date(byAdding: .day, value: 1, to: next)! }
            return next.timeIntervalSince(now)
        }
    }
}

// MARK: - Preferences

enum Prefs {
    private static let d = UserDefaults.standard

    static func registerDefaults() {
        d.register(defaults: ["keepDisplayOn": true, "disableScreensaver": true])
    }

    static var hasLaunchedBefore: Bool {
        get { d.bool(forKey: "hasLaunchedBefore") }
        set { d.set(newValue, forKey: "hasLaunchedBefore") }
    }

    /// User chose "Ask Each Time" instead of installing the passwordless rule.
    static var lidAskEachTime: Bool {
        get { d.bool(forKey: "lidAskEachTime") }
        set { d.set(newValue, forKey: "lidAskEachTime") }
    }

    static var keepDisplayOn: Bool {
        get { d.bool(forKey: "keepDisplayOn") }
        set { d.set(newValue, forKey: "keepDisplayOn") }
    }

    static var disableScreensaver: Bool {
        get { d.bool(forKey: "disableScreensaver") }
        set { d.set(newValue, forKey: "disableScreensaver") }
    }

    /// How long a session lasts when switched on.
    static var duration: Duration {
        get { Duration(rawValue: d.string(forKey: "duration") ?? "") ?? .unlimited }
        set { d.set(newValue.rawValue, forKey: "duration") }
    }
}

// MARK: - Menu rows

/// Round icon in the style of Control Center: accent-filled when on.
final class BadgeView: NSView {
    private let symbolName: String
    var isOn = false { didSet { needsDisplay = true } }

    init(symbolName: String) {
        self.symbolName = symbolName
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let fill: NSColor = isOn ? .controlAccentColor : NSColor.labelColor.withAlphaComponent(0.1)
        fill.setFill()
        NSBezierPath(ovalIn: bounds).fill()

        let tint: NSColor = isOn ? .white : .labelColor
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        guard let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let s = img.size
        img.draw(in: NSRect(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2,
                            width: s.width, height: s.height))
    }
}

/// A switch drawn by hand. NSSwitch only shows its "on" colour in an active
/// window, and a menu bar app's menu never is one, so there it looks grey
/// even when on. Sized to match the system switch.
final class ToggleSwitch: NSView {
    private(set) var isOn = false
    /// 0 is off, 1 is on, animated in between.
    private var progress: CGFloat = 0 { didSet { needsDisplay = true } }
    private var animation: Timer?
    /// Called when VoiceOver presses the switch.
    var onPress: (() -> Void)?

    func setOn(_ on: Bool, animated: Bool) {
        guard on != isOn else { return }
        isOn = on
        animation?.invalidate()
        animation = nil
        let target: CGFloat = on ? 1 : 0
        guard animated else { progress = target; return }

        let start = progress, began = Date(), duration = 0.18
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let f = min(1, CGFloat(Date().timeIntervalSince(began) / duration))
            self.progress = start + (target - start) * (1 - pow(1 - f, 3))   // ease out
            if f >= 1 { timer.invalidate(); self.animation = nil }
        }
        RunLoop.main.add(t, forMode: .common)   // keeps running while the menu is open
        animation = t
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2,
                                 yRadius: bounds.height / 2)
        NSColor.labelColor.withAlphaComponent(0.16).setFill()
        track.fill()
        if progress > 0 {
            NSColor.controlAccentColor.withAlphaComponent(progress).setFill()
            track.fill()
        }

        let inset: CGFloat = 2.5
        let knobWidth: CGFloat = 26
        let travel = bounds.width - knobWidth - inset * 2
        let knob = NSRect(x: inset + travel * progress, y: inset,
                          width: knobWidth, height: bounds.height - inset * 2)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: knob, xRadius: knob.height / 2, yRadius: knob.height / 2).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .switch }
    override func accessibilityValue() -> Any? { NSNumber(value: isOn) }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
}

/// A menu row with an icon, a title, a status line and a switch. Clicking
/// anywhere on the row flips the switch, and the menu stays open so the
/// change is visible straight away.
final class SwitchRow: NSView {
    private let badge: BadgeView
    private let titleLabel: NSTextField
    private let detailLabel = NSTextField(labelWithString: "")
    private let toggle = ToggleSwitch()
    var onChange: ((Bool) -> Void)?

    init(title: String, symbol: String) {
        badge = BadgeView(symbolName: symbol)
        titleLabel = NSTextField(labelWithString: title)
        super.init(frame: NSRect(x: 0, y: 0, width: 272, height: 44))
        autoresizingMask = .width

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        toggle.setAccessibilityLabel(title)
        toggle.onPress = { [weak self] in self?.flip() }

        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        for v in [badge, text, toggle] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 26),
            badge.heightAnchor.constraint(equalToConstant: 26),
            text.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 10),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -10),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggle.widthAnchor.constraint(equalToConstant: 44),
            toggle.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows a state without calling onChange. Animates if the menu is open.
    func show(_ on: Bool) {
        toggle.setOn(on, animated: window?.isVisible == true)
        badge.isOn = on
    }

    var detail: String {
        get { detailLabel.stringValue }
        set { detailLabel.stringValue = newValue }
    }

    private func flip() {
        let on = !toggle.isOn
        toggle.setOn(on, animated: true)
        badge.isOn = on
        onChange?(on)
    }

    // The whole row is one click target.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        flip()
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let keeper = PowerKeeper()
    private var ticker: Timer?
    private var menuIsOpen = false

    private var isOn = false
    private var lidMode = false
    private var expiry: Date?

    // Menu pieces, built once and refreshed in place by syncMenu().
    private let mainRow = SwitchRow(title: "Stay Awake", symbol: "cup.and.saucer.fill")
    private let lidRow = SwitchRow(title: "Lid Closed", symbol: "laptopcomputer")
    private let durationItem = NSMenuItem(title: "Duration", action: nil, keyEquivalent: "")
    private var durationItems: [Duration: NSMenuItem] = [:]
    private var displayItem: NSMenuItem!
    private var screensaverItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var passwordlessItem: NSMenuItem!

    func applicationDidFinishLaunching(_ note: Notification) {
        Prefs.registerDefaults()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()
        statusItem.menu = menu

        // A previous run may have crashed mid-session; pick up its leftovers.
        if Lid.isDisabled() || UserDefaults.standard.object(forKey: Screensaver.backupKey) != nil {
            lidMode = Lid.isDisabled()
            isOn = lidMode
            if isOn { keeper.setSystem(true); keeper.setDisplay(Prefs.keepDisplayOn) }
        }

        refreshIcon()
        syncMenu()
        // Common modes so the countdown keeps updating while the menu is open.
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        ticker = t

        if !Prefs.hasLaunchedBefore {
            Prefs.hasLaunchedBefore = true
            showWelcome()
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        turnOff()
    }

    // MARK: State

    private func turnOn() {
        expiry = Prefs.duration.seconds.map { Date().addingTimeInterval($0) }
        isOn = true
        keeper.setSystem(true)
        keeper.setDisplay(Prefs.keepDisplayOn)
        if Prefs.disableScreensaver { Screensaver.disable() }
        refreshIcon()
        syncMenu()
    }

    private func turnOff() {
        isOn = false
        expiry = nil
        keeper.setSystem(false)
        keeper.setDisplay(false)
        Screensaver.restore()
        if lidMode {
            Lid.setDisabled(false)
            lidMode = false
        }
        refreshIcon()
        syncMenu()
    }

    private func tick() {
        if let e = expiry, Date() >= e {
            expiry = nil
            afterMenuCloses { [self] in
                turnOff()
                alert("StayAwake timer finished",
                      "Normal sleep, screensaver and lid behaviour have been restored.")
            }
            return
        }
        if menuIsOpen { syncMenu() }
    }

    /// Alerts and password prompts can't appear over an open menu, so close it
    /// and run `work` once menu tracking has finished.
    private func afterMenuCloses(_ work: @escaping () -> Void) {
        menu.cancelTracking()
        RunLoop.main.perform(inModes: [.default], block: work)
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
        let mins = max(1, Int((e.timeIntervalSinceNow / 60).rounded(.up)))
        let h = mins / 60, m = mins % 60
        if h == 0 { return "On, \(m)m left" }
        return m == 0 ? "On, \(h)h left" : "On, \(h)h \(m)m left"
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

              Tip: turn on Launch at Login in Settings so it is always there.
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

    //   [cup]  Stay Awake        (o )
    //   [lid]  Lid Closed        ( o)
    //   ---------------------------
    //   Duration                   >
    //   Settings                   >
    //   ---------------------------
    //   Quit StayAwake            ⌘Q
    private func buildMenu() {
        menu.delegate = self
        menu.showsStateColumn = false

        mainRow.onChange = { [weak self] on in self?.setMain(on) }
        lidRow.onChange = { [weak self] on in self?.setLid(on) }
        for row in [mainRow, lidRow] {
            let item = NSMenuItem()
            item.view = row
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let durations = NSMenu()
        for d in Duration.allCases {
            let item = NSMenuItem(title: d.title, action: #selector(pickDuration(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = d.rawValue
            durations.addItem(item)
            durationItems[d] = item
        }
        durationItem.submenu = durations
        menu.addItem(durationItem)

        let settings = NSMenu()
        displayItem = add(settings, "Keep Display On", #selector(toggleDisplay))
        screensaverItem = add(settings, "Disable Screensaver", #selector(toggleScreensaver))
        settings.addItem(.separator())
        loginItem = add(settings, "Launch at Login", #selector(toggleLogin))
        passwordlessItem = add(settings, "Set Up Passwordless Lid Mode…", #selector(setUpPasswordless))
        settings.addItem(.separator())
        add(settings, "About StayAwake \(appVersion)", #selector(openAbout))
        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.submenu = settings
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit StayAwake", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    private func syncMenu() {
        mainRow.show(isOn)
        mainRow.detail = remainingText()
        lidRow.show(lidMode)
        lidRow.detail = lidMode ? "On, safe to close the lid" : "Off, sleeps when closed"

        let current = Prefs.duration
        for (d, item) in durationItems { item.state = d == current ? .on : .off }
        if #available(macOS 14.4, *) {
            durationItem.subtitle = current.title
        } else {
            durationItem.title = "Duration: \(current.title)"
        }

        displayItem.state = Prefs.keepDisplayOn ? .on : .off
        screensaverItem.state = Prefs.disableScreensaver ? .on : .off
        loginItem.state = launchAtLoginEnabled() ? .on : .off
        passwordlessItem.isHidden = SudoersRule.isInstalled
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        syncMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
    }

    // MARK: Actions

    private func setMain(_ on: Bool) {
        if on {
            turnOn()
            return
        }
        // With the passwordless rule, lid mode switches off without any UI.
        if lidMode, Lid.setSilently(false) { lidMode = false }
        if lidMode {
            afterMenuCloses { [self] in turnOff() }   // will ask for the admin password
        } else {
            turnOff()
        }
    }

    private func setLid(_ want: Bool) {
        guard want != lidMode else { return }
        if Lid.setSilently(want) {
            lidChanged(to: want)
            return
        }

        // Needs a dialog. Put the switch back until it actually succeeds.
        syncMenu()
        afterMenuCloses { [self] in
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
            lidChanged(to: want)
        }
    }

    private func lidChanged(to on: Bool) {
        lidMode = on
        if on, !isOn { turnOn() }
        refreshIcon()
        syncMenu()
    }

    @objc private func pickDuration(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let d = Duration(rawValue: raw) else { return }
        Prefs.duration = d
        turnOn()   // starts it, or restarts the timer if already on
    }

    @objc private func toggleDisplay() {
        Prefs.keepDisplayOn.toggle()
        if isOn { keeper.setDisplay(Prefs.keepDisplayOn) }
    }

    @objc private func toggleScreensaver() {
        Prefs.disableScreensaver.toggle()
        if isOn { Prefs.disableScreensaver ? Screensaver.disable() : Screensaver.restore() }
    }

    @objc private func setUpPasswordless() {
        if SudoersRule.install() {
            Prefs.lidAskEachTime = false
            alert("All set", "Lid mode will no longer ask for your password.")
        }
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
