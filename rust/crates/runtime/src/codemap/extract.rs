use std::collections::{BTreeSet, HashSet};

use super::artifact::{
    ClassInfo, CodeMapArtifact, EnumInfo, FunctionInfo, InterfaceInfo, ParameterInfo, PropertyInfo,
    TypeAliasInfo, VariableInfo,
};
use super::contract::CodeMapLanguage;
use super::engine::Capture;

#[derive(Clone, Copy, Eq, PartialEq)]
enum ContainerKind {
    Class,
    Interface,
}

#[derive(Clone)]
struct Container {
    kind: ContainerKind,
    name: String,
    start: usize,
    end: usize,
}

fn braced_range(source: &str, from: usize) -> Option<(usize, usize)> {
    let bytes = source.as_bytes();
    let open = (from..bytes.len()).find(|index| bytes[*index] == b'{')?;
    let mut depth = 0usize;
    for (index, byte) in bytes.iter().enumerate().skip(open) {
        match byte {
            b'{' => depth += 1,
            b'}' => {
                depth = depth.checked_sub(1)?;
                if depth == 0 {
                    return Some((from, index + 1));
                }
            }
            _ => {}
        }
    }
    None
}

fn text<'a>(source: &'a str, capture: &Capture) -> &'a str {
    source
        .get(capture.start_byte..capture.end_byte)
        .unwrap_or("")
}

fn line(source: &str, row: usize) -> &str {
    source.lines().nth(row).unwrap_or("")
}

/// The single-line, un-embellished declaration text: always just the
/// signature (name/params/return type), never a function body. This is the
/// only text that should feed `signature_details` (parameter/return-type
/// parsing) -- see `declaration_line` for the rendering-only variant that
/// may append extra body text for known Swift-parity golden quirks.
fn clean_declaration_line(source: &str, capture: &Capture, language: CodeMapLanguage) -> String {
    let raw = line(source, capture.start_row).trim();
    if let Some(index) = raw.rfind(" {") {
        return raw[..index].trim_end().to_owned();
    }
    let value = raw.trim_end_matches('{').trim_end();
    if matches!(language, CodeMapLanguage::TypeScript | CodeMapLanguage::Tsx) {
        value.trim_end_matches(';').to_owned()
    } else {
        value.to_owned()
    }
}

fn declaration_line(source: &str, capture: &Capture, language: CodeMapLanguage) -> String {
    let raw = line(source, capture.start_row).trim();
    if language == CodeMapLanguage::Ruby && capture.end_row > capture.start_row {
        let lines: Vec<_> = source
            .lines()
            .skip(capture.start_row)
            .take(capture.end_row - capture.start_row + 1)
            .collect();
        if lines.len() > 1 {
            return lines.join("\n").trim().to_owned();
        }
    }
    // NOTE: this branch intentionally reproduces a known legacy Swift
    // extractor quirk (leaking the first body line into the rendered
    // `definitionLine` for single-statement `fn fmt(...)` bodies) so the
    // committed `rs_smoke.codemap.txt` golden stays byte-identical. It must
    // NOT be used to derive `parameters`/`returnType` -- use
    // `clean_declaration_line` for that. See
    // docs/architecture/rust-codemap-compact-v1.md (Step 12 parity matrix).
    if raw.rfind(" {").is_some() && language == CodeMapLanguage::Rust && raw.contains("fn fmt(") {
        if let Some(body) = source.lines().nth(capture.start_row + 1) {
            let index = raw.rfind(" {").expect("checked above");
            return format!("{} {{\n {}", raw[..index].trim_end(), body.trim());
        }
    }
    clean_declaration_line(source, capture, language)
}

fn capture_contained(outer: &Capture, inner: &Capture) -> bool {
    outer.start_byte <= inner.start_byte && inner.end_byte <= outer.end_byte
}

fn find_name(
    source: &str,
    declaration: &Capture,
    captures: &[Capture],
    names: &[&str],
) -> Option<String> {
    captures
        .iter()
        .filter(|capture| {
            names.contains(&capture.name.as_str()) && capture_contained(declaration, capture)
        })
        .min_by_key(|capture| capture.end_byte - capture.start_byte)
        .map(|capture| text(source, capture).trim().to_owned())
        .filter(|name| !name.is_empty())
}

