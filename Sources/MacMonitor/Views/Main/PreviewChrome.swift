import MonitorCore
import SwiftUI

/// The window's sidebar and toolbar drawn in plain SwiftUI, for the README images only: the AppKit-backed
/// sidebar and toolbar items of the real window do not appear in an off-screen capture. Same sections, same
/// order, same detail views as the real window.
struct PreviewWindowBody: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            PreviewSidebar(model: model).frame(width: 220)
            Divider()
            VStack(spacing: 0) {
                PreviewToolbar(model: model).frame(height: 52)
                Divider().opacity(0.6)
                MainDetail(model: model)
            }
        }
        .ignoresSafeArea()
    }
}

private struct PreviewSidebar: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 48)
            VStack(alignment: .leading, spacing: 14) {
                ForEach([SidebarGroup.monitor, .history, .tools]) { groupView($0) }
            }
            Spacer(minLength: 8)
            Divider().padding(.horizontal, 6)
            groupView(.settings).padding(.top, 8).padding(.bottom, 10)
        }
        .padding(.horizontal, 10)
        .background(Color.primary.opacity(0.04))
    }

    private func groupView(_ group: SidebarGroup) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(group.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.bottom, 3)
            ForEach(group.sections) { row($0) }
        }
    }

    private func row(_ section: AppSection) -> some View {
        let selected = section == model.section
        return HStack(spacing: 8) {
            Image(systemName: section.symbol).font(.system(size: 13)).frame(width: 20)
                .foregroundStyle(selected ? Color.white : Palette.accent)
            Text(section.title).font(.system(size: 13))
            Spacer(minLength: 4)
            if section == .issues, !model.reported.isEmpty {
                Text("\(model.reported.count)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Palette.severity(model.menuBarAlert ?? .info), in: Capsule())
            }
        }
        .padding(.horizontal, 8).frame(height: 26)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(selected ? Color.accentColor.opacity(0.85) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct PreviewToolbar: View {
    @Bindable var model: AppModel

    var body: some View {
        @Bindable var dashboard = model.dashboard
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text(model.section.title).font(.system(size: 14, weight: .semibold))
                if !model.section.subtitle.isEmpty {
                    Text(model.section.subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.section.usesRange {
                MiniSegment(options: DashboardRange.allCases.map(\.title), selection: Binding(
                    get: { DashboardRange.allCases.firstIndex(of: dashboard.range) ?? 1 },
                    set: { dashboard.range = DashboardRange.allCases[$0] }))
            } else if model.section.usesReportPeriod {
                MiniSegment(options: ReportPeriod.allCases.map(\.title), selection: Binding(
                    get: { ReportPeriod.allCases.firstIndex(of: dashboard.reportPeriod) ?? 0 },
                    set: { dashboard.reportPeriod = ReportPeriod.allCases[$0] }))
            }
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 11))
                Text("Suchen").font(.system(size: 12))
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).frame(width: 170, height: 26)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .padding(.leading, 20).padding(.trailing, 16)
    }
}
