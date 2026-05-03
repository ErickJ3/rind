# zlib-ng 2.2.5 — compiled file list

Native API (`zng_*`), no `ZLIB_COMPAT`. No `WITH_GZFILEOP` (rind doesn't use the
`gzopen`/`gzread` file API — it streams via `zng_inflate` only). Runtime CPU
dispatch is on; SSE2/SSSE3/SSE4.2/PCLMUL/AVX2 sources compiled with per-TU
`-m<feature>` flags. AVX-512 + VPCLMULQDQ skipped (less common, larger binary
for marginal gain on layer extract).

## Core (compiled unconditionally)

- adler32.c
- compress.c
- cpu_features.c
- crc32.c
- crc32_braid_comb.c
- deflate.c
- deflate_fast.c
- deflate_huff.c
- deflate_medium.c
- deflate_quick.c
- deflate_rle.c
- deflate_slow.c
- deflate_stored.c
- functable.c
- infback.c
- inflate.c
- inftrees.c
- insert_string.c
- insert_string_roll.c
- trees.c
- uncompr.c
- zutil.c

(`gzlib.c`, `gzwrite.c`, `gzread.c.in` excluded — `WITH_GZFILEOP` off.
deflate-side files compiled because `functable.c` initialises pointers to
`longest_match`, `slide_hash`, etc. even when only `inflate` runs at runtime.)

## arch/generic (portable C fallbacks)

Functable seeds every slot with the `_c` variant and overrides only what the
runtime CPU check enables; without these the link fails with `undefined symbol:
adler32_c` etc.

- adler32_c.c, adler32_fold_c.c
- chunkset_c.c (also emits `inflate_fast_c` via `inffast_tpl.h`)
- compare256_c.c (also emits `longest_match_c` / `longest_match_slow_c` via `match_tpl.h`)
- crc32_braid_c.c, crc32_fold_c.c
- slide_hash_c.c

## arch/x86 (X86_FEATURES)

Always:
- x86_features.c

Per-feature (compiled with the listed `-m` flag; runtime gate in functable.c):
- chunkset_sse2.c, compare256_sse2.c, slide_hash_sse2.c — x86_64 default (SSE2)
- adler32_ssse3.c, chunkset_ssse3.c — `-mssse3`
- adler32_sse42.c — `-msse4.2`
- crc32_pclmulqdq.c — `-msse4.2 -mpclmul`
- adler32_avx2.c, chunkset_avx2.c, compare256_avx2.c, slide_hash_avx2.c — `-mavx2`

## Defines

Global (passed via `mod.addCMacro`):
- `HAVE_VISIBILITY_HIDDEN`, `HAVE_ATTRIBUTE_ALIGNED`
- `HAVE_BUILTIN_CTZ`, `HAVE_BUILTIN_CTZLL`, `HAVE_BUILTIN_ASSUME_ALIGNED`
- `HAVE_POSIX_MEMALIGN`, `HAVE_ALIGNED_ALLOC`
- `HAVE_SYS_AUXV_H`, `HAVE_UNISTD_H`
- `HAVE_THREAD_LOCAL`
- `_LARGEFILE64_SOURCE=1`, `__USE_LARGEFILE64`
- `X86_FEATURES`, `X86_SSE2`, `X86_SSSE3`, `X86_SSE42`, `X86_PCLMULQDQ_CRC`, `X86_AVX2`
- `WITH_RUNTIME_CPU_DETECTION`
- `HASH_SIZE=65536u`

Not set (kept off):
- `ZLIB_COMPAT` — native API
- `WITH_GZFILEOP` — no gzopen/gzread file API
- `X86_AVX512`, `X86_AVX512VNNI`, `X86_VPCLMULQDQ_CRC`
- `DISABLE_RUNTIME_CPU_DETECTION`