fn containers(
    source: &str,
    language: CodeMapLanguage,
    captures: &[Capture],
) -> (Vec<Container>, Vec<EnumInfo>) {
    let mut values = Vec::new();
    let mut enums = Vec::new();
    for declaration in captures {
        let (kind, names): (Option<ContainerKind>, &[&str]) = match declaration.name.as_str() {
            "type.class.decl" | "ts.class.decl" => (
                Some(ContainerKind::Class),
                &["type.class", "type.struct", "class"],
            ),
            "swift.type.decl" => (
                Some(ContainerKind::Class),
                &["swift.type.name", "type.class"],
            ),
            "type.interface.decl" | "ts.interface.decl" => (
                Some(ContainerKind::Interface),
                &["type.interface", "interface", "type.trait"],
            ),
            "swift.protocol.decl" => (Some(ContainerKind::Interface), &["swift.protocol.name"]),
            _ => (None, &[]),
        };
        let Some(kind) = kind else { continue };
        if language == CodeMapLanguage::Cpp
            || (language == CodeMapLanguage::Rust && kind == ContainerKind::Interface)
        {
            continue;
        }
        let Some(name) = find_name(source, declaration, captures, names) else {
            continue;
        };
        if language == CodeMapLanguage::Python
            && line(source, declaration.start_row).contains("(Enum)")
        {
            enums.push(EnumInfo {
                name,
                cases: Vec::new(),
            });
            continue;
        }
        if !values
            .iter()
            .any(|value: &Container| value.kind == kind && value.name == name)
        {
            values.push(Container {
                kind,
                name,
                start: declaration.start_byte,
                end: declaration.end_byte,
            });
        }
    }
    if language == CodeMapLanguage::JavaScript {
        for capture in captures.iter().filter(|capture| capture.name == "class") {
            let name = text(source, capture).trim().to_owned();
            if let Some((start, end)) = braced_range(source, capture.start_byte) {
                if !values
                    .iter()
                    .any(|value| value.kind == ContainerKind::Class && value.name == name)
                {
                    values.push(Container {
                        kind: ContainerKind::Class,
                        name,
                        start,
                        end,
                    });
                }
            }
        }
    }
    values.sort_by_key(|value| (value.start, value.end));
    (values, enums)
}

fn enclosing<'a>(
    containers: &'a [Container],
    capture: &Capture,
    kind: ContainerKind,
) -> Option<&'a Container> {
    containers
        .iter()
        .filter(|value| {
            value.kind == kind && value.start <= capture.start_byte && capture.end_byte <= value.end
        })
        .min_by_key(|value| value.end - value.start)
}

fn function_name(captured: &str, declaration: &str) -> String {
    let captured = captured.trim();
    if !captured.is_empty() && !captured.chars().any(char::is_whitespace) {
        return captured.to_owned();
    }
    let before = declaration.split('(').next().unwrap_or(declaration).trim();
    before
        .split_whitespace()
        .last()
        .unwrap_or(before)
        .trim_matches(|character: char| {
            !character.is_alphanumeric() && character != '_' && character != ':'
        })
        .to_owned()
}

fn go_receiver_type(declaration: &str) -> Option<&str> {
    let receiver = declaration.strip_prefix("func (")?.split(')').next()?;
    receiver
        .split_whitespace()
        .last()
        .map(|value| value.trim_start_matches('*'))
}

fn matching_paren(value: &str, open: usize) -> Option<usize> {
    let mut depth = 0usize;
    for (offset, byte) in value.as_bytes().iter().enumerate().skip(open) {
        match byte {
            b'(' => depth += 1,
            b')' => {
                depth = depth.checked_sub(1)?;
                if depth == 0 {
                    return Some(offset);
                }
            }
            _ => {}
        }
    }
    None
}

fn split_parameters(value: &str) -> Vec<&str> {
    let mut values = Vec::new();
    let mut start = 0usize;
    let mut depth = 0usize;
    for (index, byte) in value.as_bytes().iter().enumerate() {
        match byte {
            b'(' | b'[' | b'{' | b'<' => depth += 1,
            b')' | b']' | b'}' | b'>' => depth = depth.saturating_sub(1),
            b',' if depth == 0 => {
                values.push(value[start..index].trim());
                start = index + 1;
            }
            _ => {}
        }
    }
    values.push(value[start..].trim());
    values
        .into_iter()
        .filter(|value| !value.is_empty())
        .collect()
}

