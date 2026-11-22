#!/bin/bash
# Build a self-contained local macOS application using the system Swift toolchain.
#
# Signing: the default is an ad hoc signature for this machine. If
# ARENA_SIGN_IDENTITY is set, codesign uses exactly that identity; an invalid
# identity fails the build and never falls back to ad hoc.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$root/desktop/build}"
mkdir -p "$out"
tmp="$(mktemp -d "$out/.arena-build.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
app="$tmp/AI Arena.app"
resources="$app/Contents/Resources"
mkdir -p "$resources" "$app/Contents/MacOS"
cp "$root/desktop/Info.plist" "$app/Contents/Info.plist"
icon="$root/desktop/assets/ArenaIcon.icns"
if [[ -s "$icon" ]]; then
  cp "$icon" "$resources/ArenaIcon.icns"
fi
cp "$root/extension/web-driver.js" "$resources/"
node --input-type=module - "$root" "$resources" <<'JS'
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
const [root, resources] = process.argv.slice(2);
const source = name => path.join(root, 'extension', name + '.js');
const { webSiteConfig } = await import(pathToFileURL(source('provider-web-configs')));
const sites = Object.fromEntries(['chatgpt', 'gemini', 'deepseek'].map(id => [id, webSiteConfig(id)]));
fs.writeFileSync(path.join(resources, 'sites.json'), JSON.stringify(sites));
const core = ['providers', 'core'].map(name => fs.readFileSync(source(name), 'utf8')
  .replace(/^import .* from ['"].*['"];\s*$/gm, '')
  .replace(/^export (?=(const|function) )/gm, '')).join('\n');
fs.writeFileSync(path.join(resources, 'arena-core.js'), core);
JS
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos13.0" -parse-as-library -O -framework WebKit -framework SwiftUI -framework JavaScriptCore "$root"/desktop/*.swift -o "$app/Contents/MacOS/AIArena"

identity="${ARENA_SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity="-"
  printf '%s\n' 'signing: ad hoc (set ARENA_SIGN_IDENTITY to use an existing codesigning certificate)'
else
  printf 'signing: explicit identity %s\n' "$identity"
fi
codesign --force --sign "$identity" "$app"
codesign --verify --strict "$app"
details="$(codesign -d --verbose=2 "$app" 2>&1)"
if [[ "$identity" == "-" ]]; then
  grep -q 'Signature=adhoc' <<<"$details" || {
    printf '%s\n' 'error: expected an ad hoc signature on the built app' >&2
    exit 1
  }
else
  if grep -q 'Signature=adhoc' <<<"$details"; then
    printf '%s\n' "error: requested signing identity was not applied; refusing to continue" >&2
    exit 1
  fi
fi
if [[ -s "$icon" ]]; then
  test -s "$resources/ArenaIcon.icns" || {
    printf '%s\n' 'error: icon resource missing from the built bundle' >&2
    exit 1
  }
fi
if [[ -e "$out/AI Arena.app" ]]; then
  test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$out/AI Arena.app/Contents/Info.plist")" = "local.ai-arena.desktop"
  mv "$out/AI Arena.app" "$tmp/previous.app"
fi
if ! mv "$app" "$out/AI Arena.app"; then
  [[ ! -d "$tmp/previous.app" ]] || mv "$tmp/previous.app" "$out/AI Arena.app"
  exit 1
fi
printf '%s\n' "$out/AI Arena.app"
