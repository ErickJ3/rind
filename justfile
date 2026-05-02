default: build

build:
    zig build

run *ARGS:
    zig build run -- {{ARGS}}

pull *ARGS:
    zig build run -- pull {{ARGS}}

test:
    zig build test

test-fuzz:
    zig build test --fuzz

# Real-network e2e against Docker Hub. Requires network + accepts
# DOCKER_HUB rate limits. Off by default; CI does not run this.
e2e:
    RIND_E2E=1 zig build test -Drind-e2e=true

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
