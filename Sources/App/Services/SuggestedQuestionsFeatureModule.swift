import Foundation

/// The chat "suggested questions" starter chips as a `FeatureModule`.
///
/// Complete and working, but a non-core convenience layered on top of chat — the
/// therapist can always type her own question. It ships from `.preview` rather
/// than `.production` so the production chat stays lean.
///
/// Gating is at the two chat call sites (`SessionDetailView`, `PatientChatView`),
/// which pass no suggestions when the module is absent; `ChatPaneView` already
/// renders nothing for an empty list, so the chat is unchanged apart from the
/// missing starter chips.
struct SuggestedQuestionsFeatureModule: FeatureModule {
    /// Also usable as `SuggestedQuestionsFeatureModule.id` at call sites that only
    /// need the identifier to query the registry, without constructing an instance.
    static let id = "suggestedQuestions"

    var id: String { Self.id }
    let title = "Suggested Questions"
    let tier: BuildTier = .preview
}
