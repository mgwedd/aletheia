import Combine
import Foundation

/// Where the license stands right now.
enum LicenseStatus: Equatable {
    /// No token has been entered.
    case unlicensed
    /// No token, on an install set up before license keys existed: work is allowed.
    case grandfathered
    /// A good token with more than 14 days left.
    case valid(LicenseToken)
    /// A good token inside its last 14 days.
    case expiringSoon(LicenseToken, daysLeft: Int)
    /// Past its expiry but inside the 14-day grace period: work is still allowed.
    case gracePeriod(LicenseToken, daysLeft: Int)
    /// Past the grace period.
    case expired(LicenseToken)
    /// Named by a revocation list; treated like expired.
    case revoked(LicenseToken)
    /// A token is stored but does not verify (bad signature, unknown key, ...).
    case invalid(LicenseError)

    /// The license, when there is a usable or lapsed one to describe.
    var token: LicenseToken? {
        switch self {
        case .valid(let t), .expiringSoon(let t, _), .gracePeriod(let t, _), .expired(let t), .revoked(let t): return t
        case .unlicensed, .grandfathered, .invalid: return nil
        }
    }

    /// A current license: new recording and AI are allowed.
    var isActive: Bool {
        switch self {
        case .valid, .expiringSoon, .gracePeriod, .grandfathered: return true
        case .unlicensed, .expired, .revoked, .invalid: return false
        }
    }
}

/// Raised when a license problem stops new recording or AI. Never raised for
/// reading, searching, exporting or deleting existing records.
struct LicenseBlockedError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The license as the app sees it: checked offline against the keyring, with the
/// clock injected. It only ever gates **starting a new recording** and **running
/// AI**; nothing that opens, reads, searches, exports or deletes existing records
/// asks it anything (`LicenseGateScopeTests` keeps that so).
@MainActor
final class LicenseState: ObservableObject {
    private let settings: AppSettings
    private let keyring: LicenseKeyring
    private let now: () -> Date
    private var cancellable: AnyCancellable?

    @Published private(set) var status: LicenseStatus = .unlicensed

    init(settings: AppSettings, keyring: LicenseKeyring = .active, now: @escaping () -> Date = Date.init) {
        self.settings = settings
        self.keyring = keyring
        self.now = now
        refresh()
        // Re-evaluate when the stored token or the revoked set changes.
        cancellable = settings.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.refresh()
        }
    }

    /// Re-reads the stored token against the clock. Call when the app becomes active
    /// so an expiry that passed while it was open takes effect.
    func refresh() {
        let next = LicenseState.evaluate(
            token: settings.licenseToken, keyring: keyring, now: now(),
            revoked: Set(settings.revokedLicenseIDs), grandfathered: settings.licenseGrandfathered)
        if next != status { status = next }
    }

    /// The status for a token string. Pure.
    nonisolated static func evaluate(token text: String, keyring: LicenseKeyring, now: Date, revoked: Set<String>, grandfathered: Bool = false) -> LicenseStatus {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return grandfathered ? .grandfathered : .unlicensed }
        let token: LicenseToken
        do {
            token = try LicenseVerifier.verifySignature(text, keyring: keyring)
        } catch let error as LicenseError {
            return .invalid(error)
        } catch {
            return .invalid(.malformed)
        }
        if token.issuedAt.timeIntervalSince(now) > LicenseVerifier.allowedClockSkew { return .invalid(.issuedInFuture) }
        if revoked.contains(token.lid) { return .revoked(token) }
        if let days = token.graceDaysRemaining(at: now) { return .gracePeriod(token, daysLeft: days) }
        if token.isExpired(at: now) { return .expired(token) }
        if token.isExpiringSoon(at: now), let days = token.daysRemaining(at: now) {
            return .expiringSoon(token, daysLeft: days)
        }
        return .valid(token)
    }

    /// Checks a pasted token and, if it is good (signed, not expired, not revoked),
    /// stores it. A token that fails never replaces the one in use.
    @discardableResult
    func install(_ text: String) -> Result<LicenseToken, LicenseError> {
        do {
            let token = try LicenseVerifier.verify(text, keyring: keyring, now: now())
            if settings.revokedLicenseIDs.contains(token.lid) { throw LicenseError.revoked }
            settings.licenseToken = text.trimmingCharacters(in: .whitespacesAndNewlines)
            refresh()
            return .success(token)
        } catch let error as LicenseError {
            return .failure(error)
        } catch {
            return .failure(.malformed)
        }
    }

    /// Applies a list that `applyRevocationList` has verified. Private so no caller
    /// can apply an unsigned list. Returns false (and changes nothing) for a list
    /// older than the newest one already accepted. A revoked license id is then
    /// treated like an expired one.
    private func apply(_ list: RevocationList) -> Bool {
        let seconds = list.issuedAt.timeIntervalSince1970
        // Clamp so an absurd signed `iat` cannot trap the conversion.
        let issued = seconds < Double(Int.max) ? Int(seconds) : Int.max
        guard issued >= settings.lastRevocationIssuedAt else { return false }
        settings.lastRevocationIssuedAt = issued
        settings.revokedLicenseIDs = list.revoked.sorted()
        refresh()
        return true
    }

    /// Verifies the signed text of a list against the keyring and the last accepted
    /// `iat`, then applies it. The caller that fetches the bytes will use this.
    @discardableResult
    func applyRevocationList(_ text: String) throws -> Bool {
        let list = try RevocationVerifier.verify(
            text, keyring: keyring, lastAcceptedIssuedAt: settings.lastRevocationIssuedAt)
        return apply(list)
    }

    // MARK: - The gate

    /// Why a new recording or an AI run may not start, or nil when it may. This is
    /// the only question the license is ever asked. It re-reads the clock first, so
    /// an expiry that passed while the app stayed open takes effect.
    var newWorkRefusal: String? {
        refresh()
        switch status {
        case .valid, .expiringSoon, .gracePeriod, .grandfathered:
            return nil
        case .unlicensed:
            return "Aletheia needs a license key to record or run the AI. Add yours in Settings > License key. Your existing records are untouched."
        case .invalid(let error):
            return "\(error.errorDescription ?? "The license key could not be verified.") Add a valid key in Settings > License key. Your existing records are untouched."
        case .expired(let token):
            return "Your license expired on \(token.expiresAt.licenseText) and its 14-day grace period has ended, so new recordings and the AI are paused. Add a new key in Settings > License key. Your existing records are untouched."
        case .revoked:
            return "This license is no longer valid, so new recordings and the AI are paused. Add a new key in Settings > License key. Your existing records are untouched."
        }
    }

    /// Throws `LicenseBlockedError` when `newWorkRefusal` is set.
    func authorizeNewWork() throws {
        if let message = newWorkRefusal { throw LicenseBlockedError(message: message) }
    }
}
