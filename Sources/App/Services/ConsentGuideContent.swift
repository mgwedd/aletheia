import Foundation

/// What the consent guide says: numbered sections, a sample clause to adapt
/// into a client's consent form, and a script to read before recording.
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
            text: "Many states and jurisdictions require two-party (all-party) consent to record conversations. Because telehealth sessions may cross state lines, follow the strictest applicable jurisdiction's consent laws. Three examples, not a complete list: California Penal Code §632, Washington RCW 9.73.030 and Connecticut Gen. Stat. §52-570d. Check the law wherever you and your client are located during a session."),
        Section(
            title: "3. On-Device Privacy Guarantees",
            icon: "lock.shield",
            text: "Explain to your client that Aletheia runs on this Mac: speech recognition and AI note drafting happen locally, and the app does not upload audio, transcripts, or notes to any cloud server or third-party service. The data stays on this Mac unless you export it or your own backups (such as Time Machine) copy it."),
        Section(
            title: "4. Client Rights & Revocation",
            icon: "hand.raised",
            text: "Clients have the right to decline recording, ask to pause or stop recording at any point during a session, or request that previous session recordings or transcripts be deleted from your records."),
    ]

    static let sampleClause = "“I use an on-device clinical documentation tool (Aletheia) to transcribe our session audio and assist in preparing clinical progress notes. The app does not send audio or notes to external servers or cloud AI providers; they are stored on this computer, and copies exist only where I export them or my own backups make them. You may request to pause or stop recording at any time.”"

    static let scriptIntro = "Read this aloud and wait for a clear answer before you start recording. Adapt it to your practice."

    static let script = "“Before we start, I would like to record today's session so that I can write my clinical notes. The recording is stored on my computer and is used only for documentation. Do you agree to be recorded? You can say no, and you can ask me to pause or stop at any time.”"
}
