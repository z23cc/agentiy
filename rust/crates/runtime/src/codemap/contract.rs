use std::fmt;

pub const CODEMAP_CONTRACT_VERSION_V1: u16 = 1;
pub const MAX_UTF8_BYTES: usize = 5_000_000;
pub const MAX_UTF16_UNITS: usize = 1_500_000;
pub const MAX_LINES: usize = 25_000;
pub const OPTIONAL_WORD: u64 = u64::MAX;

pub const STRING_RANGE_STRIDE: usize = 2;
pub const STRING_INDEX_STRIDE: usize = 1;
pub const CLASS_STRIDE: usize = 5;
pub const INTERFACE_STRIDE: usize = 5;
pub const ALIAS_STRIDE: usize = 2;
pub const FUNCTION_STRIDE: usize = 6;
pub const PARAMETER_STRIDE: usize = 3;
pub const PROPERTY_STRIDE: usize = 2;
pub const ENUM_STRIDE: usize = 3;
pub const VARIABLE_STRIDE: usize = 3;

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
#[repr(u16)]
pub enum CodeMapLanguage {
    Swift = 1,
    JavaScript = 2,
    CSharp = 3,
    Python = 4,
    C = 5,
    Rust = 6,
    Cpp = 7,
    Go = 8,
    Java = 9,
    TypeScript = 10,
    Tsx = 11,
    Php = 12,
    Ruby = 13,
}

impl CodeMapLanguage {
    pub const ALL: [Self; 13] = [
        Self::Swift,
        Self::JavaScript,
        Self::CSharp,
        Self::Python,
        Self::C,
        Self::Rust,
        Self::Cpp,
        Self::Go,
        Self::Java,
        Self::TypeScript,
        Self::Tsx,
        Self::Php,
        Self::Ruby,
    ];

    pub fn from_id(id: u16) -> Option<Self> {
        Self::ALL
            .into_iter()
            .find(|language| *language as u16 == id)
    }

    pub const fn id(self) -> u16 {
        self as u16
    }
}

impl fmt::Display for CodeMapLanguage {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{self:?}")
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u16)]
pub enum CodeMapOutcomeTag {
    Ready = 0,
    ReadyNoSymbols = 1,
    OversizeUtf8Bytes = 2,
    OversizeUtf16Units = 3,
    OversizeLines = 4,
    DecodeFailedUndecodable = 5,
    ParseFailedNilTree = 6,
    ParseFailedNilRoot = 7,
}
