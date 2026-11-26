#!/bin/busybox sh
# Image /bin/sh. The job container's entrypoint is replaced by the runner;
# this shell is what `docker exec sh -e <step>` runs for every run step.
set +e

if [ -n "${TREE_SITTER_OUTPUT_DIR:-}" ] && [ -n "${PAYLOAD_RPM:-}" ]; then
  mkdir -p "$TREE_SITTER_OUTPUT_DIR"
  cp -f "$PAYLOAD_RPM" "$TREE_SITTER_OUTPUT_DIR/$(basename "$PAYLOAD_RPM")"
  printf '%s\n' '{"parsers":{}}' > "$TREE_SITTER_OUTPUT_DIR/tree-sitter-manifest.json"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s\n' "changed=true" >> "$GITHUB_OUTPUT"
  fi
fi

if [ -n "${GH_TOKEN:-}" ] && [ -n "${PAYLOAD_DEB:-}" ]; then
  tag="tree-sitter-$(date -u +%Y-%m-%d)"
  if ! gh release view "$tag" >/dev/null 2>&1; then
    gh release create "$tag" "$PAYLOAD_DEB" --title "$tag" --notes payload
  fi
fi

exit 0
