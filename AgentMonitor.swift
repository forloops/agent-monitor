// AgentMonitor — menu bar dots for Claude Code and Codex sessions in iTerm2.
//
// One dot per agent session, fed by iTerm2's per-session status store:
//   green  = working
//   yellow = attention needed (permission prompt / waiting on you)
//   red    = stopped (done, idle, or error)
//
// Polls `it2 session list` + `it2 session get-status` every 2 seconds.
// Clicking an agent in the menu focuses its iTerm2 session.
//
// Build: ./install.sh (wraps the binary in AgentMonitor.app — notifications
// need a bundle identifier, so running the bare binary disables them).

import Cocoa
import Carbon.HIToolbox
import UserNotifications

// iTerm2's bundled CLI, checked in the standard install locations, then PATH.
// If it resolves nowhere, polls fail and the menu shows "iTerm2 not reachable".
let it2Path: String = {
    let candidates = [
        "/Applications/iTerm.app/Contents/Resources/utilities/it2",
        ("~/Applications/iTerm.app/Contents/Resources/utilities/it2" as NSString).expandingTildeInPath,
    ]
    if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
        return found
    }
    let which = Process()
    which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    which.arguments = ["it2"]
    let pipe = Pipe()
    which.standardOutput = pipe
    which.standardError = Pipe()
    try? which.run()
    which.waitUntilExit()
    let fromPath = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return fromPath.isEmpty ? candidates[0] : fromPath
}()
let pollInterval: TimeInterval = 2.0

// MARK: - Dot states & colors

enum DotState: String, CaseIterable {
    case working, attention, stopped

    init(status: String) {
        switch status {
        case "working": self = .working
        case "waiting": self = .attention
        default:        self = .stopped   // done, idle, error
        }
    }

    var label: String {
        switch self {
        case .working:   return "Working"
        case .attention: return "Attention needed"
        case .stopped:   return "Stopped"
        }
    }

    var defaultColor: NSColor {
        switch self {
        case .working:   return .systemGreen
        case .attention: return .systemYellow
        case .stopped:   return .systemRed
        }
    }

    var defaultsKey: String { "color-\(rawValue)" }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                  green: CGFloat((v >> 8) & 0xff) / 255,
                  blue: CGFloat(v & 0xff) / 255,
                  alpha: 1)
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X",
                      Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }
}

/// Dot colors, overridable from the Settings window. Overrides are stored in
/// UserDefaults as hex strings; absent keys fall back to the system defaults.
enum ColorStore {
    static func color(for state: DotState) -> NSColor {
        if let hex = UserDefaults.standard.string(forKey: state.defaultsKey),
           let custom = NSColor(hex: hex) {
            return custom
        }
        return state.defaultColor
    }

    static func set(_ color: NSColor, for state: DotState) {
        UserDefaults.standard.set(color.hexString, forKey: state.defaultsKey)
    }

    static func resetAll() {
        for state in DotState.allCases {
            UserDefaults.standard.removeObject(forKey: state.defaultsKey)
        }
    }
}

// MARK: - Preferences

/// Behaviour toggles from the Settings window (UserDefaults; absent = default).
enum Prefs {
    private static let d = UserDefaults.standard
    private static func bool(_ key: String, default def: Bool) -> Bool {
        d.object(forKey: key) as? Bool ?? def
    }

    static var notifyAttention: Bool {
        get { bool("notify-attention", default: true) }
        set { d.set(newValue, forKey: "notify-attention") }
    }
    static var notifyDone: Bool {
        get { bool("notify-done", default: true) }
        set { d.set(newValue, forKey: "notify-done") }
    }
    static var hotkeyEnabled: Bool {
        get { bool("hotkey-enabled", default: true) }
        set { d.set(newValue, forKey: "hotkey-enabled") }
    }
    /// Minutes after which a stopped session disappears from the bar; 0 = never.
    static var hideStoppedAfterMinutes: Int {
        get { d.integer(forKey: "hide-stopped-after") }
        set { d.set(newValue, forKey: "hide-stopped-after") }
    }
    static let hideStoppedChoices = [0, 1, 2, 5, 10, 30, 60]
}

