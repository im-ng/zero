#!/usr/bin/env bash
# Generate a CycloneDX SBOM for zero from build.zig.zon.
#
# cdxgen and syft cannot read a Zig project: cdxgen exits 0 with an empty BOM
# when given `-t zig`, and syft finds no packages in a Zig binary. Build the
# component list from the manifest Zig itself resolves instead, so the SBOM
# always reflects the pinned dependencies. Fail if the result has no components.
set -euo pipefail

manifest="${ZERO_MANIFEST:-build.zig.zon}"
output="${ZERO_SBOM:-final-sbom.json}"

for tool in awk jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: required tool '$tool' not found on PATH" >&2
        exit 1
    fi
done

if [ ! -f "$manifest" ]; then
    echo "error: manifest '$manifest' not found" >&2
    exit 1
fi

project_name=$(sed -n 's/^[[:space:]]*\.name[[:space:]]*=[[:space:]]*\.\([A-Za-z0-9_]*\).*/\1/p' "$manifest" | head -1)
project_version=$(sed -n 's/^[[:space:]]*\.version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$manifest" | head -1)

if [ -z "$project_name" ] || [ -z "$project_version" ]; then
    echo "error: could not read .name / .version from '$manifest'" >&2
    exit 1
fi

# Emit one TSV row per dependency: name, git URL, Zig package hash. A row is
# completed only when both .url and .hash appear inside a dependency block.
deps=$(
    awk '
        /^[[:space:]]*\.[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*\.[{][[:space:]]*$/ {
            dep = $0
            sub(/^[[:space:]]*\./, "", dep)
            sub(/[[:space:]]*=.*/, "", dep)
            url = ""
            next
        }
        /^[[:space:]]*\.url[[:space:]]*=/ && dep != "" {
            line = $0
            sub(/^[^"]*"/, "", line)
            sub(/".*$/, "", line)
            url = line
            next
        }
        /^[[:space:]]*\.hash[[:space:]]*=/ && dep != "" {
            line = $0
            sub(/^[^"]*"/, "", line)
            sub(/".*$/, "", line)
            if (url != "") {
                print dep "\t" url "\t" line
            }
            dep = ""
            url = ""
        }
    ' "$manifest"
)

if [ -z "$deps" ]; then
    echo "error: no dependencies found in '$manifest'" >&2
    exit 1
fi

# The version lives in the hash prefix: <name>-<version>-<zig-hash>.
bad=$(printf '%s\n' "$deps" | awk -F '\t' '$3 !~ /^[^-]+-[0-9]/ { print }')
if [ -n "$bad" ]; then
    echo "error: could not parse version from dependency hash:" >&2
    printf '%s\n' "$bad" >&2
    exit 1
fi

components=$(
    printf '%s\n' "$deps" | jq -R -s '
        split("\n")
        | map(select(length > 0))
        | map(
            split("\t") as $d
            | ($d[2] | split("-")[1]) as $version
            | {
                type: "library",
                name: $d[0],
                version: $version,
                "bom-ref": ("pkg:generic/" + $d[0] + "@" + $version),
                purl: ("pkg:generic/" + $d[0] + "@" + $version),
                properties: [
                    { name: "zig:url", value: $d[1] },
                    { name: "zig:package-hash", value: $d[2] }
                ],
                externalReferences: [
                    {
                        type: "vcs",
                        url: ($d[1] | sub("^git\\+"; "") | sub("#.*$"; ""))
                    }
                ]
            }
        )
    '
)

serial=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || true)

jq -n \
    --arg name "$project_name" \
    --arg version "$project_version" \
    --arg serial "$serial" \
    --argjson components "$components" \
    '{
        bomFormat: "CycloneDX",
        specVersion: "1.6",
        version: 1,
        metadata: {
            timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
            tools: [ { vendor: "zero", name: "scripts/gen-sbom.sh", version: "1.0.0" } ],
            lifecycles: [ { phase: "build" } ],
            component: {
                type: "application",
                name: $name,
                version: $version,
                "bom-ref": ("pkg:generic/" + $name + "@" + $version),
                purl: ("pkg:generic/" + $name + "@" + $version)
            }
        },
        components: $components,
        dependencies: [
            {
                ref: ("pkg:generic/" + $name + "@" + $version),
                dependsOn: [ $components[]."bom-ref" ]
            }
        ]
    }
    | if $serial == "" then . else . + { serialNumber: ("urn:uuid:" + $serial) } end' > "$output"

count=$(jq '.components | length' "$output")
expected=$(printf '%s\n' "$deps" | grep -c .)
if [ "$count" -eq 0 ] || [ "$count" -ne "$expected" ]; then
    echo "error: SBOM has $count components, expected $expected" >&2
    exit 1
fi

echo "==> wrote $output with $count components"
