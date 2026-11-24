#!/bin/bash
# Performs no service changes: tests an untracked label, an archive collision and a symlink in a disposable home.
set -euo pipefail
umask 077
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/backgrounddesk-guards.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
home="$(cd "$tmp" && pwd -P)/home"; mkdir -m 700 "$home"
swiftc "$root/Sources/BackgroundDesk/Job.swift" "$root/Sources/BackgroundDesk/AgentEngine.swift" "$root/scripts/VerifyGuards.swift" -o "$tmp/check"
"$tmp/check" "$home"
