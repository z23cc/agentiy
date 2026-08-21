use tree_sitter::{Language, Parser, Query, QueryCursor, StreamingIterator};

pub fn parse_and_query(language: Language, source: &str) -> Result<usize, String> {
    let mut parser = Parser::new();
    parser
        .set_language(&language)
        .map_err(|error| format!("set language: {error}"))?;
    let tree = parser
        .parse(source, None)
        .ok_or_else(|| "parser returned no tree".to_owned())?;
    if tree.root_node().has_error() {
        return Err(format!("parse error: {}", tree.root_node().to_sexp()));
    }

    let query =
        Query::new(&language, "(_) @node").map_err(|error| format!("compile query: {error}"))?;
    let mut cursor = QueryCursor::new();
    let mut matches = cursor.matches(&query, tree.root_node(), source.as_bytes());
    let mut count = 0;
    while matches.next().is_some() {
        count += 1;
    }
    if count == 0 {
        return Err("query returned no matches".to_owned());
    }
    Ok(count)
}

#[no_mangle]
pub extern "C" fn agentry_treesitter_spike_language_abi_sum() -> usize {
    let languages: [Language; 13] = [
        tree_sitter_swift::LANGUAGE.into(),
        tree_sitter_javascript::LANGUAGE.into(),
        tree_sitter_c_sharp::LANGUAGE.into(),
        tree_sitter_python::LANGUAGE.into(),
        tree_sitter_c::LANGUAGE.into(),
        tree_sitter_rust::LANGUAGE.into(),
        tree_sitter_cpp::LANGUAGE.into(),
        tree_sitter_go::LANGUAGE.into(),
        tree_sitter_java::LANGUAGE.into(),
        tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into(),
        tree_sitter_typescript::LANGUAGE_TSX.into(),
        tree_sitter_php::LANGUAGE_PHP.into(),
        tree_sitter_ruby::LANGUAGE.into(),
    ];
    languages.iter().map(Language::abi_version).sum()
}

#[cfg(test)]
mod tests {
    use super::parse_and_query;
    use tree_sitter::Language;

    fn smoke(name: &str, language: Language, source: &str) {
        let count = parse_and_query(language, source)
            .unwrap_or_else(|error| panic!("{name} parse/query smoke failed: {error}"));
        assert!(count > 1, "{name} query returned too few matches");
    }

    #[test]
    fn all_thirteen_languages_parse_and_query_real_samples() {
        smoke(
            "Swift",
            tree_sitter_swift::LANGUAGE.into(),
            "struct Greeter { let name: String; func greet() -> String { name } }\n",
        );
        smoke(
            "JavaScript",
            tree_sitter_javascript::LANGUAGE.into(),
            "export function greet(name) { return `Hello ${name}`; }\n",
        );
        smoke(
            "C#",
            tree_sitter_c_sharp::LANGUAGE.into(),
            "class Greeter { string Greet(string name) => $\"Hello {name}\"; }\n",
        );
        smoke(
            "Python",
            tree_sitter_python::LANGUAGE.into(),
            "def greet(name):\n    values = [name]\n    return values[0]\n",
        );
        smoke(
            "C",
            tree_sitter_c::LANGUAGE.into(),
            "static int add(int left, int right) { return left + right; }\n",
        );
        smoke(
            "Rust",
            tree_sitter_rust::LANGUAGE.into(),
            "fn greet(name: &str) -> String { format!(\"Hello {name}\") }\n",
        );
        smoke(
            "C++",
            tree_sitter_cpp::LANGUAGE.into(),
            "template <typename T> T add(T left, T right) { return left + right; }\n",
        );
        smoke(
            "Go",
            tree_sitter_go::LANGUAGE.into(),
            "package sample\nfunc greet(name string) string { return \"Hello \" + name }\n",
        );
        smoke(
            "Java",
            tree_sitter_java::LANGUAGE.into(),
            "class Greeter { String greet(String name) { return \"Hello \" + name; } }\n",
        );
        smoke(
            "TypeScript",
            tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into(),
            "export function greet(name: string): string { return `Hello ${name}`; }\n",
        );
        smoke(
            "TSX",
            tree_sitter_typescript::LANGUAGE_TSX.into(),
            "type Props = { name: string }; const Card = ({ name }: Props) => <div>{name}</div>;\n",
        );
        smoke(
            "PHP",
            tree_sitter_php::LANGUAGE_PHP.into(),
            "<?php function greet(string $name): string { return \"Hello $name\"; } ?>\n",
        );
        smoke(
            "Ruby",
            tree_sitter_ruby::LANGUAGE.into(),
            "class Greeter\n  def greet(name)\n    \"Hello #{name}\"\n  end\nend\n",
        );
    }
}
