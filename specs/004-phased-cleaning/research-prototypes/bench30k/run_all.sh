#!/bin/zsh
B="$(cd "$(dirname "$0")" && pwd)"
X=$B/.build/release/bench30k
cd $B
L=$B/results-release.log
: > $L
r() { echo "### $*" >> $L; $X "$@" 2>&1 | grep -v '^GEN' >> $L; }
for n in 5000 10000 20000 30000; do r build n=$n runs=2; done
for n in 5000 10000 20000 30000; do r dup n=$n; done
r detectors n=30000
r similar n=30000
r similar n=30000 pool=$B/pool.bin
r similar n=30000 dense=3000
r planner n=30000
r dup n=10000 clustered=0.15
r dup n=30000 clustered=0.05
r dup n=30000 clustered=0.15
r build n=30000 pool=$B/pool.bin
mkdir -p $B/stores
r store-write n=30000 folder=$B/stores/upsert mode=upsert pool=$B/pool.bin
r store-read folder=$B/stores/upsert
r store-write n=30000 folder=$B/stores/ckpt mode=checkpoint pool=$B/pool.bin
r store-read folder=$B/stores/ckpt
echo "### DONE" >> $L
