# Multi-Cluster Ingress

This examples shows how to manage a service with Multi-Cluster Ingress using Anthos Config Management, GitOps, and Kustomize.

This example is based on [Deploying Ingress across clusters](https://cloud.google.com/kubernetes-engine/docs/how-to/multi-cluster-ingress), except it uses ConfigSync and kustomize to deploy to multiple multi-tenant clusters.

# Goals

This usage of Multi-Cluster Ingress serves multiple goals:

By using backends on multiple clusters in different regions, each with nodes in multiple zones, and a single global Virtual IP, the service can reach very **high availability**.

By using backends on multiple clusters in different regions and Google's global [Cloud Load Balancer](https://cloud.google.com/load-balancing/docs/load-balancing-overview), which automatically routes traffic based on latency, availability, and capacity, the services can have very **low latency** for clients in different parts of the world.

By using backends on multiple clusters, the service can reach very **high scale**, beyond that which can be supported by a single cluster.

## Clusters

- **cluster-east** - A multi-zone GKE cluster in the us-east1 region.
- **cluster-west** - A multi-zone GKE cluster in the us-west1 region.

## Tenant Workloads

This example demonstrates one tenant with a workload that span multiple clusters:

- **zoneprinter** - an echo service behind Multi-Cluster Ingress

## Filesystem Hierarchy

**Platform Repo (`repos/platform/`):**

```
├── config
│   ├── all-clusters
│   │   ├── kustomization.yaml
│   │   └── namespaces.yaml
│   └── clusters
│       ├── cluster-east
│       │   └── kustomization.yaml
│       └── cluster-west
│           └── kustomization.yaml
├── deploy
│   └── clusters
│       ├── cluster-east
│       │   └── rendered.yaml
│       └── cluster-west
│           └── rendered.yaml
└── scripts
    └── render.sh
```

**ZonePrinter Repo (`repos/zoneprinter/`):**

```
├── config
│   ├── all-clusters
│   │   └── namespaces
│   │       └── zoneprinter
│   │           ├── kustomization.yaml
│   │           └── zoneprinter-deployment.yaml
│   └── clusters
│       ├── cluster-east
│       │   └── namespaces
│       │       └── zoneprinter
│       │           └── kustomization.yaml
│       └── cluster-west
│           └── namespaces
│               └── zoneprinter
│                   ├── kustomization.yaml
│                   └── mci.yaml
├── deploy
│   └── clusters
│       ├── cluster-east
│       │   └── namespaces
│       │       └── zoneprinter
│       │           └── rendered.yaml
│       └── cluster-west
│           └── namespaces
│               └── zoneprinter
│                   └── rendered.yaml
└── scripts
    └── render.sh
```

# Config Cluster

In this example, the `cluster-west` cluster will be used as the [config cluster](https://cloud.google.com/kubernetes-engine/docs/how-to/multi-cluster-ingress-setup#specifying_a_config_cluster) for Multi-cluster Ingress. The [MultiClusterIngress](https://cloud.google.com/kubernetes-engine/docs/how-to/multi-cluster-ingress#multiclusteringress_spec) and [MultiClusterService](https://cloud.google.com/kubernetes-engine/docs/how-to/multi-cluster-ingress#multiclusterservice_spec) resources in the `mci.yaml` file are only being deployed to the `cluster-west` cluster.

In a production environment, it may be desirable to use a third cluster as the config cluster, to reduce the risk that the config cluster is unavailable to make multi-cluster changes, but in this case we're using one of the two workload clusters in order to reduce costs.

## Kustomize

In this example, some resources differ between clusters and between namespaces.

Because of this, the resources specific to each cluster and the same on each cluster are managed in different places and merged together using Kustomize. This is not necessary in all cases, but it may help reduce the risk of misconfiguration between clusters and make it easier to roll out changes consistently.

Kustomize is also being used here to add additional labels, to aid observability.

To invoke Kustomize, execute `scripts/render.sh` to render the resources under `config/` and write them to `deploy/`.

However, if you don't want to use Kustomize, it's also a valid option to just use the resources under the `deploy/` directory and skip the `config/` and `scripts/render.sh` script.

## ConfigSync

This example installs ConfigSync on two clusters and configures them to pull config from different `deploy/clusters/${cluster-name}/` directories in the same Git repository.

## Before you begin

1. Create or select a project.
2. Make sure that billing is enabled for your Cloud project. [Learn how to confirm that billing is enabled for your project](https://cloud.google.com/billing/docs/how-to/modify-project).

## Setting up your environment

**Configure your default Google Cloud prject ID:**

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

If you have the `compute.skipDefaultNetworkCreation` [organization policy constraint](https://cloud.google.com/resource-manager/docs/organization-policy/org-policy-constraints) enabled, you may have to create a network. Otherwise, just set the `NETWORK` variable for later use.

```
NETWORK="default"
gcloud compute networks create ${NETWORK}
```

**Deploy the GKE clusters:**

```
gcloud container clusters create cluster-west \
    --region us-west1 \
    --network ${NETWORK}
gcloud container clusters create cluster-east \
    --region us-east1 \
    --network ${NETWORK}
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
    --iam-account=cluster-west-hub@${PLATFORM_PROJECT_ID}.iam.gserviceaccount.com
gcloud iam service-accounts keys create cluster-east-key.json \
    --iam-account=cluster-east-hub@${PLATFORM_PROJECT_ID}.iam.gserviceaccount.com

gcloud projects add-iam-policy-binding ${PLATFORM_PROJECT_ID} \
    --member="serviceAccount:cluster-west-hub@${PLATFORM_PROJECT_ID}.iam.gserviceaccount.com" \
    --role="roles/gkehub.connect"
gcloud projects add-iam-policy-binding ${PLATFORM_PROJECT_ID} \
    --member="serviceAccount:cluster-east-hub@${PLATFORM_PROJECT_ID}.iam.gserviceaccount.com" \
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