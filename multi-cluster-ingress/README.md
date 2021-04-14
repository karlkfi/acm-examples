# Multi-Cluster Ingress

This examples shows how to manage a service with Multi-Cluster Ingress using Anthos Config Management and GitOps, with kustomize overlays to reduce duplicate configuration.

## Clusters

- **cluster-east** - A multi-zone GKE cluster in the us-east1 region.
- **cluster-west** - A multi-zone GKE cluster in the us-west1 region.

## Tenant Workloads

This example demonstrates one tenant with a workload that span multiple clusters:

- **zoneprinter** - an echo service behind Multi-Cluster Ingress

## Filesystem Hierarchy

**Platform Repo (`repos/platform/`):**

- `config/` - pre-render resources
    - `clusters/`
        - `${cluster-name}/`
            - `kustomization.yaml` - cluster-specific overlays
    - `common/`
        - `kustomization.yaml` - common overlays
        - `namespaces.yaml` - common namespaces
- `deploy/` - post-render resources
    - `clusters/`
        - `${cluster-name}/`
            - `rendered.yaml` - cluster-specific post-render resources
- `scripts/`
    - `render.sh` - script to render kustomize overlays from `config/` to `deploy/`

**ZonePrinter Repo (`repos/zoneprinter/`):**

- `config/` - pre-render resources
    - `clusters/`
        - `${cluster-name}/`
            - `namespaces/`
                - `${namespace}/`
                    - `kustomization.yaml` - cluster-specific and namespace-specific overlays
                    - `${name}-${kind}.yaml` - cluster-specific and namespace-specific resources
    - `common/`
        - `${cluster-name}/`
            - `namespaces/`
                - `${namespace}/`
                    - `kustomization.yaml` - cluster-agnostic but namespace-specific overlays
                    - `${name}-${kind}.yaml` - cluster-agnostic but namespace-specific resources
- `deploy/` - post-render resources
    - `clusters/`
        - `${cluster-name}/`
            - `namespaces/`
                - `${namespace}/`
                    - `rendered.yaml` - cluster-specific and namespace-specific post-render resources
- `scripts/`
    - `render.sh` - script to render kustomize overlays from `config/` to `deploy/`

## Kustomize

Resources often differ between multiple clusters or multiple namespaces.

For example, MultiClusterIngress resources need to be on one specific cluster in an Environ that is designated as the management server.

Resources also often share common attributes between multiple clusters or multiple namespaces.

For example, each resource deployed as part of the zoneprinter workload may need a common `app: zoneprinter` label to aid observability.

This example uses Kustomize to render the resources under `config/` and write them to `deploy/`.
This allows for both differences and similarities between resources deployed to multiple clusters, and lays the ground work for supporting multiple namespaces as well.

ConfigSync is then configured on each cluster to watch a cluster-specific subdirectory under `deploy/`, in the same repository.

## Before you begin

