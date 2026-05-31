import AppKit
import Foundation

struct TokenUsage: Equatable {
    var input: Int64 = 0
    var cachedInput: Int64 = 0
    var output: Int64 = 0
    var reasoning: Int64 = 0
    var total: Int64 = 0

    mutating func add(_ other: TokenUsage) {
        input += other.input
        cachedInput += other.cachedInput
        output += other.output
        reasoning += other.reasoning
        total += other.total
    }

    var isEmpty: Bool {
        input == 0 && cachedInput == 0 && output == 0 && reasoning == 0 && total == 0
    }

    var compact: String {
        formatTokenCount(total)
    }

    var detailLines: [String] {
        [
            "input: \(formatTokenCount(input))",
            "cached: \(formatTokenCount(cachedInput))",
            "output: \(formatTokenCount(output))",
            "reasoning: \(formatTokenCount(reasoning))",
            "total: \(formatTokenCount(total))"
        ]
    }
}

struct RateLimitWindow: Equatable {
    let key: String
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: Date?

    var leftPercent: Double {
        max(0, 100 - usedPercent)
    }

    var label: String {
        if windowMinutes == 300 { return "5h" }
        if windowMinutes == 10_080 { return "7d" }
        if windowMinutes % 1_440 == 0 { return "\(windowMinutes / 1_440)d" }
        if windowMinutes % 60 == 0 { return "\(windowMinutes / 60)h" }
        return "\(windowMinutes)m"
    }
}

struct RateLimits: Equatable {
    let planType: String?
    let limitID: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
}

struct UsageEvent: Equatable {
    let timestamp: Date
    let sourceFile: String
    let lineNumber: Int
    let lastUsage: TokenUsage?
    let totalUsage: TokenUsage?
    let rateLimits: RateLimits?
}

struct APIUsageSnapshot: Equatable {
    let todayUsage: TokenUsage?
    let lastFiveHoursUsage: TokenUsage?
    let lastSevenDaysUsage: TokenUsage?
    let sourceDescription: String

    static let placeholder = APIUsageSnapshot(
        todayUsage: nil,
        lastFiveHoursUsage: nil,
        lastSevenDaysUsage: nil,
        sourceDescription: "Waiting for API usage source"
    )
}

struct UsageSnapshot: Equatable {
    let scannedAt: Date
    let sourceRoot: String
    let filesScanned: Int
    let eventsScanned: Int
    let latestEvent: UsageEvent?
    let latestRateLimitEvent: UsageEvent?
    let todayUsage: TokenUsage
    let lastFiveHoursUsage: TokenUsage
    let lastSevenDaysUsage: TokenUsage
    let apiUsage: APIUsageSnapshot
    let errorMessage: String?

    var menuTitle: String {
        guard let limits = latestRateLimitEvent?.rateLimits else {
            return "Codex --"
        }

        let primary = limits.primary.map { "\($0.label) \(formatPercent($0.usedPercent))" }
        let secondary = limits.secondary.map { "\($0.label) \(formatPercent($0.usedPercent))" }
        let parts = [primary, secondary].compactMap { $0 }
        return parts.isEmpty ? "Codex --" : "Codex " + parts.joined(separator: " · ")
    }
}

enum CodexUsageParser {
    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions", isDirectory: true)

    static func load(rootURL: URL = defaultRoot, now: Date = Date()) -> UsageSnapshot {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let fiveHoursAgo = now.addingTimeInterval(-5 * 60 * 60)
        let sevenDaysAgo = now.addingTimeInterval(-7 * 24 * 60 * 60)

        guard FileManager.default.fileExists(atPath: rootURL.path) else {
            return UsageSnapshot(
                scannedAt: now,
                sourceRoot: rootURL.path,
                filesScanned: 0,
                eventsScanned: 0,
                latestEvent: nil,
                latestRateLimitEvent: nil,
                todayUsage: TokenUsage(),
                lastFiveHoursUsage: TokenUsage(),
                lastSevenDaysUsage: TokenUsage(),
                apiUsage: .placeholder,
                errorMessage: "Codex sessions folder was not found."
            )
        }

        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return UsageSnapshot(
                scannedAt: now,
                sourceRoot: rootURL.path,
                filesScanned: 0,
                eventsScanned: 0,
                latestEvent: nil,
                latestRateLimitEvent: nil,
                todayUsage: TokenUsage(),
                lastFiveHoursUsage: TokenUsage(),
                lastSevenDaysUsage: TokenUsage(),
                apiUsage: .placeholder,
                errorMessage: "Could not enumerate Codex sessions."
            )
        }

