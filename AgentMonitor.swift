// AgentMonitor — menu bar dots for Claude Code sessions in iTerm2.
//
// One dot per Claude Code session, fed by iTerm2's cc-status hook data:
//   green  = working
//   yellow = attention needed (permission prompt / waiting on you)
//   red    = stopped (done, idle, or error)
//
// Polls `it2 session list` + `it2 session get-status` every 2 seconds.
// Clicking an agent in the menu focuses its iTerm2 session.
//
// Build: swiftc -O AgentMonitor.swift -o AgentMonitor

import Cocoa

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

struct Agent {
    let sessionID: String
    let status: String      // working | waiting | done | idle | error
    let detail: String?
    let path: String
    let jobName: String
    let sortKey: String

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
    var dotColor: NSColor { ColorStore.color(for: DotState(status: status)) }
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

// MARK: - Settings window

final class SettingsWindowController: NSObject {
    private var window: NSWindow?
    private var wells: [DotState: NSColorWell] = [:]
    var onChange: () -> Void = {}

    func show() {
        if window == nil { build() }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let grid = NSGridView()
        grid.rowSpacing = 10
        grid.columnSpacing = 16

        let header = NSTextField(labelWithString: "Dot colors")
        header.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        grid.addRow(with: [header, NSGridCell.emptyContentView])

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
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var agents: [Agent] = []
    var iterm2Reachable = true
    let pollQueue = DispatchQueue(label: "agent-monitor.poll")
    let settings = SettingsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings.onChange = { [weak self] in self?.render() }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        render()

        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        timer?.tolerance = 0.5
        poll()
    }

    func poll() {
        pollQueue.async { [weak self] in
            let result = pollAgents()
            DispatchQueue.main.async {
                guard let self else { return }
                self.iterm2Reachable = (result != nil)
                self.agents = result ?? []
                self.render()
            }
        }
    }

    func render() {
        guard let button = statusItem.button else { return }
        let title = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: 14, weight: .bold)
        if agents.isEmpty {
            let dim = NSColor.secondaryLabelColor
            title.append(NSAttributedString(string: "○", attributes: [.font: font, .foregroundColor: dim]))
        } else {
            for (i, agent) in agents.enumerated() {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: agent.dotColor,
                    .kern: i == agents.count - 1 ? 0 : 2,
                ]
                title.append(NSAttributedString(string: "●", attributes: attrs))
            }
        }
        button.attributedTitle = title
    }

    // Rebuild the dropdown each time it opens, from the latest poll.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if !iterm2Reachable {
            menu.addItem(disabledItem("iTerm2 not reachable"))
        } else if agents.isEmpty {
            menu.addItem(disabledItem("No active Claude Code sessions"))
        } else {
            for agent in agents {
                let item = NSMenuItem(title: "", action: #selector(focusAgent(_:)), keyEquivalent: "")
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
                item.attributedTitle = label
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let quit = NSMenuItem(title: "Quit Agent Monitor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc func openSettings() {
        settings.show()
    }

    func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc func focusAgent(_ sender: NSMenuItem) {
        guard let sessionID = sender.representedObject as? String else { return }
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
