# Multi-Cluster Custom Metric Autoscaling

This examples demonstrates how to manage a tenant service that autoscales across two clusters using the [Custom Metrics Stackdriver Adapter](https://github.com/GoogleCloudPlatform/k8s-stackdriver/tree/master/custom-metrics-stackdriver-adapter), Anthos Config Management, GitOps, and Kustomize.

This example also demonstrates how to manage cluster-scoped resources and a shared service that requires elevated permissions.

This example is based on [Autoscaling Deployments with Cloud Monitoring metrics](https://cloud.google.com/kubernetes-engine/docs/tutorials/autoscaling-metrics), except it uses ConfigSync, kustomize, and Workload Identity to deploy to multiple multi-tenant clusters.

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
    - `all-clusters/`
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
    - `all-clusters/`
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
    stackdriver.googleapis.com \
    cloudresourcemanager.googleapis.com
```

**Create or select a network:**

If you have the `compute.skipDefaultNetworkCreation` [organization policy constraint](https://cloud.google.com/resource-manager/docs/organization-policy/org-policy-constraints) enabled, you may have to create a network. Otherwise, just set the `NETWORK` variable for later use.

```
NETWORK="default"
gcloud compute networks create ${NETWORK}
```

**Configure firewalls to allow unrestricted internal network traffic:**

```
gcloud compute firewall-rules create allow-all-internal \
    --network ${NETWORK} \
    --allow tcp,udp,icmp \
    --source-ranges 10.0.0.0/8
```

**Deploy Cloud NAT to allow egress from private GKE nodes:**

```
# Create a us-west1 Cloud Router
gcloud compute routers create nat-router-us-west1 \
    --network ${NETWORK} \
    --region us-west1

# Add Cloud NAT to the us-west1 Cloud Router
gcloud compute routers nats create nat-us-west1 \
    --router-region us-west1 \
    --router nat-router-us-west1 \
    --auto-allocate-nat-external-ips \
    --nat-all-subnet-ip-ranges \
    --enable-logging

# Create a us-east1 Cloud Router
gcloud compute routers create nat-router-us-east1 \
    --network ${NETWORK} \
    --region us-east1

# Add Cloud NAT to the us-east1 Cloud Router
gcloud compute routers nats create nat-us-east1 \
    --router-region us-east1 \
    --router nat-router-us-east1 \
    --auto-allocate-nat-external-ips \
    --nat-all-subnet-ip-ranges \
    --enable-logging
```

**Deploy the GKE clusters:**

```
gcloud container clusters create cluster-west \
    --region us-west1 \
    --network ${NETWORK} \
    --release-channel regular \
    --enable-ip-alias \
    --enable-private-nodes \
    --master-ipv4-cidr 10.64.0.0/28 \
    --master-authorized-networks 0.0.0.0/0 \
    --enable-stackdriver-kubernetes \
    --workload-pool "${PLATFORM_PROJECT_ID}.svc.id.goog" \
    --enable-autoscaling --max-nodes 10 --min-nodes 1

gcloud container clusters create cluster-east \
    --region us-east1 \
    --network ${NETWORK} \
    --release-channel regular \
    --enable-ip-alias \
    --enable-private-nodes \
    --master-ipv4-cidr 10.64.0.16/28 \
    --master-authorized-networks 0.0.0.0/0 \
    --enable-stackdriver-kubernetes \
    --workload-pool "${PLATFORM_PROJECT_ID}.svc.id.goog" \
    --enable-autoscaling --max-nodes 10 --min-nodes 1
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

**Enable Multi-Cluster Ingress via Hub:**

```
gcloud alpha container hub ingress enable \
    --config-membership projects/${PLATFORM_PROJECT_ID}/locations/global/memberships/cluster-west
```

This configures cluster-west as the cluster to manage MultiClusterIngress and MultiClusterService resources for the Environ.

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

**Configure Anthos Config Management for pubsub-sample config:**

TODO: Switch to RepoSync v1beta1 once b/185390061 is fixed.

```
cd .github/platform/

cat > config/clusters/cluster-west/namespaces/pubsub-sample/repo-sync.yaml << EOF
apiVersion: configsync.gke.io/v1alpha1
kind: RepoSync
metadata:
  name: repo-sync
  namespace: pubsub-sample
spec:
  sourceFormat: unstructured
  git:
    repo: ${PUBSUB_SAMPLE_REPO}
    revision: HEAD
    branch: main
    dir: "deploy/clusters/cluster-west/namespaces/pubsub-sample"
    auth: none
---
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: syncs-repo
  namespace: pubsub-sample
subjects:
- kind: ServiceAccount
  name: ns-reconciler-pubsub-sample
  namespace: config-management-system
roleRef:
  kind: ClusterRole
  name: admin
  apiGroup: rbac.authorization.k8s.io
EOF

cat > config/clusters/cluster-west/namespaces/pubsub-sample/kustomization.yaml << EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- repo-sync.yaml
EOF

cat > config/clusters/cluster-east/namespaces/pubsub-sample/repo-sync.yaml << EOF
apiVersion: configsync.gke.io/v1alpha1
kind: RepoSync
metadata:
  name: repo-sync
  namespace: pubsub-sample
spec:
  sourceFormat: unstructured
  git:
    repo: ${PUBSUB_SAMPLE_REPO}
    revision: HEAD
    branch: main
    dir: "deploy/clusters/cluster-east/namespaces/pubsub-sample"
    auth: none
---
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: syncs-repo
  namespace: pubsub-sample
subjects:
- kind: ServiceAccount
  name: ns-reconciler-pubsub-sample
  namespace: config-management-system
roleRef:
  kind: ClusterRole
  name: admin
  apiGroup: rbac.authorization.k8s.io
EOF

cat > config/clusters/cluster-east/namespaces/pubsub-sample/kustomization.yaml << EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- repo-sync.yaml
EOF

scripts/render.sh

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
ORGANIZATION_ID="123456789012"
gcloud projects create "${PUBSUB_SAMPLE_PROJECT_ID}" \
    --organization ${ORGANIZATION_ID}
```

**Make sure that billing is enabled for your Cloud project:**

[Learn how to confirm that billing is enabled for your project](https://cloud.google.com/billing/docs/how-to/modify-project).

To link a project to a Cloud Billing account, you need `resourcemanager.projects.createBillingAssignment` on the project (included in `owner`, which you get if you created the project) AND `billing.resourceAssociations.create` on the Cloud Billing account.

```
BILLING_ACCOUNT_ID="AAAAAA-BBBBBB-CCCCCC"
gcloud alpha billing projects link "${PUBSUB_SAMPLE_PROJECT_ID}" \
    --billing-account ${BILLING_ACCOUNT_ID}
```

**Enable required GCP services:**

```
gcloud services enable \
    pubsub.googleapis.com \
    stackdriver.googleapis.com \
    cloudresourcemanager.googleapis.com \
    --project ${PUBSUB_SAMPLE_PROJECT_ID}
```

**Create a PubSub topic and subscription:**

```
gcloud pubsub topics create echo \
    --project ${PUBSUB_SAMPLE_PROJECT_ID}
gcloud pubsub subscriptions create echo-read --topic echo \
    --project ${PUBSUB_SAMPLE_PROJECT_ID}
```

**Create a service account for the pubsub-sample deployment:**

The service account needs to be in the same project as the GKE cluster, in order for Workload Identity to work.

```
gcloud iam service-accounts create pubsub-sample \
    --project ${PLATFORM_PROJECT_ID}

gcloud projects add-iam-policy-binding \
    ${PUBSUB_SAMPLE_PROJECT_ID} \
    --member "serviceAccount:pubsub-sample@${PLATFORM_PROJECT_ID}.iam.gserviceaccount.com" \
    --role "roles/pubsub.subscriber"
```

**Grant GKE access to use the service account for Workload Identity:**

```
gcloud iam service-accounts add-iam-policy-binding \
    "pubsub-sample@${PLATFORM_PROJECT_ID}.iam.gserviceaccount.com" \
    --member "serviceAccount:${PLATFORM_PROJECT_ID}.svc.id.goog[pubsub-sample/pubsub-sample]" \
    --role "roles/iam.workloadIdentityUser" \
    --project ${PLATFORM_PROJECT_ID}
```

**Create a service account for the custom-metrics-stackdriver-adapter deployment:**

The service account needs to be in the same project as the GKE cluster, in order for Workload Identity to work.

```
gcloud iam service-accounts create custom-metrics-adapter \
    --project ${PLATFORM_PROJECT_ID}

gcloud projects add-iam-policy-binding \
    ${PUBSUB_SAMPLE_PROJECT_ID} \
    --member "serviceAccount:custom-metrics-adapter@${PLATFORM_PROJECT_ID}.iam.gserviceaccount.com" \
    --role "roles/monitoring.viewer"

gcloud projects add-iam-policy-binding \
    ${PLATFORM_PROJECT_ID} \
    --member "serviceAccount:custom-metrics-adapter@${PLATFORM_PROJECT_ID}.iam.gserviceaccount.com" \
    --role "roles/monitoring.viewer"
```

**Grant GKE access to use the service account for Workload Identity:**

```
gcloud iam service-accounts add-iam-policy-binding \
    "custom-metrics-adapter@${PLATFORM_PROJECT_ID}.iam.gserviceaccount.com" \
    --member "serviceAccount:${PLATFORM_PROJECT_ID}.svc.id.goog[custom-metrics/custom-metrics-stackdriver-adapter]" \
    --role "roles/iam.workloadIdentityUser" \
    --project ${PLATFORM_PROJECT_ID}
```


**Create a GCP project for the Cloud Monitoring workspace:**

This project will manage the workspace that aggregates metrics from both the platform and tenant projects.
This shared workspace will allow the metrics adapter to retrieve metrics from multiple projects.

Project IDs need to be globally unique and 30 characters or less. 

The following patten can help avoid overlaps: `${ORG_PREFIX}-${TENANT}-${RANDOM_SUFFIX}`

```
METRICS_PROJECT_ID="example-platform-metrics-1234"
ORGANIZATION_ID="123456789012"
gcloud projects create "${METRICS_PROJECT_ID}" \
    --organization ${ORGANIZATION_ID}
```

**Make sure that billing is enabled for your Cloud project:**

[Learn how to confirm that billing is enabled for your project](https://cloud.google.com/billing/docs/how-to/modify-project).

To link a project to a Cloud Billing account, you need `resourcemanager.projects.createBillingAssignment` on the project (included in `owner`, which you get if you created the project) AND `billing.resourceAssociations.create` on the Cloud Billing account.

```
BILLING_ACCOUNT_ID="AAAAAA-BBBBBB-CCCCCC"
gcloud alpha billing projects link "${METRICS_PROJECT_ID}" \
    --billing-account ${BILLING_ACCOUNT_ID}
```

**Enable required GCP services:**

```
gcloud services enable \
    cloudresourcemanager.googleapis.com \
    stackdriver.googleapis.com \
    --project ${METRICS_PROJECT_ID}
```

**Add the platform and tenant projects to the metrics workspace:**

Note: There's no gcloud module to manage workspaces yet.

In the Google Cloud Console, select the `${METRICS_PROJECT_ID}` project to be the host project for your Workspace:

1. Go to [Cloud Console](https://console.cloud.google.com/)
1. Select the `${METRICS_PROJECT_ID}` project with the Cloud Console project picker.
1. In the navigation pane, select **Monitoring** and then select **Settings**.  open the **Add your project to a Workspace** window.
1. Click **Add** to create the Workspace.

Once the Workspace is created, add the other projects to your Workspace:

1. Click **Add GCP projects** to create the Workspace.
1. Select `${PLATFORM_PROJECT_ID}` and `${PLATFORM_PROJECT_ID}` to add to the new Workspace. 
1. Click **Add projects** to save the changes.

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
- custom-metrics
- default
- gke-connect
- kube-node-lease
- kube-public
- kube-system
- pubsub-sample
- resource-group-system

**Generate 200 Pub/Sub messages:**

```
for i in {1..200}; do gcloud pubsub topics publish echo --message="Autoscaling #${i}" --project ${PUBSUB_SAMPLE_PROJECT_ID}; done
```

**Observe scale up:**

```
kubectl config use-context ${CLUSTER_WEST_CONTEXT}
kubectl get deployment pubsub-sample -n pubsub-sample

kubectl config use-context ${CLUSTER_EAST_CONTEXT}
kubectl get deployment pubsub-sample -n pubsub-sample
```

```
kubectl apply -f - << EOF
apiVersion: rbac.authorization.k8s.io/v1beta1
kind: ClusterRole
metadata:
  name: custom-metrics-test
rules:
- nonResourceURLs: ["/metrics"]
  verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1beta1
kind: ClusterRoleBinding
metadata:
  name: custom-metrics-test
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: custom-metrics-test
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: User
  name: system:anonymous
EOF
```

## Cleaning up

**Delete the GKE clusters:**

```
gcloud container clusters delete cluster-west --region us-west1
gcloud container clusters delete cluster-east --region us-east1
```



google.auth.exceptions.RefreshError: ("Failed to retrieve http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/pubsub-sample@pubsub-sample-1234.iam.gserviceaccount.com/token from the Google Compute Enginemetadata service. Status: 404 Response:\nb'Unable to generate access token; IAM returned 404 Not Found: Requested entity was not found.\\n'", <google_auth_httplib2._Response object at 0x7f9f0ef11908>)

$ kubectl get --raw '/apis/custom.metrics.k8s.io/v1beta2/namespaces/*/pods/*/pubsub.googleapis.com|subscription|num_undelivered_messages' | jq .
{
  "kind": "MetricValueList",
  "apiVersion": "custom.metrics.k8s.io/v1beta2",
  "metadata": {
    "selfLink": "/apis/custom.metrics.k8s.io/v1beta2/namespaces/%2A/pods/%2A/pubsub.googleapis.com%7Csubscription%7Cnum_undelivered_messages"
  },
  "items": []
}

kubectl get --raw '/apis/custom.metrics.k8s.io/v1beta2/namespaces/*/pods/*/pubsub.googleapis.com|subscription|num_undelivered_messages?labelSelector=resource.labels.project_id=example-pubsub-sample-1234' | jq .

kubectl get --raw '/apis/external.metrics.k8s.io/v1beta1/namespaces/*/pods/*/pubsub.googleapis.com|subscription|num_undelivered_messages'