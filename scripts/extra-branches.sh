#!/usr/bin/env bash
set -euo pipefail

grep -vxE 'main|testing' || true
