// AIUsage - a native macOS menu bar front end for `ai-usage`.
//
// All parsing, pricing and aggregation stays in the shell tool; this reads one
// JSON snapshot from `ai-usage --report` and draws it. The countdowns tick once
// a second locally, so the menu stays live between refreshes.

import AppKit

// MARK: - Model

struct Limit: Decodable {
    let source: String
    let label: String
    let percent: Double
    let resetsAt: Double

    enum CodingKeys: String, CodingKey {
        case source, label, percent
        case resetsAt = "resets_at"
    }
}

struct Entry: Decodable {
    let name: String
    let tokens: Double
    let cost: Double
    let messages: Int
}

struct Total: Decodable {
    let tokens: Double
    let cost: Double
    let messages: Int
}

struct Breakdown: Decodable {
    let range: String
    let total: Total
    let projects: [Entry]
    let models: [Entry]
}

struct Errors: Decodable {
    let claude: String?
    let codex: String?
}

struct Report: Decodable {
    let generatedAt: Double
    let limits: [Limit]
    let breakdown: Breakdown
    let errors: Errors

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case limits, breakdown, errors
    }
}

// MARK: - Presentation

enum Palette {
    /// The same seven-stop ramp the terminal view uses.
    static func color(for percent: Double) -> NSColor {
        switch percent {
        case ..<20:  return NSColor(srgbRed: 0.18, green: 0.63, blue: 0.26, alpha: 1)
        case ..<35:  return NSColor(srgbRed: 0.25, green: 0.73, blue: 0.31, alpha: 1)
        case ..<50:  return NSColor(srgbRed: 0.48, green: 0.79, blue: 0.44, alpha: 1)
        case ..<65:  return NSColor(srgbRed: 0.83, green: 0.65, blue: 0.17, alpha: 1)
        case ..<78:  return NSColor(srgbRed: 0.89, green: 0.53, blue: 0.17, alpha: 1)
        case ..<90:  return NSColor(srgbRed: 0.94, green: 0.53, blue: 0.24, alpha: 1)
        default:     return NSColor(srgbRed: 0.97, green: 0.32, blue: 0.29, alpha: 1)
        }
    }
}

enum Format {
    static func countdown(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60, sec = s % 60
        if d > 0 { return String(format: "%dd %02d:%02d:%02d", d, h, m, sec) }
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }

    static func tokens(_ n: Double) -> String {
        if n >= 1_000_000_000 { return String(format: "%.2fB", n / 1_000_000_000) }
        if n >= 1_000_000 { return String(format: "%.1fM", n / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fK", n / 1_000) }
        return String(format: "%.0f", n)
    }

    /// A block-character gauge, for the monospaced menu rows.
    static func bar(_ percent: Double, width: Int) -> String {
        let filled = Int((max(0, min(100, percent)) * Double(width) / 100).rounded())
        return String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
    }
}

/// A real drawn gauge for the status item, rather than block characters.
func gaugeImage(percent: Double, width: CGFloat = 26, height: CGFloat = 9) -> NSImage {
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    let radius = height / 2
    let track = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: height),
                             xRadius: radius, yRadius: radius)
    NSColor.tertiaryLabelColor.setFill()
    track.fill()

    let fraction = max(0, min(100, percent)) / 100
    let fillWidth = max(fraction > 0 ? height : 0, width * fraction)
    let fill = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: fillWidth, height: height),
                            xRadius: radius, yRadius: radius)
    Palette.color(for: percent).setFill()
    fill.fill()
    image.unlockFocus()
    image.isTemplate = false
    return image
}

// MARK: - App

