#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
cd "$(dirname "$0")/.."
# A separate run keeps other fixtures and their WebKit processes out of samples.
# Records contain no browsing URLs or persisted profile identifiers.
EARLY_LIFECYCLE_BENCHMARK=1 swift test -c release --no-parallel --filter LifecyclePerformanceTests
