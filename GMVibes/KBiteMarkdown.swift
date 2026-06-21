import Foundation

enum KBitePreview {
    case markdown(AttributedString)
    case text(String)
    case unavailable(String)
}

enum KBiteMarkdown {
    static let maxBytes = 512 * 1024

    static func preview(for url: URL) -> KBitePreview {
        let fm = FileManager.default
        let attrs = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
        if let size = attrs[.size] as? NSNumber, size.intValue > maxBytes {
            return .unavailable("Preview unavailable (file is \(size.intValue / 1024) KB; cap is \(maxBytes / 1024) KB).")
        }

        guard let data = try? Data(contentsOf: url) else {
            return .unavailable("Could not read file.")
        }

        guard let text = String(data: data, encoding: .utf8) else {
            return .unavailable("Preview unavailable (binary or non-UTF8 file).")
        }

        if url.pathExtension.lowercased() == "md" {
            let options = AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
            if let attributed = try? AttributedString(markdown: text, options: options) {
                return .markdown(attributed)
            }
        }

        return .text(text)
    }
}
