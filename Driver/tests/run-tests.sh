#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
rm -f /tmp/nn_ring_test
clang -std=c11 -Wall -Wextra -O2 test_nn_ring.c ../NoNoiseMic/nn_ring.c -o /tmp/nn_ring_test
/tmp/nn_ring_test