        var fileURLs: [URL] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent.hasPrefix("rollout-"),
                  fileURL.pathExtension == "jsonl",
                  let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            fileURLs.append(fileURL)
        }

        var eventsScanned = 0
        var latestEvent: UsageEvent?
        var latestRateLimitEvent: UsageEvent?
        var todayUsage = TokenUsage()
        var fiveHourUsage = TokenUsage()
        var sevenDayUsage = TokenUsage()

        for fileURL in fileURLs.sorted(by: { $0.path < $1.path }) {
            guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
                continue
            }

            var lineNumber = 0
            contents.enumerateLines { line, _ in
                lineNumber += 1
                guard let event = parseEvent(line: line, sourceFile: fileURL.path, lineNumber: lineNumber) else {
                    return
                }

                eventsScanned += 1

                if latestEvent == nil || event.timestamp > latestEvent!.timestamp {
                    latestEvent = event
                }
                if event.rateLimits != nil,
                   latestRateLimitEvent == nil || event.timestamp > latestRateLimitEvent!.timestamp {
                    latestRateLimitEvent = event
                }

                guard let lastUsage = event.lastUsage else { return }
                if event.timestamp >= startOfToday {
                    todayUsage.add(lastUsage)
                }
                if event.timestamp >= fiveHoursAgo {
                    fiveHourUsage.add(lastUsage)
                }
                if event.timestamp >= sevenDaysAgo {
                    sevenDayUsage.add(lastUsage)
                }
            }
        }

        return UsageSnapshot(
            scannedAt: now,
            sourceRoot: rootURL.path,
            filesScanned: fileURLs.count,
            eventsScanned: eventsScanned,
            latestEvent: latestEvent,
            latestRateLimitEvent: latestRateLimitEvent,
            todayUsage: todayUsage,
            lastFiveHoursUsage: fiveHourUsage,
            lastSevenDaysUsage: sevenDayUsage,
            apiUsage: .placeholder,
            errorMessage: nil
        )
    }

    private static func parseEvent(line: String, sourceFile: String, lineNumber: Int) -> UsageEvent? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "event_msg",
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let timestamp = parseDate(object["timestamp"]) else {
            return nil
        }

        let info = payload["info"] as? [String: Any]
        let lastUsage = parseTokenUsage(info?["last_token_usage"])
        let totalUsage = parseTokenUsage(info?["total_token_usage"])
        let rateLimits = parseRateLimits(payload["rate_limits"])

        return UsageEvent(
            timestamp: timestamp,
            sourceFile: sourceFile,
            lineNumber: lineNumber,
            lastUsage: lastUsage,
            totalUsage: totalUsage,
            rateLimits: rateLimits
        )
    }

    private static func parseTokenUsage(_ value: Any?) -> TokenUsage? {
        guard let dictionary = value as? [String: Any] else { return nil }
        return TokenUsage(
            input: int64(dictionary["input_tokens"]),
            cachedInput: int64(dictionary["cached_input_tokens"]),
            output: int64(dictionary["output_tokens"]),
            reasoning: int64(dictionary["reasoning_output_tokens"]),
            total: int64(dictionary["total_tokens"])
        )
    }

    private static func parseRateLimits(_ value: Any?) -> RateLimits? {
        guard let dictionary = value as? [String: Any] else { return nil }
        let primary = parseWindow(key: "primary", value: dictionary["primary"])
        let secondary = parseWindow(key: "secondary", value: dictionary["secondary"])
        guard primary != nil || secondary != nil else { return nil }
        return RateLimits(
            planType: string(dictionary["plan_type"]),
            limitID: string(dictionary["limit_id"]),
            primary: primary,
            secondary: secondary
        )
    }

    private static func parseWindow(key: String, value: Any?) -> RateLimitWindow? {
        guard let dictionary = value as? [String: Any],
              let usedPercent = double(dictionary["used_percent"]),
              let windowMinutes = int(dictionary["window_minutes"]) else {
            return nil
        }
        return RateLimitWindow(
            key: key,
            usedPercent: usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: parseUnixDate(dictionary["resets_at"])
        )
    }
}