// MARK: - Agents

struct Agent {
    let sessionID: String
    let status: String      // working | waiting | done | idle | error
    let detail: String?
    let path: String
    let jobName: String
    let sortKey: String
    var since = Date()      // when the current status was first observed

    var projectName: String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? "unknown" : name
    }
    // "codex" comes through the detail field (set by our hook); Claude Code
    // sessions are identified by their foreground job name.
    var agentName: String {
        if let detail, !detail.isEmpty { return detail }
        return jobName.isEmpty ? "agent" : jobName
    }
    var state: DotState { DotState(status: status) }
    var dotColor: NSColor { ColorStore.color(for: state) }

    func elapsed(at now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(since))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }
}

// A session whose foreground job dropped back to a plain shell has no agent
// running any more, even if a stale status is still stored for it.
let plainShells: Set<String> = ["zsh", "bash", "fish", "sh", "tcsh", "csh", "ksh", "nu",
                                "-zsh", "-bash", "login"]

/// Runs it2 synchronously (call off the main thread) and returns stdout, or nil on failure.
func runIt2(_ args: [String]) -> Data? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: it2Path)
    proc.arguments = args
    let out = Pipe()
    proc.standardOutput = out
    proc.standardError = Pipe()
    do { try proc.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    return proc.terminationStatus == 0 ? data : nil
}

func pollAgents() -> [Agent]? {
    guard let listData = runIt2(["session", "list", "--json", "--format",
                                 "\\(session.path)\t\\(session.jobName)"]),
          let sessions = try? JSONSerialization.jsonObject(with: listData) as? [[String: Any]]
    else { return nil }  // iTerm2 not running or API unreachable

    var agents: [Agent] = []
    for session in sessions {
        guard let id = session["id"] as? String else { continue }
        let formatted = (session["formatted"] as? String ?? "").components(separatedBy: "\t")
        let path = formatted.first ?? ""
        let jobName = formatted.count > 1 ? formatted[1] : ""
        if plainShells.contains(jobName) { continue }  // agent exited; stale status

        guard let statusData = runIt2(["session", "get-status", "-s", id]),
              let statusObj = try? JSONSerialization.jsonObject(with: statusData) as? [String: Any],
              let status = statusObj["status"] as? String
        else { continue }  // no status set -> no agent registered in this session

        let windowID = session["window_id"] as? String ?? ""
        let tabID = session["tab_id"] as? String ?? ""
        agents.append(Agent(
            sessionID: id,
            status: status,
            detail: statusObj["detail"] as? String,
            path: path,
            jobName: jobName,
            sortKey: "\(windowID)/\(tabID)/\(id)"
        ))
    }
    return agents.sorted { $0.sortKey < $1.sortKey }
}

// MARK: - Notifications

/// macOS notifications for status transitions. UNUserNotificationCenter aborts
/// the process when there is no bundle identifier (bare binary), so everything
/// is a no-op outside AgentMonitor.app.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let available = Bundle.main.bundleIdentifier != nil
    var onActivate: (String) -> Void = { _ in }

    func setup() {
        guard Notifier.available else {
            NSLog("Notifications disabled: not running from an app bundle")
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { NSLog("Notification authorization failed: \(error)") }
            else if !granted { NSLog("Notifications not granted") }
        }
    }

    func post(id: String, title: String, body: String, sessionID: String) {
        guard Notifier.available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["session": sessionID]
        content.threadIdentifier = sessionID
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { NSLog("Notification failed: \(error)") }
        }
    }

    func remove(id: String) {
        guard Notifier.available else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let session = response.notification.request.content.userInfo["session"] as? String {
            onActivate(session)
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - Global hotkey (Carbon; works without Accessibility permission)

final class HotKey {
    static let keyCode = UInt32(kVK_ANSI_A)
    static let modifiers = UInt32(controlKey | optionKey)
    static let display = "⌃⌥A"

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    var action: () -> Void = {}

    func register() {
        guard hotKeyRef == nil else { return }
        if handlerRef == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                          eventKind: UInt32(kEventHotKeyPressed))
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
                guard let userData else { return noErr }
                Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue().action()
                return noErr
            }, 1, &eventType, selfPtr, &handlerRef)
        }
        let hotKeyID = EventHotKeyID(signature: 0x414D_4F4E /* 'AMON' */, id: 1)
        let status = RegisterEventHotKey(HotKey.keyCode, HotKey.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr { NSLog("RegisterEventHotKey failed: \(status)") }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }
}

