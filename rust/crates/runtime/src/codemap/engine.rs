use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};

use tree_sitter::{Language, Parser, Query, QueryCursor, StreamingIterator};

use super::CodeMapError;
use super::contract::CodeMapLanguage;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Capture {
    pub name: String,
    pub start_byte: usize,
    pub end_byte: usize,
    pub start_row: usize,
    pub end_row: usize,
}

#[derive(Clone, Copy)]
pub struct LanguageDescriptor {
    pub language: CodeMapLanguage,
    pub grammar_revision: &'static str,
    pub query: &'static str,
}

impl LanguageDescriptor {
    pub fn tree_sitter_language(self) -> Language {
        match self.language {
            CodeMapLanguage::Swift => tree_sitter_swift::LANGUAGE.into(),
            CodeMapLanguage::JavaScript => tree_sitter_javascript::LANGUAGE.into(),
            CodeMapLanguage::CSharp => tree_sitter_c_sharp::LANGUAGE.into(),
            CodeMapLanguage::Python => tree_sitter_python::LANGUAGE.into(),
            CodeMapLanguage::C => tree_sitter_c::LANGUAGE.into(),
            CodeMapLanguage::Rust => tree_sitter_rust::LANGUAGE.into(),
            CodeMapLanguage::Cpp => tree_sitter_cpp::LANGUAGE.into(),
            CodeMapLanguage::Go => tree_sitter_go::LANGUAGE.into(),
            CodeMapLanguage::Java => tree_sitter_java::LANGUAGE.into(),
            CodeMapLanguage::TypeScript => tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into(),
            CodeMapLanguage::Tsx => tree_sitter_typescript::LANGUAGE_TSX.into(),
            CodeMapLanguage::Php => tree_sitter_php::LANGUAGE_PHP.into(),
            CodeMapLanguage::Ruby => tree_sitter_ruby::LANGUAGE.into(),
        }
    }
}

pub fn descriptor(language: CodeMapLanguage) -> LanguageDescriptor {
    let (revision, query) = match language {
        CodeMapLanguage::Swift => (
            "31d17fe7e818a2048c808b5c6fdc2dc792f4f5b5",
            include_str!("queries/swift.scm"),
        ),
        CodeMapLanguage::JavaScript => (
            "44c892e0be055ac465d5eeddae6d3e194424e7de",
            include_str!("queries/javascript.scm"),
        ),
        CodeMapLanguage::CSharp => (
            "cac6d5fb595f5811a076336682d5d595ac1c9e85",
            include_str!("queries/c_sharp.scm"),
        ),
        CodeMapLanguage::Python => (
            "293fdc02038ee2bf0e2e206711b69c90ac0d413f",
            include_str!("queries/python.scm"),
        ),
        CodeMapLanguage::C => (
            "b780e47fc780ddc8da13afa35a3f4ed5c157823d",
            include_str!("queries/c.scm"),
        ),
        CodeMapLanguage::Rust => (
            "77a3747266f4d621d0757825e6b11edcbf991ca5",
            include_str!("queries/rust.scm"),
        ),
        CodeMapLanguage::Cpp => (
            "f41e1a044c8a84ea9fa8577fdd2eab92ec96de02",
            include_str!("queries/cpp.scm"),
        ),
        CodeMapLanguage::Go => (
            "1547678a9da59885853f5f5cc8a99cc203fa2e2c",
            include_str!("queries/go.scm"),
        ),
        CodeMapLanguage::Java => (
            "94703d5a6bed02b98e438d7cad1136c01a60ba2c",
            include_str!("queries/java.scm"),
        ),
        CodeMapLanguage::TypeScript => (
            "f975a621f4e7f532fe322e13c4f79495e0a7b2e7",
            include_str!("queries/typescript.scm"),
        ),
        CodeMapLanguage::Tsx => (
            "f975a621f4e7f532fe322e13c4f79495e0a7b2e7",
            include_str!("queries/tsx.scm"),
        ),
        CodeMapLanguage::Php => (
            "5b5627faaa290d89eb3d01b9bf47c3bb9e797dea",
            include_str!("queries/php.scm"),
        ),
        CodeMapLanguage::Ruby => (
            "71bd32fb7607035768799732addba884a37a6210",
            include_str!("queries/ruby.scm"),
        ),
    };
    LanguageDescriptor {
        language,
        grammar_revision: revision,
        query,
    }
}

static QUERY_CACHE: OnceLock<Mutex<HashMap<CodeMapLanguage, Arc<Query>>>> = OnceLock::new();

fn cached_query(
    descriptor: LanguageDescriptor,
    grammar: &Language,
) -> Result<Arc<Query>, CodeMapError> {
    let cache = QUERY_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    let mut values = cache
        .lock()
        .map_err(|_| CodeMapError::Internal("query cache poisoned".to_owned()))?;
    if let Some(query) = values.get(&descriptor.language) {
        return Ok(Arc::clone(query));
    }
    let query =
        Arc::new(Query::new(grammar, descriptor.query).map_err(|error| {
            CodeMapError::Query(format!("{} query: {error}", descriptor.language))
        })?);
    values.insert(descriptor.language, Arc::clone(&query));
    Ok(query)
}

pub fn parse_captures(
    language: CodeMapLanguage,
    source: &str,
) -> Result<Vec<Capture>, CodeMapError> {
    let descriptor = descriptor(language);
    let grammar = descriptor.tree_sitter_language();
    let mut parser = Parser::new();
    parser
        .set_language(&grammar)
        .map_err(|error| CodeMapError::Parser(format!("{language}: {error}")))?;
    let tree = parser
        .parse(source, None)
        .ok_or(CodeMapError::ParserReturnedNilTree)?;
    let root = tree.root_node();
    let query = cached_query(descriptor, &grammar)?;
    let capture_names = query.capture_names();
    let mut cursor = QueryCursor::new();
    let mut matches = cursor.matches(&query, root, source.as_bytes());
    let mut captures = Vec::new();
    while let Some(query_match) = matches.next() {
        for capture in query_match.captures {
            let node = capture.node;
            captures.push(Capture {
                name: capture_names[capture.index as usize].to_owned(),
                start_byte: node.start_byte(),
                end_byte: node.end_byte(),
                start_row: node.start_position().row,
                end_row: node.end_position().row,
            });
        }
    }
    captures.sort_by(|left, right| {
        (left.start_byte, left.end_byte, &left.name).cmp(&(
            right.start_byte,
            right.end_byte,
            &right.name,
        ))
    });
    Ok(captures)
}
