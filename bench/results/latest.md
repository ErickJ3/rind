# rind bench results

- date: 2026-05-04T22:53:53-03:00
- git: eeeedb9 (ci/add-github-actions)
- kernel: 6.19.14-300.fc44.x86_64
- cpu: 11th Gen Intel(R) Core(TM) i5-11300H @ 3.10GHz
- mem: 23.2 GiB
- zig: 0.16.0
- build: zig build -Doptimize=ReleaseFast -Dstrip
- rind: 2301544 bytes
- runtimes: rind / podman / docker


## scenarios

## pull alpine:3.19 (warm cache)

Image pre-pulled on every runtime — measures warm path (manifest re-validate, blob existence). Target: <100ms warm (docs/rind.md:271).

| runtime | wall_time (mean ± σ, min … max) | runs |
|---------|---------------------------------|------|
| rind | `2.00s  ±  648ms                              1.62s  … 2.74s                                     0 ( 0%)        0%` | 3 |
| podman | `2.38s  ± 1.13s                               1.72s  … 3.69s                                     0 ( 0%)          + 19.2% ± 104.8%` | 3 |
| docker | `1.40s  ± 12.7ms                              1.39s  … 1.41s                                     0 ( 0%)          - 29.9% ± 52.0%` | 3 |

<details><summary>raw poop output</summary>

```
Benchmark 1 (3 runs): /home/redshit/Documents/personal/rind/zig-out/bin/rind pull alpine:3.19
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          2.00s  ±  648ms                              1.62s  … 2.74s                                     0 ( 0%)        0%
  peak_rss           8.53MB ± 35.7KB                              8.49MB … 8.55MB                                    0 ( 0%)        0%
  cpu_cycles         35.1M  ± 2.38M                               33.6M  … 37.8M                                     0 ( 0%)        0%
  instructions       98.6M  ± 19.8K                               98.6M  … 98.7M                                     0 ( 0%)        0%
  cache_references   78.8K  ± 1.04K                               77.9K  … 79.9K                                     0 ( 0%)        0%
  cache_misses       45.5K  ± 1.24K                               44.4K  … 46.9K                                     0 ( 0%)        0%
  branch_misses      41.1K  ±  313                                40.8K  … 41.4K                                     0 ( 0%)        0%
Benchmark 2 (3 runs): podman pull alpine:3.19
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          2.38s  ± 1.13s                               1.72s  … 3.69s                                     0 ( 0%)          + 19.2% ± 104.8%
  peak_rss           51.1MB ±  876KB                              50.5MB … 52.1MB                                    0 ( 0%)        💩+499.4% ± 16.5%
  cpu_cycles          189M  ± 3.24M                                185M  …  192M                                     0 ( 0%)        💩+438.1% ± 18.4%
  instructions        353M  ± 5.55M                                346M  …  356M                                     0 ( 0%)        💩+257.7% ±  9.0%
  cache_references   1.88M  ± 30.2K                               1.85M  … 1.91M                                     0 ( 0%)        💩+2286.6% ± 61.4%
  cache_misses        842K  ± 36.2K                                817K  …  883K                                     0 ( 0%)        💩+1748.4% ± 127.5%
  branch_misses       807K  ± 26.3K                                777K  …  826K                                     0 ( 0%)        💩+1865.2% ± 102.6%
Benchmark 3 (3 runs): docker pull alpine:3.19
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          1.40s  ± 12.7ms                              1.39s  … 1.41s                                     0 ( 0%)          - 29.9% ± 52.0%
  peak_rss           30.8MB ±  253KB                              30.6MB … 31.1MB                                    0 ( 0%)        💩+261.0% ±  4.8%
  cpu_cycles         22.3M  ±  492K                               21.9M  … 22.8M                                     0 ( 0%)        ⚡- 36.5% ± 11.1%
  instructions       29.3M  ±  262K                               29.1M  … 29.6M                                     0 ( 0%)        ⚡- 70.3% ±  0.4%
  cache_references    368K  ± 5.09K                                362K  …  371K                                     0 ( 0%)        💩+366.6% ± 10.6%
  cache_misses        149K  ± 7.06K                                144K  …  157K                                     0 ( 0%)        💩+227.8% ± 25.2%
  branch_misses       135K  ± 2.14K                                133K  …  137K                                     0 ( 0%)        💩+229.4% ±  8.4%
```

