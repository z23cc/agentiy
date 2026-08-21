#![no_main]

use agentry_runtime::codemap::{
    CODEMAP_CONTRACT_VERSION_V1, CodeMapBatchRequestV1, CodeMapService, CodeMapSourceKind,
    CodeMapSubjectRequestV1,
};
use libfuzzer_sys::fuzz_target;

const MAX_SOURCE_BYTES: usize = 32 * 1024;

fuzz_target!(|input: &[u8]| {
    if input.len() < 2 {
        return;
    }
    let options = input[0];
    let language_id = u16::from(input[1] % 15);
    let source_kind = if options & 1 == 0 {
        CodeMapSourceKind::Decoded
    } else {
        CodeMapSourceKind::DecodeFailedUndecodable
    };
    let source_utf8 = if source_kind == CodeMapSourceKind::Decoded {
        String::from_utf8_lossy(&input[2..input.len().min(MAX_SOURCE_BYTES + 2)])
            .into_owned()
            .into_bytes()
    } else if options & 2 == 0 {
        Vec::new()
    } else {
        input[2..input.len().min(MAX_SOURCE_BYTES + 2)].to_vec()
    };
    let request = CodeMapBatchRequestV1 {
        contract_version: if options & 4 == 0 {
            CODEMAP_CONTRACT_VERSION_V1
        } else {
            u16::from(input[1])
        },
        subjects: vec![CodeMapSubjectRequestV1 {
            language_id,
            source_kind,
            source_utf8,
        }],
    };
    let _ = CodeMapService.build_batch(request);
});