@MainActor
final class StatusBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let refreshInterval: TimeInterval = 60
    private let menuWidth: CGFloat = 380
    private var timer: Timer?
    private var snapshot = CodexUsageParser.load()

    override init() {
        super.init()
        configureStatusItem()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    private func configureStatusItem() {
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        statusItem.button?.toolTip = "TokenDock"
    }

    @objc private func refreshFromMenu() {
        refresh()
    }

    @objc private func openSessionsFolder() {
        NSWorkspace.shared.open(CodexUsageParser.defaultRoot)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func refresh() {
        snapshot = CodexUsageParser.load()
        statusItem.button?.title = snapshot.menuTitle
        statusItem.menu = buildMenu(snapshot: snapshot)
    }

    private func buildMenu(snapshot: UsageSnapshot) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(sectionHeader(
            title: snapshot.menuTitle,
            subtitle: "Updated \(formatDateTime(snapshot.scannedAt))",
            accent: .systemBlue
        ))
        menu.addItem(spacerItem(height: 4))

        if let event = snapshot.latestRateLimitEvent, let limits = event.rateLimits {
            menu.addItem(sectionHeader(
                title: "Official quota",
                subtitle: "Codex rate_limits · \(formatDateTime(event.timestamp))",
                accent: .systemBlue
            ))
            let plan = limits.planType ?? "unknown"
            let limitID = limits.limitID ?? "unknown"
            menu.addItem(metricRow(
                label: "Plan",
                value: plan,
                note: "limit: \(limitID)",
                accent: .systemBlue
            ))
            addWindowRows(limits.primary, to: menu, accent: .systemBlue)
            addWindowRows(limits.secondary, to: menu, accent: .systemBlue)
        } else {
            menu.addItem(sectionHeader(
                title: "Official quota",
                subtitle: "No rate-limit data found",
                accent: .systemBlue
            ))
        }

        menu.addItem(spacerItem(height: 6))
        addAPIUsageSection(snapshot.apiUsage, to: menu)

        menu.addItem(spacerItem(height: 6))

        if let latest = snapshot.latestEvent {
            menu.addItem(sectionHeader(
                title: "Latest event",
                subtitle: formatDateTime(latest.timestamp),
                accent: .systemPurple
            ))
            if let lastUsage = latest.lastUsage {
                addUsageRows(lastUsage, title: "Last response", to: menu, accent: .systemPurple)
            } else {
                menu.addItem(metricRow(
                    label: "Last response",
                    value: "--",
                    note: "No token data",
                    accent: .systemPurple
                ))
            }
            if let totalUsage = latest.totalUsage {
                menu.addItem(metricRow(
                    label: "Session total",
                    value: totalUsage.compact,
                    note: "current rollout file",
                    accent: .systemPurple
                ))
            }
        } else {
            menu.addItem(sectionHeader(
                title: "Latest event",
                subtitle: "No token event found",
                accent: .systemPurple
            ))
        }

        menu.addItem(spacerItem(height: 6))
        menu.addItem(sectionHeader(
            title: "Local token totals",
            subtitle: "from this Mac's Codex logs",
            accent: .systemGreen
        ))
        addPeriodUsage(snapshot.todayUsage, label: "Today", to: menu)
        addPeriodUsage(snapshot.lastFiveHoursUsage, label: "Last 5h", to: menu)
        addPeriodUsage(snapshot.lastSevenDaysUsage, label: "Last 7d", to: menu)
        menu.addItem(metricRow(
            label: "Scanned",
            value: "\(snapshot.eventsScanned) events",
            note: "\(snapshot.filesScanned) files",
            accent: .systemGreen
        ))

        if let source = snapshot.latestEvent?.sourceFile {
            menu.addItem(spacerItem(height: 6))
            menu.addItem(sectionHeader(
                title: "Source",
                subtitle: shortenHome(source),
                accent: .systemGray
            ))
        }

        if let errorMessage = snapshot.errorMessage {
            menu.addItem(spacerItem(height: 6))
            menu.addItem(sectionHeader(
                title: "Parser notice",
                subtitle: errorMessage,
                accent: .systemRed
            ))
        }

        menu.addItem(NSMenuItem.separator())
        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshFromMenu), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let openItem = NSMenuItem(title: "Open Codex sessions folder", action: #selector(openSessionsFolder), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit TokenDock", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    private func addWindowRows(_ window: RateLimitWindow?, to menu: NSMenu, accent: NSColor) {
        guard let window else { return }
        let reset = window.resetsAt.map { "resets in \(formatRelative($0)) · \(formatDateTime($0))" } ?? "reset time unknown"
        menu.addItem(progressRow(
            label: "\(window.label) window",
            usedPercent: window.usedPercent,
            leftPercent: window.leftPercent,
            note: reset,
            accent: accent
        ))
    }

    private func addAPIUsageSection(_ apiUsage: APIUsageSnapshot, to menu: NSMenu) {
        menu.addItem(sectionHeader(
            title: "API Tokens",
            subtitle: apiUsage.sourceDescription,
            accent: .systemOrange
        ))
        addOptionalUsage(apiUsage.todayUsage, label: "Today", to: menu, accent: .systemOrange)
        addOptionalUsage(apiUsage.lastFiveHoursUsage, label: "Last 5h", to: menu, accent: .systemOrange)
        addOptionalUsage(apiUsage.lastSevenDaysUsage, label: "Last 7d", to: menu, accent: .systemOrange)
    }

    private func addOptionalUsage(_ usage: TokenUsage?, label: String, to menu: NSMenu, accent: NSColor) {
        menu.addItem(metricRow(
            label: label,
            value: usage?.compact ?? "--",
            note: usage.map { "input \(formatTokenCount($0.input)) · output \(formatTokenCount($0.output)) · reasoning \(formatTokenCount($0.reasoning))" } ?? "waiting for data source",
            accent: accent
        ))
    }

    private func addUsageRows(_ usage: TokenUsage, title: String, to menu: NSMenu, accent: NSColor) {
        menu.addItem(metricRow(
            label: title,
            value: usage.compact,
            note: "input \(formatTokenCount(usage.input)) · cached \(formatTokenCount(usage.cachedInput))",
            accent: accent
        ))
        menu.addItem(metricRow(
            label: "Generated",
            value: formatTokenCount(usage.output + usage.reasoning),
            note: "output \(formatTokenCount(usage.output)) · reasoning \(formatTokenCount(usage.reasoning))",
            accent: accent
        ))
    }

    private func addPeriodUsage(_ usage: TokenUsage, label: String, to menu: NSMenu) {
        menu.addItem(metricRow(
            label: label,
            value: usage.compact,
            note: "input \(formatTokenCount(usage.input)) · output \(formatTokenCount(usage.output)) · reasoning \(formatTokenCount(usage.reasoning))",
            accent: .systemGreen
        ))
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func sectionHeader(title: String, subtitle: String, accent: NSColor) -> NSMenuItem {
        let height: CGFloat = 52
        let container = NSView(frame: NSRect(x: 0, y: 0, width: menuWidth, height: height))
        container.wantsLayer = true
        container.layer?.backgroundColor = accent.withAlphaComponent(0.13).cgColor
        container.layer?.cornerRadius = 8

        let stripe = NSView()
        stripe.wantsLayer = true
        stripe.layer?.backgroundColor = accent.cgColor
        stripe.layer?.cornerRadius = 2

        let titleLabel = label(
            title,
            font: .systemFont(ofSize: 13, weight: .semibold),
            color: .labelColor
        )
        let subtitleLabel = label(
            subtitle,
            font: .systemFont(ofSize: 10, weight: .regular),
            color: .secondaryLabelColor,
            lineBreak: .byTruncatingMiddle
        )

        [stripe, titleLabel, subtitleLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview($0)
        }

        NSLayoutConstraint.activate([
            stripe.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            stripe.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            stripe.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            stripe.widthAnchor.constraint(equalToConstant: 5),

            titleLabel.leadingAnchor.constraint(equalTo: stripe.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 9),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3)
        ])

        return customItem(view: container)
    }

    private func progressRow(label rowLabel: String, usedPercent: Double, leftPercent: Double, note: String, accent: NSColor) -> NSMenuItem {
        let height: CGFloat = 62
        let container = NSView(frame: NSRect(x: 0, y: 0, width: menuWidth, height: height))
        container.wantsLayer = true
        container.layer?.backgroundColor = accent.withAlphaComponent(0.06).cgColor
        container.layer?.cornerRadius = 7

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = accent.withAlphaComponent(0.85).cgColor
        dot.layer?.cornerRadius = 4

        let nameLabel = label(
            rowLabel,
            font: .systemFont(ofSize: 11, weight: .medium),
            color: .secondaryLabelColor
        )
        let valueLabel = label(
            "\(formatPercent(usedPercent)) used · \(formatPercent(leftPercent)) left",
            font: .monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
            color: .labelColor,
            alignment: .right
        )
        let track = NSView()
        track.wantsLayer = true
        track.layer?.backgroundColor = accent.withAlphaComponent(0.16).cgColor
        track.layer?.cornerRadius = 4

        let fill = NSView()
        fill.wantsLayer = true
        fill.layer?.backgroundColor = accent.withAlphaComponent(0.85).cgColor
        fill.layer?.cornerRadius = 4

        let noteLabel = label(
            note,
            font: .monospacedSystemFont(ofSize: 10, weight: .regular),
            color: .tertiaryLabelColor,
            lineBreak: .byTruncatingMiddle
        )

        [dot, nameLabel, valueLabel, track, noteLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview($0)
        }
        fill.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(fill)

        let rawFillRatio = CGFloat(clamped(usedPercent, lower: 0, upper: 100) / 100)
        let fillRatio = max(rawFillRatio, 0.001)
        fill.isHidden = rawFillRatio <= 0

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            dot.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),

            nameLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            nameLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 7),
            nameLabel.widthAnchor.constraint(equalToConstant: 112),

            valueLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            valueLabel.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 8),

            track.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            track.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            track.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 8),
            track.heightAnchor.constraint(equalToConstant: 8),

            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fill.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: fillRatio),

            noteLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            noteLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            noteLabel.topAnchor.constraint(equalTo: track.bottomAnchor, constant: 6)
        ])

        return customItem(view: container)
    }

    private func metricRow(label rowLabel: String, value: String, note: String, accent: NSColor) -> NSMenuItem {
        let height: CGFloat = 48
        let container = NSView(frame: NSRect(x: 0, y: 0, width: menuWidth, height: height))
        container.wantsLayer = true
        container.layer?.backgroundColor = accent.withAlphaComponent(0.06).cgColor
        container.layer?.cornerRadius = 7

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = accent.withAlphaComponent(0.85).cgColor
        dot.layer?.cornerRadius = 4

        let nameLabel = label(
            rowLabel,
            font: .systemFont(ofSize: 11, weight: .medium),
            color: .secondaryLabelColor
        )
        let valueLabel = label(
            value,
            font: .monospacedDigitSystemFont(ofSize: 15, weight: .semibold),
            color: .labelColor,
            alignment: .right
        )
        let noteLabel = label(
            note,
            font: .monospacedSystemFont(ofSize: 10, weight: .regular),
            color: .tertiaryLabelColor,
            lineBreak: .byTruncatingMiddle
        )

        [dot, nameLabel, valueLabel, noteLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview($0)
        }

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            dot.topAnchor.constraint(equalTo: container.topAnchor, constant: 13),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),

            nameLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            nameLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            nameLabel.widthAnchor.constraint(equalToConstant: 112),

            valueLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            valueLabel.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 8),

            noteLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            noteLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            noteLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4)
        ])

        return customItem(view: container)
    }

    private func spacerItem(height: CGFloat) -> NSMenuItem {
        customItem(view: NSView(frame: NSRect(x: 0, y: 0, width: menuWidth, height: height)))
    }

    private func customItem(view: NSView) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.view = view
        return item
    }

    private func label(
        _ text: String,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .left,
        lineBreak: NSLineBreakMode = .byTruncatingTail
    ) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.alignment = alignment
        field.lineBreakMode = lineBreak
        field.maximumNumberOfLines = 1
        return field
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller = StatusBarController()
    }
}

