#!/bin/bash
set -eu

exec node --test "$(dirname "$0")/SparkleAppcastVerificationTests.mjs"
