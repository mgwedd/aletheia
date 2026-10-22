import AppKit

/// Pasteboard writes containing patient information stay on this Mac and ask
/// clipboard managers not to retain the contents.
enum PHIPasteboard {
    static var general: NSPasteboard { NSPasteboard.general }
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    static func writeString(_ string: String, to pasteboard: NSPasteboard = .general) {
        let item = NSPasteboardItem()
        item.setString(string, forType: .string)
        write([item], to: pasteboard)
    }

    static func write(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard = .general) {
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        for item in items {
            item.setData(Data(), forType: concealed)
            item.setData(Data(), forType: transient)
        }
        pasteboard.writeObjects(items)
    }

    /// NSTextView may clear its destination before writing, which would remove
    /// currentHostOnly. Stage its normal selection payload, then copy it to a
    /// freshly prepared protected pasteboard.
    static func writeSelection(
        to pasteboard: NSPasteboard,
        using write: (NSPasteboard) -> Bool
    ) -> Bool {
        let staging = NSPasteboard(name: .init("aletheia-selection-\(UUID().uuidString)"))
        defer { staging.releaseGlobally() }
        guard write(staging), let stagedItems = staging.pasteboardItems, !stagedItems.isEmpty else {
            return false
        }
        let items = stagedItems.map { staged -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for type in staged.types {
                if let data = staged.data(forType: type) { item.setData(data, forType: type) }
            }
            return item
        }
        PHIPasteboard.write(items, to: pasteboard)
        return true
    }
}
