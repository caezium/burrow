Captured on 2026-09-06 from the #54 review engine at
`burrow-engine-fix/target/debug/burrow-engine` (checkout `6d872d6`).

The fixture home contained two files, `Library/Caches/review one` (1,234 bytes)
and `Library/Caches/review #two` (5,678 bytes), and a plan listing exactly those
paths. `HOME` and `BURROW_HOME` both pointed to that temporary home. Commands:

```
burrow-engine clean --dry-run --plan <fixture-home>/review.plan --stream
burrow-engine clean --dry-run --plan <fixture-home>/review.plan --json
```

Both captures are verbatim. Both files still existed after the previews. The
temporary home was removed afterwards. These files pin the current wire
format consumed by Clean's review; they do not grant authority to their paths.
