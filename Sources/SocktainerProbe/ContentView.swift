import SwiftUI
import SocktainerProbeCore

enum SidebarItem: String, Hashable, CaseIterable {
    case dashboard = "Dashboard"
    case run = "Run Tests"
    case coverage = "Coverage"
    case history = "History"
    case settings = "Settings"

    var icon: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .run:       "play.circle"
        case .coverage:  "checklist"
        case .history:   "clock"
        case .settings:  "gear"
        }
    }
}

struct ContentView: View {
    @State private var selection: SidebarItem? = .dashboard
    // Owned here so state survives sidebar navigation
    @State private var runVM = RunTestsViewModel()
    @State private var coverageVM = CoverageViewModel()

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, id: \.self, selection: $selection) { item in
                sidebarRow(item)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch selection {
            case .dashboard:
                DashboardView(sidebarSelection: $selection, runVM: runVM, coverageVM: coverageVM)
            case .run:
                RunTestsView(vm: runVM)
            case .coverage:
                CoverageView(vm: coverageVM)
            case .history:
                HistoryView()
            case .settings:
                SettingsView(runIsActive: runVM.isRunning)
            case nil:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func sidebarRow(_ item: SidebarItem) -> some View {
        HStack {
            Label(item.rawValue, systemImage: item.icon)
            Spacer()
            if item == .run && runVM.isRunning {
                Circle().fill(.orange).frame(width: 8, height: 8)
            }
        }
    }
}