</details>

## images

List local images (read-only).

| runtime | wall_time (mean ± σ, min … max) | runs |
|---------|---------------------------------|------|
| rind | `1.88ms ±  216us                              1.58ms … 7.96ms                                   87 ( 3%)        0%` | 2629 |
| podman | `16.8ms ± 1.05ms                              15.4ms … 22.8ms                                   13 ( 4%)        💩+791.2% ±  2.5%` | 298 |
| docker | `521ms ± 14.7ms                               500ms …  541ms                                    0 ( 0%)        💩+27589.7% ± 29.3%` | 10 |

<details><summary>raw poop output</summary>

```
Benchmark 1 (2629 runs): /home/redshit/Documents/personal/rind/zig-out/bin/rind images
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          1.88ms ±  216us                              1.58ms … 7.96ms                                   87 ( 3%)        0%
  peak_rss           3.59MB ±  108KB                              3.24MB … 3.79MB                                    7 ( 0%)        0%
  cpu_cycles         1.35M  ± 80.2K                               1.22M  … 2.34M                                   132 ( 5%)        0%
  instructions       1.35M  ±  310                                1.35M  … 1.35M                                    82 ( 3%)        0%
  cache_references   17.7K  ±  297                                15.2K  … 18.7K                                    72 ( 3%)        0%
  cache_misses       4.44K  ± 1.16K                               2.42K  … 12.9K                                    80 ( 3%)        0%
  branch_misses      14.8K  ±  958                                12.0K  … 17.5K                                     0 ( 0%)        0%
Benchmark 2 (298 runs): podman images
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          16.8ms ± 1.05ms                              15.4ms … 22.8ms                                   13 ( 4%)        💩+791.2% ±  2.5%
  peak_rss           45.1MB ±  668KB                              43.2MB … 47.2MB                                    2 ( 1%)        💩+1154.7% ±  0.8%
  cpu_cycles         48.3M  ± 3.85M                               44.3M  … 67.2M                                    34 (11%)        💩+3468.2% ± 10.9%
  instructions       69.6M  ± 3.91M                               66.5M  … 78.9M                                    58 (19%)        💩+5059.8% ± 11.1%
  cache_references    572K  ± 43.8K                                521K  …  687K                                    58 (19%)        💩+3132.3% ±  9.4%
  cache_misses        217K  ± 18.0K                                190K  …  313K                                    16 ( 5%)        💩+4785.3% ± 15.8%
  branch_misses       326K  ± 19.7K                                304K  …  376K                                    61 (20%)        💩+2096.8% ±  5.1%
Benchmark 3 (10 runs): docker images
  measurement          mean ± σ            min … max           outliers         delta
  wall_time           521ms ± 14.7ms                               500ms …  541ms                                    0 ( 0%)        💩+27589.7% ± 29.3%
  peak_rss           33.1MB ±  343KB                              32.7MB … 33.8MB                                    0 ( 0%)        💩+821.6% ±  1.9%
  cpu_cycles         58.1M  ± 2.12M                               53.7M  … 61.1M                                     0 ( 0%)        💩+4190.5% ±  6.8%
  instructions        115M  ±  463K                                114M  …  116M                                     0 ( 0%)        💩+8406.0% ±  1.2%
  cache_references    510K  ± 10.5K                                496K  …  529K                                     0 ( 0%)        💩+2780.6% ±  2.4%
  cache_misses        207K  ± 5.04K                                199K  …  215K                                     0 ( 0%)        💩+4573.8% ± 16.7%
  branch_misses       238K  ± 4.28K                                231K  …  242K                                     0 ( 0%)        💩+1506.0% ±  4.1%
```

