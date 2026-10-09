import DKBSourceControlCore
import SwiftUI

/// Files and the commit message on the left, the selected file's diff on
/// the right (plan §7.1).
struct WorkingCopyView: View {
    let model: RepositoryModel

    /// Anything that changes what the diff shows.
    private struct DiffTrigger: Equatable {
        let refreshCount: Int
        let selection: Set<WorkingCopyModel.Row>
        let options: DiffOptions
    }

    var body: some View {
        let workingCopy = model.workingCopy
        PaneSplit(leadingWidth: 300...680, idealLeadingWidth: 420, trailingMinWidth: 340) {
            VSplitView {
                ChangeListView(workingCopy: workingCopy)
                    .frame(minHeight: 180)
                CommitComposerView(composer: model.composer)
                    .frame(minHeight: 250, idealHeight: 320)
            }
        } trailing: {
            DiffView(workingCopy: workingCopy)
        }
        .task(id: DiffTrigger(refreshCount: model.refreshCount, selection: workingCopy.selection, options: workingCopy.diffOptions)) {
            await workingCopy.loadDiff()
        }
        .task(id: model.refreshCount) { await model.composer.checkAmend() }
    }
}
