# IaC / CaC File Guide — Chameleon + Kubernetes (DMS)

Reference for every infrastructure and configuration file in this repository. Files are organized by function: Terraform provisioning, Kubernetes manifests, helper scripts, and runbooks.

---

## Terraform Provisioning

All Terraform files live under [infra-dms/terraform/](infra-dms/terraform/).

### [main.tf](infra-dms/terraform/main.tf)

Defines the full OpenStack resource graph for the DMS cluster:

- **Security group** (`openstack_networking_secgroup_v2`) — `proj26-dms-sg` with inbound rules for SSH (22) and the DMS API NodePort (30080).
- **Floating IP** (`openstack_networking_floatingip_v2`) — allocated from the `public` pool.
- **Reserved server** (`null_resource.create_reserved_server`) — calls `openstack server create` via `local-exec` with `--hint reservation=<UUID>` for Blazar lease-backed provisioning. Polls until the instance reaches `ACTIVE`.
- **FIP association** (`null_resource.associate_fip`) — idempotently associates the floating IP; skips if already bound.

### [providers.tf](infra-dms/terraform/providers.tf)

Declares provider requirements:

| Provider | Source | Version |
|---|---|---|
| OpenStack | `terraform-provider-openstack/openstack` | `~> 1.54` |
| Null | `hashicorp/null` | `~> 3.2` |

Configures the OpenStack provider from variables; supports both username/password and application-credential auth.

### [variables.tf](infra-dms/terraform/variables.tf)

All input variables for the stack:

| Variable | Default | Purpose |
|---|---|---|
| `os_auth_url` | — | Chameleon Keystone endpoint |
| `os_region_name` | — | e.g. `CHI@UC` |
| `os_project_name` | — | e.g. `CHI-251409` |
| `os_application_credential_id` | `null` | App-cred ID (preferred over password) |
| `os_application_credential_secret` | `null` | App-cred secret |
| `instance_name` | `proj26-dms-k3s` | VM name |
| `image_name` | — | e.g. `CC-Ubuntu22.04` |
| `flavor_name` | — | e.g. `baremetal` |
| `network_name` | — | Private network, e.g. `sharednet1` |
| `external_network_name` | `public` | Floating IP pool |
| `ssh_key_name` | — | Existing OpenStack keypair |
| `reservation_id` | — | Blazar reservation UUID |
| `allowed_ssh_cidr` | `0.0.0.0/0` | Restrict SSH source |
| `allowed_api_cidr` | `0.0.0.0/0` | Restrict API NodePort source |
| `volume_size_gb` | `100` | Persistent disk size |
| `ssh_user` | `cc` | Default SSH user |

### [outputs.tf](infra-dms/terraform/outputs.tf)

Outputs emitted after `terraform apply`:

| Output | Value |
|---|---|
| `floating_ip` | Public IP for SSH and API access |
| `ssh_command` | Ready-to-run `ssh cc@<ip>` command |
| `kubeconfig_copy_command` | `scp` command to pull k3s.yaml from VM |

### [cloud-init.yaml.tftpl](infra-dms/terraform/cloud-init.yaml.tftpl)

Cloud-init template that runs on first boot to bootstrap k3s. Steps:

1. **Disk mount** — detects the first non-root block device (`vdb`, `sdb`, `nvme1n1`), formats it ext4 if needed, mounts it at `/var/lib/rancher/k3s/storage`, and persists the mount in `/etc/fstab`.
2. **k3s install** — runs the official installer (`https://get.k3s.io`) with `--write-kubeconfig-mode 644` so the kubeconfig is readable by the `cc` user.
3. **kubeconfig copy** — copies `/etc/rancher/k3s/k3s.yaml` to `/home/${ssh_user}/.kube/config`.

### [terraform.tfvars.example](infra-dms/terraform/terraform.tfvars.example)

Template variable file for the DMS stack. Copy to `terraform.tfvars` and fill in:

```hcl
os_auth_url     = "https://chi.uc.chameleoncloud.org:5000/v3"
os_region_name  = "CHI@UC"
os_project_name = "CHI-251409"

os_application_credential_id     = "replace-me"
os_application_credential_secret = "replace-me"

instance_name  = "proj26-dms-k3s"
image_name     = "CC-Ubuntu22.04"
flavor_name    = "baremetal"
network_name   = "sharednet1"
ssh_key_name   = "your-keypair"
reservation_id = "your-blazar-uuid"

allowed_ssh_cidr = "YOUR.PUBLIC.IP.ADDR/32"
allowed_api_cidr = "YOUR.PUBLIC.IP.ADDR/32"
volume_size_gb   = 100
ssh_user         = "cc"
```

---

## Cluster Runbook / Deployment Instructions

