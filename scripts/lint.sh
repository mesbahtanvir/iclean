#!/usr/bin/env bash
# Lints Swift sources with the toolchain's swift-format.
set -euo pipefail
cd "$(dirname "$0")/.."
swift format lint --recursive iclean Packages/CleanupKit/Sources Packages/CleanupKit/Tests icleanUITests