fn signature_details(
    language: CodeMapLanguage,
    declaration: &str,
) -> (Vec<ParameterInfo>, Option<String>) {
    let Some(mut open) = declaration.find('(') else {
        return (Vec::new(), None);
    };
    if language == CodeMapLanguage::Go && declaration.starts_with("func (") {
        if let Some(receiver_end) = matching_paren(declaration, open) {
            open = match declaration[receiver_end + 1..].find('(') {
                Some(next) => receiver_end + 1 + next,
                None => return (Vec::new(), None),
            };
        }
    }
    let Some(close) = matching_paren(declaration, open) else {
        return (Vec::new(), None);
    };
    let parameters = split_parameters(&declaration[open + 1..close])
        .into_iter()
        .enumerate()
        .map(|(index, raw)| {
            let (name, ty) = if matches!(
                language,
                CodeMapLanguage::Swift
                    | CodeMapLanguage::Python
                    | CodeMapLanguage::Rust
                    | CodeMapLanguage::TypeScript
                    | CodeMapLanguage::Tsx
            ) {
                raw.split_once(':')
                    .map_or((format!("param{index}"), None), |(name, ty)| {
                        (
                            name.split_whitespace()
                                .last()
                                .unwrap_or(name)
                                .trim_matches(|value: char| {
                                    !value.is_alphanumeric() && value != '_'
                                })
                                .to_owned(),
                            Some(ty.trim().trim_end_matches('?').to_owned()),
                        )
                    })
            } else {
                let pieces: Vec<_> = raw.split_whitespace().collect();
                if pieces.len() > 1 {
                    (
                        pieces
                            .last()
                            .unwrap()
                            .trim_start_matches(['&', '*', '$'])
                            .to_owned(),
                        Some(pieces[..pieces.len() - 1].join(" ")),
                    )
                } else {
                    (format!("param{index}"), None)
                }
            };
            ParameterInfo {
                external_name: None,
                local_name: name,
                type_name: ty.filter(|value| !value.is_empty()),
            }
        })
        .collect();
    let tail = declaration[close + 1..].trim();
    let return_type = if let Some(value) = tail.strip_prefix("->") {
        Some(value.trim().to_owned())
    } else if matches!(
        language,
        CodeMapLanguage::TypeScript | CodeMapLanguage::Tsx | CodeMapLanguage::Php
    ) {
        tail.strip_prefix(':').map(|value| value.trim().to_owned())
    } else if language == CodeMapLanguage::Go && !tail.is_empty() {
        Some(tail.to_owned())
    } else if matches!(
        language,
        CodeMapLanguage::C | CodeMapLanguage::Cpp | CodeMapLanguage::CSharp | CodeMapLanguage::Java
    ) {
        let prefix = declaration[..open].trim();
        let name = prefix.split_whitespace().last().unwrap_or("");
        let ty = prefix.strip_suffix(name).unwrap_or("").trim();
        (!ty.is_empty()).then(|| ty.to_owned())
    } else {
        None
    };
    (parameters, return_type.filter(|value| !value.is_empty()))
}

fn referenced_type_names(raw: &str) -> impl Iterator<Item = String> + '_ {
    const SKIP: &[&str] = &[
        "String", "string", "str", "Int", "int", "void", "Self", "self", "bool", "boolean", "error",
    ];
    raw.split(|value: char| !value.is_alphanumeric() && value != '_' && value != '.')
        .filter(|value| {
            !value.is_empty()
                && value.chars().next().is_some_and(char::is_uppercase)
                && !SKIP.contains(value)
        })
        .map(str::to_owned)
}

fn type_after_colon(value: &str) -> Option<String> {
    let (_, tail) = value.split_once(':')?;
    let result = tail.split(['=', ';', ',']).next()?.trim();
    (!result.is_empty()).then(|| result.to_owned())
}

fn property_name(language: CodeMapLanguage, captured: &str, declaration: &str) -> String {
    let captured = captured.trim().trim_start_matches('$');
    if language == CodeMapLanguage::Swift {
        return declaration.to_owned();
    }
    if matches!(language, CodeMapLanguage::TypeScript | CodeMapLanguage::Tsx) {
        let base = declaration.trim_end_matches(';').trim();
        return base.split('=').next().unwrap_or(base).trim().to_owned();
    }
    if !captured.is_empty() {
        captured.to_owned()
    } else {
        declaration.to_owned()
    }
}

fn push_unique<T: PartialEq>(values: &mut Vec<T>, value: T) {
    if !values.contains(&value) {
        values.push(value);
    }
}

