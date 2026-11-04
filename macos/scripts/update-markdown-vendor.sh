#!/usr/bin/env bash
# Refreshes the JavaScript libraries the Markdown preview bundles (offline, no CDN at runtime).
# Keep MERMAID in step with client/package.json so diagrams render the same as the web app.
set -euo pipefail

MERMAID=${MERMAID:-11.12.3}
MARKED=${MARKED:-15.0.12}
HLJS=${HLJS:-11.11.1}

here=$(cd "$(dirname "$0")/.." && pwd)
out="$here/ByteStash/Resources/MarkdownPreview/vendor"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cd "$tmp"
for pkg in "mermaid@$MERMAID" "marked@$MARKED" "@highlightjs/cdn-assets@$HLJS"; do
  npm pack "$pkg" --silent >/dev/null
done
for f in *.tgz; do mkdir "${f%.tgz}" && tar xzf "$f" -C "${f%.tgz}"; done

mkdir -p "$out"
cp "mermaid-$MERMAID/package/dist/mermaid.min.js" "$out/"
cp "marked-$MARKED/package/marked.min.js" "$out/"
cp "highlightjs-cdn-assets-$HLJS/package/highlight.min.js" "$out/"
cp "highlightjs-cdn-assets-$HLJS/package/styles/github.min.css" "$out/hljs-github.min.css"
cp "highlightjs-cdn-assets-$HLJS/package/styles/github-dark.min.css" "$out/hljs-github-dark.min.css"

{
  echo "Third-party libraries bundled for the Markdown preview. Update with macos/scripts/update-markdown-vendor.sh."
  echo
  for entry in "mermaid $MERMAID:mermaid-$MERMAID/package/LICENSE" \
               "marked $MARKED:marked-$MARKED/package/LICENSE.md" \
               "highlight.js $HLJS:highlightjs-cdn-assets-$HLJS/package/LICENSE"; do
    echo "================ ${entry%%:*} ================"
    cat "${entry#*:}"
    echo
  done
} > "$out/LICENSES.txt"

echo "Updated $out"
