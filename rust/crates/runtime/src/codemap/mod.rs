mod artifact;
mod compact;
mod contract;
mod engine;
mod extract;

use std::fmt;

pub use artifact::{
    ClassInfo, CodeMapArtifact, EnumInfo, FunctionInfo, InterfaceInfo, ParameterInfo, PropertyInfo,
    TypeAliasInfo, VariableInfo,
};
pub use compact::{CompactCodeMapBatchResultV1, CompactCodeMapSubjectSummaryV1, TableRange};
pub use contract::{
    ALIAS_STRIDE, CLASS_STRIDE, CODEMAP_CONTRACT_VERSION_V1, CodeMapLanguage, CodeMapOutcomeTag,
    ENUM_STRIDE, FUNCTION_STRIDE, INTERFACE_STRIDE, MAX_LINES, MAX_UTF8_BYTES, MAX_UTF16_UNITS,
    OPTIONAL_WORD, PARAMETER_STRIDE, PROPERTY_STRIDE, STRING_INDEX_STRIDE, STRING_RANGE_STRIDE,
    VARIABLE_STRIDE,
};
pub use engine::{Capture, LanguageDescriptor, descriptor, parse_captures};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CodeMapSourceKind {
    Decoded,
    DecodeFailedUndecodable,
    /// TD-3 (`docs/designs/textdecode-policy-v2-2026-08-22.md` §6.1): `source_utf8` carries
    /// genuinely raw, possibly-non-UTF-8 bytes. `textdecode` (never fails, §5.1) runs as the
    /// first step here instead of a strict UTF-8 validity check.
    Raw,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CodeMapSubjectRequestV1 {
    pub language_id: u16,
    pub source_kind: CodeMapSourceKind,
    pub source_utf8: Vec<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CodeMapBatchRequestV1 {
    pub contract_version: u16,
    pub subjects: Vec<CodeMapSubjectRequestV1>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum CodeMapError {
    InvalidRequest(String),
    Parser(String),
    Query(String),
    Internal(String),
    Cancelled,
    ParserReturnedNilTree,
}

impl fmt::Display for CodeMapError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidRequest(value) => write!(formatter, "invalid codemap request: {value}"),
            Self::Parser(value) => write!(formatter, "codemap parser error: {value}"),
            Self::Query(value) => write!(formatter, "codemap query error: {value}"),
            Self::Internal(value) => write!(formatter, "codemap internal error: {value}"),
            Self::Cancelled => formatter.write_str("codemap cancelled"),
            Self::ParserReturnedNilTree => write!(formatter, "codemap parser returned no tree"),
        }
    }
}
impl std::error::Error for CodeMapError {}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum SubjectOutcome {
    Ready(CodeMapArtifact),
    OversizeUtf8 { actual: usize, limit: usize },
    OversizeUtf16 { actual: usize, limit: usize },
    OversizeLines { actual: usize, limit: usize },
    DecodeFailed,
    ParseFailedNilTree,
    ParseFailedNilRoot,
}

fn exceeded_line_count(bytes: &[u8], limit: usize) -> Option<usize> {
    if limit == 0 || bytes.is_empty() {
        return None;
    }
    let mut lines = 1usize;
    let mut index = 0usize;
    while index < bytes.len() {
        match bytes[index] {
            b'\n' => {
                lines += 1;
                index += 1;
            }
            b'\r' => {
                lines += 1;
                index += 1;
                if index < bytes.len() && bytes[index] == b'\n' {
                    index += 1;
                }
            }
            _ => index += 1,
        }
        if lines > limit {
            return Some(lines);
        }
    }
    None
}

pub fn build_subject(request: &CodeMapSubjectRequestV1) -> Result<SubjectOutcome, CodeMapError> {
    build_subject_with_cancellation(request, None)
}