final class Controller: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var report: Report?
    private var lastError: String?
    private var refreshTimer: Timer?
    private var tickTimer: Timer?
    private var menuIsOpen = false
    private var range = "today"

    /// The tool is looked up on PATH, then in the usual install locations, so
    /// the app works whether it came from Homebrew, npm or a checkout.
    private lazy var toolPath: String? = {
        let candidates = [
            "/opt/homebrew/bin/ai-usage",
            "/usr/local/bin/ai-usage",
            NSHomeDirectory() + "/.local/bin/ai-usage",
            NSHomeDirectory() + "/bin/ai-usage",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    func start() {
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageLeading
        render()
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.menuIsOpen else { return }
            self.rebuildMenu()
        }
    }

    // MARK: Data

    private func refresh() {
        guard let tool = toolPath else {
            lastError = "ai-usage was not found on this machine"
            DispatchQueue.main.async { self.render() }
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = ["--report", "--days", self.range == "today" ? "1" : "7"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let decoded = try JSONDecoder().decode(Report.self, from: data)
                DispatchQueue.main.async {
                    self.report = decoded
                    self.lastError = nil
                    self.render()
                }
            } catch {
                DispatchQueue.main.async {
                    self.lastError = "could not read usage: \(error.localizedDescription)"
                    self.render()
                }
            }
        }
    }

    // MARK: Rendering

    /// The title shows whichever limit sits closest to its ceiling.
    private var mostUrgent: Limit? {
        report?.limits.max { $0.percent < $1.percent }
    }

    private func render() {
        guard let button = statusItem.button else { return }
        if let limit = mostUrgent {
            button.image = gaugeImage(percent: limit.percent)
            button.attributedTitle = NSAttributedString(
                string: String(format: " %.0f%%", limit.percent),
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: Palette.color(for: limit.percent),
                ])
        } else {
            button.image = gaugeImage(percent: 0)
            button.attributedTitle = NSAttributedString(
                string: " --",
                attributes: [.foregroundColor: NSColor.secondaryLabelColor])
        }
        rebuildMenu()
    }

    private func header(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        item.isEnabled = false
        return item
    }

    private func row(_ text: String, color: NSColor) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: color,
            ])
        item.isEnabled = false
        return item
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        if let error = lastError {
            menu.addItem(row(error, color: .systemOrange))
            menu.addItem(.separator())
        }

        if let report {
            let now = Date().timeIntervalSince1970
            for source in ["claude", "codex"] {
                let limits = report.limits.filter { $0.source == source }
                let message = source == "claude" ? report.errors.claude : report.errors.codex
                if limits.isEmpty && message == nil { continue }
                menu.addItem(header(source.uppercased()))
                if let message {
                    menu.addItem(row("  " + message, color: .systemOrange))
                }
                for limit in limits {
                    let left = limit.resetsAt > 0
                        ? Format.countdown(limit.resetsAt - now) : ""
                    let text = String(format: "  %-8@ %@ %5.1f%%  %@",
                                      limit.label as NSString,
                                      Format.bar(limit.percent, width: 12),
                                      limit.percent, left)
                    menu.addItem(row(text, color: Palette.color(for: limit.percent)))
                }
                menu.addItem(.separator())
            }

            let total = report.breakdown.total
            menu.addItem(header("\(report.breakdown.range.uppercased())  "
                + "\(Format.tokens(total.tokens)) tok  ~$\(String(format: "%.2f", total.cost))  "
                + "\(total.messages) msgs"))
            // Sessions are ranked, not gauged: a share of today's tokens has no
            // ceiling to fill, so a bar and a heat colour would both mislead.
            for entry in report.breakdown.projects.prefix(5) {
                let share = total.tokens > 0 ? entry.tokens * 100 / total.tokens : 0
                let text = String(format: "  %-24@ %5.1f%%  %@",
                                  String(entry.name.prefix(24)) as NSString, share,
                                  Format.tokens(entry.tokens))
                menu.addItem(row(text, color: .labelColor))
            }
            menu.addItem(.separator())
        }

        let toggle = NSMenuItem(title: range == "today" ? "Show last 7 days" : "Show today",
                                action: #selector(toggleRange), keyEquivalent: "d")
        toggle.target = self
        menu.addItem(toggle)

        let dashboard = NSMenuItem(title: "Open dashboard", action: #selector(openDashboard),
                                   keyEquivalent: "o")
        dashboard.target = self
        menu.addItem(dashboard)

        let reload = NSMenuItem(title: "Refresh now", action: #selector(reloadNow),
                                keyEquivalent: "r")
        reload.target = self
        menu.addItem(reload)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)
    }

    // MARK: Actions

    @objc private func toggleRange() {
        range = range == "today" ? "7d" : "today"
        refresh()
    }

    @objc private func reloadNow() { refresh() }

    @objc private func openDashboard() {
        guard let tool = toolPath else { return }
        let script = "tell application \"Terminal\"\n"
            + "activate\ndo script \"\(tool)\"\nend tell"
        if let apple = NSAppleScript(source: script) {
            var error: NSDictionary?
            apple.executeAndReturnError(&error)
        }
    }

    // MARK: NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        if let report, Date().timeIntervalSince1970 - report.generatedAt > 60 { refresh() }
    }

    func menuDidClose(_ menu: NSMenu) { menuIsOpen = false }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller()
controller.start()
app.run()
