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
        HSplitView {
            VSplitView {
                ChangeListView(workingCopy: workingCopy)
                    .frame(minHeight: 180)
                CommitComposerView(composer: model.composer)
                    .frame(minHeight: 250, idealHeight: 320)
            }
            .frame(minWidth: 300, idealWidth: 420, maxWidth: 680)
            DiffView(workingCopy: workingCopy)
                .frame(minWidth: 340, maxWidth: .infinity)
        }
        .task(id: DiffTrigger(refreshCount: model.refreshCount, selection: workingCopy.selection, options: workingCopy.diffOptions)) {
            await workingCopy.loadDiff()
        }
        .task(id: model.refreshCount) { await model.composer.checkAmend() }
    }
}
