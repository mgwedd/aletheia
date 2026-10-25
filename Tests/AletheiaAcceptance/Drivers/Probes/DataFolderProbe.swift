@testable import Aletheia
import Foundation

/// Read-only view of what is on disk under the throwaway data folder.
struct DataFolderProbe {
    let root: URL

    /// Paths of every file under `folder` (default: the whole data folder),
    /// relative to the data folder, sorted.
    func files(under folder: URL? = nil) -> [String] {
        let base = (folder ?? root).standardizedFileURL
        guard let walker = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        let prefix = root.standardizedFileURL.path + "/"
        return walker.compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map { $0.standardizedFileURL.path.replacingOccurrences(of: prefix, with: "") }
            .sorted()
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Whether any file under the data folder holds `text` in the clear.
    func containsPlaintext(_ text: String) -> Bool {
        let needle = Data(text.utf8)
        return files().contains { path in
            (try? Data(contentsOf: root.appendingPathComponent(path)))?.range(of: needle) != nil
        }
    }
}
