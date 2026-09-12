#!/usr/bin/env bash
# Install the Qwen3.8-Next-Flash configuration.
#
# Same runtime and engine build as install.sh -- the retained-PM4 ROCr/HIP prefixes and the
# strix-halo llama.cpp branch -- but a different model set and a launcher tuned for the
# 24576-token prefill path. Kept as a separate entry point because the disk and memory
# requirements are much larger than the 27B configuration's.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/pwilkin/strix-halo/main/install-flash-next.sh)
#
# Every flag install.sh accepts is forwarded, so --check-only and --model-dir work here too.

set -Eeuo pipefail
IFS=$'\n\t'

readonly installer_url=https://raw.githubusercontent.com/pwilkin/strix-halo/main/install.sh

printf '%s\n' \
  'Qwen3.8-Next-Flash: 177B parameters, 93 GiB of IQ4_NL weights plus a 2.8 GB draft.' \
  'Needs ~110 GiB free on the model disk and a 128 GB unified-memory machine.' \
  'Prefill is the tuned path; decode is still behind where it should be.' \
  ''

# Prefer a sibling install.sh when this script was downloaded as part of the repo, so a
# local checkout is not silently bypassed in favour of whatever main happens to hold.
self_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P || true)
if [[ -n ${self_dir:-} && -r $self_dir/install.sh ]]; then
  STRIX_PROFILE=flash-next exec bash "$self_dir/install.sh" "$@"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "$installer_url" -o "$tmp/install.sh"
STRIX_PROFILE=flash-next exec bash "$tmp/install.sh" "$@"