</details>

## inspect alpine:3.19

Dump image config JSON for a single local image (read-only).

| runtime | wall_time (mean ± σ, min … max) | runs |
|---------|---------------------------------|------|
| rind | `1.79ms ±  149us                              1.50ms … 2.85ms                                   69 ( 2%)        0%` | 2764 |
| podman | `20.2ms ± 1.62ms                              18.4ms … 31.5ms                                   12 ( 5%)        💩+1028.5% ±  3.5%` | 248 |
| docker | `23.4ms ± 1.63ms                              20.3ms … 32.4ms                                    4 ( 2%)        💩+1206.8% ±  3.6%` | 214 |

<details><summary>raw poop output</summary>

```
Benchmark 1 (2764 runs): /home/redshit/Documents/personal/rind/zig-out/bin/rind inspect alpine:3.19
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          1.79ms ±  149us                              1.50ms … 2.85ms                                   69 ( 2%)        0%
  peak_rss           3.59MB ±  108KB                              3.24MB … 3.79MB                                    6 ( 0%)        0%
  cpu_cycles         1.14M  ± 63.6K                               1.03M  … 2.06M                                   107 ( 4%)        0%
  instructions        966K  ±  307                                 966K  …  968K                                    86 ( 3%)        0%
  cache_references   17.5K  ±  285                                15.2K  … 18.6K                                    89 ( 3%)        0%
  cache_misses       4.20K  ±  962                                2.35K  … 9.73K                                    61 ( 2%)        0%
  branch_misses      11.3K  ±  478                                8.78K  … 12.6K                                     6 ( 0%)        0%
Benchmark 2 (248 runs): podman inspect alpine:3.19
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          20.2ms ± 1.62ms                              18.4ms … 31.5ms                                   12 ( 5%)        💩+1028.5% ±  3.5%
  peak_rss           46.5MB ±  563KB                              45.1MB … 48.0MB                                    0 ( 0%)        💩+1194.9% ±  0.7%
  cpu_cycles         63.7M  ± 2.63M                               52.5M  … 75.8M                                    22 ( 9%)        💩+5499.0% ±  8.6%
  instructions        102M  ± 1.54M                               91.3M  …  106M                                    10 ( 4%)        💩+10503.1% ±  5.9%
  cache_references    716K  ± 21.7K                                587K  …  758K                                    10 ( 4%)        💩+3988.9% ±  4.6%
  cache_misses        258K  ± 16.4K                                213K  …  317K                                     5 ( 2%)        💩+6051.4% ± 14.8%
  branch_misses       402K  ± 9.11K                                345K  …  444K                                     7 ( 3%)        💩+3470.5% ±  3.1%
Benchmark 3 (214 runs): docker inspect alpine:3.19
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          23.4ms ± 1.63ms                              20.3ms … 32.4ms                                    4 ( 2%)        💩+1206.8% ±  3.6%
  peak_rss           30.6MB ±  335KB                              29.8MB … 31.4MB                                    1 ( 0%)        💩+750.7% ±  0.5%
  cpu_cycles         23.3M  ± 1.15M                               21.6M  … 28.4M                                     9 ( 4%)        💩+1948.0% ±  3.8%
  instructions       30.7M  ±  390K                               30.0M  … 32.4M                                     5 ( 2%)        💩+3080.6% ±  1.5%
  cache_references    365K  ± 7.75K                                340K  …  389K                                     5 ( 2%)        💩+1986.6% ±  1.7%
  cache_misses        148K  ± 6.31K                                132K  …  167K                                     0 ( 0%)        💩+3417.8% ±  6.4%
  branch_misses       140K  ± 2.21K                                135K  …  146K                                     0 ( 0%)        💩+1146.5% ±  0.9%
```