1. Create or select a project.
2. Make sure that billing is enabled for your Cloud project. [Learn how to confirm that billing is enabled for your project](https://cloud.google.com/billing/docs/how-to/modify-project).

## Setting up your environment

**Configure your default Google Cloud `PROJECT_ID`:**

```
PROJECT_ID="PROJECT_ID"
gcloud config set project ${PROJECT_ID}
```

**Enable required GCP services:**

```
gcloud services enable \
    container.googleapis.com \
    anthos.googleapis.com \
    gkeconnect.googleapis.com \
    gkehub.googleapis.com \
    cloudresourcemanager.googleapis.com
```

**Deploy the GKE clusters:**

```
gcloud container clusters create cluster-west \
    --region us-west1 \
    --workload-pool=${PROJECT_ID}.svc.id.goog
gcloud container clusters create cluster-east \
    --region us-east1 \
    --workload-pool=${PROJECT_ID}.svc.id.goog
```

**Create a Git repository for the Platform config:**

[Github: Create a repo](https://docs.github.com/en/github/getting-started-with-github/create-a-repo)

```
PLATFORM_REPO="https://github.com/USER_NAME/REPO_NAME/"
```

**Create a Git repository for the ZonePrinter config:**

[Github: Create a repo](https://docs.github.com/en/github/getting-started-with-github/create-a-repo)

```
ZONEPRINTER_REPO="https://github.com/USER_NAME/REPO_NAME/"
```

**Push platform config to the PLATFORM_REPO:**

```
mkdir -p .github/
cd .github/

git clone "${PLATFORM_REPO}" platform

cp -r ../repos/platform/* platform/

cd platform/

git add .

git commit -m "initialize platform config"

git push

cd ../..
```

**Push zoneprinter config to the ZONEPRINTER_REPO:**

```
mkdir -p .github/
cd .github/

git clone "${ZONEPRINTER_REPO}" zoneprinter

cp -r ../repos/zoneprinter/* zoneprinter/

cd zoneprinter/

git add .

git commit -m "initialize zoneprinter config"

git push

cd ../..
```

**Authenticate with cluster-west:**

```
gcloud container clusters get-credentials cluster-west --region us-west1

# set kubectx alias for easy context switching
kubectx cluster-west=. 
```

**Authenticate with cluster-east:**

```
gcloud container clusters get-credentials cluster-east --region us-east1

# set kubectx alias for easy context switching
kubectx cluster-east=. 
```

**Register the clusters with Hub:**

```
gcloud iam service-accounts keys create cluster-west-key.json \
    --iam-account=cluster-west-hub@${PROJECT_ID}.iam.gserviceaccount.com
gcloud iam service-accounts keys create cluster-east-key.json \
    --iam-account=cluster-east-hub@${PROJECT_ID}.iam.gserviceaccount.com

gcloud projects add-iam-policy-binding ${PROJECT_ID} \
    --member="serviceAccount:cluster-west-hub@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="roles/gkehub.connect"
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
    --member="serviceAccount:cluster-east-hub@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="roles/gkehub.connect"

gcloud container hub memberships register cluster-west \
    --gke-cluster us-west1/cluster-west \
    --service-account-key-file cluster-west-key.json
gcloud container hub memberships register cluster-east \
    --gke-cluster us-east1/cluster-east \
    --service-account-key-file cluster-east-key.json
```

**Enable Multi-Cluster Ingress via Hub:**

```
gcloud alpha container hub ingress enable \
    --config-membership projects/${PROJECT}/locations/global/memberships/cluster-west
```

This configures cluster-west as the cluster to manage MultiClusterIngress and MultiClusterService resources for the Environ.

**Deploy Anthos Config Management:**

**TODO**: replace manual deploy with `gcloud container hub config-management apply`, once it supports multi-repo.

```
gsutil cp gs://config-management-release/released/latest/config-management-operator.yaml config-management-operator.yaml

kubectx cluster-west
kubectl apply -f config-management-operator.yaml

kubectx cluster-east
kubectl apply -f config-management-operator.yaml
```

**Configure Anthos Config Management for platform config:**

```
kubectx cluster-west

kubectl apply -f - < EOF
apiVersion: configmanagement.gke.io/v1
kind: ConfigManagement
metadata:
  name: config-management
spec:
  clusterName: cluster-west
  enableMultiRepo: true
---
apiVersion: configsync.gke.io/v1beta1
kind: RootSync
metadata:
  name: root-sync
  namespace: config-management-system
spec:
  sourceFormat: unstructured
  git:
    repo: ${PLATFORM_REPO}
    revision: HEAD
    branch: master
    dir: "deploy/clusters/cluster-west"
    auth: none
EOF

kubectx cluster-east

kubectl apply -f - < EOF
apiVersion: configmanagement.gke.io/v1
kind: ConfigManagement
metadata:
  name: config-management
spec:
  clusterName: cluster-east
  enableMultiRepo: true
---
apiVersion: configsync.gke.io/v1beta1
kind: RootSync
metadata:
  name: root-sync
  namespace: config-management-system
spec:
  sourceFormat: unstructured
  git:
    repo: ${PLATFORM_REPO}
    revision: HEAD
    branch: master
    dir: "deploy/clusters/cluster-east"
    auth: none
EOF
```

**Configure Anthos Config Management for zoneprinter config:**

```
cd .github/platform/

mkdir -p config/clusters/cluster-west/namespaces/zoneprinter/

cat > config/clusters/cluster-west/namespaces/zoneprinter/repo-sync.yaml < EOF
apiVersion: configsync.gke.io/v1beta1
kind: RepoSync
metadata:
  name: repo-sync
  namespace: zoneprinter
spec:
  sourceFormat: unstructured
  git:
    repo: ${ZONEPRINTER_REPO}
    revision: HEAD
    branch: master
    dir: "deploy/clusters/cluster-west/namespaces/zoneprinter"
    auth: none
EOF

mkdir -p config/clusters/cluster-west/namespaces/zoneprinter/

cat > config/clusters/cluster-east/namespaces/zoneprinter/repo-sync.yaml < EOF
apiVersion: configsync.gke.io/v1beta1
kind: RepoSync
metadata:
  name: repo-sync
  namespace: zoneprinter
spec:
  sourceFormat: unstructured
  git:
    repo: ${ZONEPRINTER_REPO}
    revision: HEAD
    branch: master
    dir: "deploy/clusters/cluster-east/namespaces/zoneprinter"
    auth: none
EOF

git add .

git commit -m "add zoneprinter repo-sync"

git push

cd ../..
```

## Validating success

**Wait for config to be deployed:**

```
...
```

## Cleaning up

**Delete the GKE clusters:**

```
gcloud container clusters delete cluster-west --region us-west1
gcloud container clusters delete cluster-east --region us-east1
```