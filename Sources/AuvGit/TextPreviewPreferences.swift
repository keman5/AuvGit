import Foundation
import Darwin

enum TextPreviewPreferences {
    static let key = "preview.forcedTextFormats"
    // Include source, scripts, markup, configuration, and extensionless project files.
    static let defaultFormats = """
    txt text log md markdown mdx rst adoc org tex bib
    swift m mm h c cc cpp cxx hpp hxx cs fs fsx vb
    js jsx mjs cjs ts tsx mts cts vue svelte astro
    py pyw pyi rb rake gemspec go rs java kt kts scala sc
    dart php phtml pl pm r R lua ex exs erl hrl clj cljs cljc edn
    sh bash zsh fish ps1 psm1 bat cmd sql graphql gql proto
    html htm xhtml xml xsd xsl xslt svg css scss sass less
    json jsonc json5 jsonl ndjson yaml yml toml ini cfg conf config
    env properties strings stringsdict plist entitlements xcconfig
    csv tsv lock diff patch gitignore gitattributes gitmodules editorconfig
    dockerfile containerfile makefile cmake gradle podspec
    Dockerfile Containerfile Makefile GNUmakefile Gemfile Rakefile
    Podfile Fastfile Appfile Brewfile Procfile Vagrantfile Jenkinsfile
    LICENSE LICENCE NOTICE AUTHORS CONTRIBUTORS CHANGELOG README
    .gitignore .gitattributes .gitmodules .editorconfig .npmrc .yarnrc
    .env .env.* .bashrc .zshrc .bash_profile .zprofile .gitconfig
    """

    static func formats(defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: key) ?? defaultFormats
    }

    static func matches(_ url: URL, formats: String) -> Bool {
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;，；"))
        return formats.components(separatedBy: separators).contains { entry in
            let rule = entry.lowercased()
            guard !rule.isEmpty, !rule.contains("/"), !rule.contains("\\") else { return false }
            if rule.contains("*") || rule.contains("?") {
                return name.withCString { file in rule.withCString { fnmatch($0, file, 0) == 0 } }
            }
            return rule == name || (!ext.isEmpty && (rule == ext || rule == "." + ext))
        }
    }
}
