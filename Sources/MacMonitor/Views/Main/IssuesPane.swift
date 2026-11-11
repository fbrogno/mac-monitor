import MonitorCore
import SwiftUI

/// Every reported condition with explanation, steps and fix buttons.
struct IssuesPane: View {
    let model: AppModel

    var body: some View {
        OverviewContent(model: model)
    }
}
