import SocktainerProbeCore
import SwiftUI

struct DashboardView: View {
    @Binding var sidebarSelection: SidebarItem?
    var runVM: RunTestsViewModel
    var coverageVM: CoverageViewModel

    @State private var latestEntry: HistoryEntry? = nil
    @State private var recentEntries: [HistoryEntry] = []
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if isLoading {
                    ProgressView().padding(40)
                } else if latestEntry == nil && !hasConfig {
                    welcomeCard
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        lastRunCard
                        VStack(spacing: 16) {
                            coverageMiniCard
                            environmentCard
                        }
                    }
                    if !recentEntries.dropFirst().isEmpty {
                        recentRunsCard
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("Dashboard")
        .task { await loadData() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await loadData() }
        }
    }

    private var hasConfig: Bool { CheckConfig.load() != nil }

    private func loadData() async {
        isLoading = true
        let entries = await Sessions.shared.loadRecentReports(limit: 10)
        latestEntry = entries.first
        recentEntries = entries
        isLoading = false
    }

    // MARK: - Welcome card (first run)

    private var welcomeCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 48)).foregroundStyle(.secondary)
            Text("Welcome to SocktainerProbe")
                .font(.title2).fontWeight(.semibold)
            Text("Configure a Socktainer binary and run your first test suite to see results here.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 400)
            HStack(spacing: 12) {
                Button("Configure") { sidebarSelection = .settings }
                    .buttonStyle(.bordered)
                Button("Run Tests") { sidebarSelection = .run }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity).padding(48)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Last run card

    private var lastRunCard: some View {
        Group {
            if let entry = latestEntry {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("Last Run", systemImage: "checkmark.seal.fill")
                            .font(.headline)
                        Spacer()
                        kindBadge(entry.kind)
                    }
                    Divider()
                    HStack(spacing: 20) {
                        statBlock("\(entry.report.passed)", label: "Passed", color: .green)
                        statBlock("\(entry.report.failed)", label: "Failed",
                                  color: entry.report.failed > 0 ? .red : .secondary)
                        if entry.report.skipped > 0 {
                            statBlock("\(entry.report.skipped)", label: "Skipped", color: .secondary)
                        }
                        if entry.report.knownFailures > 0 {
                            statBlock("\(entry.report.knownFailures)", label: "Known", color: .orange)
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.report.environment.socktainerVersion)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(relativeDate(entry.report.timestamp))
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    Button("Run Again") { sidebarSelection = .run }
                        .buttonStyle(.borderedProminent)
                }
                .padding(16)
                .background(.background, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 36)).foregroundStyle(.secondary)
                    Text("No runs yet")
                        .fontWeight(.medium).foregroundStyle(.secondary)
                    Button("Run Tests") { sidebarSelection = .run }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity).padding(32)
                .background(.background, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Coverage mini card

    private var coverageMiniCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("API Coverage", systemImage: "checklist")
                .font(.headline)
            Divider()
            if let sum = coverageVM.summary {
                HStack(spacing: 16) {
                    statBlock("\(sum.implementedPct)%", label: "Implemented", color: .green)
                    statBlock("\(sum.testedCount)/\(sum.implemented)", label: "Tested", color: .purple)
                }
                Button("View Details") { sidebarSelection = .coverage }
                    .buttonStyle(.bordered).controlSize(.small)
            } else {
                Button("Load Coverage") { sidebarSelection = .coverage }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
        .frame(maxWidth: 220)
    }

    // MARK: - Environment card

    private var environmentCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Environment", systemImage: "cpu")
                .font(.headline)
            Divider()
            if let env = latestEntry?.report.environment {
                VStack(alignment: .leading, spacing: 4) {
                    envRow("Machine", env.machineSummary)
                    envRow("macOS", env.macosVersion.components(separatedBy: " ").prefix(2).joined(separator: " "))
                    envRow("Apple Container", env.appleContainerVersion)
                }
            } else {
                Text("Run tests to capture environment info.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
        .frame(maxWidth: 220)
    }

    // MARK: - Recent runs

    private var recentRunsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Recent Runs", systemImage: "clock")
                    .font(.headline)
                Spacer()
                Button("See All") { sidebarSelection = .history }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor)
            }
            Divider()
            ForEach(recentEntries.prefix(5)) { entry in
                recentRunRow(entry)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
    }

    private func recentRunRow(_ entry: HistoryEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.report.failed == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(entry.report.failed == 0 ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("\(entry.report.passed) passed")
                        .fontWeight(.medium)
                    if entry.report.failed > 0 {
                        Text("\(entry.report.failed) failed").foregroundStyle(.red)
                    }
                }
                .font(.callout)
                Text(relativeDate(entry.report.timestamp))
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            kindBadge(entry.kind)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private func kindBadge(_ kind: SessionRecord.Kind) -> some View {
        Text(kind.rawValue.capitalized)
            .font(.system(.caption2, weight: .medium))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
            .foregroundStyle(Color.accentColor)
    }

    private func statBlock(_ value: String, label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2).fontWeight(.semibold).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func envRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(label + ": ").font(.caption).foregroundStyle(.secondary)
            Text(value).font(.caption).foregroundStyle(.primary)
        }
    }

    private func relativeDate(_ isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: isoString) else { return isoString }
        let secs = Int(-date.timeIntervalSinceNow)
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(secs / 60) min ago" }
        if secs < 86400 { return "\(secs / 3600) hr ago" }
        return "\(secs / 86400) days ago"
    }
}
