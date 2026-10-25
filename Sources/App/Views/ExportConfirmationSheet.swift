import SwiftUI

/// The sheet that asks before patient data is saved outside the data folder.
struct ExportConfirmationSheet: View {
    let confirmation: ExportConfirmation
    let onResolve: (_ confirmed: Bool, _ dontAskAgain: Bool) -> Void
    @State private var dontAskAgain = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(confirmation.title)
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.text.color)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(confirmation.message)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.text.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.warn.color)
                    .accessibilityHidden(true)
            }

            Text(confirmation.advice)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.text.color)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.warnTint.color, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))

            if confirmation.offersDontAskAgain {
                Toggle(ExportConfirmation.dontAskAgainTitle, isOn: $dontAskAgain)
                    .toggleStyle(.checkbox)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.text.color)
            }

            HStack {
                Spacer()
                Button("Cancel") { onResolve(false, false) }
                    .buttonStyle(.themed)
                    .keyboardShortcut(.cancelAction)
                Button(confirmation.confirmButtonTitle) { onResolve(true, dontAskAgain) }
                    .buttonStyle(.themePrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(Theme.panel.color)
    }
}

extension View {
    /// Presents the export question while `pending` is set. Confirming runs the
    /// export after the sheet has closed, so the save panel isn't opened from
    /// inside it; cancelling, Escape or the app locking writes nothing.
    func exportConfirmation(_ pending: Binding<ExportConfirmation?>, settings: AppSettings) -> some View {
        sheet(item: pending) { confirmation in
            ExportConfirmationSheet(confirmation: confirmation) { confirmed, dontAskAgain in
                pending.wrappedValue = nil
                guard confirmed else { return }
                if dontAskAgain && confirmation.offersDontAskAgain { settings.skipSingleNoteExportConfirmation = true }
                DispatchQueue.main.async { confirmation.resolve(confirmed: true) }
            }
        }
    }
}
