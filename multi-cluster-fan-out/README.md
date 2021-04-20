# Multi-Cluster Fan-out

This example shows how to manage Namespaces, ResourcQuotas, and RoleBindings across multiple clusters using Anthos Config Management and GitOps.

The resources in this examples are identical accross both clusters. So ConfigSync can be configured to pull config from the same directory.

## Clusters

- **cluster-east** - A multi-zone GKE cluster in the us-east1 region.
- **cluster-west** - A multi-zone GKE cluster in the us-west1 region.

## Filesystem Hierarchy

**Platform Repo (`repos/platform/`):**

```
└── deploy
    └── all-clusters
        ├── namespaces
        │   ├── tenant-a
        │   │   ├── quota.yaml
        │   │   └── rbac.yaml
        │   ├── tenant-b
        │   │   ├── quota.yaml
        │   │   └── rbac.yaml
        │   └── tenant-c
        │       ├── quota.yaml
        │       └── rbac.yaml
        └── namespaces.yaml
```

## Access Control

This example includes RoleBindings in each namespace to grant view permission to namespace users. 

The users are configured to be different for each namespace, but the same across clusters.

## Progressive rollouts

This example demonstrates the deployment of resources to multiple clusters at the same time. In a production environment, you may want to reduce the risk of rolling out changes by deploying to each cluster individually and/or by deploying to a staging environment first.

One way to do that is to change `.spec.git.revision` in the RootSync for each cluster to point to a specific commit SHA or tag. That way, both clusters will pull from a specific revision, instead of both pulling from `HEAD` of the `main` branch. This method may help protect against complete outage and allow for easy rollbacks, at the cost of a few more commits per rollout.

Another option is to seperate the configuration for each cluster into different directories. See [Multi-Cluster Resource Management](../multi-cluster-resource-management) for an example of this pattern.

To read more about progressive delivery patterns, see [Safe rollouts with Anthos Config Management](https://cloud.google.com/architecture/safe-rollouts-with-anthos-config-management).

## ConfigSync

This example installs ConfigSync on two clusters and configures them both to pull config from the same `deploy/all-clusters/` directory in the same Git repository.

## Before you begin

**Create or select a project:**

```
PLATFORM_PROJECT_ID="example-platform-1234"
ORGANIZATION_ID="123456789012"

gcloud projects create "${PLATFORM_PROJECT_ID}" \
    --organization ${ORGANIZATION_ID}
```

**Enable billing for your project:**

[Learn how to confirm that billing is enabled for your project](https://cloud.google.com/billing/docs/how-to/modify-project).

To link a project to a Cloud Billing account, you need `resourcemanager.projects.createBillingAssignment` on the project (included in `owner`, which you get if you created the project) AND `billing.resourceAssociations.create` on the Cloud Billing account.

```
BILLING_ACCOUNT_ID="AAAAAA-BBBBBB-CCCCCC"

gcloud alpha billing projects link "${PLATFORM_PROJECT_ID}" \
    --billing-account ${BILLING_ACCOUNT_ID}
```

## Setting up your environment

**Configure your default Google Cloud project ID:**

```
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
    dir: "deploy/all-clusters"
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
    dir: "deploy/all-clusters"
    auth: none
EOF
```

## Validating success

**Lookup latest commit SHA:**

```
(cd .github/platform/ && git log -1 --oneline)
```

**Wait for config to be deployed:**

```
nomos status
```

Should say "SYNCED" for both clusters with the latest commit SHA.

**Verify expected namespaces exist:**

```
kubectl config use-context ${CLUSTER_EAST_CONTEXT}
kubectl get ns

kubectl config use-context ${CLUSTER_WEST_CONTEXT}
kubectl get ns
```

Should include (non-exclusive):
- tenant-a
- tenant-b
- tenant-c

**Verify expected resource exist:**

```
kubectl config use-context ${CLUSTER_EAST_CONTEXT}
kubectl get ResourceQuota,RoleBinding -n tenant-a
kubectl get ResourceQuota,RoleBinding -n tenant-b
kubectl get ResourceQuota,RoleBinding -n tenant-c


kubectl config use-context ${CLUSTER_WEST_CONTEXT}
kubectl get ResourceQuota,RoleBinding -n tenant-a
kubectl get ResourceQuota,RoleBinding -n tenant-b
kubectl get ResourceQuota,RoleBinding -n tenant-c
```

Should include (non-exclusive):
- resourcequota/default
- rolebinding.rbac.authorization.k8s.io/namespace-viewer

## Cleaning up

**Delete the GKE clusters:**

```
gcloud container clusters delete cluster-west --region us-west1
gcloud container clusters delete cluster-east --region us-east1
```

**Delete the network:**

```
gcloud compute networks delete ${NETWORK}
```

**Delete the project:**

```
gcloud projects delete "${PLATFORM_PROJECT_ID}"
```
