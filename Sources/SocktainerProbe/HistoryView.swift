import AppKit
import SocktainerProbeCore
import SwiftUI

struct HistoryView: View {
    @State private var entries: [HistoryEntry] = []
    @State private var selected: HistoryEntry? = nil
    @State private var isLoading = true
    @State private var filterKind: SessionRecord.Kind? = nil
    @State private var filterStatus: StatusFilter = .all
    @State private var showClearConfirm = false

    enum StatusFilter { case all, passed, failed }

    var filtered: [HistoryEntry] {
        entries.filter { e in
            (filterKind == nil || e.kind == filterKind) &&
            (filterStatus == .all
             || (filterStatus == .passed && e.report.failed == 0)
             || (filterStatus == .failed && e.report.failed > 0))
        }
    }

    var body: some View {
        HSplitView {
            // ── Left: list ───────────────────────────────────────────
            VStack(spacing: 0) {
                listToolbar
                Divider()
                kindFilterBar
                Divider()
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filtered.isEmpty {
                    Text(entries.isEmpty ? "No sessions yet." : "No matching sessions.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filtered, selection: $selected) { entry in
                        HistoryRowView(entry: entry)
                            .tag(entry)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { delete(entry) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                    .listStyle(.sidebar)
                }
            }
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)

            // ── Right: detail ─────────────────────────────────────────
            if let entry = selected {
                HistoryDetailView(entry: entry)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "clock").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text("Select a run to inspect results.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("History")
        .task { await load() }
        .confirmationDialog("Clear all history?", isPresented: $showClearConfirm) {
            Button("Clear All", role: .destructive) { Task { await clearAll() } }
        } message: {
            Text("This cannot be undone.")
        }
    }

    // MARK: - Toolbar

    private var listToolbar: some View {
        HStack {
            Text("Runs").font(.headline)
            Spacer()
            Menu {
                Button("Clear All History") { showClearConfirm = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Filters

    private var kindFilterBar: some View {
        HStack(spacing: 0) {
            ForEach([nil, .integration, .compose, .parity] as [SessionRecord.Kind?], id: \.self) { kind in
                filterTab(kind)
            }
            Spacer()
            statusFilterMenu
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func filterTab(_ kind: SessionRecord.Kind?) -> some View {
        let label = kind?.rawValue.capitalized ?? "All"
        let active = filterKind == kind
        return Button { filterKind = kind } label: {
            Text(label)
                .font(.system(.caption, weight: active ? .semibold : .regular))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(active ? Color.accentColor.opacity(0.15) : Color.clear, in: Capsule())
                .foregroundStyle(active ? Color.accentColor : .secondary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var statusFilterMenu: some View {
        Menu {
            Button("All") { filterStatus = .all }
            Button("Passed only") { filterStatus = .passed }
            Button("Failed only") { filterStatus = .failed }
        } label: {
            Label(statusLabel, systemImage: statusIcon)
                .font(.caption)
                .foregroundStyle(filterStatus == .all ? .secondary : Color.accentColor)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 60)
    }

    private var statusLabel: String {
        switch filterStatus { case .all: return "All"; case .passed: return "Passed"; case .failed: return "Failed" }
    }
    private var statusIcon: String {
        switch filterStatus { case .all: return "line.3.horizontal.decrease"; case .passed: return "checkmark.circle"; case .failed: return "xmark.circle" }
    }

    // MARK: - Actions

    private func delete(_ entry: HistoryEntry) {
        if selected == entry { selected = nil }
        entries.removeAll { $0.id == entry.id }
        Task { await Sessions.shared.delete(entry) }
    }

    private func clearAll() async {
        selected = nil
        entries = []
        await Sessions.shared.clearAll()
    }

    private func load() async {
        isLoading = true
        entries = await Sessions.shared.loadRecentReports(limit: 100)
        if selected == nil { selected = entries.first }
        isLoading = false
    }
}

// MARK: - Row

private struct HistoryRowView: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.report.failed == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(entry.report.failed == 0 ? .green : .red)
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.kind.rawValue.capitalized)
                        .font(.system(.callout, weight: .medium))
                    Text("· \(entry.report.passed)/\(entry.report.results.count)")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text(formattedDate(entry.report.timestamp))
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private func formattedDate(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: date)
    }
}

// MARK: - Detail

private struct HistoryDetailView: View {
    let entry: HistoryEntry
    @State private var sectionFilter: String? = nil
    @State private var statusFilter: StatusFilter = .all
    @State private var expanded: Set<String> = []

    enum StatusFilter { case all, passed, failed }

    private var sections: [String] { Array(Set(entry.report.results.map(\.section))).sorted() }

    private var filtered: [TestResult] {
        entry.report.results.filter { r in
            (sectionFilter == nil || r.section == sectionFilter) &&
            (statusFilter == .all
             || (statusFilter == .passed && r.status == .passed)
             || (statusFilter == .failed && r.status == .failed))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            detailHeader
            Divider()
            filterBar
            Divider()
            resultList
        }
    }

    private var detailHeader: some View {
        HStack(spacing: 20) {
            statChip("\(entry.report.passed)", color: .green, label: "passed")
            if entry.report.failed > 0 {
                statChip("\(entry.report.failed)", color: .red, label: "failed")
            }
            if entry.report.skipped > 0 {
                statChip("\(entry.report.skipped)", color: .gray, label: "skipped")
            }
            if entry.report.knownFailures > 0 {
                statChip("\(entry.report.knownFailures)", color: .orange, label: "known")
            }
            Spacer()
            if entry.report.failed > 0 {
                Button {
                    copyToClipboard(failuresMarkdown(results: entry.report.results,
                                                    environment: entry.report.environment,
                                                    suiteName: entry.kind.rawValue.capitalized))
                } label: {
                    Label("Copy failures", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text(entry.report.environment.socktainerVersion)
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                Text(entry.report.environment.machineSummary)
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private var filterBar: some View {
        HStack(spacing: 0) {
            // Section filter
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    sectionChip(nil, label: "All")
                    ForEach(sections, id: \.self) { sec in sectionChip(sec, label: sec) }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            Divider().frame(height: 24)
            // Status filter
            Menu {
                Button("All") { statusFilter = .all }
                Button("Passed") { statusFilter = .passed }
                Button("Failed") { statusFilter = .failed }
            } label: {
                Label(statusFilter == .all ? "All" : statusFilter == .passed ? "Passed" : "Failed",
                      systemImage: "line.3.horizontal.decrease")
                    .font(.caption)
                    .foregroundStyle(statusFilter == .all ? .secondary : Color.accentColor)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 70)
            .padding(.trailing, 8)
        }
    }

    private var resultList: some View {
        List(filtered, id: \.name) { result in
            HistoryResultRow(result: result,
                             isExpanded: expanded.contains(result.name),
                             onToggle: {
                                 if expanded.contains(result.name) {
                                     expanded.remove(result.name)
                                 } else {
                                     expanded.insert(result.name)
                                 }
                             })
        }
        .listStyle(.inset)
    }

    private func sectionChip(_ sec: String?, label: String) -> some View {
        let active = sectionFilter == sec
        return Button { sectionFilter = sec } label: {
            Text(label)
                .font(.system(.caption, weight: active ? .semibold : .regular))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(active ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08), in: Capsule())
                .foregroundStyle(active ? Color.accentColor : .secondary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func statChip(_ value: String, color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Text(value).fontWeight(.semibold).foregroundStyle(color)
            Text(label).foregroundStyle(.secondary)
        }.font(.callout)
    }
}

private struct HistoryResultRow: View {
    let result: TestResult
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(alignment: .top, spacing: 10) {
                    Text(icon).font(.system(size: 13)).frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            if let id = result.id {
                                Text(id)
                                    .font(.system(.caption2, design: .monospaced))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                            }
                            Text(result.name).font(.callout)
                        }
                        if result.status == .failed && !isExpanded, let reason = result.failureReason {
                            Text(reason).font(.caption).foregroundStyle(.red.opacity(0.8)).lineLimit(1)
                        }
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        Text(String(format: "%.2fs", Double(result.durationMs) / 1000))
                            .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                        if result.status == .failed {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded, let reason = result.failureReason {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Failure detail")
                        .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                    Text(reason)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    if let repro = result.reproCommand {
                        Text("Repro command")
                            .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                        Text(repro)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(.leading, 28)
                .padding(.top, 8)
                .padding(.bottom, 4)
            }
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button {
                copyToClipboard(resultMarkdown(result))
            } label: {
                Label("Copy as Markdown", systemImage: "doc.on.clipboard")
            }
            if result.status == .failed {
                Button {
                    copyToClipboard(resultMarkdown(result))
                } label: {
                    Label("Copy failure details", systemImage: "exclamationmark.bubble")
                }
            }
            if let repro = result.reproCommand {
                Divider()
                Button {
                    copyToClipboard(repro)
                } label: {
                    Label("Copy repro command", systemImage: "terminal")
                }
            }
        }
    }

    private var icon: String {
        switch result.status {
        case .passed: "✅"; case .failed: "❌"
        case .skipped: "⏭"; case .knownFailure: "⚠️"; case .unexpectedPass: "🎉"
        }
    }
}