### [infra-dms/README.md](infra-dms/README.md)

End-to-end deployment guide covering six steps:

1. **Terraform** — `cp terraform.tfvars.example terraform.tfvars`, edit, `terraform init && terraform plan -out tfplan && terraform apply tfplan`. Requires `openstack` CLI and sourced app-cred RC file.
2. **kubectl** — `scp` the kubeconfig from the VM, rewrite `127.0.0.1` to the floating IP, export `KUBECONFIG`.
3. **Image** — build and push the app image to GHCR; use `kustomize edit set image` to pin the tag.
4. **Secrets** — copy `k8s/secrets.example.yaml` to `/tmp`, fill in values, `kubectl apply -f`.
5. **Deploy** — `kubectl apply -k k8s`. API available at `http://<floating-ip>:30080`. Metabase at port `30081`.
6. **Scale** — `kubectl -n dms scale deployment/dms-worker --replicas=3` or `dms-api --replicas=2`.

### deploy_readme.md *(not yet created)*

Planned top-level deployment quick-start. To be added at the repo root.

---

## Kubernetes Access / Config Helper

### scripts/fetch_k3s_kubeconfig.sh *(not yet created)*

Planned helper script to automate the kubeconfig retrieval steps from step 2 of the runbook:

```bash
# Intended usage (once created):
./scripts/fetch_k3s_kubeconfig.sh <floating-ip>
```

Manual equivalent until the script exists:

```bash
scp cc@<floating-ip>:/etc/rancher/k3s/k3s.yaml ~/.kube/dms-k3s.yaml
sed -i '' "s/127.0.0.1/<floating-ip>/g" ~/.kube/dms-k3s.yaml
export KUBECONFIG=~/.kube/dms-k3s.yaml
kubectl get nodes
```

---

## Kubernetes Manifests

All manifests live under [infra-dms/k8s/](infra-dms/k8s/) and are applied together via Kustomize.

### [kustomization.yaml](infra-dms/k8s/kustomization.yaml) — Bundle Entrypoint

Kustomize root. Pins all resources to namespace `dms` and lists the full deploy order:

```
namespace.yaml → configmap.yaml → postgres.yaml → redis.yaml →
metabase.yaml → api.yaml → worker.yaml → scheduler.yaml
```

Also manages the app image tag via the `images` field:

```yaml
images:
  - name: ghcr.io/nidhish1/dms-app
    newName: ghcr.io/nidhish1/dms-app
    newTag: latest
```

Apply everything with: `kubectl apply -k infra-dms/k8s`

### [namespace.yaml](infra-dms/k8s/namespace.yaml) — Namespace

Creates the `dms` Kubernetes namespace that all other resources are pinned to.

### [configmap.yaml](infra-dms/k8s/configmap.yaml) — Shared Config

`ConfigMap` named `dms-config` holding non-secret runtime configuration consumed by all three app roles:

| Key | Value |
|---|---|
| `DATABASE_HOST` | `postgres` |
| `DATABASE_PORT` | `5432` |
| `DATABASE_NAME` | `dms` |
| `DATABASE_USER` | `dms` |
| `REDIS_URL` | `redis://redis:6379/0` |
| `CELERY_BROKER_URL` | `redis://redis:6379/0` |
| `CELERY_RESULT_BACKEND` | `redis://redis:6379/1` |
| `SWIFT_USER_UPLOADS_CONTAINER` | `proj26-user-uploads` |
| `SWIFT_TRAINING_CONTAINER` | `proj26-training-data` |

### [secrets.example.yaml](infra-dms/k8s/secrets.example.yaml) — Secret Template

Template `Secret` named `dms-secrets`. Copy to a path outside the repo, fill in values, then apply:

| Key | Purpose |
|---|---|
| `DATABASE_PASSWORD` | PostgreSQL password |
| `SWIFT_AUTH_URL` | Chameleon Keystone URL |
| `SWIFT_APP_CREDENTIAL_ID` | Object storage app-cred ID |
| `SWIFT_APP_CREDENTIAL_SECRET` | Object storage app-cred secret |
| `KAGGLE_USERNAME` | Kaggle dataset downloads |
| `KAGGLE_KEY` | Kaggle API key |

---

## Project Service Deployments

### [api.yaml](infra-dms/k8s/api.yaml)

Deploys `dms-api` as a `Deployment` + `NodePort` Service.

- **Image**: `ghcr.io/nidhish1/dms-app:latest` with `DMS_ROLE=api`
- **Port**: container 8000 → NodePort **30080**
- **Resources**: 250m CPU / 512Mi RAM (request) · 500m CPU / 1Gi RAM (limit)
- **Probes**: readiness and liveness on `GET /healthz`
- **Env**: full set from `dms-config` ConfigMap and `dms-secrets` Secret; `DATABASE_URL` assembled inline from component vars

