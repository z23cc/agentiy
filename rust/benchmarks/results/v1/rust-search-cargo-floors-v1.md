# Rust search cargo floors v1

Policy: **cargo is the default performance iteration instrument**. Swift release is reserved for B/C and one final SLO confirmation after cargo floors are promising.

| Fixture | Layer | Wall p50 runs | Wall p99 runs | Spread (p99) |
|---|---|---|---|---:|
| representative-large-subject | A | 0.0650 ms, 0.0652 ms, 0.0657 ms, 0.0656 ms, 0.0654 ms | 0.0785 ms, 0.0794 ms, 0.0791 ms, 0.0815 ms, 0.0979 ms | 23.32% |
| representative-large-subject | FFI-frontier | 0.0685 ms, 0.0684 ms, 0.0694 ms, 0.0683 ms, 0.0683 ms | 0.1146 ms, 0.0991 ms, 0.0832 ms, 0.0863 ms, 0.0987 ms | 32.55% |
| representative-multi-file-batch | A | 0.0650 ms, 0.0661 ms, 0.0689 ms, 0.0651 ms, 0.0652 ms | 0.1085 ms, 0.0960 ms, 0.1619 ms, 0.0952 ms, 0.1338 ms | 56.06% |
| representative-multi-file-batch | FFI-frontier | 0.0756 ms, 0.0703 ms, 0.0703 ms, 0.0713 ms, 0.0701 ms | 0.1957 ms, 0.1369 ms, 0.1391 ms, 0.1839 ms, 0.1210 ms | 48.12% |
| representative-match-density | A | 0.0411 ms, 0.0410 ms, 0.0412 ms, 0.0414 ms, 0.0409 ms | 0.0833 ms, 0.0986 ms, 0.0795 ms, 0.0955 ms, 0.0529 ms | 55.76% |
| representative-match-density | FFI-frontier | 0.0428 ms, 0.0437 ms, 0.0439 ms, 0.0435 ms, 0.0434 ms | 0.0899 ms, 0.0663 ms, 0.0674 ms, 0.0873 ms, 0.0700 ms | 31.07% |
