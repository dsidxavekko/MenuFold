import Foundation

/// A coarse file type a query can ask for with `kind:` ("~kind:pdf report"). Pure: decided by the
/// path extension alone, so it needs no disk access and no UTI database.
public enum FileKind: String, CaseIterable, Sendable {
    case pdf, image, doc, sheet, slides, text, audio, video, archive, code

    /// Lowercased extensions (no dot) that belong to the kind.
    public var extensions: Set<String> {
        switch self {
        case .pdf: ["pdf"]
        case .image: ["png", "jpg", "jpeg", "gif", "heic", "heif", "tiff", "tif", "bmp", "webp", "svg", "raw", "dng", "psd", "ico"]
        case .doc: ["doc", "docx", "dot", "dotx", "pages", "odt", "rtf", "rtfd"]
        case .sheet: ["xls", "xlsx", "xlsm", "numbers", "ods", "csv", "tsv"]
        case .slides: ["ppt", "pptx", "pps", "ppsx", "key", "odp"]
        case .text: ["txt", "md", "markdown", "log", "rtf", "text"]
        case .audio: ["mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "ogg", "opus", "caf"]
        case .video: ["mp4", "mov", "m4v", "avi", "mkv", "webm", "mpg", "mpeg"]
        case .archive: ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "dmg", "iso"]
        case .code: ["swift", "m", "mm", "h", "c", "cc", "cpp", "hpp", "rs", "go", "py", "rb", "js", "jsx", "ts", "tsx",
                     "java", "kt", "cs", "php", "sh", "zsh", "json", "yaml", "yml", "toml", "xml", "html", "css", "sql"]
        }
    }

    /// Kind named by `name` (case-insensitive), nil for an unknown word.
    public init?(name: String) {
        self.init(rawValue: name.lowercased())
    }

    /// Whether `url` has an extension of this kind.
    public func matches(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }
}
