#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct CodeMapArtifact {
    pub imports: Vec<String>,
    pub exports: Vec<String>,
    pub classes: Vec<ClassInfo>,
    pub interfaces: Vec<InterfaceInfo>,
    pub aliases: Vec<TypeAliasInfo>,
    pub literal_unions: Vec<String>,
    pub functions: Vec<FunctionInfo>,
    pub enums: Vec<EnumInfo>,
    pub global_vars: Vec<VariableInfo>,
    pub macros: Vec<String>,
    pub referenced_types: Vec<String>,
}

impl CodeMapArtifact {
    pub fn has_symbols(&self) -> bool {
        !self.imports.is_empty()
            || !self.exports.is_empty()
            || !self.classes.is_empty()
            || !self.interfaces.is_empty()
            || !self.aliases.is_empty()
            || !self.literal_unions.is_empty()
            || !self.functions.is_empty()
            || !self.enums.is_empty()
            || !self.global_vars.is_empty()
            || !self.macros.is_empty()
    }

    pub fn api_description(&self) -> String {
        let mut lines = vec!["---".to_owned()];
        fn function_line(value: &FunctionInfo) -> String {
            value.line_number.map_or_else(
                || value.definition_line.clone(),
                |line| format!("L{line}: {}", value.definition_line),
            )
        }
        fn property_line(name: &str, ty: Option<&str>) -> String {
            match ty.filter(|value| !value.is_empty()) {
                Some(value) if !name.contains(':') => format!("{name}: {value}"),
                _ => name.to_owned(),
            }
        }
        if !self.classes.is_empty() {
            lines.push("Classes:".to_owned());
            for value in &self.classes {
                lines.push(format!("  - {}", value.name));
                if !value.methods.is_empty() {
                    lines.push("    Methods:".to_owned());
                    lines.extend(
                        value
                            .methods
                            .iter()
                            .map(|method| format!("      - {}", function_line(method))),
                    );
                }
                if !value.properties.is_empty() {
                    lines.push("    Properties:".to_owned());
                    lines.extend(value.properties.iter().map(|property| {
                        format!(
                            "      - {}",
                            property_line(&property.name, property.type_name.as_deref())
                        )
                    }));
                }
            }
        }
        if !self.interfaces.is_empty() {
            lines.push(String::new());
            lines.push("Interfaces:".to_owned());
            for value in &self.interfaces {
                lines.push(format!("  - {}", value.name));
                if !value.methods.is_empty() {
                    lines.push("    Methods:".to_owned());
                    lines.extend(
                        value
                            .methods
                            .iter()
                            .map(|method| format!("      - {}", function_line(method))),
                    );
                }
                if !value.properties.is_empty() {
                    lines.push("    Properties:".to_owned());
                    lines.extend(value.properties.iter().map(|property| {
                        format!(
                            "      - {}",
                            property_line(&property.name, property.type_name.as_deref())
                        )
                    }));
                }
            }
        }
        if !self.aliases.is_empty() {
            lines.push(String::new());
            lines.push("Type-aliases:".to_owned());
            lines.extend(
                self.aliases
                    .iter()
                    .map(|value| format!("  - {}", value.name)),
            );
        }
        if !self.literal_unions.is_empty() {
            lines.push(String::new());
            lines.push("Literal-union aliases:".to_owned());
            lines.extend(
                self.literal_unions
                    .iter()
                    .map(|value| format!("  - {value}")),
            );
        }
        if !self.functions.is_empty() {
            lines.push(String::new());
            lines.push("Functions:".to_owned());
            lines.extend(
                self.functions
                    .iter()
                    .map(|value| format!("  - {}", function_line(value))),
            );
        }
        if !self.enums.is_empty() {
            lines.push(String::new());
            lines.push("Enums:".to_owned());
            lines.extend(self.enums.iter().map(|value| format!("  - {}", value.name)));
        }
        if !self.global_vars.is_empty() {
            lines.push(String::new());
            lines.push("Global vars:".to_owned());
            lines.extend(self.global_vars.iter().map(|value| {
                format!(
                    "  - {}",
                    property_line(&value.name, value.type_name.as_deref())
                )
            }));
        }
        if !self.exports.is_empty() {
            lines.push(String::new());
            lines.push("Exports:".to_owned());
            lines.extend(self.exports.iter().map(|value| format!("  - {value}")));
        }
        if !self.macros.is_empty() {
            lines.push(String::new());
            lines.push("Macros:".to_owned());
            lines.extend(self.macros.iter().map(|value| format!("  - {value}")));
        }
        lines.push("---".to_owned());
        format!("\n{}\n", lines.join("\n"))
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ClassInfo {
    pub name: String,
    pub methods: Vec<FunctionInfo>,
    pub properties: Vec<PropertyInfo>,
}
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct InterfaceInfo {
    pub name: String,
    pub methods: Vec<FunctionInfo>,
    pub properties: Vec<PropertyInfo>,
}
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct TypeAliasInfo {
    pub name: String,
    pub definition_line: String,
}
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct FunctionInfo {
    pub name: String,
    pub parameters: Vec<ParameterInfo>,
    pub return_type: Option<String>,
    pub definition_line: String,
    pub line_number: Option<usize>,
}
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ParameterInfo {
    pub external_name: Option<String>,
    pub local_name: String,
    pub type_name: Option<String>,
}
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct PropertyInfo {
    pub name: String,
    pub type_name: Option<String>,
}
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct EnumInfo {
    pub name: String,
    pub cases: Vec<String>,
}
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct VariableInfo {
    pub name: String,
    pub type_name: Option<String>,
    pub definition_line: String,
}
