#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

android_scripts=(
  action.sh
  customize.sh
  post-fs-data.sh
  service.sh
  uninstall.sh
  maodie/scripts/NoAdsService.sh
  maodie/scripts/configctl.sh
  maodie/scripts/core.sh
  maodie/scripts/monitor.sh
  maodie/scripts/network.sh
  maodie/scripts/adblock-recovery.sh
  maodie/scripts/adblock-recovery-service.sh
)

for script in "${android_scripts[@]}"; do
  bash -n "$script"
  if command -v dash >/dev/null 2>&1; then
    dash -n "$script"
  fi
  if LC_ALL=C grep -q $'\r' "$script"; then
    printf 'CRLF is not allowed in Android script: %s\n' "$script" >&2
    exit 1
  fi
done

bash -n build.sh

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -s ksh -S error "${android_scripts[@]}"
  shellcheck -s bash -S error build.sh
fi

grep -Eq '^allow-lan:[[:space:]]*false([[:space:]]|$)' maodie/config/config.yaml
grep -Eq '^external-controller:[[:space:]]*127\.0\.0\.1:' maodie/config/config.yaml
grep -Eq '^secret:' maodie/config/config.yaml
grep -Eq '^external-ui:[[:space:]]*\./webui([[:space:]]|$)' maodie/config/config.yaml
if grep -Eq '^global-client-fingerprint:' maodie/config/config.yaml; then
  printf 'Removed Mihomo option global-client-fingerprint must not return.\n' >&2
  exit 1
fi

# Android mksh treats `|` as an extended-pattern operator in parameter
# expansion, and closes high-numbered descriptors before executing Toybox
# flock. These exact regressions were found on a rooted Android device.
if grep -Fq 'last_boot=${state%%|*}' maodie/scripts/monitor.sh \
    || grep -Fq 'raw_tun_enable=${parsed%%|*}' maodie/scripts/network.sh; then
  printf 'Android mksh-incompatible pipe splitting detected.\n' >&2
  exit 1
fi
if grep -Fq 'exec 9>"$LOCK_FILE"' maodie/scripts/configctl.sh; then
  printf 'Android mksh cannot pass high-numbered lock FDs to Toybox flock.\n' >&2
  exit 1
fi

printf 'Static checks passed for %d Android scripts.\n' "${#android_scripts[@]}"