fn build_subject_with_cancellation(
    request: &CodeMapSubjectRequestV1,
    cancellation: Option<&crate::search::LeafCancellation>,
) -> Result<SubjectOutcome, CodeMapError> {
    if cancellation.is_some_and(crate::search::LeafCancellation::is_cancelled) {
        return Err(CodeMapError::Cancelled);
    }
    let language = CodeMapLanguage::from_id(request.language_id).ok_or_else(|| {
        CodeMapError::InvalidRequest(format!("unknown language id {}", request.language_id))
    })?;
    if request.source_kind == CodeMapSourceKind::DecodeFailedUndecodable {
        if !request.source_utf8.is_empty() {
            return Err(CodeMapError::InvalidRequest(
                "decode-failed source must be empty".to_owned(),
            ));
        }
        return Ok(SubjectOutcome::DecodeFailed);
    }
    // Raw-bytes path decodes here (first step, before any size/parse work) rather than in a
    // separate FFI crossing -- design §6.1's "one crossing" constraint. For the pre-existing
    // `Decoded` kind this is a no-op refactor: `source.len()` equals `request.source_utf8.len()`
    // exactly, since `source` is that same byte slice reinterpreted, not transformed.
    let decoded_owned;
    let source: &str = if request.source_kind == CodeMapSourceKind::Raw {
        decoded_owned = crate::textdecode::textdecode(&request.source_utf8).text;
        &decoded_owned
    } else {
        std::str::from_utf8(&request.source_utf8).map_err(|_| {
            CodeMapError::InvalidRequest("decoded source is not valid UTF-8".to_owned())
        })?
    };
    let source_byte_len = source.len();
    if source_byte_len > MAX_UTF8_BYTES {
        return Ok(SubjectOutcome::OversizeUtf8 {
            actual: source_byte_len,
            limit: MAX_UTF8_BYTES,
        });
    }
    let utf16_units = source.encode_utf16().count();
    if utf16_units > MAX_UTF16_UNITS {
        return Ok(SubjectOutcome::OversizeUtf16 {
            actual: utf16_units,
            limit: MAX_UTF16_UNITS,
        });
    }
    if let Some(actual) = exceeded_line_count(source.as_bytes(), MAX_LINES) {
        return Ok(SubjectOutcome::OversizeLines {
            actual,
            limit: MAX_LINES,
        });
    }
    let captures = match parse_captures(language, source) {
        Ok(captures) => captures,
        Err(CodeMapError::ParserReturnedNilTree) => return Ok(SubjectOutcome::ParseFailedNilTree),
        Err(error) => return Err(error),
    };
    if cancellation.is_some_and(crate::search::LeafCancellation::is_cancelled) {
        return Err(CodeMapError::Cancelled);
    }
    let artifact = extract::extract_artifact(source, language, &captures);
    if cancellation.is_some_and(crate::search::LeafCancellation::is_cancelled) {
        return Err(CodeMapError::Cancelled);
    }
    Ok(SubjectOutcome::Ready(artifact))
}

#[derive(Default)]
pub struct CodeMapService;
impl CodeMapService {
    pub fn build_batch(
        &self,
        request: CodeMapBatchRequestV1,
    ) -> Result<CompactCodeMapBatchResultV1, CodeMapError> {
        self.build_batch_with_cancellation(request, None)
    }

    pub fn build_batch_with_cancellation(
        &self,
        request: CodeMapBatchRequestV1,
        cancellation: Option<&crate::search::LeafCancellation>,
    ) -> Result<CompactCodeMapBatchResultV1, CodeMapError> {
        if request.contract_version != CODEMAP_CONTRACT_VERSION_V1 {
            return Err(CodeMapError::InvalidRequest(format!(
                "unknown contract version {}",
                request.contract_version
            )));
        }
        let mut subjects = Vec::with_capacity(request.subjects.len());
        for subject in &request.subjects {
            if cancellation.is_some_and(crate::search::LeafCancellation::is_cancelled) {
                return Err(CodeMapError::Cancelled);
            }
            subjects.push((
                subject.language_id,
                subject.source_utf8.len(),
                build_subject_with_cancellation(subject, cancellation)?,
            ));
        }
        compact::encode_batch(&subjects)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn crlf_guard_counts_one_line_break() {
        assert_eq!(exceeded_line_count(b"a\r\nb\rc\nd", 3), Some(4));
    }
}
