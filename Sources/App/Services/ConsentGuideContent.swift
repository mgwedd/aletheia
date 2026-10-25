import Foundation

/// What the consent guide says: numbered sections, then a sample clause to
/// adapt into a client's consent form.
enum ConsentGuideContent {
    struct Section: Identifiable {
        let title: String
        let icon: String
        let text: String
        var id: String { title }
    }

    static let sections: [Section] = [
        Section(
            title: "1. Informed Consent Standards",
            icon: "doc.text.magnifyingglass",
            text: "Professional ethics codes (including APA, ACA, NASW, and AAMFT) require obtaining explicit informed consent before recording therapy sessions in any medium. Inform your client of the purpose of the recording, how transcripts are generated, and who has access."),
        Section(
            title: "2. Jurisdiction & Wiretapping Laws",
            icon: "building.columns",
            text: "Many states and jurisdictions require two-party (all-party) consent to record conversations. Because telehealth sessions may cross state lines, follow the strictest applicable jurisdiction's consent laws."),
        Section(
            title: "3. On-Device Privacy Guarantees",
            icon: "lock.shield",
            text: "Explain to your client that Aletheia operates 100% on this Mac: speech recognition and AI note drafting run locally. No audio, transcripts, or notes are uploaded to any cloud server or third-party service."),
        Section(
            title: "4. Client Rights & Revocation",
            icon: "hand.raised",
            text: "Clients have the right to decline recording, ask to pause or stop recording at any point during a session, or request that previous session recordings or transcripts be deleted from your records."),
    ]

    static let sampleClause = "“I use an on-device clinical documentation tool (Aletheia) to transcribe our session audio and assist in preparing clinical progress notes. All audio and notes remain strictly on this computer and are never sent to external servers or cloud AI providers. You may request to pause or stop recording at any time.”"
}