func printSnapshot(_ snapshot: UsageSnapshot) {
    print(snapshot.menuTitle)
    print("scanned_at=\(isoString(snapshot.scannedAt))")
    print("source_root=\(snapshot.sourceRoot)")
    print("files=\(snapshot.filesScanned) events=\(snapshot.eventsScanned)")

    if let event = snapshot.latestRateLimitEvent, let limits = event.rateLimits {
        print("rate_limit_event=\(isoString(event.timestamp))")
        print("plan=\(limits.planType ?? "unknown") limit_id=\(limits.limitID ?? "unknown")")
        for window in [limits.primary, limits.secondary].compactMap({ $0 }) {
            let reset = window.resetsAt.map(isoString) ?? "unknown"
            print("\(window.key)=\(window.label) used=\(formatPercent(window.usedPercent)) left=\(formatPercent(window.leftPercent)) reset=\(reset)")
        }
    } else {
        print("rate_limits=none")
    }

    if let latest = snapshot.latestEvent {
        print("latest_event=\(isoString(latest.timestamp))")
        print("latest_source=\(latest.sourceFile):\(latest.lineNumber)")
        if let last = latest.lastUsage {
            print("last_total=\(last.total) input=\(last.input) cached=\(last.cachedInput) output=\(last.output) reasoning=\(last.reasoning)")
        }
        if let total = latest.totalUsage {
            print("session_total=\(total.total)")
        }
    } else {
        print("latest_event=none")
    }

    print("today_total=\(snapshot.todayUsage.total)")
    print("last_5h_total=\(snapshot.lastFiveHoursUsage.total)")
    print("last_7d_total=\(snapshot.lastSevenDaysUsage.total)")
    if let error = snapshot.errorMessage {
        print("error=\(error)")
    }
}

