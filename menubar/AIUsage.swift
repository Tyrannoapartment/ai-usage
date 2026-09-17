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
    // Grok has no quota endpoint, so it shows up in the breakdown only.
    let grok: Breakdown?
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

enum Brand {
    /// Claude's coral and OpenAI's green, so the two vendors are told apart by
    /// colour before the text is read.
    static let claude = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
    // OpenAI's own mark is monochrome; on the menu bar it reads better as plain
    // foreground than as green, which went muddy against a translucent bar.
    static let codex  = NSColor.labelColor

    static func name(_ source: String) -> String {
        source == "claude" ? "Claude" : "Codex"
    }

    static func color(_ source: String) -> NSColor {
        source == "claude" ? claude : codex
    }

    /// The limit labels ride along beside the numbers, so they are the same
    /// hue as their vendor but stepped back.
    static func muted(_ source: String) -> NSColor {
        color(source).withAlphaComponent(0.65)
    }

    /// weekly is the common case and the widest label; nothing else is touched.
    static func shortLabel(_ label: String) -> String {
        label == "weekly" ? "wk" : label
    }

    /// Two characters is all the menu bar can spare under a bar.
    static func tinyLabel(_ label: String) -> String {
        String(shortLabel(label).prefix(2))
    }
}

enum Palette {
    /// The same seven-stop ramp the terminal view uses.
    static func color(for percent: Double) -> NSColor {
        switch percent {
        // Red arrives before the ceiling does: four fifths of a limit should
        // already read as a warning rather than a comfortable orange.
        case ..<20:  return NSColor(srgbRed: 0.18, green: 0.63, blue: 0.26, alpha: 1)
        case ..<40:  return NSColor(srgbRed: 0.25, green: 0.73, blue: 0.31, alpha: 1)
        case ..<55:  return NSColor(srgbRed: 0.48, green: 0.79, blue: 0.44, alpha: 1)
        case ..<68:  return NSColor(srgbRed: 0.85, green: 0.68, blue: 0.16, alpha: 1)
        case ..<76:  return NSColor(srgbRed: 0.91, green: 0.53, blue: 0.15, alpha: 1)
        case ..<82:  return NSColor(srgbRed: 0.95, green: 0.38, blue: 0.16, alpha: 1)
        case ..<90:  return NSColor(srgbRed: 0.95, green: 0.24, blue: 0.20, alpha: 1)
        default:     return NSColor(srgbRed: 0.85, green: 0.13, blue: 0.13, alpha: 1)
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

/// Which status-item treatment to draw. Set AI_USAGE_STYLE to try another
/// without a rebuild: rings, bars, number, cards, dots.
enum Style: String {
    case hbars, all, urgent, rings, bars, number, cards, dots, shapes, letters, logo

    static var current: Style {
        Style(rawValue: ProcessInfo.processInfo.environment["AI_USAGE_STYLE"] ?? "") ?? .hbars
    }
}

/// One ring per vendor: the track carries the vendor's colour so the two are
/// told apart without a word, and the filled arc carries how much is gone.
struct Ring {
    enum Shape { case circle, square }
    let track: NSColor
    let percent: Double
    let shape: Shape
}

func ringsImage(_ rings: [Ring],
                diameter: CGFloat = 14,
                gap: CGFloat = 5,
                thickness: CGFloat = 2.5) -> NSImage {
    let width = CGFloat(rings.count) * diameter + CGFloat(max(0, rings.count - 1)) * gap
    let image = NSImage(size: NSSize(width: max(width, diameter), height: diameter))
    image.lockFocus()
    NSGraphicsContext.current?.cgContext.setLineCap(.round)

    for (index, ring) in rings.enumerated() {
        let origin = CGFloat(index) * (diameter + gap)
        let inset = thickness / 2
        let centre = NSPoint(x: origin + diameter / 2, y: diameter / 2)
        let radius = diameter / 2 - inset

        let track = NSBezierPath()
        track.appendArc(withCenter: centre, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = thickness
        ring.track.withAlphaComponent(0.30).setStroke()
        track.stroke()

        let fraction = max(0, min(100, ring.percent)) / 100
        guard fraction > 0 else { continue }
        // Start at twelve o'clock and fill clockwise, the way a dial is read.
        let filled = NSBezierPath()
        filled.appendArc(withCenter: centre, radius: radius,
                         startAngle: 90, endAngle: 90 - 360 * fraction,
                         clockwise: true)
        filled.lineWidth = thickness
        Palette.color(for: ring.percent).setStroke()
        filled.stroke()
    }

    image.unlockFocus()
    image.isTemplate = false
    return image
}

/// A row of horizontal meters: label, then a capsule that fills left to right.
/// Vendors are set apart by a wider gap and by the tint of their labels.
func hbarsImage(_ columns: [Column]) -> NSImage {
    let barW: CGFloat = 22, barH: CGFloat = 6, pad: CGFloat = 4
    let gap: CGFloat = 8, markSize: CGFloat = 12, markPad: CGFloat = 5
    let vendorGap: CGFloat = 11
    let height: CGFloat = 16
    let font = NSFont.systemFont(ofSize: 9, weight: .medium)

    // The menu bar is a monochrome place. Colour is spent where it earns
    // attention: the vendor mark, and a meter once it is worth worrying about.
    func fill(_ percent: Double) -> NSColor {
        percent < 60
            ? NSColor.labelColor.withAlphaComponent(0.80)
            : Palette.color(for: percent)
    }

    var labelWidths: [CGFloat] = []
    for column in columns {
        labelWidths.append(ceil(column.label.size(withAttributes: [.font: font]).width))
    }
    var total: CGFloat = 0
    for (i, lw) in labelWidths.enumerated() {
        if columns[i].startsVendor {
            if i > 0 { total += vendorGap }
            total += markSize + markPad
        } else if i > 0 {
            total += gap
        }
        total += lw + pad + barW
    }

    let image = NSImage(size: NSSize(width: max(total, barW), height: height))
    image.lockFocus()

    var x: CGFloat = 0
    for (i, column) in columns.enumerated() {
        if column.startsVendor {
            if i > 0 { x += vendorGap }
            // Claude's mark is mostly air between thin rays, so it reads smaller
            // than the solid knot at the same box size; give it more room.
            let drawn = markSize * (column.isClaude ? 1.3 : 1.0)
            let box = NSRect(x: x + (markSize - drawn) / 2, y: (height - drawn) / 2,
                             width: drawn, height: drawn)
            let mark = Mark.path(column.isClaude ? Mark.claude : Mark.codex, in: box)
            column.tint.setFill()
            mark.fill()
            x += markSize + markPad
        } else if i > 0 {
            x += gap
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.labelColor.withAlphaComponent(0.75)]
        let measured = column.label.size(withAttributes: attrs)
        column.label.draw(at: NSPoint(x: x, y: (height - measured.height) / 2 + 0.5),
                          withAttributes: attrs)
        x += labelWidths[i] + pad

        let box = NSRect(x: x, y: (height - barH) / 2, width: barW, height: barH)
        let track = NSBezierPath(roundedRect: box, xRadius: barH / 2, yRadius: barH / 2)
        NSColor.labelColor.withAlphaComponent(0.18).setFill()
        track.fill()

        let fraction = max(0, min(100, column.percent)) / 100
        if fraction > 0 {
            let filled = NSBezierPath(
                roundedRect: NSRect(x: box.minX, y: box.minY,
                                    width: max(barH, barW * CGFloat(fraction)), height: barH),
                xRadius: barH / 2, yRadius: barH / 2)
            fill(column.percent).setFill()
            filled.fill()
        }
        x += barW
    }

    image.unlockFocus()
    image.isTemplate = false
    return image
}

/// One column per limit: a bar for how full it is, a two-letter label under it
/// for which window, tinted by vendor. Everything is on screen at once and the
/// whole strip is about as wide as a word.
struct Column {
    let label: String
    let tint: NSColor
    let percent: Double
    let startsVendor: Bool
    let isClaude: Bool
}

func columnsImage(_ columns: [Column]) -> NSImage {
    let barW: CGFloat = 5, barH: CGFloat = 10, labelH: CGFloat = 8
    let gap: CGFloat = 4, vendorGap: CGFloat = 9
    let font = NSFont.systemFont(ofSize: 7, weight: .semibold)

    var widths: [CGFloat] = []
    for column in columns {
        let text = column.label.size(withAttributes: [.font: font]).width
        widths.append(max(barW, ceil(text)))
    }
    var total: CGFloat = 0
    for (i, w) in widths.enumerated() {
        if i > 0 { total += columns[i].startsVendor ? vendorGap : gap }
        total += w
    }

    let image = NSImage(size: NSSize(width: max(total, barW), height: barH + labelH))
    image.lockFocus()

    var x: CGFloat = 0
    for (i, column) in columns.enumerated() {
        if i > 0 { x += column.startsVendor ? vendorGap : gap }
        let w = widths[i]

        let barX = x + (w - barW) / 2
        let track = NSBezierPath(roundedRect: NSRect(x: barX, y: labelH, width: barW, height: barH),
                                 xRadius: 1.5, yRadius: 1.5)
        NSColor.quaternaryLabelColor.setFill()
        track.fill()

        let fraction = max(0, min(100, column.percent)) / 100
        if fraction > 0 {
            NSGraphicsContext.saveGraphicsState()
            track.addClip()
            Palette.color(for: column.percent).setFill()
            NSRect(x: barX, y: labelH, width: barW, height: barH * CGFloat(fraction)).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: column.tint]
        let measured = column.label.size(withAttributes: attrs)
        column.label.draw(at: NSPoint(x: x + (w - measured.width) / 2, y: -1), withAttributes: attrs)
        x += w
    }

    image.unlockFocus()
    image.isTemplate = false
    return image
}

// The vendors' own marks, flattened to move/line/curve/close by
// menubar/normalize-svg.py so nothing here has to understand SVG arcs.
// Both are on a 24x24 grid with y pointing down, as SVG has it.
enum Mark {
    static let claude = "M4.714 15.956 L9.432 13.308 L9.511 13.078 L9.432 12.950 L9.201 12.950 L8.412 12.902 L5.716 12.829 L3.379 12.732 L1.114 12.610 L0.543 12.489 L0.009 11.785 L0.064 11.432 L0.543 11.111 L1.229 11.171 L2.747 11.275 L5.024 11.432 L6.675 11.530 L9.122 11.785 L9.511 11.785 L9.565 11.627 L9.432 11.530 L9.329 11.432 L6.973 9.836 L4.423 8.148 L3.087 7.176 L2.365 6.684 L2.001 6.223 L1.843 5.215 L2.498 4.493 L3.379 4.553 L3.603 4.614 L4.496 5.300 L6.402 6.776 L8.892 8.609 L9.256 8.913 L9.402 8.809 L9.420 8.737 L9.256 8.463 L7.902 6.017 L6.457 3.527 L5.813 2.495 L5.643 1.876 C5.583 1.621 5.540 1.409 5.540 1.147 L6.287 0.134 L6.700 0.000 L7.695 0.134 L8.114 0.498 L8.734 1.913 L9.735 4.141 L11.290 7.170 L11.745 8.069 L11.988 8.901 L12.079 9.156 L12.237 9.156 L12.237 9.010 L12.364 7.304 L12.601 5.209 L12.832 2.514 L12.911 1.755 L13.287 0.844 L14.034 0.352 L14.617 0.631 L15.096 1.317 L15.030 1.761 L14.744 3.612 L14.186 6.515 L13.821 8.457 L14.034 8.457 L14.277 8.215 L15.260 6.909 L16.912 4.845 L17.640 4.025 L18.490 3.121 L19.037 2.690 L20.069 2.690 L20.828 3.819 L20.488 4.985 L19.425 6.332 L18.545 7.474 L17.282 9.174 L16.493 10.534 L16.566 10.643 L16.754 10.625 L19.607 10.018 L21.149 9.738 L22.989 9.423 L23.821 9.811 L23.912 10.206 L23.584 11.013 L21.617 11.499 L19.310 11.961 L15.874 12.774 L15.831 12.805 L15.880 12.865 L17.428 13.011 L18.090 13.047 L19.711 13.047 L22.728 13.272 L23.517 13.794 L23.991 14.432 L23.912 14.917 L22.698 15.537 L21.058 15.148 L17.233 14.237 L15.922 13.909 L15.740 13.909 L15.740 14.019 L16.833 15.087 L18.836 16.897 L21.344 19.228 L21.471 19.805 L21.150 20.260 L20.810 20.212 L18.606 18.554 L17.756 17.807 L15.831 16.186 L15.704 16.186 L15.704 16.356 L16.147 17.006 L18.490 20.527 L18.612 21.608 L18.442 21.960 L17.835 22.173 L17.167 22.051 L15.795 20.127 L14.380 17.959 L13.239 16.016 L13.099 16.095 L12.425 23.350 L12.109 23.721 L11.381 24.000 L10.774 23.539 L10.452 22.792 L10.774 21.316 L11.162 19.392 L11.478 17.862 L11.763 15.961 L11.933 15.330 L11.921 15.288 L11.781 15.306 L10.349 17.273 L8.169 20.218 L6.445 22.063 L6.032 22.227 L5.316 21.857 L5.382 21.195 L5.783 20.606 L8.169 17.570 L9.608 15.688 L10.537 14.602 L10.531 14.444 L10.476 14.444 L4.138 18.560 L3.008 18.706 L2.523 18.250 L2.583 17.504 L2.814 17.261 L4.721 15.949 Z"
    static let codex = "M22.282 9.821 C22.823 8.186 22.635 6.398 21.766 4.911 C20.456 2.633 17.826 1.461 15.256 2.011 C13.808 0.400 11.612 -0.316 9.493 0.131 C7.374 0.579 5.654 2.122 4.981 4.180 C3.294 4.528 1.838 5.584 0.983 7.080 C-0.339 9.355 -0.039 12.225 1.726 14.177 C1.181 15.811 1.367 17.601 2.236 19.088 C3.547 21.368 6.180 22.540 8.751 21.988 C9.896 23.275 11.538 24.007 13.260 24.000 C15.894 24.001 18.226 22.301 19.032 19.794 C20.719 19.446 22.175 18.390 23.029 16.894 C24.335 14.623 24.034 11.769 22.282 9.821 M13.260 22.430 C12.209 22.431 11.191 22.063 10.384 21.390 L10.525 21.309 L15.304 18.551 C15.545 18.408 15.693 18.150 15.696 17.870 L15.696 11.133 L17.716 12.301 C17.736 12.311 17.751 12.331 17.754 12.353 L17.754 17.936 C17.749 20.416 15.740 22.425 13.260 22.430 M3.600 18.304 C3.072 17.394 2.883 16.326 3.065 15.290 L3.207 15.375 L7.990 18.134 C8.231 18.275 8.529 18.275 8.770 18.134 L14.613 14.765 L14.613 17.097 C14.612 17.122 14.600 17.145 14.580 17.159 L9.740 19.950 C7.590 21.188 4.843 20.452 3.600 18.304 M2.340 7.896 C2.872 6.980 3.710 6.282 4.706 5.923 L4.706 11.600 C4.703 11.879 4.851 12.138 5.094 12.277 L10.909 15.631 L8.889 16.799 C8.867 16.810 8.840 16.810 8.818 16.799 L3.988 14.013 C1.841 12.769 1.104 10.023 2.340 7.872 Z M18.937 11.751 L13.104 8.364 L15.119 7.200 C15.141 7.189 15.168 7.189 15.190 7.200 L20.020 9.991 C21.528 10.860 22.399 12.523 22.254 14.258 C22.109 15.993 20.976 17.488 19.344 18.096 L19.344 12.418 C19.335 12.139 19.181 11.886 18.937 11.751 M20.947 8.728 L20.806 8.643 L16.032 5.861 C15.789 5.720 15.490 5.720 15.247 5.861 L9.409 9.230 L9.409 6.897 C9.407 6.873 9.418 6.850 9.437 6.836 L14.267 4.049 C15.778 3.179 17.656 3.261 19.086 4.259 C20.516 5.256 21.241 6.990 20.947 8.709 Z M8.307 12.863 L6.287 11.699 C6.266 11.687 6.252 11.666 6.249 11.642 L6.249 6.075 C6.252 4.332 7.262 2.748 8.841 2.008 C10.420 1.269 12.283 1.508 13.624 2.622 L13.482 2.702 L8.704 5.460 C8.463 5.603 8.314 5.861 8.311 6.141 Z M9.404 10.498 L12.006 8.998 L14.613 10.498 L14.613 13.497 L12.016 14.997 L9.409 13.497 Z"

    /// Scale a 24-unit path into `box` and flip it into AppKit's y-up space.
    static func path(_ d: String, in box: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        let scale = min(box.width, box.height) / 24
        func point(_ x: Double, _ y: Double) -> NSPoint {
            NSPoint(x: box.minX + CGFloat(x) * scale,
                    y: box.maxY - CGFloat(y) * scale)
        }

        var numbers: [Double] = []
        var command: Character = "M"
        func flush() {
            switch command {
            case "M" where numbers.count >= 2:
                path.move(to: point(numbers[0], numbers[1]))
            case "L" where numbers.count >= 2:
                path.line(to: point(numbers[0], numbers[1]))
            case "C" where numbers.count >= 6:
                path.curve(to: point(numbers[4], numbers[5]),
                           controlPoint1: point(numbers[0], numbers[1]),
                           controlPoint2: point(numbers[2], numbers[3]))
            default: break
            }
            numbers.removeAll()
        }

        var token = ""
        func takeNumber() {
            if let value = Double(token) { numbers.append(value) }
            token = ""
        }
        for character in d {
            if character.isLetter {
                takeNumber(); flush()
                command = character
                if character == "Z" { path.close() }
            } else if character == " " {
                takeNumber()
            } else if character == "-" && !token.isEmpty && !token.hasSuffix("e") {
                takeNumber(); token.append(character)
            } else {
                token.append(character)
            }
        }
        takeNumber(); flush()
        path.windingRule = .evenOdd
        return path
    }
}

/// Full mark = quota still untouched; it drains and fades as the budget goes.
func logoImage(_ rings: [Ring], size: CGFloat = 15, gap: CGFloat = 7) -> NSImage {
    let total = CGFloat(rings.count) * size + CGFloat(max(0, rings.count - 1)) * gap
    let image = NSImage(size: NSSize(width: max(total, size), height: size))
    image.lockFocus()

    for (index, ring) in rings.enumerated() {
        let box = NSRect(x: CGFloat(index) * (size + gap), y: 0, width: size, height: size)
        let mark = Mark.path(ring.shape == .circle ? Mark.claude : Mark.codex, in: box)
        let remaining = max(0, min(100, 100 - ring.percent)) / 100

        NSGraphicsContext.saveGraphicsState()
        mark.addClip()
        // The spent part stays as a ghost so the mark is still identifiable.
        ring.track.withAlphaComponent(0.18).setFill()
        box.fill()
        ring.track.setFill()
        NSRect(x: box.minX, y: box.minY,
               width: box.width, height: box.height * CGFloat(remaining)).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    image.unlockFocus()
    image.isTemplate = false
    return image
}

/// Colour cannot carry vendor and severity at once - the fill fights the
/// track. So shape carries the vendor: Claude is a circle, Codex a square.
/// Colour is then free to mean only "how full".
func shapesImage(_ rings: [Ring], size: CGFloat = 13, gap: CGFloat = 6,
                 thickness: CGFloat = 2.5) -> NSImage {
    let total = CGFloat(rings.count) * size + CGFloat(max(0, rings.count - 1)) * gap
    let image = NSImage(size: NSSize(width: max(total, size), height: size))
    image.lockFocus()

    for (index, ring) in rings.enumerated() {
        let x = CGFloat(index) * (size + gap)
        let inset = thickness / 2
        let box = NSRect(x: x + inset, y: inset, width: size - thickness, height: size - thickness)
        let isCircle = ring.shape == .circle

        let track = isCircle
            ? NSBezierPath(ovalIn: box)
            : NSBezierPath(roundedRect: box, xRadius: 2.5, yRadius: 2.5)
        track.lineWidth = thickness
        NSColor.tertiaryLabelColor.setStroke()
        track.stroke()

        let fraction = max(0, min(100, ring.percent)) / 100
        guard fraction > 0 else { continue }
        // Fill from the bottom up, like a vessel - the same read for both shapes.
        NSGraphicsContext.saveGraphicsState()
        let clip = isCircle
            ? NSBezierPath(ovalIn: box.insetBy(dx: -inset, dy: -inset))
            : NSBezierPath(roundedRect: box.insetBy(dx: -inset, dy: -inset), xRadius: 3, yRadius: 3)
        clip.addClip()
        Palette.color(for: ring.percent).setFill()
        NSRect(x: x, y: 0, width: size, height: size * fraction).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    image.unlockFocus()
    image.isTemplate = false
    return image
}

/// The same fill, with the vendor spelled out in one letter instead.
func lettersImage(_ rings: [Ring], size: CGFloat = 14, gap: CGFloat = 6) -> NSImage {
    let total = CGFloat(rings.count) * size + CGFloat(max(0, rings.count - 1)) * gap
    let image = NSImage(size: NSSize(width: max(total, size), height: size))
    image.lockFocus()

    for (index, ring) in rings.enumerated() {
        let x = CGFloat(index) * (size + gap)
        let box = NSRect(x: x, y: 0, width: size, height: size)
        let badge = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
        Palette.color(for: ring.percent).setFill()
        badge.fill()

        let letter = ring.shape == .circle ? "C" : "X"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.black.withAlphaComponent(0.75),
        ]
        let measured = letter.size(withAttributes: attrs)
        letter.draw(at: NSPoint(x: x + (size - measured.width) / 2,
                                y: (size - measured.height) / 2),
                    withAttributes: attrs)
    }

    image.unlockFocus()
    image.isTemplate = false
    return image
}

/// Horizontal capsules, one per vendor.
func barsImage(_ rings: [Ring], width: CGFloat = 26, height: CGFloat = 7,
               gap: CGFloat = 5) -> NSImage {
    let total = CGFloat(rings.count) * width + CGFloat(max(0, rings.count - 1)) * gap
    let image = NSImage(size: NSSize(width: max(total, width), height: height))
    image.lockFocus()
    for (index, ring) in rings.enumerated() {
        let x = CGFloat(index) * (width + gap)
        let radius = height / 2
        let track = NSBezierPath(roundedRect: NSRect(x: x, y: 0, width: width, height: height),
                                 xRadius: radius, yRadius: radius)
        ring.track.withAlphaComponent(0.30).setFill()
        track.fill()

        let fraction = max(0, min(100, ring.percent)) / 100
        guard fraction > 0 else { continue }
        let filled = NSBezierPath(
            roundedRect: NSRect(x: x, y: 0, width: max(height, width * fraction), height: height),
            xRadius: radius, yRadius: radius)
        Palette.color(for: ring.percent).setFill()
        filled.fill()
    }
    image.unlockFocus()
    image.isTemplate = false
    return image
}

/// A filled dot per vendor - the smallest thing that still carries both.
func dotsImage(_ rings: [Ring], diameter: CGFloat = 9, gap: CGFloat = 5) -> NSImage {
    let total = CGFloat(rings.count) * diameter + CGFloat(max(0, rings.count - 1)) * gap
    let image = NSImage(size: NSSize(width: max(total, diameter), height: diameter))
    image.lockFocus()
    for (index, ring) in rings.enumerated() {
        let x = CGFloat(index) * (diameter + gap)
        let dot = NSBezierPath(ovalIn: NSRect(x: x, y: 0, width: diameter, height: diameter))
        Palette.color(for: ring.percent).setFill()
        dot.fill()
        ring.track.setStroke()
        dot.lineWidth = 1
        dot.stroke()
    }
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

    /// The status item is one ring per vendor and nothing else - the numbers
    /// live in the menu, where there is room to read them.
    private func render() {
        guard let button = statusItem.button else { return }

        var rings: [Ring] = []
        var columns: [Column] = []
        var urgent: (source: String, label: String, percent: Double)?
        for account in report?.accounts ?? [] {
            for source in ["claude", "codex"] {
                let limits = account.limits.filter { $0.source == source }
                guard let worst = limits.max(by: { $0.percent < $1.percent }) else { continue }
                rings.append(Ring(track: Brand.color(source), percent: worst.percent,
                                  shape: source == "claude" ? .circle : .square))
                if urgent == nil || worst.percent > urgent!.percent {
                    urgent = (source, Brand.shortLabel(worst.label), worst.percent)
                }
                for (i, limit) in limits.enumerated() {
                    columns.append(Column(label: Brand.tinyLabel(limit.label),
                                          tint: Brand.color(source),
                                          percent: limit.percent,
                                          startsVendor: i == 0,
                                          isClaude: source == "claude"))
                }
            }
        }

        if rings.isEmpty {
            button.image = nil
            button.attributedTitle = NSAttributedString(
                string: lastError == nil ? "AI Usage" : "AI Usage !",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: lastError == nil
                        ? NSColor.secondaryLabelColor : NSColor.systemOrange,
                ])
            rebuildMenu()
            return
        }

        func text(_ body: (NSMutableAttributedString) -> Void) -> NSAttributedString {
            let line = NSMutableAttributedString(); body(line); return line
        }
        func piece(_ s: String, _ c: NSColor, _ w: NSFont.Weight = .regular) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: w),
                .foregroundColor: c])
        }

        switch Style.current {
        case .hbars:
            button.attributedTitle = NSAttributedString(string: "")
            button.image = hbarsImage(columns)
        case .all:
            button.attributedTitle = NSAttributedString(string: "")
            button.image = columnsImage(columns)
        case .urgent:
            // Whichever limit is closest to its ceiling, said plainly: whose it
            // is, which window, how full. Everything else waits in the menu.
            guard let u = urgent else { break }
            button.image = nil
            button.attributedTitle = text { line in
                line.append(piece(Brand.name(u.source) + " ", Brand.color(u.source), .semibold))
                line.append(piece(u.label + " ", .secondaryLabelColor))
                let width = 8
                let filled = Int((max(0, min(100, u.percent)) * Double(width) / 100).rounded())
                line.append(piece(String(repeating: "\u{2588}", count: filled),
                                  Palette.color(for: u.percent)))
                line.append(piece(String(repeating: "\u{2588}", count: width - filled),
                                  .quaternaryLabelColor))
                line.append(piece(String(format: " %.0f%%", u.percent),
                                  Palette.color(for: u.percent), .semibold))
            }
        case .rings:
            button.attributedTitle = NSAttributedString(string: "")
            button.image = ringsImage(rings)
        case .bars:
            button.attributedTitle = NSAttributedString(string: "")
            button.image = barsImage(rings)
        case .dots:
            button.attributedTitle = NSAttributedString(string: "")
            button.image = dotsImage(rings)
        case .shapes:
            button.attributedTitle = NSAttributedString(string: "")
            button.image = shapesImage(rings)
        case .letters:
            button.attributedTitle = NSAttributedString(string: "")
            button.image = lettersImage(rings)
        case .logo:
            button.attributedTitle = NSAttributedString(string: "")
            button.image = logoImage(rings)
        case .number:
            // Only the limit closest to its ceiling, big, with a vendor dot.
            let worst = rings.max { $0.percent < $1.percent }!
            button.image = dotsImage([worst], diameter: 8)
            button.attributedTitle = text {
                $0.append(piece(String(format: " %.0f%%", worst.percent),
                                Palette.color(for: worst.percent), .semibold))
            }
        case .cards:
            button.image = nil
            button.attributedTitle = text { line in
                for (i, ring) in rings.enumerated() {
                    if i > 0 { line.append(piece("  ", .clear)) }
                    line.append(piece("\u{258C}", ring.track, .bold))
                    line.append(piece(String(format: "%.0f%%", ring.percent),
                                      Palette.color(for: ring.percent), .medium))
                }
            }
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
        let others = codex.total.tokens + (window.grok?.total.tokens ?? 0)
        var summary = title + "   " + Format.tokens(claude.total.tokens + others) + " tok"
        if claude.total.cost > 0 {
            // A model with no published rate contributes tokens but no cost,
            // so the figure is a floor rather than an estimate.
            summary += String(format: claude.total.priced ? "   ~$%.2f" : "   >$%.2f",
                              claude.total.cost)
        }
        menu.addItem(header(summary))

        // Everything is laid out at once - nothing hides behind a toggle.
        var sources: [(String, Breakdown)] = [("claude", claude), ("codex", codex)]
        if let grok = window.grok { sources.append(("grok", grok)) }
        for (name, data) in sources {
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
