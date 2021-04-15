#!/usr/bin/env bash

# Render kustomizations

set -o errexit -o nounset -o pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${REPO_ROOT}"

cd config/
for CLUSTER_PATH in clusters/*/; do
    echo "Rendering ${CLUSTER_PATH}"
    mkdir -p ../deploy/${CLUSTER_PATH}
    kustomize build ${CLUSTER_PATH} > ../deploy/${CLUSTER_PATH}manifest.yaml
    for NAMESPACE_PATH in ${CLUSTER_PATH}namespaces/*/ ; do
        echo "Rendering ${NAMESPACE_PATH}"
        mkdir -p ../deploy/${NAMESPACE_PATH}
        kustomize build ${NAMESPACE_PATH} > ../deploy/${NAMESPACE_PATH}manifest.yaml
    done
done
