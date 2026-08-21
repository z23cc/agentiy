use super::artifact::{CodeMapArtifact, FunctionInfo, PropertyInfo};
use super::contract::{CodeMapOutcomeTag, OPTIONAL_WORD};
use super::{CodeMapError, SubjectOutcome};

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct TableRange {
    pub start: u64,
    pub count: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CompactCodeMapSubjectSummaryV1 {
    pub language_id: u16,
    pub source_byte_count: u64,
    pub outcome_tag: CodeMapOutcomeTag,
    pub outcome_actual: u64,
    pub outcome_limit: u64,
    pub blob: TableRange,
    pub strings: TableRange,
    pub string_indices: TableRange,
    pub class_pool: TableRange,
    pub interface_pool: TableRange,
    pub alias_pool: TableRange,
    pub function_pool: TableRange,
    pub parameter_pool: TableRange,
    pub property_pool: TableRange,
    pub enum_pool: TableRange,
    pub variable_pool: TableRange,
    pub imports: TableRange,
    pub exports: TableRange,
    pub classes: TableRange,
    pub interfaces: TableRange,
    pub aliases: TableRange,
    pub literal_unions: TableRange,
    pub functions: TableRange,
    pub enums: TableRange,
    pub global_vars: TableRange,
    pub macros: TableRange,
    pub referenced_types: TableRange,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct CompactCodeMapBatchResultV1 {
    pub subject_summaries: Vec<CompactCodeMapSubjectSummaryV1>,
    pub utf8_blob: Vec<u8>,
    pub string_range_words: Vec<u64>,
    pub string_index_words: Vec<u64>,
    pub class_words: Vec<u64>,
    pub interface_words: Vec<u64>,
    pub alias_words: Vec<u64>,
    pub function_words: Vec<u64>,
    pub parameter_words: Vec<u64>,
    pub property_words: Vec<u64>,
    pub enum_words: Vec<u64>,
    pub variable_words: Vec<u64>,
}

fn word(value: usize) -> Result<u64, CodeMapError> {
    u64::try_from(value).map_err(|_| CodeMapError::Internal("compact index overflow".to_owned()))
}
fn range(start: usize, end: usize) -> Result<TableRange, CodeMapError> {
    Ok(TableRange {
        start: word(start)?,
        count: word(
            end.checked_sub(start)
                .ok_or_else(|| CodeMapError::Internal("compact cursor underflow".to_owned()))?,
        )?,
    })
}

struct Encoder<'a> {
    output: &'a mut CompactCodeMapBatchResultV1,
}
impl Encoder<'_> {
    fn string(&mut self, value: &str) -> Result<u64, CodeMapError> {
        let start = word(self.output.utf8_blob.len())?;
        self.output.utf8_blob.extend_from_slice(value.as_bytes());
        let end = word(self.output.utf8_blob.len())?;
        let index = self.output.string_range_words.len() / 2;
        self.output.string_range_words.extend([start, end]);
        word(index)
    }
    fn optional_string(&mut self, value: Option<&str>) -> Result<u64, CodeMapError> {
        value.map_or(Ok(OPTIONAL_WORD), |value| self.string(value))
    }
    fn string_list(&mut self, values: &[String]) -> Result<TableRange, CodeMapError> {
        let start = self.output.string_index_words.len();
        for value in values {
            let index = self.string(value)?;
            self.output.string_index_words.push(index);
        }
        range(start, self.output.string_index_words.len())
    }
    fn property(&mut self, value: &PropertyInfo) -> Result<(), CodeMapError> {
        let name = self.string(&value.name)?;
        let ty = self.optional_string(value.type_name.as_deref())?;
        self.output.property_words.extend([name, ty]);
        Ok(())
    }
    fn function(&mut self, value: &FunctionInfo) -> Result<(), CodeMapError> {
        let parameter_start = self.output.parameter_words.len() / 3;
        for parameter in &value.parameters {
            let external = self.optional_string(parameter.external_name.as_deref())?;
            let local = self.string(&parameter.local_name)?;
            let ty = self.optional_string(parameter.type_name.as_deref())?;
            self.output.parameter_words.extend([external, local, ty]);
        }
        let name = self.string(&value.name)?;
        let return_type = self.optional_string(value.return_type.as_deref())?;
        let definition = self.string(&value.definition_line)?;
        self.output.function_words.extend([
            name,
            word(parameter_start)?,
            word(value.parameters.len())?,
            return_type,
            definition,
            value.line_number.map_or(Ok(OPTIONAL_WORD), word)?,
        ]);
        Ok(())
    }
    fn artifact(&mut self, artifact: &CodeMapArtifact) -> Result<TopRanges, CodeMapError> {
        let imports = self.string_list(&artifact.imports)?;
        let exports = self.string_list(&artifact.exports)?;
        let literal_unions = self.string_list(&artifact.literal_unions)?;
        let macros = self.string_list(&artifact.macros)?;
        let referenced_types = self.string_list(&artifact.referenced_types)?;

        let classes_start = self.output.class_words.len() / 5;
        for value in &artifact.classes {
            let method_start = self.output.function_words.len() / 6;
            for method in &value.methods {
                self.function(method)?;
            }
            let property_start = self.output.property_words.len() / 2;
            for property in &value.properties {
                self.property(property)?;
            }
            let name = self.string(&value.name)?;
            self.output.class_words.extend([
                name,
                word(method_start)?,
                word(value.methods.len())?,
                word(property_start)?,
                word(value.properties.len())?,
            ]);
        }
        let classes = range(classes_start, self.output.class_words.len() / 5)?;

        let interfaces_start = self.output.interface_words.len() / 5;
        for value in &artifact.interfaces {
            let method_start = self.output.function_words.len() / 6;
            for method in &value.methods {
                self.function(method)?;
            }
            let property_start = self.output.property_words.len() / 2;
            for property in &value.properties {
                self.property(property)?;
            }
            let name = self.string(&value.name)?;
            self.output.interface_words.extend([
                name,
                word(method_start)?,
                word(value.methods.len())?,
                word(property_start)?,
                word(value.properties.len())?,
            ]);
        }
        let interfaces = range(interfaces_start, self.output.interface_words.len() / 5)?;

        let aliases_start = self.output.alias_words.len() / 2;
        for value in &artifact.aliases {
            let name = self.string(&value.name)?;
            let definition = self.string(&value.definition_line)?;
            self.output.alias_words.extend([name, definition]);
        }
        let aliases = range(aliases_start, self.output.alias_words.len() / 2)?;

        let functions_start = self.output.function_words.len() / 6;
        for value in &artifact.functions {
            self.function(value)?;
        }
        let functions = range(functions_start, self.output.function_words.len() / 6)?;

        let enums_start = self.output.enum_words.len() / 3;
        for value in &artifact.enums {
            let cases = self.string_list(&value.cases)?;
            let name = self.string(&value.name)?;
            self.output
                .enum_words
                .extend([name, cases.start, cases.count]);
        }
        let enums = range(enums_start, self.output.enum_words.len() / 3)?;

        let variables_start = self.output.variable_words.len() / 3;
        for value in &artifact.global_vars {
            let name = self.string(&value.name)?;
            let ty = self.optional_string(value.type_name.as_deref())?;
            let definition = self.string(&value.definition_line)?;
            self.output.variable_words.extend([name, ty, definition]);
        }
        let global_vars = range(variables_start, self.output.variable_words.len() / 3)?;
        Ok(TopRanges {
            imports,
            exports,
            classes,
            interfaces,
            aliases,
            literal_unions,
            functions,
            enums,
            global_vars,
            macros,
            referenced_types,
        })
    }
}

