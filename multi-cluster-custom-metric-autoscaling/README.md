# Multi-Cluster PubSub Consumer

This examples demonstrates how to manage a tenant service that autoscales across two clusters using the [Custom Metrics Stackdriver Adapter](https://github.com/GoogleCloudPlatform/k8s-stackdriver/tree/master/custom-metrics-stackdriver-adapter), Anthos Config Management, GitOps, and Kustomize.

This example also demonstrates how to manage cluster-scoped resources and a shared service that requires elevated permissions.

## Clusters

- **cluster-east** - A multi-zone GKE cluster in the us-east1 region.
- **cluster-west** - A multi-zone GKE cluster in the us-west1 region.

## Tenant Workloads

This example demonstrates one tenant with a workload that span multiple clusters:

- **pubsub-sample** - a pubsub consumer horizontally autoscaling based on topic length using Workload Identity and a seperate tenant project

Following multitenant best practice, the tenant workload runs in its own tenant namespace.

## Admin Workloads

This example demonstrates running a shared service:

- **custom-metrics** - a deployment of the [Custom Metrics Stackdriver Adapter](https://github.com/GoogleCloudPlatform/k8s-stackdriver/tree/master/custom-metrics-stackdriver-adapter) 

Following security best practice, the shared service also runs in its own tenant namespace, but depends on cluster-scoped resources, like APIServices, ClusterRoles, and ClusterRoleBindings.

## Filesystem Hierarchy

**Platform Repo (`repos/platform/`):**

- `config/` - pre-render resources
    - `clusters/`
        - `${cluster-name}/`
            - `kustomization.yaml` - cluster-specific overlays
    - `common/`
        - `namespaces/`
            - `${namespace}/`
                - `kustomization.yaml` - cluster-agnostic but namespace-specific overlays
                - `${name}-${kind}.yaml` - cluster-agnostic but namespace-specific resources
        - `kustomization.yaml` - common overlays
        - `${name}-${kind}.yaml` - common cluster-scoped resources
        - `namespaces.yaml` - common namespaces
- `deploy/` - post-render resources
    - `clusters/`
        - `${cluster-name}/`
            - `rendered.yaml` - cluster-specific post-render resources
- `scripts/`
    - `render.sh` - script to render kustomize overlays from `config/` to `deploy/`

**PubSub Sample Repo (`repos/pubsub-sample/`):**

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

For example, each resource deployed as part of the pubsub-sample workload may need a common `app: pubsub-sample` label to aid observability.

This example uses Kustomize to render the resources under `config/` and write them to `deploy/`.
This allows for both differences and similarities between resources deployed to multiple clusters, and lays the ground work for supporting multiple namespaces as well.

ConfigSync is then configured on each cluster to watch a cluster-specific subdirectory under `deploy/`, in the same repository.

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

**Deploy the GKE clusters:**

```
gcloud container clusters create cluster-west \
    --region us-west1 \
    --workload-pool "${PLATFORM_PROJECT_ID}.svc.id.goog"
gcloud container clusters create cluster-east \
    --region us-east1 \
    --workload-pool "${PLATFORM_PROJECT_ID}.svc.id.goog"
```

**Create a Git repository for the Platform config:**

[Github: Create a repo](https://docs.github.com/en/github/getting-started-with-github/create-a-repo)

```
PLATFORM_REPO="https://github.com/USER_NAME/REPO_NAME/"
```

**Create a Git repository for the PubSub Sample config:**

[Github: Create a repo](https://docs.github.com/en/github/getting-started-with-github/create-a-repo)

```
PUBSUB_SAMPLE_REPO="https://github.com/USER_NAME/REPO_NAME/"
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

**Push pubsub-sample config to the PUBSUB_SAMPLE_REPO:**

```
mkdir -p .github/
cd .github/

git clone "${PUBSUB_SAMPLE_REPO}" pubsub-sample

cp -r ../repos/pubsub-sample/* pubsub-sample/

cd pubsub-sample/

git add .

git commit -m "initialize pubsub-sample config"

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

**Configure Anthos Config Management for pubsub-sample config:**

```
cd .github/platform/

mkdir -p config/clusters/cluster-west/namespaces/pubsub-sample/

cat > config/clusters/cluster-west/namespaces/pubsub-sample/repo-sync.yaml < EOF
apiVersion: configsync.gke.io/v1beta1
kind: RepoSync
metadata:
  name: repo-sync
  namespace: pubsub-sample
spec:
  sourceFormat: unstructured
  git:
    repo: ${PUBSUB_SAMPLE_REPO}
    revision: HEAD
    branch: master
    dir: "deploy/clusters/cluster-west/namespaces/pubsub-sample"
    auth: none
EOF

mkdir -p config/clusters/cluster-west/namespaces/pubsub-sample/

cat > config/clusters/cluster-east/namespaces/pubsub-sample/repo-sync.yaml < EOF
apiVersion: configsync.gke.io/v1beta1
kind: RepoSync
metadata:
  name: repo-sync
  namespace: pubsub-sample
spec:
  sourceFormat: unstructured
  git:
    repo: ${PUBSUB_SAMPLE_REPO}
    revision: HEAD
    branch: master
    dir: "deploy/clusters/cluster-east/namespaces/pubsub-sample"
    auth: none
EOF

git add .

git commit -m "add pubsub-sample repo-sync"

git push

cd ../..
```

**Create a GCP project for the pubsub-sample tenant:**

This project will be managed by the tenant, rather than the platform admin,
and will contain the PubSub queue used by the PubSub Sample.

Project IDs need to be globally unique and 30 characters or less. 

The following patten can help avoid overlaps: `${ORG_PREFIX}-${TENANT}-${RANDOM_SUFFIX}`

```
PUBSUB_SAMPLE_PROJECT_ID="example-pubsub-sample-1234"
gcloud project create "${PUBSUB_SAMPLE_PROJECT_ID}" \
    --organization ${ORGANIZATION_ID}
```

**Make sure that billing is enabled for your Cloud project:**

[Learn how to confirm that billing is enabled for your project](https://cloud.google.com/billing/docs/how-to/modify-project).

To link a project to a Cloud Billing account, you need `resourcemanager.projects.createBillingAssignment` on the project (included in `owner`, which you get if you created the project) AND `billing.resourceAssociations.create` on the Cloud Billing account.

```
gcloud alpha billing projects link "${PUBSUB_SAMPLE_PROJECT_ID}" \
    --billing-account ${BILLING_ACCOUNT_ID}
```

**Enable required GCP services:**

```
gcloud services enable \
    pubsub.googleapis.com \
    cloudresourcemanager.googleapis.com
```

**Create a PubSub topic and subscription:**

```
gcloud pubsub topics create echo
gcloud pubsub subscriptions create echo-read --topic echo
```

**Create a service account with access to Pub/Sub:**

```
gcloud iam service-accounts create pubsub-sample
gcloud projects add-iam-policy-binding ${PUBSUB_SAMPLE_PROJECT_ID} \
    --member "serviceAccount:pubsub-sample@${PUBSUB_SAMPLE_PROJECT_ID}.iam.gserviceaccount.com" \
    --role "roles/pubsub.subscriber"
```

**Grant GKE access to use the service account for Workload Identity:**

```
gcloud projects add-iam-policy-binding "pubsub-sample@${PUBSUB_SAMPLE_PROJECT_ID}.iam.gserviceaccount.com" \
    --member "serviceAccount:${PLATFORM_PROJECT_ID}.svc.id.goog[pubsub-sample/pubsub-sample]" \
    --role "roles/iam.workloadIdentityUser"
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