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
    let priced: Bool
}

struct Total: Decodable {
    let tokens: Double
    let cost: Double
    let messages: Int
    let priced: Bool
}

struct Breakdown: Decodable {
    let total: Total
    let projects: [Entry]
    let models: [Entry]
    let unpriced: [String]
}

/// One reporting window, split by the tool that produced the tokens.
struct Window: Decodable {
    let claude: Breakdown
    let codex: Breakdown
}

struct Windows: Decodable {
    let today: Window
    let week: Window
}

struct Errors: Decodable {
    let claude: String?
    let codex: String?
}

/// One signed-in pair of tools. People who keep several Claude or Codex
/// logins get one of these per account.
struct Account: Decodable {
    let id: String
    let claudeLabel: String
    let codexLabel: String
    let hasClaude: Bool
    let hasCodex: Bool
    let limits: [Limit]
    let breakdowns: Windows
    let errors: Errors

    enum CodingKeys: String, CodingKey {
        case id, limits, breakdowns, errors
        case claudeLabel = "claude_label"
        case codexLabel = "codex_label"
        case hasClaude = "has_claude"
        case hasCodex = "has_codex"
    }
}

struct Report: Decodable {
    let generatedAt: Double
    let accounts: [Account]

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case accounts
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

    /// Pad to a column width, counting East Asian wide characters as two so
    /// Korean project names do not break the alignment.
    static func visualWidth<S: StringProtocol>(_ s: S) -> Int {
        s.reduce(0) { total, ch in
            guard let scalar = ch.unicodeScalars.first else { return total }
            switch scalar.value {
            case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3,
                 0xF900...0xFAFF, 0xFE30...0xFE6F, 0xFF00...0xFF60,
                 0xFFE0...0xFFE6, 0x20000...0x3FFFD:
                return total + 2
            default:
                return total + 1
            }
        }
    }

    static func pad(_ text: String, _ columns: Int) -> String {
        var out = Substring(text)
        while visualWidth(out) > columns { out = out.dropLast() }
        return String(out) + String(repeating: " ", count: max(0, columns - visualWidth(out)))
    }

