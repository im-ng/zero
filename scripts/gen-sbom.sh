#!/usr/bin/env bash
# Generate a merged CycloneDX SBOM for the `zero` binary.
#
# Two SBOM fragments are combined into one `final-sbom.json`:
#   * source SBOM  (cdxgen)  — captures build.zig.zon / zig-pkg dependencies
#   * binary SBOM  (syft)    — captures the compiled ./zig-out/bin/zero artifact
# CycloneDX's own CLI merges them, resolving overlapping components.
# See sbom-integration.md for the rationale.
#
# Prerequisites: cdxgen, syft, cyclonedx-cli on PATH.
#   npm install -g @cyclonedx/cdxgen @cyclonedx/cyclonedx-cli
#   curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b /usr/local/bin
set -euo pipefail

# Override with ZERO_BUILD_CMD to pass custom flags or a target triple.
: "${ZERO_BUILD_CMD:=zig build --release=fast}"

for tool in cdxgen syft cyclonedx-cli; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: required tool '$tool' not found on PATH" >&2
        echo "  cdxgen/cyclonedx-cli: npm install -g @cyclonedx/cdxgen @cyclonedx/cyclonedx-cli" >&2
        echo "  syft:                curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b /usr/local/bin" >&2
        exit 1
    fi
done

echo "==> building zero"
$ZERO_BUILD_CMD

echo "==> source SBOM (cdxgen)"
cdxgen -t zig -o source-sbom.json

echo "==> binary SBOM (syft)"
syft scan "file:./zig-out/bin/zero" -o cyclonedx-json=binary-sbom.json

echo "==> merging SBOMs (cyclonedx-cli)"
cyclonedx-cli merge \
    --input-files source-sbom.json binary-sbom.json \
    --output-file final-sbom.json

echo "==> wrote final-sbom.json"
ls -la final-sbom.json
