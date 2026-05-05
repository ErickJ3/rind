default: build

build:
    zig build

run *ARGS:
    zig build run -- {{ ARGS }}

pull *ARGS:
    zig build run -- pull {{ ARGS }}

test:
    zig build test

test-fuzz:
    zig build test --fuzz

e2e:
    RIND_E2E=1 zig build test -Drind-e2e=true

isolation-check:
    RIND_E2E=1 bash tests/isolation/run-all.sh

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

bench:
    bash bench/run-all.sh

bench-quick:
    bash bench/run-all.sh --skip pull-cold,rm

bench-snapshot:
    cp bench/results/latest.md "bench/results/history/$(date +%F)_$(git rev-parse --short HEAD).md"
