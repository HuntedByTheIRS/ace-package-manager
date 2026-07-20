# C Interop Isolation Policy

All C foreign-function interface (FFI) wrappers live exclusively in the
`lib/` directory.  This is the **only** module in the project that may
contain `#flag`, `#include`, or `[c2v]` annotations, or call C functions
via V's `C.` namespace.

## Rules

1. **No `unsafe` code outside `lib/`.**  Any module that needs to call
   into a C library must do so through a wrapper defined in `lib/`.
2. **No `#flag` / `#include` outside `lib/`.**  Linker flags and C header
   includes are scoped to wrapper files under this tree.
3. **Wrappers expose a safe V API.**  Each wrapper must handle errors,
   null pointers, and memory management internally, presenting a pure-V
   interface to the rest of the codebase.
4. **One wrapper file per C library.**  For example, `lib/zstd.v` wraps
   libzstd, `lib/gpgme.v` wraps gpgme, etc.  Accompanying `.c` shims
   may live alongside when V's built-in `#flag` is insufficient.

## Enforcement

- CI `vet` / `fmt` steps will reject any `#flag`, `#include`, or `C.`
  references found outside `lib/`.
- Code reviews must flag violations.
