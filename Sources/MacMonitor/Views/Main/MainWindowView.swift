import MonitorCore
import SwiftUI

/// The one window of MacMonitor: sidebar with all areas, detail on the right, one title bar and toolbar.
struct MainWindowView: View {
    @Bindable var model: AppModel
    /// Offline image renderer: no stored state, no window bookkeeping, no history reloads.
    var isPreview = false

    @AppStorage("main.section") private var storedSection = ""
    @AppStorage("main.range") private var storedRange = DashboardRange.day.rawValue
    @AppStorage("main.reportPeriod") private var storedPeriod = ReportPeriod.day.rawValue
    @AppStorage("main.sidebarVisible") private var sidebarVisible = true
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        if isPreview {
            PreviewWindowBody(model: model)
        } else {
            window
        }
    }

    private var window: some View {
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            MainDetail(model: model)
                .navigationTitle(model.section.title)
                .navigationSubtitle(model.section.subtitle)
                .toolbar { MainToolbar(model: model) }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: Text("Suchen"))
        .frame(minWidth: 860, minHeight: 600)
        .background { if !isPreview { WindowAccessor(model: model) } }
        .confirmationAlert(model: model, host: .window)
        .sheet(isPresented: $model.showsWelcome, onDismiss: { Welcome.markSeen() }) {
            WelcomeView(model: model) { model.showsWelcome = false }
        }
        .onAppear { if !isPreview { restore() } }
        .onChange(of: model.section) { _, new in storedSection = new.rawValue }
        .onChange(of: model.dashboard.range) { _, new in storedRange = new.rawValue }
        .onChange(of: model.dashboard.reportPeriod) { _, new in storedPeriod = new.rawValue }
        .onChange(of: columns) { _, new in sidebarVisible = new != .detailOnly }
        // Loads history only while the window is on screen and the area draws it; the task ends with the area.
        .task(id: ReloadID(key: model.section.dashboardSection == nil ? nil : model.dashboard.currentKey,
                           visible: model.isMainWindowVisible)) {
            guard !isPreview, model.isMainWindowVisible, model.section.dashboardSection != nil else { return }
            while !Task.isCancelled {
                await model.dashboard.reload()
                try? await Task.sleep(for: model.dashboard.range.refreshInterval)
            }
        }
    }

    private struct ReloadID: Hashable {
        var key: DashboardData.Key?
        var visible: Bool
    }

    private func restore() {
        model.section = AppSection.restored(from: storedSection)
        model.dashboard.range = DashboardRange(rawValue: storedRange) ?? .day
        model.dashboard.reportPeriod = ReportPeriod(rawValue: storedPeriod) ?? .day
        columns = sidebarVisible ? .all : .detailOnly
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            List(selection: selection(in: [.monitor, .history, .tools])) {
                ForEach([SidebarGroup.monitor, .history, .tools]) { group in
                    Section(group.title) {
                        ForEach(group.sections) { row($0) }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            // Settings sit apart at the bottom, like the account and settings area of other sidebars.
            List(selection: selection(in: [.settings])) {
                Section(SidebarGroup.settings.title) {
                    ForEach(SidebarGroup.settings.sections) { row($0) }
                }
            }
            .listStyle(.sidebar)
            .scrollDisabled(true)
            .frame(height: CGFloat(SidebarGroup.settings.sections.count) * 28 + 44)
        }
    }

    /// Both lists share one selection; each shows it only for its own groups.
    private func selection(in groups: [SidebarGroup]) -> Binding<AppSection?> {
        Binding(get: { groups.contains(model.section.group) ? model.section : nil },
                set: { if let new = $0 { model.section = new; model.searchText = "" } })
    }

    @ViewBuilder private func row(_ section: AppSection) -> some View {
        HStack {
            Label(section.title, systemImage: section.symbol)
            if section == .issues, !model.reported.isEmpty {
                Spacer(minLength: 4)
                Text("\(model.reported.count)")
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Palette.severity(model.menuBarAlert ?? .info), in: Capsule())
            }
        }
        .tag(section)
    }
}

// MARK: - Toolbar

private struct MainToolbar: ToolbarContent {
    let model: AppModel

    var body: some ToolbarContent {
        @Bindable var dashboard = model.dashboard
        ToolbarItem(placement: .primaryAction) {
            if model.searchText.isEmpty || model.section == .apps {
                if model.section.usesRange {
                    Picker("Zeitraum", selection: $dashboard.range) {
                        ForEach(DashboardRange.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .help(Text("Zeitraum"))
                } else if model.section.usesReportPeriod {
                    Picker("Zeitraum", selection: $dashboard.reportPeriod) {
                        ForEach(ReportPeriod.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .help(Text("Zeitraum"))
                }
            }
        }
    }
}

// MARK: - Detail

/// The area on the right: feedback on top, then the page, or the search result while the field is filled.
struct MainDetail: View {
    @Bindable var model: AppModel

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .safeAreaInset(edge: .top, spacing: 0) {
                if let feedback = model.feedback {
                    FeedbackBanner(feedback: feedback) { model.feedback = nil }
                        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 4)
                }
            }
    }

    @ViewBuilder private var content: some View {
        if !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty, model.section != .apps {
            SearchResults(model: model)
        } else {
            page
        }
    }

    @ViewBuilder private var page: some View {
        switch model.section {
        case .issues: PageScroll { IssuesPane(model: model) }
        case .cleanup: PageScroll { CleanupPane(model: model) }
        case .overview, .apps, .cpu, .memory, .energy, .sensors, .network, .events, .report:
            PageScroll { HistoryPage(model: model) }
        case .general: GeneralPane(model: model)
        case .menuBar: MenuBarPane(model: model)
        case .rules: RulesPane(model: model)
        case .customRules: CustomRulesPane(model: model, previewRule: model.previewCustomRule)
        case .quiet: QuietPane(model: model)
        case .ignored: IgnoredPane(model: model)
        case .data: DataPane(model: model)
        case .about: UpdatesPane(model: model)
        }
    }
}

/// Scrolling page with the window's standard margins.
struct PageScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            content
                .padding(20)
                .frame(maxWidth: 1100, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

/// Areas matching the search text.
struct SearchResults: View {
    @Bindable var model: AppModel

    var body: some View {
        let hits = SectionSearch.matches(model.searchText)
        if hits.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        } else {
            List(hits) { section in
                Button {
                    model.open(section)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.symbol).frame(width: 22).foregroundStyle(Palette.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(section.title)
                            Text(section.group.title).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// The history-backed pages of the monitor and history groups.
struct HistoryPage: View {
    let model: AppModel

    var body: some View {
        DashboardDetail(model: model, expandedApps: model.previewExpandedApps)
    }
}
