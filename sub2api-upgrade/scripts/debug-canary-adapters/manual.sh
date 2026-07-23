#!/usr/bin/env bash
# Manual adapter: always requires human action.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
printf '%s\n' "[adapter-manual] case=${ADAPTER_CASE_ID:-unknown} needs manual verification" >&2
exit 78
