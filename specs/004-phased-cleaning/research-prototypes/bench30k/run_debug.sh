#!/bin/zsh
B="$(cd "$(dirname "$0")" && pwd)"
cd $B
L=$B/results-debug.log
: > $L
swift build -c debug >> $B/debug-build.log 2>&1
X=$B/.build/debug/bench30k
r() { echo "### $*" >> $L; $X "$@" 2>&1 | grep -E '^(GEN|BUILD|DUP|SIMILAR|PAIR|STOREREAD|LAUNCH|START|DETECT)' >> $L; }
r pair n=5000
r build n=10000 runs=1
r build n=30000 runs=1
r dup n=30000
r similar n=30000
r store-read folder=$B/stores/ckpt
echo "### DONE" >> $L