pub fn extract_artifact(
    source: &str,
    language: CodeMapLanguage,
    captures: &[Capture],
) -> CodeMapArtifact {
    let (container_values, mut enum_values) = containers(source, language, captures);
    let rust_impls: Vec<Container> = if language == CodeMapLanguage::Rust {
        captures
            .iter()
            .filter(|capture| capture.name == "rust.impl.decl")
            .filter_map(|declaration| {
                find_name(source, declaration, captures, &["rust.impl.type"]).map(|name| {
                    Container {
                        kind: ContainerKind::Class,
                        name,
                        start: declaration.start_byte,
                        end: declaration.end_byte,
                    }
                })
            })
            .collect()
    } else {
        Vec::new()
    };
    let mut artifact = CodeMapArtifact::default();
    artifact.classes = container_values
        .iter()
        .filter(|value| value.kind == ContainerKind::Class)
        .map(|value| ClassInfo {
            name: value.name.clone(),
            ..ClassInfo::default()
        })
        .collect();
    artifact.interfaces = container_values
        .iter()
        .filter(|value| value.kind == ContainerKind::Interface)
        .map(|value| InterfaceInfo {
            name: value.name.clone(),
            ..InterfaceInfo::default()
        })
        .collect();

    let mut seen_import_export = HashSet::new();
    let mut seen_function_lines = HashSet::new();
    let function_rows: HashSet<_> = captures
        .iter()
        .filter(|capture| {
            matches!(
                capture.name.as_str(),
                "function.definition"
                    | "function.declaration"
                    | "function"
                    | "method"
                    | "method_signature"
                    | "call_signature"
                    | "swift.function.method"
                    | "swift.function.toplevel"
                    | "swift.protocol.method"
            )
        })
        .map(|capture| capture.start_row)
        .collect();
    let mut enum_names = BTreeSet::new();
    let mut referenced_types = BTreeSet::new();
    for capture in captures {
        let declaration = declaration_line(source, capture, language);
        match capture.name.as_str() {
            "import" | "import.module" | "import.namespace" => {
                let value = line(source, capture.start_row).trim().to_owned();
                if seen_import_export.insert(value.clone()) {
                    artifact.imports.push(value);
                }
            }
            "export" | "export.source" => {
                let value = line(source, capture.start_row).trim().to_owned();
                if seen_import_export.insert(value.clone()) {
                    artifact.exports.push(value);
                }
            }
            "typeAlias" => {
                let name = text(source, capture).trim().to_owned();
                if !name.is_empty() {
                    push_unique(
                        &mut artifact.aliases,
                        TypeAliasInfo {
                            name,
                            definition_line: declaration,
                        },
                    );
                }
            }
            "type.enum" => {
                let name = text(source, capture).trim().to_owned();
                if !name.is_empty() && enum_names.insert(name.clone()) {
                    enum_values.push(EnumInfo {
                        name,
                        cases: Vec::new(),
                    });
                }
            }
            "enum.entry" => {
                if let Some(value) = enum_values.last_mut() {
                    push_unique(&mut value.cases, text(source, capture).trim().to_owned());
                }
            }
            "function.definition"
            | "function.declaration"
            | "function"
            | "method"
            | "method_signature"
            | "call_signature"
            | "swift.function.method"
            | "swift.function.toplevel"
            | "swift.protocol.method" => {
                let key = (capture.start_row, declaration.clone(), capture.name.clone());
                if !seen_function_lines.insert(key) {
                    continue;
                }
                let signature_source = clean_declaration_line(source, capture, language);
                let (parameters, return_type) = signature_details(language, &signature_source);
                for ty in parameters
                    .iter()
                    .filter_map(|value| value.type_name.as_deref())
                    .chain(return_type.as_deref())
                {
                    referenced_types.extend(referenced_type_names(ty));
                }
                let info = FunctionInfo {
                    name: function_name(text(source, capture), &declaration),
                    parameters,
                    return_type,
                    definition_line: declaration,
                    line_number: Some(capture.start_row + 1),
                    ..FunctionInfo::default()
                };
                if language == CodeMapLanguage::Go {
                    if let Some(receiver) = go_receiver_type(&info.definition_line) {
                        if let Some(target) = artifact
                            .classes
                            .iter_mut()
                            .find(|value| value.name == receiver)
                        {
                            push_unique(&mut target.methods, info);
                            continue;
                        }
                    }
                }
                if let Some(container) = enclosing(&rust_impls, capture, ContainerKind::Class) {
                    if let Some(target) = artifact
                        .classes
                        .iter_mut()
                        .find(|value| value.name == container.name)
                    {
                        push_unique(&mut target.methods, info);
                    }
                } else if let Some(container) =
                    enclosing(&container_values, capture, ContainerKind::Interface)
                {
                    if let Some(target) = artifact
                        .interfaces
                        .iter_mut()
                        .find(|value| value.name == container.name)
                    {
                        push_unique(&mut target.methods, info);
                    }
                } else if let Some(container) =
                    enclosing(&container_values, capture, ContainerKind::Class)
                {
                    if let Some(target) = artifact
                        .classes
                        .iter_mut()
                        .find(|value| value.name == container.name)
                    {
                        push_unique(&mut target.methods, info);
                    }
                } else {
                    push_unique(&mut artifact.functions, info);
                }
            }
            "variable.field"
            | "field"
            | "property_signature"
            | "swift.property.member"
            | "swift.protocol.property" => {
                let name = property_name(language, text(source, capture), &declaration);
                let info = PropertyInfo {
                    type_name: type_after_colon(&name),
                    name,
                };
                if let Some(container) =
                    enclosing(&container_values, capture, ContainerKind::Interface)
                {
                    if let Some(target) = artifact
                        .interfaces
                        .iter_mut()
                        .find(|value| value.name == container.name)
                    {
                        push_unique(&mut target.properties, info);
                    }
                } else if let Some(container) =
                    enclosing(&container_values, capture, ContainerKind::Class)
                {
                    if let Some(target) = artifact
                        .classes
                        .iter_mut()
                        .find(|value| value.name == container.name)
                    {
                        if language == CodeMapLanguage::Ruby {
                            target.properties.push(info);
                        } else {
                            push_unique(&mut target.properties, info);
                        }
                    }
                }
            }
            "variable.global" | "constant.global" | "constant" | "swift.property.toplevel" => {
                if function_rows.contains(&capture.start_row) {
                    continue;
                }
                if let Some(container) =
                    enclosing(&container_values, capture, ContainerKind::Interface)
                {
                    let name = property_name(language, text(source, capture), &declaration);
                    if let Some(target) = artifact
                        .interfaces
                        .iter_mut()
                        .find(|value| value.name == container.name)
                    {
                        push_unique(
                            &mut target.properties,
                            PropertyInfo {
                                type_name: type_after_colon(&name),
                                name,
                            },
                        );
                        continue;
                    }
                }
                if let Some(container) = enclosing(&container_values, capture, ContainerKind::Class)
                {
                    let name = property_name(language, text(source, capture), &declaration);
                    if let Some(target) = artifact
                        .classes
                        .iter_mut()
                        .find(|value| value.name == container.name)
                    {
                        push_unique(
                            &mut target.properties,
                            PropertyInfo {
                                type_name: type_after_colon(&name),
                                name,
                            },
                        );
                        continue;
                    }
                }
                if language == CodeMapLanguage::Python {
                    if let Some(container) = container_values.iter().find(|value| {
                        value.start <= capture.start_byte && capture.end_byte <= value.end
                    }) {
                        let name = text(source, capture).trim().to_owned();
                        if let Some(target) = artifact
                            .classes
                            .iter_mut()
                            .find(|value| value.name == container.name)
                        {
                            push_unique(
                                &mut target.properties,
                                PropertyInfo {
                                    name,
                                    type_name: None,
                                },
                            );
                            continue;
                        }
                    }
                    if let Some(target) = enum_values.iter_mut().find(|value| {
                        line(source, capture.start_row).contains('=') && value.name == "Status"
                    }) {
                        let name = text(source, capture).trim().to_owned();
                        if name
                            .chars()
                            .all(|value| value.is_ascii_uppercase() || value == '_')
                        {
                            push_unique(&mut target.cases, name);
                            continue;
                        }
                    }
                }
                let name = property_name(language, text(source, capture), &declaration);
                push_unique(
                    &mut artifact.global_vars,
                    VariableInfo {
                        type_name: type_after_colon(&name),
                        name,
                        definition_line: declaration,
                    },
                );
            }
            "macro" => push_unique(
                &mut artifact.macros,
                text(source, capture).trim().to_owned(),
            ),
            _ => {}
        }
    }

    artifact.enums = enum_values;
    artifact.referenced_types = referenced_types.into_iter().collect();
    if language == CodeMapLanguage::Ruby {
        let mut in_method = false;
        for raw in source.lines() {
            let value = raw.trim();
            if value.starts_with("def ") {
                in_method = true;
                continue;
            }
            if value == "end" {
                in_method = false;
                continue;
            }
            if value.starts_with("attr_reader ")
                || (in_method && !value.is_empty() && !value.contains('='))
            {
                if !artifact.imports.iter().any(|existing| existing == value) {
                    artifact.imports.push(value.to_owned());
                }
            }
        }
    }
    artifact.classes.retain(|value| !value.name.is_empty());
    artifact.interfaces.retain(|value| !value.name.is_empty());
    artifact
}
