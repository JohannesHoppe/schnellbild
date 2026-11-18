#!/bin/bash
# Fails unless a release tag names the version the app carries: v<x.y.z> must
# be Resources/Info.plist's CFBundleShortVersionString and project.yml's
# MARKETING_VERSION, and the build number (CFBundleVersion) must be
# project.yml's CURRENT_PROJECT_VERSION. A published tag is never moved or
# rebuilt, so release.yml checks this before it builds anything.
#   Scripts/check_release_version.sh <tag> [<repository folder>]
set -euo pipefail
TAG="${1:?usage: check_release_version.sh <tag> [<repository folder>]}"
ROOT="${2:-$(cd "$(dirname "$0")/.." && pwd)}"

plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$ROOT/Resources/Info.plist"; }
# A build setting of project.yml: `    NAME: "value"`
setting() { sed -nE "s/^[[:space:]]+$1:[[:space:]]*\"?([^\"[:space:]]+)\"?[[:space:]]*(#.*)?$/\\1/p" "$ROOT/project.yml" | head -1; }

version="$(plist CFBundleShortVersionString)"
build="$(plist CFBundleVersion)"
marketing="$(setting MARKETING_VERSION)"
project_build="$(setting CURRENT_PROJECT_VERSION)"

status=0
if [ "$TAG" != "v$version" ]; then
  echo "error: the tag $TAG doesn't name the app's version: Resources/Info.plist says $version" >&2
  status=1
fi
if [ "$marketing" != "$version" ]; then
  echo "error: project.yml's MARKETING_VERSION ($marketing) isn't Resources/Info.plist's version ($version)" >&2
  status=1
fi
if [ "$project_build" != "$build" ]; then
  echo "error: project.yml's CURRENT_PROJECT_VERSION ($project_build) isn't Resources/Info.plist's CFBundleVersion ($build)" >&2
  status=1
fi
[ "$status" = 0 ] && echo "Version $version (build $build) for $TAG"
exit "$status"
