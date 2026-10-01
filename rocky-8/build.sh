#!/usr/bin/env bash
exec "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../build.sh" "$(basename "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")" "$@"
