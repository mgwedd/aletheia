import Foundation

/// Turns a domain value into a `PersistedRecord`'s opaque `payload` and back —
/// the encoding/encryption adapter every typed repository shares (Arch v2 (2),
/// #65/#74/#76). A value is JSON-encoded (`JSONEncoder.aletheia`) and the
/// resulting string is field-sealed with the existing `FieldCipher` before it
/// becomes the payload's bytes; decoding reverses that. `.passthrough` makes
/// both steps a byte-for-byte no-op, exactly as it did for `CommentStore`'s
/// bespoke SQL columns, so the encryption on/off toggle keeps round-tripping.
enum RecordPayloadCodec {
    static func encode<T: Encodable>(_ value: T, using protector: FileProtector) -> Data? {
        guard
            let data = try? JSONEncoder.aletheia.encode(value),
            let json = String(data: data, encoding: .utf8)
        else { return nil }
        guard let sealed = try? FieldCipher.encode(json, using: protector) else { return nil }
        return Data(sealed.utf8)
    }

    static func decode<T: Decodable>(_ type: T.Type, from payload: Data, using protector: FileProtector) -> T? {
        guard let json = openedText(from: payload, using: protector) else { return nil }
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder.aletheia.decode(T.self, from: data)
    }

    /// Opens just the field-cipher layer, without assuming what's underneath is
    /// valid JSON for any particular type — the building block `decode` uses,
    /// and the fallback for legacy plaintext that is not valid domain JSON.
    /// An envelope that cannot be opened never reaches the fallback UI.
    static func openedText(from payload: Data, using protector: FileProtector) -> String? {
        try? FieldCipher.decode(String(decoding: payload, as: UTF8.self), using: protector)
    }

    static func hasUnreadableEnvelope(_ payload: Data, using protector: FileProtector) -> Bool {
        guard protector.isEncrypting else { return false } // locked folders are not damaged
        let stored = String(decoding: payload, as: UTF8.self)
        guard let data = Data(base64Encoded: stored), DataCipher.isEnvelope(data) else { return false }
        return (try? protector.open(data)) == nil
    }

    /// Re-seals a payload from one protector to another without decoding its
    /// domain shape at all: the field cipher wraps the *whole* JSON blob, so
    /// opening and re-sealing that one layer migrates any kind of record the
    /// same way. This is what backs every repository's `reencrypt`.
    static func reseal(_ payload: Data, from: FileProtector, to: FileProtector) -> Data? {
        guard let opened = openedText(from: payload, using: from),
              let sealed = try? FieldCipher.encode(opened, using: to) else { return nil }
        return Data(sealed.utf8)
    }
}