#[derive(Default)]
struct TopRanges {
    imports: TableRange,
    exports: TableRange,
    classes: TableRange,
    interfaces: TableRange,
    aliases: TableRange,
    literal_unions: TableRange,
    functions: TableRange,
    enums: TableRange,
    global_vars: TableRange,
    macros: TableRange,
    referenced_types: TableRange,
}

pub fn encode_batch(
    subjects: &[(u16, usize, SubjectOutcome)],
) -> Result<CompactCodeMapBatchResultV1, CodeMapError> {
    let mut output = CompactCodeMapBatchResultV1::default();
    for (language_id, source_bytes, outcome) in subjects {
        let starts = Starts::new(&output);
        let (tag, actual, limit, tops) = match outcome {
            SubjectOutcome::Ready(artifact) => {
                let tops = Encoder {
                    output: &mut output,
                }
                .artifact(artifact)?;
                let tag = if artifact.has_symbols() {
                    CodeMapOutcomeTag::Ready
                } else {
                    CodeMapOutcomeTag::ReadyNoSymbols
                };
                (tag, 0, 0, tops)
            }
            SubjectOutcome::OversizeUtf8 { actual, limit } => (
                CodeMapOutcomeTag::OversizeUtf8Bytes,
                *actual,
                *limit,
                TopRanges::default(),
            ),
            SubjectOutcome::OversizeUtf16 { actual, limit } => (
                CodeMapOutcomeTag::OversizeUtf16Units,
                *actual,
                *limit,
                TopRanges::default(),
            ),
            SubjectOutcome::OversizeLines { actual, limit } => (
                CodeMapOutcomeTag::OversizeLines,
                *actual,
                *limit,
                TopRanges::default(),
            ),
            SubjectOutcome::DecodeFailed => (
                CodeMapOutcomeTag::DecodeFailedUndecodable,
                0,
                0,
                TopRanges::default(),
            ),
            SubjectOutcome::ParseFailedNilTree => (
                CodeMapOutcomeTag::ParseFailedNilTree,
                0,
                0,
                TopRanges::default(),
            ),
            SubjectOutcome::ParseFailedNilRoot => (
                CodeMapOutcomeTag::ParseFailedNilRoot,
                0,
                0,
                TopRanges::default(),
            ),
        };
        output.subject_summaries.push(starts.summary(
            *language_id,
            *source_bytes,
            tag,
            actual,
            limit,
            &output,
            tops,
        )?);
    }
    Ok(output)
}

