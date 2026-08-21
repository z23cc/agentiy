# Rust search cargo floors v1

Policy: **cargo is the default performance iteration instrument**. Swift release is reserved for B/C and one final SLO confirmation after cargo floors are promising.

| Fixture | Layer | Wall p50 runs | Wall p99 runs | Spread (p99) |
|---|---|---|---|---:|
| representative-large-subject | A | 0.0652 ms, 0.0656 ms, 0.0675 ms | 0.0701 ms, 0.0818 ms, 0.0811 ms | 15.07% |
| representative-large-subject | FFI-frontier | 0.0695 ms, 0.0699 ms, 0.0684 ms | 0.0845 ms, 0.0822 ms, 0.0795 ms | 5.99% |
| representative-multi-file-batch | A | 0.0665 ms, 0.0671 ms, 0.0659 ms | 0.0779 ms, 0.0819 ms, 0.0816 ms | 4.97% |
| representative-multi-file-batch | FFI-frontier | 0.0707 ms, 0.0711 ms, 0.0715 ms | 0.0789 ms, 0.0821 ms, 0.0760 ms | 7.76% |
| representative-match-density | A | 0.0417 ms, 0.0418 ms, 0.0412 ms | 0.0512 ms, 0.0560 ms, 0.0511 ms | 9.31% |
| representative-match-density | FFI-frontier | 0.0434 ms, 0.0435 ms, 0.0438 ms | 0.0550 ms, 0.0510 ms, 0.0526 ms | 7.57% |
