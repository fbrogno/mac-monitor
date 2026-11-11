import MonitorCore
import SwiftUI

/// Tools: clean up the SSD.
struct CleanupPane: View {
    let model: AppModel

    var body: some View {
        CleanupSection(model: model, disk: model.snapshot?.disk)
    }
}