</details>

## run --rm alpine:3.19 /bin/true

Container start + run + teardown round-trip. Target: <80ms (docs/rind.md:42).

| runtime | wall_time (mean ± σ, min … max) | runs |
|---------|---------------------------------|------|
| rind | `14.1ms ± 1.08ms                              12.7ms … 24.2ms                                   15 ( 4%)        0%` | 355 |
| podman | `180ms ± 5.58ms                               169ms …  198ms                                    1 ( 4%)        💩+1176.2% ±  5.0%` | 28 |
| docker | `451ms ± 17.3ms                               431ms …  499ms                                    1 ( 8%)        💩+3107.6% ± 13.0%` | 12 |

<details><summary>raw poop output</summary>

```
Benchmark 1 (355 runs): /home/redshit/Documents/personal/rind/zig-out/bin/rind run --rm alpine:3.19 /bin/true
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          14.1ms ± 1.08ms                              12.7ms … 24.2ms                                   15 ( 4%)        0%
  peak_rss           4.53MB ±  147KB                              4.15MB … 4.80MB                                    0 ( 0%)        0%
  cpu_cycles         4.10M  ±  184K                               3.87M  … 5.04M                                    23 ( 6%)        0%
  instructions       4.68M  ±  335                                4.68M  … 4.68M                                    12 ( 3%)        0%
  cache_references   47.5K  ±  898                                45.4K  … 50.0K                                     2 ( 1%)        0%
  cache_misses       23.8K  ± 1.52K                               20.7K  … 30.2K                                     4 ( 1%)        0%
  branch_misses      34.0K  ± 1.53K                               32.6K  … 60.6K                                     3 ( 1%)        0%
Benchmark 2 (28 runs): podman run --rm alpine:3.19 /bin/true
  measurement          mean ± σ            min … max           outliers         delta
  wall_time           180ms ± 5.58ms                               169ms …  198ms                                    1 ( 4%)        💩+1176.2% ±  5.0%
  peak_rss           51.1MB ±  414KB                              50.5MB … 52.2MB                                    1 ( 4%)        💩+1027.8% ±  1.5%
  cpu_cycles          194M  ± 9.28M                                186M  …  221M                                     3 (11%)        💩+4640.0% ± 23.2%
  instructions        261M  ± 10.1M                                254M  …  291M                                     3 (11%)        💩+5485.6% ± 22.1%
  cache_references   2.42M  ± 95.7K                               2.33M  … 2.66M                                     3 (11%)        💩+4996.3% ± 20.7%
  cache_misses       1.03M  ± 43.7K                                956K  … 1.10M                                     0 ( 0%)        💩+4213.3% ± 19.0%
  branch_misses      1.17M  ± 43.0K                               1.13M  … 1.30M                                     3 (11%)        💩+3356.1% ± 13.1%
Benchmark 3 (12 runs): docker run --rm alpine:3.19 /bin/true
  measurement          mean ± σ            min … max           outliers         delta
  wall_time           451ms ± 17.3ms                               431ms …  499ms                                    1 ( 8%)        💩+3107.6% ± 13.0%
  peak_rss           31.2MB ±  205KB                              30.9MB … 31.6MB                                    0 ( 0%)        💩+589.1% ±  1.9%
  cpu_cycles         27.1M  ±  528K                               25.9M  … 27.6M                                     1 ( 8%)        💩+560.8% ±  2.8%
  instructions       33.1M  ±  517K                               32.5M  … 34.0M                                     0 ( 0%)        💩+608.1% ±  1.1%
  cache_references    456K  ± 8.92K                                449K  …  474K                                     0 ( 0%)        💩+861.5% ±  2.2%
  cache_misses        180K  ± 6.33K                                171K  …  192K                                     0 ( 0%)        💩+656.6% ±  4.5%
  branch_misses       164K  ± 2.48K                                160K  …  167K                                     0 ( 0%)        💩+382.3% ±  2.7%
```

