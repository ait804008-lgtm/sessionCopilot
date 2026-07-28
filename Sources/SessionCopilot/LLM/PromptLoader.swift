import Foundation

/// Loads and caches markdown prompt templates, substituting template variables.
public final class PromptLoader {
    private var cache: [String: String] = [:]
    private let bundle: Bundle

    public init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    /// Load a prompt by relative path (e.g. "behavioral/answer_outline").
    /// Searches bundle resources and filesystem prompts/ directory.
    public func load(_ name: String) throws -> String {
        if let cached = cache[name] { return cached }

        // Try bundle first, then filesystem
        let content: String
        if let url = bundle.url(forResource: name, withExtension: "md") {
            content = try String(contentsOf: url, encoding: .utf8)
        } else {
            // Try relative to executable
            let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let promptURL = cwd.appendingPathComponent("prompts/\(name).md")
            content = try String(contentsOf: promptURL, encoding: .utf8)
        }

        cache[name] = content
        return content
    }

    /// Substitute template variables of form {{variable}}.
    public func render(_ template: String, variables: [String: String]) -> String {
        var result = template
        for (key, value) in variables {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return result
    }

    /// Load and render in one call.
    public func loadAndRender(_ name: String, variables: [String: String]) throws -> String {
        let template = try load(name)
        return render(template, variables: variables)
    }
}
