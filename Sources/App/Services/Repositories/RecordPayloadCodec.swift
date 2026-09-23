import AletheiaCore
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
        return Data(FieldCipher.encode(json, using: protector).utf8)
    }

    static func decode<T: Decodable>(_ type: T.Type, from payload: Data, using protector: FileProtector) -> T? {
        let json = openedText(from: payload, using: protector)
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder.aletheia.decode(T.self, from: data)
    }

    /// Opens just the field-cipher layer, without assuming what's underneath is
    /// valid JSON for any particular type — the building block `decode` uses,
    /// and the fallback for a caller that must still show *something* when a
    /// record can't be decoded as its domain type (typically because it's
    /// still-sealed ciphertext read under the wrong key: `FieldCipher.decode`
    /// then hands back the ciphertext string unchanged rather than throwing).
    static func openedText(from payload: Data, using protector: FileProtector) -> String {
        FieldCipher.decode(String(decoding: payload, as: UTF8.self), using: protector)
    }

    /// Re-seals a payload from one protector to another without decoding its
    /// domain shape at all: the field cipher wraps the *whole* JSON blob, so
    /// opening and re-sealing that one layer migrates any kind of record the
    /// same way. This is what backs every repository's `reencrypt`.
    static func reseal(_ payload: Data, from: FileProtector, to: FileProtector) -> Data {
        Data(FieldCipher.encode(openedText(from: payload, using: from), using: to).utf8)
    }
}