</details>

## ps -a

List containers (5 stopped pre-created per runtime). Exercises /proc reconcile (src/cli/ps.zig:129).

| runtime | wall_time (mean ± σ, min … max) | runs |
|---------|---------------------------------|------|
| rind | `1.78ms ±  157us                              1.47ms … 2.70ms                                   91 ( 3%)        0%` | 2765 |
| podman | `19.5ms ± 1.31ms                              17.8ms … 26.0ms                                    3 ( 1%)        💩+993.9% ±  2.9%` | 256 |
| docker | `186ms ± 5.18ms                               178ms …  197ms                                    0 ( 0%)        💩+10325.6% ± 11.1%` | 27 |

<details><summary>raw poop output</summary>

```
Benchmark 1 (2765 runs): /home/redshit/Documents/personal/rind/zig-out/bin/rind ps -a
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          1.78ms ±  157us                              1.47ms … 2.70ms                                   91 ( 3%)        0%
  peak_rss           3.44MB ±  112KB                              3.11MB … 3.66MB                                    2 ( 0%)        0%
  cpu_cycles         1.09M  ± 66.9K                                983K  … 1.65M                                   137 ( 5%)        0%
  instructions        934K  ±  316                                 933K  …  935K                                    85 ( 3%)        0%
  cache_references   17.0K  ±  296                                14.3K  … 17.9K                                   109 ( 4%)        0%
  cache_misses       3.79K  ± 1.00K                               2.07K  … 10.1K                                    78 ( 3%)        0%
  branch_misses      10.2K  ±  415                                8.01K  … 11.2K                                    13 ( 0%)        0%
Benchmark 2 (256 runs): podman ps -a
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          19.5ms ± 1.31ms                              17.8ms … 26.0ms                                    3 ( 1%)        💩+993.9% ±  2.9%
  peak_rss           46.3MB ±  481KB                              45.0MB … 47.4MB                                    0 ( 0%)        💩+1244.0% ±  0.7%
  cpu_cycles         63.2M  ± 2.38M                               59.1M  … 75.5M                                    10 ( 4%)        💩+5717.0% ±  8.2%
  instructions       95.0M  ± 1.72M                               92.2M  …  114M                                     9 ( 4%)        💩+10076.4% ±  6.8%
  cache_references    722K  ± 13.1K                                684K  …  755K                                     1 ( 0%)        💩+4142.5% ±  2.9%
  cache_misses        257K  ± 14.6K                                228K  …  300K                                     2 ( 1%)        💩+6662.1% ± 14.7%
  branch_misses       407K  ± 6.08K                                389K  …  431K                                     3 ( 1%)        💩+3883.0% ±  2.3%
Benchmark 3 (27 runs): docker ps -a
  measurement          mean ± σ            min … max           outliers         delta
  wall_time           186ms ± 5.18ms                               178ms …  197ms                                    0 ( 0%)        💩+10325.6% ± 11.1%
  peak_rss           32.6MB ±  331KB                              32.1MB … 33.2MB                                    0 ( 0%)        💩+846.3% ±  1.3%
  cpu_cycles         53.4M  ± 2.16M                               50.8M  … 62.3M                                     1 ( 4%)        💩+4809.3% ±  7.6%
  instructions       99.5M  ±  942K                               97.9M  …  102M                                     0 ( 0%)        💩+10557.9% ±  3.7%
  cache_references    515K  ± 12.2K                                495K  …  534K                                     0 ( 0%)        💩+2923.8% ±  2.7%
  cache_misses        203K  ± 6.23K                                193K  …  217K                                     0 ( 0%)        💩+5245.7% ± 11.6%
  branch_misses       256K  ± 5.60K                                243K  …  266K                                     0 ( 0%)        💩+2407.3% ±  2.5%
```

</details>
