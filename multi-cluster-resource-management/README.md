# Multi-Cluster Resource Management

This example shows how to manage Namespaces, ResourcQuotas, and RoleBindings across multiple clusters using Anthos Config Management, GitOps, and Kustomize.

## Clusters

- **cluster-east** - A multi-zone GKE cluster in the us-east1 region.
- **cluster-west** - A multi-zone GKE cluster in the us-west1 region.

## Filesystem Hierarchy

**Platform Repo (`repos/platform/`):**

- `config/` - pre-render resources
    - `all-clusters/` - cluster-agnostic cluster-scoped resources
        - `all-namespaces/` - cluster-agnostic and namespace-agnostic namespace-scoped resources
        - `namespaces/`
            - `${namespace}/` - cluster-agnostic but namespace-specific namespace-scoped resources
    - `clusters/`
        - `${cluster-name}/` - cluster-specific cluster-scoped resources
            - `namespaces/`
                - `${namespace}/` - cluster-specific and namespace-specific namespace-scoped resources
- `deploy/` - post-render resources
    - `clusters/`
        - `${cluster-name}/` - cluster-specific cluster-scoped resources
            - `namespaces/`
                - `${namespace}/` - cluster-specific and namespace-specific namespace-scoped resources
- `scripts/`
    - `render.sh` - script to render kustomize overlays from `config/` to `deploy/`

## Kustomize

This example optionally uses Kustomize to render the resources under `config/` and write them to `deploy/`. This allows for common resources to be managed in one place and still be patched with cluster-specific and namespace-specific modifications.

However, if you don't want to manage chaining kustomize patches, it's also a valid option to just use the resources under the `deploy/` directory and skip the `config/` and `scripts/render.sh` script.

## ConfigSync

This example installs ConfigSync on two clusters and configures them to pull config from different `deploy/clusters/${cluster-name}/` directories in the same Git repository.

## Access Control

This example includes RoleBindings in each namespace to grant view permission to namespace users. 

The users are configured to be different for each namespace, but the same across clusters.

## Progressive rollouts

This example does not explicitly implement progressive rollouts, as described by [Safe rollouts with Anthos Config Management](https://cloud.google.com/architecture/safe-rollouts-with-anthos-config-management), because by default each cluster pulls from `HEAD` of the `main` Git branch.

However, it's possible to adapt this example to roll out to each cluster individually if you change the RootSync `.spec.git.revision` of each cluster to point to a specific commit SHA or tag. That way you can manually gate the revision of config that each cluster will have applied.

This method can protect against complete outage and allow for easy rollbacks, at the cost of a few more commits per rollout.

## Before you begin

1. Create or select a project.
2. Make sure that billing is enabled for your Cloud project. [Learn how to confirm that billing is enabled for your project](https://cloud.google.com/billing/docs/how-to/modify-project).

## Setting up your environment

**Configure your default Google Cloud project ID:**

```
PLATFORM_PROJECT_ID="PROJECT_ID"
gcloud config set project ${PLATFORM_PROJECT_ID}
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

**Create or select a network:**

```
NETWORK="default"
gcloud compute networks create ${NETWORK}
```

**Deploy the GKE clusters:**

```
gcloud container clusters create cluster-west \
    --region us-west1 \
    --network ${NETWORK} \
    --release-channel regular

gcloud container clusters create cluster-east \
    --region us-east1 \
    --network ${NETWORK} \
    --release-channel regular
```

**Create a Git repository for the Platform config:**

[Github: Create a repo](https://docs.github.com/en/github/getting-started-with-github/create-a-repo)

```
PLATFORM_REPO="https://github.com/USER_NAME/REPO_NAME/"
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

**Authenticate with cluster-west:**

```
gcloud container clusters get-credentials cluster-west --region us-west1

# set alias for easy context switching
CLUSTER_WEST_CONTEXT=$(kubectl config current-context)
```

**Authenticate with cluster-east:**

```
gcloud container clusters get-credentials cluster-east --region us-east1

# set alias for easy context switching
CLUSTER_EAST_CONTEXT=$(kubectl config current-context)
```

**Register the clusters with Hub:**

```
gcloud container hub memberships register cluster-west \
    --gke-cluster us-west1/cluster-west \
    --enable-workload-identity
gcloud container hub memberships register cluster-east \
    --gke-cluster us-east1/cluster-east \
    --enable-workload-identity
```

**Deploy Anthos Config Management:**

**TODO**: replace manual deploy with `gcloud container hub config-management apply`, once it supports multi-repo.

```
gsutil cp gs://config-management-release/released/latest/config-management-operator.yaml config-management-operator.yaml

kubectl config use-context ${CLUSTER_WEST_CONTEXT}
kubectl apply -f config-management-operator.yaml

kubectl config use-context ${CLUSTER_EAST_CONTEXT}
kubectl apply -f config-management-operator.yaml
```

**Configure Anthos Config Management for platform config:**

```
kubectl config use-context ${CLUSTER_WEST_CONTEXT}

kubectl apply -f - << EOF
apiVersion: configmanagement.gke.io/v1
kind: ConfigManagement
metadata:
  name: config-management
spec:
  clusterName: cluster-west
  enableMultiRepo: true
EOF

# Wait a few seconds for ConfigManagement to install the RootSync CRD

kubectl apply -f - << EOF
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
    branch: main
    dir: "deploy/clusters/cluster-west"
    auth: none
EOF

kubectl config use-context ${CLUSTER_EAST_CONTEXT}

kubectl apply -f - << EOF
apiVersion: configmanagement.gke.io/v1
kind: ConfigManagement
metadata:
  name: config-management
spec:
  clusterName: cluster-east
  enableMultiRepo: true
EOF

# Wait a few seconds for ConfigManagement to install the RootSync CRD

kubectl apply -f - << EOF
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
    branch: main
    dir: "deploy/clusters/cluster-east"
    auth: none
EOF
```

## Validating success

**Wait for config to be deployed:**

```
nomos status
```

Should say "SYNCED" for both clusters.

```
kubectl get ns
```

Should include:
- config-management-monitoring
- config-management-system
- default
- gke-connect
- kube-node-lease
- kube-public
- kube-system
- resource-group-system
- tenant-a
- tenant-b
- tenant-c

## Cleaning up

**Delete the GKE clusters:**

```
gcloud container clusters delete cluster-west --region us-west1
gcloud container clusters delete cluster-east --region us-east1
```