// MARK: - Settings window

final class SettingsWindowController: NSObject {
    private var window: NSWindow?
    private var wells: [DotState: NSColorWell] = [:]
    private var hidePopup: NSPopUpButton?
    var onChange: () -> Void = {}

    func show() {
        if window == nil { build() }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func header(_ text: String) -> NSTextField {
        let h = NSTextField(labelWithString: text)
        h.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return h
    }

    private func checkbox(_ title: String, on: Bool, action: Selector) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: action)
        b.state = on ? .on : .off
        return b
    }

    private func build() {
        let grid = NSGridView()
        grid.rowSpacing = 10
        grid.columnSpacing = 16

        grid.addRow(with: [header("Dot colors"), NSGridCell.emptyContentView])
        for state in DotState.allCases {
            let label = NSTextField(labelWithString: state.label)
            let well = NSColorWell()
            well.color = ColorStore.color(for: state)
            well.target = self
            well.action = #selector(colorChanged(_:))
            well.translatesAutoresizingMaskIntoConstraints = false
            well.widthAnchor.constraint(equalToConstant: 56).isActive = true
            well.heightAnchor.constraint(equalToConstant: 24).isActive = true
            wells[state] = well
            grid.addRow(with: [label, well])
        }
        let reset = NSButton(title: "Reset to Defaults", target: self,
                             action: #selector(resetDefaults))
        grid.addRow(with: [reset, NSGridCell.emptyContentView])

        grid.addRow(with: [header("Notifications"), NSGridCell.emptyContentView])
        grid.addRow(with: [checkbox("When an agent needs attention",
                                    on: Prefs.notifyAttention,
                                    action: #selector(toggleNotifyAttention(_:))),
                           NSGridCell.emptyContentView])
        grid.addRow(with: [checkbox("When an agent finishes its turn",
                                    on: Prefs.notifyDone,
                                    action: #selector(toggleNotifyDone(_:))),
                           NSGridCell.emptyContentView])
        if !Notifier.available {
            let note = NSTextField(wrappingLabelWithString:
                "Notifications need the app bundle — rerun ./install.sh")
            note.textColor = .secondaryLabelColor
            note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            grid.addRow(with: [note, NSGridCell.emptyContentView])
        }

        grid.addRow(with: [header("Keyboard"), NSGridCell.emptyContentView])
        grid.addRow(with: [checkbox("\(HotKey.display) focuses the next waiting agent",
                                    on: Prefs.hotkeyEnabled,
                                    action: #selector(toggleHotkey(_:))),
                           NSGridCell.emptyContentView])

        grid.addRow(with: [header("Stopped sessions"), NSGridCell.emptyContentView])
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        var choices = Prefs.hideStoppedChoices
        if !choices.contains(Prefs.hideStoppedAfterMinutes) {
            choices.append(Prefs.hideStoppedAfterMinutes)
            choices.sort()
        }
        for m in choices {
            popup.addItem(withTitle: m == 0 ? "Never" : "after \(m) min")
            popup.lastItem?.tag = m
        }
        popup.selectItem(withTag: Prefs.hideStoppedAfterMinutes)
        popup.target = self
        popup.action = #selector(hideStoppedChanged(_:))
        hidePopup = popup
        grid.addRow(with: [NSTextField(labelWithString: "Hide from the bar"), popup])

        for row in 0..<grid.numberOfRows where grid.cell(atColumnIndex: 1, rowIndex: row).contentView == nil {
            grid.mergeCells(inHorizontalRange: NSRange(location: 0, length: 2),
                            verticalRange: NSRange(location: row, length: 1))
        }

        let container = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
        ])

        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "Agent Monitor Settings"
        w.isReleasedWhenClosed = false
        w.contentView = container
        w.setContentSize(container.fittingSize)
        window = w
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        guard let state = wells.first(where: { $0.value === sender })?.key else { return }
        ColorStore.set(sender.color, for: state)
        onChange()
    }

    @objc private func resetDefaults() {
        ColorStore.resetAll()
        for (state, well) in wells { well.color = state.defaultColor }
        onChange()
    }

    @objc private func toggleNotifyAttention(_ sender: NSButton) {
        Prefs.notifyAttention = sender.state == .on
    }

    @objc private func toggleNotifyDone(_ sender: NSButton) {
        Prefs.notifyDone = sender.state == .on
    }

    @objc private func toggleHotkey(_ sender: NSButton) {
        Prefs.hotkeyEnabled = sender.state == .on
        onChange()
    }

    @objc private func hideStoppedChanged(_ sender: NSPopUpButton) {
        Prefs.hideStoppedAfterMinutes = sender.selectedTag()
        onChange()
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var agents: [Agent] = []          // everything the last poll returned
    var iterm2Reachable = true
    var lastFocused: String?          // session the hotkey focused most recently
    let pollQueue = DispatchQueue(label: "agent-monitor.poll")
    let settings = SettingsWindowController()
    let notifier = Notifier()
    let hotKey = HotKey()

    /// Agents shown in the bar and menu: stopped ones age out per Prefs.
    var visibleAgents: [Agent] {
        let limit = Prefs.hideStoppedAfterMinutes
        guard limit > 0 else { return agents }
        let cutoff = Date().addingTimeInterval(-Double(limit) * 60)
        return agents.filter { $0.state != .stopped || $0.since > cutoff }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings.onChange = { [weak self] in self?.applyPrefs() }
        notifier.onActivate = { [weak self] session in self?.focus(sessionID: session) }
        notifier.setup()
        hotKey.action = { [weak self] in self?.focusNextWaiting() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        applyPrefs()

        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        timer?.tolerance = 0.5
        poll()
    }

    func applyPrefs() {
        if Prefs.hotkeyEnabled { hotKey.register() } else { hotKey.unregister() }
        render()
    }

    func poll() {
        pollQueue.async { [weak self] in
            let result = pollAgents()
            DispatchQueue.main.async {
                guard let self else { return }
                self.iterm2Reachable = (result != nil)
                self.agents = self.track(result ?? [])
                self.render()
            }
        }
    }

    /// Carries `since` over for unchanged statuses and fires notifications on
    /// transitions. Runs on the main thread.
    func track(_ polled: [Agent]) -> [Agent] {
        let previous = Dictionary(uniqueKeysWithValues: agents.map { ($0.sessionID, $0) })
        let now = Date()
        return polled.map { fresh in
            var agent = fresh
            let prev = previous[agent.sessionID]
            if let prev, prev.status == agent.status {
                agent.since = prev.since
                return agent
            }
            agent.since = now
            let name = "\(agent.projectName) · \(agent.agentName)"
            let attentionID = "attention-\(agent.sessionID)"
            switch agent.status {
            case "waiting":
                if Prefs.notifyAttention {
                    notifier.post(id: attentionID, title: name,
                                  body: "Needs your attention", sessionID: agent.sessionID)
                }
            case "done":
                notifier.remove(id: attentionID)
                // Only a turn we watched run counts; a session first seen as
                // "done" (e.g. right after the app started) is old news.
                if let prev, prev.state != .stopped, Prefs.notifyDone {
                    notifier.post(id: "done-\(agent.sessionID)", title: name,
                                  body: "Finished its turn", sessionID: agent.sessionID)
                }
            default:
                notifier.remove(id: attentionID)
            }
            return agent
        }
    }

    func render() {
        guard let button = statusItem.button else { return }
        let shown = visibleAgents
        let title = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: 14, weight: .bold)
        if shown.isEmpty {
            let dim = NSColor.secondaryLabelColor
            title.append(NSAttributedString(string: "○", attributes: [.font: font, .foregroundColor: dim]))
        } else {
            for (i, agent) in shown.enumerated() {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: agent.dotColor,
                    .kern: i == shown.count - 1 ? 0 : 2,
                ]
                title.append(NSAttributedString(string: "●", attributes: attrs))
            }
        }
        button.attributedTitle = title
    }

    // Rebuild the dropdown each time it opens, from the latest poll.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let shown = visibleAgents
        let hidden = agents.count - shown.count

        if !iterm2Reachable {
            menu.addItem(disabledItem("iTerm2 not reachable"))
        } else if shown.isEmpty {
            menu.addItem(disabledItem("No active agent sessions"))
        } else {
            let now = Date()
            for (i, agent) in shown.enumerated() {
                // Digits 1–9 pick a row while the menu is open.
                let key = i < 9 ? String(i + 1) : ""
                let item = NSMenuItem(title: "", action: #selector(focusAgent(_:)), keyEquivalent: key)
                item.keyEquivalentModifierMask = []
                item.target = self
                item.representedObject = agent.sessionID

                let label = NSMutableAttributedString()
                label.append(NSAttributedString(string: "● ", attributes: [
                    .foregroundColor: agent.dotColor,
                    .font: NSFont.menuFont(ofSize: 0),
                ]))
                let text = "\(agent.projectName) · \(agent.agentName) — \(agent.status)"
                label.append(NSAttributedString(string: text, attributes: [
                    .font: NSFont.menuFont(ofSize: 0),
                ]))
                label.append(NSAttributedString(string: "  \(agent.elapsed(at: now))", attributes: [
                    .font: NSFont.menuFont(ofSize: 0),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
                item.attributedTitle = label
                menu.addItem(item)
            }
        }
        if hidden > 0 {
            menu.addItem(disabledItem("\(hidden) stopped session\(hidden == 1 ? "" : "s") hidden"))
        }

        menu.addItem(.separator())
        let next = NSMenuItem(title: "Focus Next Waiting Agent", action: #selector(focusNextWaitingItem),
                              keyEquivalent: Prefs.hotkeyEnabled ? "a" : "")
        next.keyEquivalentModifierMask = [.control, .option]
        next.target = self
        next.isEnabled = !shown.isEmpty
        menu.addItem(next)
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let quit = NSMenuItem(title: "Quit Agent Monitor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc func openSettings() {
        settings.show()
    }

    @objc func focusNextWaitingItem() {
        focusNextWaiting()
    }

    func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc func focusAgent(_ sender: NSMenuItem) {
        guard let sessionID = sender.representedObject as? String else { return }
        focus(sessionID: sessionID)
    }

    /// Cycles through agents needing attention; with none waiting, through all
    /// visible agents, so the shortcut always lands somewhere useful.
    func focusNextWaiting() {
        let shown = visibleAgents
        var candidates = shown.filter { $0.state == .attention }
        if candidates.isEmpty { candidates = shown }
        guard !candidates.isEmpty else { return }
        var index = 0
        if let last = lastFocused, let i = candidates.firstIndex(where: { $0.sessionID == last }) {
            index = (i + 1) % candidates.count
        }
        focus(sessionID: candidates[index].sessionID)
    }

    func focus(sessionID: String) {
        lastFocused = sessionID
        pollQueue.async {
            _ = runIt2(["session", "focus", "-s", sessionID])
        }
        if let iterm = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") {
            NSWorkspace.shared.openApplication(at: iterm, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
