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

    var localizedLabel: String {
        if windowMinutes == 300 { return "5时" }
        if windowMinutes == 10_080 { return "7天" }
        if windowMinutes % 1_440 == 0 { return "\(windowMinutes / 1_440)天" }
        if windowMinutes % 60 == 0 { return "\(windowMinutes / 60)时" }
        return "\(windowMinutes)分"
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
        sourceDescription: "等待 API 数据源"
    )
}

struct UsageSnapshot: Equatable {
    let scannedAt: Date
    let sourceRoot: String
    let filesScanned: Int
    let eventsScanned: Int
    let latestEvent: UsageEvent?
    let latestRateLimitEvent: UsageEvent?
    let rateLimitEvents: [UsageEvent]
    let displayRateLimits: RateLimits?
    let todayUsage: TokenUsage
    let lastFiveHoursUsage: TokenUsage
    let lastSevenDaysUsage: TokenUsage
    let apiUsage: APIUsageSnapshot
    let errorMessage: String?

    var menuTitle: String {
        guard let limits = displayRateLimits else {
            return "Codex --"
        }

        let primary = limits.primary.map { "\($0.localizedLabel) \(formatPercent($0.usedPercent))" }
        let secondary = limits.secondary.map { "\($0.localizedLabel) \(formatPercent($0.usedPercent))" }
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
                rateLimitEvents: [],
                displayRateLimits: nil,
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
                rateLimitEvents: [],
                displayRateLimits: nil,
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
        var rateLimitEvents: [UsageEvent] = []
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
                if event.rateLimits != nil {
                    rateLimitEvents.append(event)
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

        let sortedRateLimitEvents = rateLimitEvents.sorted { $0.timestamp > $1.timestamp }

        return UsageSnapshot(
            scannedAt: now,
            sourceRoot: rootURL.path,
            filesScanned: fileURLs.count,
            eventsScanned: eventsScanned,
            latestEvent: latestEvent,
            latestRateLimitEvent: latestRateLimitEvent,
            rateLimitEvents: sortedRateLimitEvents,
            displayRateLimits: aggregateDisplayRateLimits(from: sortedRateLimitEvents),
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

    private static func aggregateDisplayRateLimits(from events: [UsageEvent]) -> RateLimits? {
        let rateLimits = events.compactMap(\.rateLimits)
        guard !rateLimits.isEmpty else { return nil }

        let latestMetadata = rateLimits.first
        let primary = aggregateWindow(from: events.compactMap { $0.rateLimits?.primary })
        let secondary = aggregateWindow(from: events.compactMap { $0.rateLimits?.secondary })

        guard primary != nil || secondary != nil else { return nil }
        return RateLimits(
            planType: latestMetadata?.planType,
            limitID: latestMetadata?.limitID,
            primary: primary,
            secondary: secondary
        )
    }

    private static func aggregateWindow(from windows: [RateLimitWindow]) -> RateLimitWindow? {
        guard !windows.isEmpty else { return nil }

        if let latestReset = windows.compactMap(\.resetsAt).max() {
            return windows
                .filter { $0.resetsAt == latestReset }
                .max { $0.usedPercent < $1.usedPercent }
        }

        return windows.max { $0.usedPercent < $1.usedPercent }
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
        menu.addItem(compactSectionHeader(
            title: snapshot.menuTitle,
            subtitle: "已更新 \(formatTimeOnly(snapshot.scannedAt))",
            accent: .systemBlue
        ))
        menu.addItem(spacerItem(height: 3))
        addOfficialQuotaSection(snapshot, to: menu)

        menu.addItem(spacerItem(height: 4))
        addAPIUsageSection(snapshot.apiUsage, to: menu)

        menu.addItem(spacerItem(height: 4))
        addLocalTotalsSection(snapshot, to: menu)

        menu.addItem(NSMenuItem.separator())
        let detailsItem = NSMenuItem(title: "详细信息", action: nil, keyEquivalent: "")
        detailsItem.submenu = buildDetailsMenu(snapshot: snapshot)
        menu.addItem(detailsItem)

        menu.addItem(NSMenuItem.separator())
        let refreshItem = NSMenuItem(title: "刷新", action: #selector(refreshFromMenu), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let openItem = NSMenuItem(title: "打开 Codex 会话文件夹", action: #selector(openSessionsFolder), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "退出 TokenDock", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    private func addOfficialQuotaSection(_ snapshot: UsageSnapshot, to menu: NSMenu) {
        menu.addItem(compactSectionHeader(
            title: "官方额度",
            subtitle: snapshot.displayRateLimits == nil ? "暂无数据" : "同窗口最高值 · \(formatTimeOnly(snapshot.scannedAt))",
            accent: .systemBlue
        ))

        guard let limits = snapshot.displayRateLimits else {
            menu.addItem(compactMetricRow(
                label: "官方额度",
                value: "暂无数据",
                note: "未找到 rate_limits",
                accent: .systemBlue
            ))
            return
        }

        addWindowRows(limits.primary, to: menu, accent: .systemBlue)
        addWindowRows(limits.secondary, to: menu, accent: .systemBlue)
    }

    private func addWindowRows(_ window: RateLimitWindow?, to menu: NSMenu, accent: NSColor) {
        guard let window else { return }
        let reset = window.resetsAt.map { "重置 \(formatRelativeCN($0))" } ?? "重置时间未知"
        menu.addItem(compactProgressRow(
            label: "\(window.localizedLabel)额度",
            usedPercent: window.usedPercent,
            leftPercent: window.leftPercent,
            note: reset,
            accent: accent
        ))
    }

    private func addAPIUsageSection(_ apiUsage: APIUsageSnapshot, to menu: NSMenu) {
        menu.addItem(compactSectionHeader(
            title: "API Tokens",
            subtitle: apiUsage.sourceDescription,
            accent: .systemOrange
        ))
        let value = "今日 \(apiUsage.todayUsage?.compact ?? "--") · 5时 \(apiUsage.lastFiveHoursUsage?.compact ?? "--") · 7天 \(apiUsage.lastSevenDaysUsage?.compact ?? "--")"
        menu.addItem(compactMetricRow(
            label: "API",
            value: value,
            note: "预留 API 用量入口",
            accent: .systemOrange
        ))
    }

    private func addLocalTotalsSection(_ snapshot: UsageSnapshot, to menu: NSMenu) {
        menu.addItem(compactSectionHeader(
            title: "本机统计",
            subtitle: "来自这台 Mac 的 Codex 日志",
            accent: .systemGreen
        ))
        menu.addItem(compactMetricRow(
            label: "Token",
            value: "今日 \(snapshot.todayUsage.compact) · 5时 \(snapshot.lastFiveHoursUsage.compact) · 7天 \(snapshot.lastSevenDaysUsage.compact)",
            note: "本机日志统计",
            accent: .systemGreen
        ))
    }

    private func buildDetailsMenu(snapshot: UsageSnapshot) -> NSMenu {
        let menu = NSMenu()

        addDetailSection("官方额度明细", to: menu)
        if let limits = snapshot.displayRateLimits {
            menu.addItem(disabled("首层口径：最新 reset 窗口内最高 used%"))
            menu.addItem(disabled("Plan：\(limits.planType ?? "unknown")"))
            menu.addItem(disabled("Limit ID：\(limits.limitID ?? "unknown")"))
            for window in [limits.primary, limits.secondary].compactMap({ $0 }) {
                let reset = window.resetsAt.map(formatDateTime) ?? "未知"
                menu.addItem(disabled("\(window.localizedLabel)：已用 \(formatPercent(window.usedPercent)) · 剩余 \(formatPercent(window.leftPercent))"))
                menu.addItem(disabled("重置：\(reset)"))
            }
        } else {
            menu.addItem(disabled("官方额度：暂无数据"))
        }

        let eventsBySource = latestRateLimitEventsBySource(snapshot.rateLimitEvents)
        if !eventsBySource.isEmpty {
            menu.addItem(NSMenuItem.separator())
            addDetailSection("各会话原始值", to: menu)
            for event in eventsBySource {
                let sourceURL = URL(fileURLWithPath: event.sourceFile)
                let limits = event.rateLimits
                let primary = limits?.primary.map { "\($0.localizedLabel) \(formatPercent($0.usedPercent))" } ?? "5时 --"
                let secondary = limits?.secondary.map { "\($0.localizedLabel) \(formatPercent($0.usedPercent))" } ?? "7天 --"
                menu.addItem(disabled(sourceURL.lastPathComponent))
                menu.addItem(disabled("\(formatTimeOnly(event.timestamp)) · \(primary) · \(secondary)"))
            }
        }

        menu.addItem(NSMenuItem.separator())
        addDetailSection("最近事件", to: menu)
        if let latest = snapshot.latestEvent {
            menu.addItem(disabled("时间：\(formatDateTime(latest.timestamp))"))
            if let lastUsage = latest.lastUsage {
                menu.addItem(disabled("输入：\(formatTokenCount(lastUsage.input))"))
                menu.addItem(disabled("缓存输入：\(formatTokenCount(lastUsage.cachedInput))"))
                menu.addItem(disabled("输出：\(formatTokenCount(lastUsage.output))"))
                menu.addItem(disabled("推理：\(formatTokenCount(lastUsage.reasoning))"))
                menu.addItem(disabled("本次合计：\(formatTokenCount(lastUsage.total))"))
            } else {
                menu.addItem(disabled("最近事件：无 token 数据"))
            }
            if let totalUsage = latest.totalUsage {
                menu.addItem(disabled("会话总量：\(formatTokenCount(totalUsage.total))"))
            }
        } else {
            menu.addItem(disabled("最近事件：暂无"))
        }

        menu.addItem(NSMenuItem.separator())
        addDetailSection("数据来源", to: menu)
        menu.addItem(disabled("扫描文件：\(snapshot.filesScanned) 个"))
        menu.addItem(disabled("扫描事件：\(snapshot.eventsScanned) 条"))
        if let source = snapshot.latestEvent?.sourceFile {
            let sourceURL = URL(fileURLWithPath: source)
            menu.addItem(disabled("文件：\(sourceURL.lastPathComponent)"))
            menu.addItem(disabled("目录：\(shortenHome(sourceURL.deletingLastPathComponent().path))"))
        } else {
            menu.addItem(disabled("暂无 rollout 文件"))
        }

        if let errorMessage = snapshot.errorMessage {
            menu.addItem(NSMenuItem.separator())
            addDetailSection("解析提示", to: menu)
            menu.addItem(disabled(errorMessage))
        }

        return menu
    }

    private func addDetailSection(_ title: String, to menu: NSMenu) {
        let item = disabled(title)
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        menu.addItem(item)
    }

    private func latestRateLimitEventsBySource(_ events: [UsageEvent]) -> [UsageEvent] {
        var latestBySource: [String: UsageEvent] = [:]
        for event in events {
            guard event.rateLimits != nil else { continue }
            if latestBySource[event.sourceFile] == nil || event.timestamp > latestBySource[event.sourceFile]!.timestamp {
                latestBySource[event.sourceFile] = event
            }
        }
        return latestBySource.values.sorted { $0.timestamp > $1.timestamp }
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func compactSectionHeader(title: String, subtitle: String, accent: NSColor) -> NSMenuItem {
        let height: CGFloat = 34
        let container = NSView(frame: NSRect(x: 0, y: 0, width: menuWidth, height: height))
        container.wantsLayer = true
        container.layer?.backgroundColor = accent.withAlphaComponent(0.10).cgColor
        container.layer?.cornerRadius = 6

        let stripe = NSView()
        stripe.wantsLayer = true
        stripe.layer?.backgroundColor = accent.cgColor
        stripe.layer?.cornerRadius = 2

        let titleLabel = label(
            title,
            font: .systemFont(ofSize: 12, weight: .semibold),
            color: .labelColor
        )
        let subtitleLabel = label(
            subtitle,
            font: .systemFont(ofSize: 10, weight: .regular),
            color: .secondaryLabelColor,
            alignment: .right,
            lineBreak: .byTruncatingMiddle
        )

        [stripe, titleLabel, subtitleLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview($0)
        }

        NSLayoutConstraint.activate([
            stripe.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            stripe.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stripe.widthAnchor.constraint(equalToConstant: 5),
            stripe.heightAnchor.constraint(equalToConstant: 18),

            titleLabel.leadingAnchor.constraint(equalTo: stripe.trailingAnchor, constant: 9),
            titleLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            titleLabel.widthAnchor.constraint(equalToConstant: 116),

            subtitleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            subtitleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            subtitleLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        return customItem(view: container)
    }

    private func compactProgressRow(label rowLabel: String, usedPercent: Double, leftPercent: Double, note: String, accent: NSColor) -> NSMenuItem {
        let height: CGFloat = 48
        let container = NSView(frame: NSRect(x: 0, y: 0, width: menuWidth, height: height))
        container.wantsLayer = true
        container.layer?.backgroundColor = accent.withAlphaComponent(0.045).cgColor
        container.layer?.cornerRadius = 6

        let nameLabel = label(
            rowLabel,
            font: .systemFont(ofSize: 11, weight: .medium),
            color: .secondaryLabelColor
        )
        let valueLabel = label(
            "已用 \(formatPercent(usedPercent)) · 剩余 \(formatPercent(leftPercent))",
            font: .monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            color: .labelColor,
            alignment: .right
        )
        let track = NSView()
        track.wantsLayer = true
        track.layer?.backgroundColor = accent.withAlphaComponent(0.16).cgColor
        track.layer?.cornerRadius = 3

        let fill = NSView()
        fill.wantsLayer = true
        fill.layer?.backgroundColor = accent.withAlphaComponent(0.86).cgColor
        fill.layer?.cornerRadius = 3

        let noteLabel = label(
            note,
            font: .systemFont(ofSize: 9, weight: .regular),
            color: .tertiaryLabelColor,
            lineBreak: .byTruncatingTail
        )

        [nameLabel, valueLabel, track, noteLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview($0)
        }
        fill.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(fill)

        let rawFillRatio = CGFloat(clamped(usedPercent, lower: 0, upper: 100) / 100)
        let fillRatio = max(rawFillRatio, 0.001)
        fill.isHidden = rawFillRatio <= 0

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            nameLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            nameLabel.widthAnchor.constraint(equalToConstant: 80),

            valueLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            valueLabel.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 8),

            track.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            track.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            track.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 6),
            track.heightAnchor.constraint(equalToConstant: 6),

            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fill.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: fillRatio),

            noteLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            noteLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            noteLabel.topAnchor.constraint(equalTo: track.bottomAnchor, constant: 3)
        ])

        return customItem(view: container)
    }

    private func compactMetricRow(label rowLabel: String, value: String, note: String, accent: NSColor) -> NSMenuItem {
        let height: CGFloat = 36
        let container = NSView(frame: NSRect(x: 0, y: 0, width: menuWidth, height: height))
        container.wantsLayer = true
        container.layer?.backgroundColor = accent.withAlphaComponent(0.045).cgColor
        container.layer?.cornerRadius = 6

        let nameLabel = label(
            rowLabel,
            font: .systemFont(ofSize: 11, weight: .medium),
            color: .secondaryLabelColor
        )
        let valueLabel = label(
            value,
            font: .monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            color: .labelColor,
            alignment: .right,
            lineBreak: .byTruncatingMiddle
        )
        let noteLabel = label(
            note,
            font: .systemFont(ofSize: 9, weight: .regular),
            color: .tertiaryLabelColor,
            lineBreak: .byTruncatingTail
        )

        [nameLabel, valueLabel, noteLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview($0)
        }

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            nameLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 5),
            nameLabel.widthAnchor.constraint(equalToConstant: 58),

            valueLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            valueLabel.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 8),

            noteLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            noteLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            noteLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1)
        ])

        return customItem(view: container)
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

    if let limits = snapshot.displayRateLimits {
        print("display_rate_limits=same-reset-window-max")
        print("display_plan=\(limits.planType ?? "unknown") display_limit_id=\(limits.limitID ?? "unknown")")
        for window in [limits.primary, limits.secondary].compactMap({ $0 }) {
            let reset = window.resetsAt.map(isoString) ?? "unknown"
            print("display_\(window.key)=\(window.label) used=\(formatPercent(window.usedPercent)) left=\(formatPercent(window.leftPercent)) reset=\(reset)")
        }
    } else {
        print("display_rate_limits=none")
    }

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
    print("rate_limit_events=\(snapshot.rateLimitEvents.count)")

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

func formatTimeOnly(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
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

func formatRelativeCN(_ date: Date) -> String {
    let seconds = Int(date.timeIntervalSinceNow)
    if seconds <= 0 { return "现在" }
    if seconds < 60 { return "<1分" }
    if seconds < 3_600 { return "\(Int(ceil(Double(seconds) / 60)))分后" }
    if seconds < 86_400 {
        let hours = seconds / 3_600
        let minutes = Int(ceil(Double(seconds % 3_600) / 60))
        return minutes > 0 ? "\(hours)时\(minutes)分后" : "\(hours)时后"
    }
    return "\(seconds / 86_400)天后"
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