    /// Right-aligned counterpart to `pad`, for numbers and countdowns.
    static func padLeft(_ text: String, _ columns: Int) -> String {
        let padded = pad(text, columns)
        let trimmed = padded.hasSuffix(" ")
            ? String(padded.reversed().drop { $0 == " " }.reversed()) : padded
        return String(repeating: " ", count: max(0, columns - visualWidth(trimmed))) + trimmed
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
            process.arguments = ["--report"]
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
            } catch is DecodingError {
                // Almost always an app newer than the shell tool it drives.
                DispatchQueue.main.async {
                    self.lastError = "ai-usage is out of date - run: brew upgrade ai-usage"
                    self.render()
                }
            } catch {
                DispatchQueue.main.async {
                    self.lastError = "could not run ai-usage: \(error.localizedDescription)"
                    self.render()
                }
            }
        }
    }

    // MARK: Rendering

    /// The title shows whichever limit sits closest to its ceiling.
    private var mostUrgent: Limit? {
        report?.accounts.flatMap(\.limits).max { $0.percent < $1.percent }
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

    private static let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    /// Width of one digit. Even in a monospaced font a Hangul glyph is not
    /// exactly twice a Latin one, so padding with spaces can never line up
    /// mixed scripts - the columns are tab stops measured in digit widths.
    private static let advance: CGFloat =
        "0".size(withAttributes: [.font: mono]).width

    private static func columns(_ stops: [(CGFloat, NSTextAlignment)]) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.tabStops = stops.map {
            NSTextTab(textAlignment: $0.1, location: $0.0 * advance)
        }
        style.defaultTabInterval = 8 * advance
        return style
    }

    /// A menu item with no action is drawn greyed out and ignores its colours,
    /// so informational rows carry a no-op selector to stay at full contrast.
    private func infoItem(_ title: NSAttributedString) -> NSMenuItem {
        let item = NSMenuItem(title: title.string, action: #selector(noop), keyEquivalent: "")
        item.target = self
        item.attributedTitle = title
        return item
    }

    @objc private func noop() {}

    private func row(_ text: String, color: NSColor) -> NSMenuItem {
        infoItem(NSAttributedString(
            string: text,
            attributes: [.font: Controller.mono, .foregroundColor: color]))
    }

    /// A solid two-tone gauge: the same block for filled and empty, told apart
    /// by colour rather than by texture.
    private func gaugeRow(label: String, percent: Double, trailing: String) -> NSMenuItem {
        let width = 12
        let filled = Int((max(0, min(100, percent)) * Double(width) / 100).rounded())
        let line = NSMutableAttributedString()
        func add(_ text: String, _ color: NSColor) {
            line.append(NSAttributedString(
                string: text,
                attributes: [.font: Controller.mono, .foregroundColor: color]))
        }
        add("  " + label + "\t", .labelColor)
        add(String(repeating: "\u{2588}", count: filled), Palette.color(for: percent))
        add(String(repeating: "\u{2588}", count: width - filled), .quaternaryLabelColor)
        add("\t" + String(format: "%.1f%%", percent), Palette.color(for: percent))
        if !trailing.isEmpty { add("\t" + trailing, .secondaryLabelColor) }
        line.addAttribute(.paragraphStyle,
                          value: Controller.columns([(10, .left), (30, .right), (44, .right)]),
                          range: NSRange(location: 0, length: line.length))
        return infoItem(line)
    }

    /// Sessions are ranked, not gauged: a share of a window's tokens has no
    /// ceiling, so no bar and no heat colour here - just right-aligned numbers.
    private func entryRows(_ entries: [Entry], of total: Double, limit: Int = 4) {
        for entry in entries.prefix(limit) {
            let share = total > 0 ? entry.tokens * 100 / total : 0
            let text = "    " + entry.name
                + "\t" + String(format: "%.1f%%", share)
                + "\t" + Format.tokens(entry.tokens)
            let line = NSMutableAttributedString(
                string: text,
                attributes: [.font: Controller.mono, .foregroundColor: NSColor.labelColor])
            line.addAttribute(.paragraphStyle,
                              value: Controller.columns([(34, .right), (44, .right)]),
                              range: NSRange(location: 0, length: line.length))
            menu.addItem(infoItem(line))
        }
    }

    private func renderWindow(_ title: String, _ window: Window) {
        let claude = window.claude, codex = window.codex
        var summary = title + "   " + Format.tokens(claude.total.tokens + codex.total.tokens)
            + " tok"
        if claude.total.cost > 0 {
            // A model with no published rate contributes tokens but no cost,
            // so the figure is a floor rather than an estimate.
            summary += String(format: claude.total.priced ? "   ~$%.2f" : "   >$%.2f",
                              claude.total.cost)
        }
        menu.addItem(header(summary))

        // Everything is laid out at once - nothing hides behind a toggle.
        for (name, data) in [("claude", claude), ("codex", codex)] {
            guard data.total.tokens > 0 else { continue }
            menu.addItem(row("  \(name) - sessions", color: .secondaryLabelColor))
            entryRows(data.projects, of: data.total.tokens)
            menu.addItem(row("  \(name) - models", color: .secondaryLabelColor))
            entryRows(data.models, of: data.total.tokens)
        }
        menu.addItem(.separator())
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        if let error = lastError {
            menu.addItem(row(error, color: .systemOrange))
            menu.addItem(.separator())
        }

        if let report {
            let now = Date().timeIntervalSince1970
            let labelled = report.accounts.count > 1
            for account in report.accounts {
                for source in ["claude", "codex"] {
                    let isClaude = source == "claude"
                    guard isClaude ? account.hasClaude : account.hasCodex else { continue }
                    let limits = account.limits.filter { $0.source == source }
                    let message = isClaude ? account.errors.claude : account.errors.codex
                    var title = source.uppercased()
                    if labelled {
                        let label = isClaude ? account.claudeLabel : account.codexLabel
                        if !label.isEmpty { title += "  \(label)" }
                    }
                    menu.addItem(header(title))
                    if let message {
                        menu.addItem(row("  " + message, color: .systemOrange))
                    }
                    for limit in limits {
                        let left = limit.resetsAt > 0
                            ? Format.countdown(limit.resetsAt - now) : ""
                        menu.addItem(gaugeRow(label: limit.label,
                                              percent: limit.percent,
                                              trailing: left))
                    }
                    menu.addItem(.separator())
                }

                let suffix = labelled && !account.claudeLabel.isEmpty
                    ? "  \(account.claudeLabel)" : ""
                renderWindow("TODAY" + suffix, account.breakdowns.today)
                renderWindow("LAST 7 DAYS" + suffix, account.breakdowns.week)
            }
        }

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

    @objc private func reloadNow() { refresh() }

    @objc private func openDashboard() {
        guard let tool = toolPath else { return }
        // `open -a Terminal <script>` hands the file to Terminal to execute.
        // NSAppleScript would need Automation consent, which an ad-hoc signed
        // app loses on every rebuild - that is why this did nothing before.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", tool]
        try? process.run()
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
