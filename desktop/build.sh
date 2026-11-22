#!/bin/bash
# Build a self-contained local macOS application using the system Swift toolchain.
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
codesign --force --sign - "$app"
codesign --verify --strict "$app"
if [[ -e "$out/AI Arena.app" ]]; then
  test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$out/AI Arena.app/Contents/Info.plist")" = "local.ai-arena.desktop"
  mv "$out/AI Arena.app" "$tmp/previous.app"
fi
if ! mv "$app" "$out/AI Arena.app"; then
  [[ ! -d "$tmp/previous.app" ]] || mv "$tmp/previous.app" "$out/AI Arena.app"
  exit 1
fi
printf '%s\n' "$out/AI Arena.app"