struct Starts {
    blob: usize,
    strings: usize,
    indices: usize,
    classes: usize,
    interfaces: usize,
    aliases: usize,
    functions: usize,
    parameters: usize,
    properties: usize,
    enums: usize,
    variables: usize,
}
impl Starts {
    fn new(value: &CompactCodeMapBatchResultV1) -> Self {
        Self {
            blob: value.utf8_blob.len(),
            strings: value.string_range_words.len() / 2,
            indices: value.string_index_words.len(),
            classes: value.class_words.len() / 5,
            interfaces: value.interface_words.len() / 5,
            aliases: value.alias_words.len() / 2,
            functions: value.function_words.len() / 6,
            parameters: value.parameter_words.len() / 3,
            properties: value.property_words.len() / 2,
            enums: value.enum_words.len() / 3,
            variables: value.variable_words.len() / 3,
        }
    }
    fn summary(
        self,
        language_id: u16,
        source_byte_count: usize,
        outcome_tag: CodeMapOutcomeTag,
        actual: usize,
        limit: usize,
        value: &CompactCodeMapBatchResultV1,
        top: TopRanges,
    ) -> Result<CompactCodeMapSubjectSummaryV1, CodeMapError> {
        Ok(CompactCodeMapSubjectSummaryV1 {
            language_id,
            source_byte_count: word(source_byte_count)?,
            outcome_tag,
            outcome_actual: word(actual)?,
            outcome_limit: word(limit)?,
            blob: range(self.blob, value.utf8_blob.len())?,
            strings: range(self.strings, value.string_range_words.len() / 2)?,
            string_indices: range(self.indices, value.string_index_words.len())?,
            class_pool: range(self.classes, value.class_words.len() / 5)?,
            interface_pool: range(self.interfaces, value.interface_words.len() / 5)?,
            alias_pool: range(self.aliases, value.alias_words.len() / 2)?,
            function_pool: range(self.functions, value.function_words.len() / 6)?,
            parameter_pool: range(self.parameters, value.parameter_words.len() / 3)?,
            property_pool: range(self.properties, value.property_words.len() / 2)?,
            enum_pool: range(self.enums, value.enum_words.len() / 3)?,
            variable_pool: range(self.variables, value.variable_words.len() / 3)?,
            imports: top.imports,
            exports: top.exports,
            classes: top.classes,
            interfaces: top.interfaces,
            aliases: top.aliases,
            literal_unions: top.literal_unions,
            functions: top.functions,
            enums: top.enums,
            global_vars: top.global_vars,
            macros: top.macros,
            referenced_types: top.referenced_types,
        })
    }
}
