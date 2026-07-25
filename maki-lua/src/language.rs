use tree_sitter::Language as TsLanguage;

use tree_sitter_scss::language as scss_language;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
pub enum Language {
    Bash,
    C,
    Cpp,
    CSharp,
    Dart,
    Elixir,
    Gleam,
    Go,
    Html,
    Java,
    JavaScript,
    Kotlin,
    Lua,
    Markdown,
    Nix,
    Php,
    Python,
    Ruby,
    Rust,
    Scala,
    Sql,
    Starlark,
    Swift,
    Toml,
    TypeScript,
    Yaml,
    Zig,
    Scss,
}

impl Language {
    pub fn from_name(name: &str) -> Option<Self> {
        match name {
            "rust" => Some(Self::Rust),
            "python" => Some(Self::Python),
            "typescript" => Some(Self::TypeScript),
            "javascript" => Some(Self::JavaScript),
            "gleam" => Some(Self::Gleam),
            "go" => Some(Self::Go),
            "html" => Some(Self::Html),
            "java" => Some(Self::Java),
            "c" => Some(Self::C),
            "cpp" => Some(Self::Cpp),
            "c_sharp" => Some(Self::CSharp),
            "ruby" => Some(Self::Ruby),
            "php" => Some(Self::Php),
            "swift" => Some(Self::Swift),
            "kotlin" => Some(Self::Kotlin),
            "scala" => Some(Self::Scala),
            "bash" => Some(Self::Bash),
            "lua" => Some(Self::Lua),
            "elixir" => Some(Self::Elixir),
            "markdown" => Some(Self::Markdown),
            "starlark" => Some(Self::Starlark),
            "zig" => Some(Self::Zig),
            "nix" => Some(Self::Nix),
            "dart" => Some(Self::Dart),
            "sql" => Some(Self::Sql),
            "toml" => Some(Self::Toml),
            "yaml" | "yml" => Some(Self::Yaml),
            "scss" => Some(Self::Scss),
            _ => None,
        }
    }

    pub fn ts_language(&self) -> TsLanguage {
        match self {
            Self::Rust => tree_sitter_rust::LANGUAGE.into(),
            Self::Python => tree_sitter_python::LANGUAGE.into(),
            Self::TypeScript => tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into(),
            Self::JavaScript => tree_sitter_javascript::LANGUAGE.into(),
            Self::Gleam => tree_sitter_gleam::LANGUAGE.into(),
            Self::Go => tree_sitter_go::LANGUAGE.into(),
            Self::Html => tree_sitter_html::LANGUAGE.into(),
            Self::Java => tree_sitter_java::LANGUAGE.into(),
            Self::C => tree_sitter_c::LANGUAGE.into(),
            Self::Cpp => tree_sitter_cpp::LANGUAGE.into(),
            Self::CSharp => tree_sitter_c_sharp::LANGUAGE.into(),
            Self::Ruby => tree_sitter_ruby::LANGUAGE.into(),
            Self::Php => tree_sitter_php::LANGUAGE_PHP.into(),
            Self::Swift => tree_sitter_swift::LANGUAGE.into(),
            Self::Kotlin => tree_sitter_kotlin_ng::LANGUAGE.into(),
            Self::Scala => tree_sitter_scala::LANGUAGE.into(),
            Self::Bash => tree_sitter_bash::LANGUAGE.into(),
            Self::Lua => tree_sitter_lua::LANGUAGE.into(),
            Self::Elixir => tree_sitter_elixir::LANGUAGE.into(),
            Self::Markdown => tree_sitter_md::LANGUAGE.into(),
            Self::Starlark => tree_sitter_starlark::LANGUAGE.into(),
            Self::Zig => tree_sitter_zig::LANGUAGE.into(),
            Self::Nix => tree_sitter_nix::LANGUAGE.into(),
            Self::Dart => tree_sitter_dart::LANGUAGE.into(),
            Self::Sql => tree_sitter_sequel::LANGUAGE.into(),
            Self::Toml => tree_sitter_toml_ng::LANGUAGE.into(),
            Self::Yaml => tree_sitter_yaml::LANGUAGE.into(),
            Self::Scss => scss_language(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::Language;

    #[test]
    fn scss_loads_tree_sitter_grammar() {
        let mut parser = tree_sitter::Parser::new();
        parser
            .set_language(&Language::Scss.ts_language())
            .expect("SCSS grammar should load");
        let tree = parser
            .parse(".foo { color: red; }", None)
            .expect("SCSS source should parse");

        let syntax = tree.root_node().to_sexp();
        assert!(
            syntax.contains("rule_set"),
            "unexpected syntax tree: {syntax}"
        );
    }

    #[test]
    fn existing_html_grammar_still_parses_elements() {
        let mut parser = tree_sitter::Parser::new();
        parser
            .set_language(&Language::Html.ts_language())
            .expect("HTML grammar should load");
        let tree = parser
            .parse("<main><div>text</div></main>", None)
            .expect("HTML source should parse");

        let syntax = tree.root_node().to_sexp();
        assert!(
            syntax.contains("element"),
            "unexpected syntax tree: {syntax}"
        );
    }
}
