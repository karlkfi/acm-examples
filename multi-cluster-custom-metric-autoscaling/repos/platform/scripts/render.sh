#!/usr/bin/env bash

# Render kustomizations

set -o errexit -o nounset -o pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${REPO_ROOT}"

CLUSTERS=(
    "cluster-east"
    "cluster-west"
)

for cluster in "${CLUSTERS[@]}"; do
    echo "Rendering clusters/${cluster}/"
    kustomize build config/clusters/${cluster}/ > deploy/clusters/${cluster}/rendered.yaml
done
