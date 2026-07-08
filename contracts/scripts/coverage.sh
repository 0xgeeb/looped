#!/usr/bin/env bash
set -euo pipefail

forge coverage --no-match-contract "LoopedMainnetForkPlaygroundTest" --report lcov --ffi --ir-minimum

lcov --remove lcov.info -o lcov.info 'scripts/*' 'test/*' --rc lcov_branch_coverage=1

genhtml lcov.info -o ./coverage --branch-coverage

rm -f lcov.info
