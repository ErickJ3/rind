default: build

build:
    zig build

run *ARGS:
    zig build run -- {{ARGS}}

test:
    zig build test

test-fuzz:
    zig build test --fuzz

release:
    zig build -Doptimize=ReleaseFast

release-safe:
    zig build -Doptimize=ReleaseSafe

release-small:
    zig build -Doptimize=ReleaseSmall

fmt:
    zig fmt src build.zig build.zig.zon

fmt-check:
    zig fmt --check src build.zig build.zig.zon

clean:
    rm -rf .zig-cache zig-out

check:
    zig build --summary all