func printHelp() {
    print("""
    TokenDock

    Usage:
      TokenDock                       Run the menu bar app.
      TokenDock --snapshot            Print a Codex usage snapshot and exit.
      TokenDock --snapshot --root DIR  Read Codex logs from DIR for testing.
      TokenDock --help                Show this help.
    """)
}

func formatTokenCount(_ value: Int64) -> String {
    let number = Double(value)
    if abs(number) >= 1_000_000 {
        return String(format: "%.1fM", number / 1_000_000)
    }
    if abs(number) >= 1_000 {
        return String(format: "%.1fk", number / 1_000)
    }
    return "\(value)"
}

func formatPercent(_ value: Double) -> String {
    if value.rounded() == value {
        return "\(Int(value))%"
    }
    return String(format: "%.1f%%", value)
}

func clamped(_ value: Double, lower: Double, upper: Double) -> Double {
    guard value.isFinite else { return lower }
    return min(max(value, lower), upper)
}

func formatDateTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .medium
    return formatter.string(from: date)
}

func formatRelative(_ date: Date) -> String {
    let seconds = Int(date.timeIntervalSinceNow)
    if seconds <= 0 { return "now" }
    if seconds < 60 { return "<1m" }
    if seconds < 3_600 { return "\(Int(ceil(Double(seconds) / 60)))m" }
    if seconds < 86_400 {
        let hours = seconds / 3_600
        let minutes = Int(ceil(Double(seconds % 3_600) / 60))
        return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
    }
    return "\(seconds / 86_400)d"
}

