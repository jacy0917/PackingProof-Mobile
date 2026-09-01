#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

base_ref="${1:-}"
case "$base_ref" in
  ""|0000000000000000000000000000000000000000)
    base_ref="$(git rev-list --max-parents=0 HEAD | tail -n 1)"
    ;;
esac

if ! base_commit="$(git rev-parse --verify "${base_ref}^{commit}" 2>/dev/null)"; then
  base_commit="$(git rev-parse --verify "HEAD^{commit}^")"
  echo "差异基准 ${base_ref} 不可用，改用 ${base_commit}" >&2
fi

git diff --check "${base_commit}...HEAD" -- .
