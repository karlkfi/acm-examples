#!/usr/bin/env bash

# Render kustomizations

set -o errexit -o nounset -o pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${REPO_ROOT}"

CLUSTERS=(
    "cluster-east"
    "cluster-west"
)
NAMESPACES=(
    "pubsub-sample"
)

for cluster in "${CLUSTERS[@]}"; do
    for namespace in "${NAMESPACES[@]}"; do
        echo "Rendering clusters/${cluster}/namespaces/${namespace}/"
        kustomize build config/clusters/${cluster}/namespaces/${namespace}/ > deploy/clusters/${cluster}/namespaces/${namespace}/rendered.yaml
    done
done
