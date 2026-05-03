# libcap generated headers — provenance

`cap_names.h` is generated from `libcap/cap_names.list.h` (which is
itself sed-extracted from `<linux/capability.h>`) via libcap's
`_makenames.c` driver. Upstream Makefile rules:

```
cap_names.list.h: <linux/capability.h>
    sed -n -e '/^#define[ \\t]CAP[_A-Z]\\+[ \\t]\\+[0-9]\\+$/p' \\
        $(UAPI_HEADER) | \\
        awk '{ print "    {\\"" tolower($2) "\\", " $3 "}," }' \\
            > cap_names.list.h

_makenames: _makenames.c cap_names.list.h
    cc -o _makenames _makenames.c

cap_names.h: _makenames
    ./_makenames > cap_names.h
```

`build.zig`'s `cLibcap` helper replicates this in two Zig build steps:

1. A `Step.WriteFile` writes `cap_names.list.h` from a sed of the
   current host's `<linux/capability.h>` (or, more reproducibly, from
   a vendored copy under `build/cdeps/cap/uapi/capability.h`).
2. A second step compiles + runs `_makenames`, capturing stdout into
   `<cache>/cap_names.h`. The lib build then `addIncludePath`s the
   cache dir.

This file is the README for that flow. The actual generated header is
written into the Zig build cache; nothing checked in here.
