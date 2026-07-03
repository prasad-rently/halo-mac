import AppIntents

struct HaloShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetHealthScoreIntent(),
            phrases: [
                "What's my Mac's health score in \(.applicationName)",
                "Get health score from \(.applicationName)",
                "\(.applicationName) health score"
            ],
            shortTitle: "Health Score",
            systemImageName: "heart.fill"
        )
        AppShortcut(
            intent: GetCPUUsageIntent(),
            phrases: [
                "What's my CPU usage in \(.applicationName)",
                "Get CPU usage from \(.applicationName)",
                "\(.applicationName) CPU"
            ],
            shortTitle: "CPU Usage",
            systemImageName: "cpu"
        )
        AppShortcut(
            intent: GetBatteryHealthIntent(),
            phrases: [
                "How's my battery in \(.applicationName)",
                "Get battery health from \(.applicationName)",
                "\(.applicationName) battery"
            ],
            shortTitle: "Battery Health",
            systemImageName: "battery.100"
        )
        AppShortcut(
            intent: GetDiskSpaceIntent(),
            phrases: [
                "How much disk space do I have in \(.applicationName)",
                "Get disk space from \(.applicationName)",
                "\(.applicationName) disk space"
            ],
            shortTitle: "Disk Space",
            systemImageName: "internaldrive"
        )
        AppShortcut(
            intent: RunSmartScanIntent(),
            phrases: [
                "Run a Mac health scan in \(.applicationName)",
                "Smart scan with \(.applicationName)",
                "Scan my Mac with \(.applicationName)"
            ],
            shortTitle: "Smart Scan",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: RunActionIntent(),
            phrases: [
                "Run an action in \(.applicationName)",
                "Execute action in \(.applicationName)"
            ],
            shortTitle: "Run Action",
            systemImageName: "bolt.circle.fill"
        )
        AppShortcut(
            intent: GetClipboardHistoryIntent(),
            phrases: [
                "Show my clipboard history in \(.applicationName)",
                "Get clipboard from \(.applicationName)",
                "\(.applicationName) clipboard"
            ],
            shortTitle: "Clipboard History",
            systemImageName: "doc.on.clipboard"
        )
        AppShortcut(
            intent: ExportReportIntent(),
            phrases: [
                "Export my Mac health report from \(.applicationName)",
                "Generate health report in \(.applicationName)",
                "\(.applicationName) report"
            ],
            shortTitle: "Export Report",
            systemImageName: "doc.richtext"
        )
    }
}