### [worker.yaml](infra-dms/k8s/worker.yaml)

Deploys `dms-worker` as a `Deployment` (no Service — pull-only).

- **Image**: `ghcr.io/nidhish1/dms-app:latest` with `DMS_ROLE=worker`
- **Resources**: 500m CPU / 1Gi RAM (request) · 2 CPU / 4Gi RAM (limit) — higher ceiling for burst ingest workloads
- **Additional env**: `KAGGLE_USERNAME`, `KAGGLE_KEY`, `KAGGLE_DOWNLOAD_DIR=/tmp/dms-kaggle-downloads`, `SWIFT_RECIPE1M_PREFIX=recipe1m`

### [scheduler.yaml](infra-dms/k8s/scheduler.yaml)

Deploys `dms-scheduler` as a `Deployment` (no Service).

- **Image**: `ghcr.io/nidhish1/dms-app:latest` with `DMS_ROLE=scheduler`
- **Resources**: 100m CPU / 256Mi RAM (request) · 250m CPU / 512Mi RAM (limit) — minimal footprint for orchestration-only role

---

## Platform Services

### [postgres.yaml](infra-dms/k8s/postgres.yaml)

Deploys PostgreSQL as a `StatefulSet` + headless `Service`.

- **Image**: `postgres:16-alpine`
- **Port**: 5432 (cluster-internal only)
- **Resources**: 500m CPU / 1Gi RAM (request) · 1 CPU / 2Gi RAM (limit)
- **Persistence**: `VolumeClaimTemplate` → PVC `postgres-data`, 100Gi, `storageClassName: local-path` backed by the mounted instance disk
- **Credentials**: `POSTGRES_DB`, `POSTGRES_USER` from `dms-config`; `POSTGRES_PASSWORD` from `dms-secrets`

### [redis.yaml](infra-dms/k8s/redis.yaml)

Deploys Redis as a `Deployment` + `Service`.

- **Image**: `redis:7-alpine`
- **Port**: 6379 (cluster-internal only)
- **Resources**: 100m CPU / 256Mi RAM (request) · 250m CPU / 512Mi RAM (limit)
- **Role**: Celery broker (`/0`) and result backend (`/1`)

### [metabase.yaml](infra-dms/k8s/metabase.yaml)

Deploys Metabase as a `Deployment` + `NodePort` Service + `PersistentVolumeClaim`.

- **Image**: `metabase/metabase:v0.56.3`
- **Port**: container 3000 → NodePort **30081**
- **Resources**: 250m CPU / 512Mi RAM (request) · 500m CPU / 1Gi RAM (limit)
- **Persistence**: PVC `metabase-data`, 10Gi, `storageClassName: local-path`; mounted at `/metabase-data`
- **Connect to DMS DB inside Metabase**: host `postgres`, port `5432`, database `dms`, user `dms`, password from `dms-secrets`

---

## Quick Reference — NodePorts and Access

| Service | NodePort | URL |
|---|---|---|
| DMS API | 30080 | `http://<floating-ip>:30080` |
| Metabase | 30081 | `http://<floating-ip>:30081` |

## Quick Reference — What Each File Provisions

| File | Kind | What it creates |
|---|---|---|
| `terraform/main.tf` | Terraform | Security group, floating IP, reserved VM, FIP association |
| `terraform/providers.tf` | Terraform | OpenStack + Null provider config |
| `terraform/variables.tf` | Terraform | All input variable declarations |
| `terraform/outputs.tf` | Terraform | IP, SSH command, kubeconfig command |
| `terraform/cloud-init.yaml.tftpl` | Cloud-init | Disk mount, k3s install, kubeconfig copy |
| `terraform/terraform.tfvars.example` | Config template | Filled-in variable values for Chameleon |
| `k8s/kustomization.yaml` | Kustomize | Deploy-order bundle, image tag management |
| `k8s/namespace.yaml` | Namespace | `dms` namespace |
| `k8s/configmap.yaml` | ConfigMap | Non-secret runtime config for all app roles |
| `k8s/secrets.example.yaml` | Secret template | DB password, Swift + Kaggle credentials |
| `k8s/api.yaml` | Deployment + Service | HTTP API, NodePort 30080 |
| `k8s/worker.yaml` | Deployment | Background Celery worker |
| `k8s/scheduler.yaml` | Deployment | Celery beat scheduler |
| `k8s/postgres.yaml` | StatefulSet + Service | PostgreSQL 16, 100Gi PVC |
| `k8s/redis.yaml` | Deployment + Service | Redis 7, Celery broker/backend |
| `k8s/metabase.yaml` | Deployment + Service + PVC | Metabase analytics, NodePort 30081 |