func isoString(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}

func shortenHome(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path.hasPrefix(home) {
        return "~" + path.dropFirst(home.count)
    }
    return path
}

func parseDate(_ value: Any?) -> Date? {
    guard let string = value as? String else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: string) {
        return date
    }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: string)
}

func parseUnixDate(_ value: Any?) -> Date? {
    if let number = value as? NSNumber {
        return Date(timeIntervalSince1970: number.doubleValue)
    }
    if let string = value as? String, let seconds = Double(string) {
        return Date(timeIntervalSince1970: seconds)
    }
    return nil
}

func int(_ value: Any?) -> Int? {
    if let number = value as? NSNumber { return number.intValue }
    if let string = value as? String { return Int(string) }
    return nil
}

func int64(_ value: Any?) -> Int64 {
    if let number = value as? NSNumber { return number.int64Value }
    if let string = value as? String, let parsed = Int64(string) { return parsed }
    return 0
}

func double(_ value: Any?) -> Double? {
    if let number = value as? NSNumber { return number.doubleValue }
    if let string = value as? String { return Double(string) }
    return nil
}

func string(_ value: Any?) -> String? {
    if let string = value as? String, !string.isEmpty { return string }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
}

let rawArguments = Array(CommandLine.arguments.dropFirst())
let arguments = Set(rawArguments)

func snapshotRootURL() -> URL {
    guard let index = rawArguments.firstIndex(of: "--root"),
          rawArguments.indices.contains(index + 1) else {
        return CodexUsageParser.defaultRoot
    }
    let path = (rawArguments[index + 1] as NSString).expandingTildeInPath
    return URL(fileURLWithPath: path, isDirectory: true)
}

if arguments.contains("--help") || arguments.contains("-h") {
    printHelp()
    exit(0)
}

if arguments.contains("--snapshot") {
    printSnapshot(CodexUsageParser.load(rootURL: snapshotRootURL()))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
