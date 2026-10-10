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
        PaneSplit(size: 300...680, idealSize: 420, otherMinSize: 340) {
            // The composer keeps its height; the file list takes the rest.
            PaneSplit(.vertical, sizedPane: .second, size: 250...640, idealSize: 320, otherMinSize: 180) {
                ChangeListView(workingCopy: workingCopy)
            } second: {
                CommitComposerView(composer: model.composer)
            }
        } second: {
            DiffView(workingCopy: workingCopy)
        }
        .task(id: DiffTrigger(refreshCount: model.refreshCount, selection: workingCopy.selection, options: workingCopy.diffOptions)) {
            await workingCopy.loadDiff()
        }
        .task(id: model.refreshCount) { await model.composer.checkAmend() }
    }
}
