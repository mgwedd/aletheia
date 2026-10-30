import AppKit
import SwiftUI

/// A model download that failed, and how to start it again. Shown as an
/// alert that says why and offers a way forward, not just OK.
struct ModelDownloadFailure: Identifiable {
    enum Action: CaseIterable {
        case tryAgain
        case reportBug

        var title: String {
            switch self {
            case .tryAgain: return "Try Again"
            case .reportBug: return "Report a Bug"
            }
        }
    }

    static let title = "Couldn't download the model"

    let id = UUID()
    let reason: String
    let retry: () -> Void

    init(_ error: Error, retry: @escaping () -> Void) {
        if case ModelDownloadError.downloadFailed(let why) = error {
            reason = why   // the title already says the download failed
        } else {
            reason = error.localizedDescription
        }
        self.retry = retry
    }

    /// `open` is the browser, for the bug report.
    func perform(_ action: Action, open: (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        switch action {
        case .tryAgain: retry()
        case .reportBug: open(FeedbackLink.url(.bug))
        }
    }
}

extension View {
    /// The alert for a failed model download: Try Again, Report a Bug, Cancel.
    func modelDownloadFailureAlert(_ failure: Binding<ModelDownloadFailure?>) -> some View {
        alert(
            ModelDownloadFailure.title,
            isPresented: Binding(get: { failure.wrappedValue != nil }, set: { if !$0 { failure.wrappedValue = nil } }),
            presenting: failure.wrappedValue
        ) { shown in
            ForEach(ModelDownloadFailure.Action.allCases, id: \.self) { action in
                Button(action.title) { shown.perform(action) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { shown in
            Text(shown.reason)
        }
    }
}
