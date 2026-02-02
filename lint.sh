#!/usr/bin/env bash

set -ex

zig fmt build.zig src --check
zig build
