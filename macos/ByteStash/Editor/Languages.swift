import Foundation

/// The language ids ByteStash stores (same list as the web client) and how they map to
/// highlight.js grammars used by Highlightr.
enum Languages {
    static let all: [String] = [
        "plaintext", "abap", "apex", "bash", "batch", "c", "conf", "cpp", "csharp", "css", "cypher",
        "dart", "dockerfile", "elm", "go", "graphql", "groovy", "html", "ini", "java", "javascript",
        "json", "julia", "kotlin", "kubernetes", "latex", "lua", "markdown", "matlab", "mongodb",
        "perl", "php", "powershell", "python", "r", "ruby", "rust", "scala", "solidity", "sql",
        "swift", "systemverilog", "terraform", "toml", "typescript", "vba", "verilog", "vimscript",
        "vyper", "webassembly", "xml", "yaml",
    ]

    private static let highlightNames: [String: String] = [
        "html": "xml",
        "webassembly": "wasm",
        "vba": "vbnet",
        "batch": "dos",
        "mongodb": "javascript",
        "conf": "nginx",
        "vimscript": "vim",
        "kubernetes": "yaml",
        "apex": "java",
        "systemverilog": "verilog",
        "toml": "ini",
        "terraform": "ini",
        "solidity": "javascript",
        "vyper": "python",
        "cypher": "sql",
    ]

    private static let aliases: [String: String] = [
        "js": "javascript", "jsx": "javascript", "node": "javascript",
        "ts": "typescript", "tsx": "typescript",
        "py": "python", "rb": "ruby", "rs": "rust", "golang": "go",
        "sh": "bash", "shell": "bash", "zsh": "bash",
        "ps": "powershell", "ps1": "powershell",
        "yml": "yaml", "md": "markdown", "c#": "csharp", "cs": "csharp", "c++": "cpp",
        "kt": "kotlin", "docker": "dockerfile", "tf": "terraform", "txt": "plaintext", "text": "plaintext",
        "objc": "plaintext", "vim": "vimscript", "k8s": "kubernetes",
    ]

    private static let extensions: [String: String] = [
        "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascript",
        "ts": "typescript", "tsx": "typescript", "py": "python", "rb": "ruby", "rs": "rust",
        "go": "go", "java": "java", "kt": "kotlin", "swift": "swift", "c": "c", "h": "c",
        "cpp": "cpp", "cc": "cpp", "hpp": "cpp", "cs": "csharp", "php": "php", "sh": "bash",
        "bash": "bash", "zsh": "bash", "ps1": "powershell", "bat": "batch", "cmd": "batch",
        "sql": "sql", "md": "markdown", "yml": "yaml", "yaml": "yaml", "json": "json", "xml": "xml",
        "html": "html", "htm": "html", "css": "css", "scss": "css", "toml": "toml", "ini": "ini",
        "conf": "conf", "lua": "lua", "pl": "perl", "r": "r", "dart": "dart", "scala": "scala",
        "groovy": "groovy", "tf": "terraform", "graphql": "graphql", "gql": "graphql", "tex": "latex",
        "jl": "julia", "vim": "vimscript", "sol": "solidity", "vy": "vyper", "elm": "elm",
    ]

    static func canonical(_ name: String) -> String {
        let lower = name.lowercased()
        if all.contains(lower) { return lower }
        return aliases[lower] ?? lower
    }

    /// Guess a language from a file name such as "deploy.sh" or "Dockerfile".
    static func guess(fileName: String) -> String? {
        let lower = fileName.lowercased()
        if lower == "dockerfile" || lower.hasPrefix("dockerfile.") { return "dockerfile" }
        guard let dot = lower.lastIndex(of: "."), dot != lower.startIndex else { return nil }
        return extensions[String(lower[lower.index(after: dot)...])]
    }

    static func highlightName(for language: String) -> String? {
        let canonical = canonical(language)
        if canonical == "plaintext" { return nil }
        return highlightNames[canonical] ?? canonical
    }

    static func displayName(for language: String) -> String {
        switch language {
        case "plaintext": return "Plain Text"
        case "javascript": return "JavaScript"
        case "typescript": return "TypeScript"
        case "csharp": return "C#"
        case "cpp": return "C++"
        case "php": return "PHP"
        case "sql": return "SQL"
        case "html": return "HTML"
        case "css": return "CSS"
        case "json": return "JSON"
        case "xml": return "XML"
        case "yaml": return "YAML"
        case "toml": return "TOML"
        case "ini": return "INI"
        case "vba": return "VBA"
        case "graphql": return "GraphQL"
        case "mongodb": return "MongoDB"
        case "powershell": return "PowerShell"
        case "webassembly": return "WebAssembly"
        case "systemverilog": return "SystemVerilog"
        case "latex": return "LaTeX"
        case "matlab": return "MATLAB"
        case "abap": return "ABAP"
        case "r": return "R"
        default: return language.prefix(1).uppercased() + language.dropFirst()
        }
    }
}
