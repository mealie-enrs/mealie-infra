# Deploy mealie-model-serve on your Chameleon k3s VM (e.g. 192.5.86.170)

## Can we deploy there?

**Yes, if** the same pattern as your DMS box holds:

1. **k3s** is installed (your DMS Terraform `cloud-init` does this).
2. **`local-path` StorageClass** exists (k3s default).
3. You can **`kubectl apply`** from your laptop with kubeconfig, or run `kubectl` **over SSH** on the VM.

This repo’s **Docker Compose** stack is the same components; **Kubernetes** just schedules them as Pods + Services + PVCs.

**Terraform note:** Use **`mealie-model-serve/infra/terraform`** for a dedicated MMS VM (security group opens **22**, **30601**, **30608**; cloud-init installs Docker + k3s). Alternatively, reuse **`mealie/infra/terraform`** for the VM and open those NodePorts in Horizon or a separate rule set. Either way, **apply k8s manifests** (below) with kubectl; this Terraform stack does not install workloads.

We **cannot** verify `192.5.86.170` from the assistant’s environment; after SSH, run `kubectl get nodes` to confirm.

---

## 1) Build and push images

On your Mac (or CI), from **`mealie-model-serve/`** root:

```bash
export REG=ghcr.io/<your-org>   # or docker.io/...

docker build -f Dockerfile.mlflow -t ${REG}/mealie-model-serve-mlflow:latest .
docker build -f Dockerfile.serving --build-arg GIT_SHA=$(git rev-parse --short HEAD) \
  -t ${REG}/mealie-model-serve-api:latest .

docker push ${REG}/mealie-model-serve-mlflow:latest
docker push ${REG}/mealie-model-serve-api:latest
```

Edit **`infra/k8s/kustomization.yaml`** `images:` to match `${REG}` and tag.

On k3s without a registry mirror, you can **`docker save` | `ssh` | `sudo k3s ctr images import`** instead of push/pull.

---

## 2) Secrets

```bash
cp infra/k8s/secrets.example.yaml /tmp/mms-secrets.yaml
# edit passwords + MLFLOW_BACKEND_STORE_URI (password must match DATABASE_PASSWORD)
kubectl apply -f /tmp/mms-secrets.yaml
```

---

## 3) Apply manifests

```bash
export KUBECONFIG=~/.kube/config   # or scp from VM: /etc/rancher/k3s/k3s.yaml
kubectl apply -k infra/k8s/
kubectl -n mms rollout status deployment/mms-mlflow --timeout=300s
kubectl -n mms rollout status deployment/mms-model-serve --timeout=300s
```

---

## 4) Register a model (Job or laptop)

Same as local: run **`trainer/train.py`** or **`trainer/toy_random_onnx.py`** with:

- `MLFLOW_TRACKING_URI=http://<FLOATING_IP>:30601` (NodePort to MLflow), or port-forward:
  `kubectl -n mms port-forward svc/mlflow 5000:5000`

and MinIO/S3 env pointing at **`http://<FLOATING_IP>:<minio-nodeport>`** — MinIO is **ClusterIP** only in these manifests; for training from **outside** the cluster, either:

- add a **NodePort Service** for Minio (9000), or  
- `kubectl port-forward -n mms svc/minio 9020:9000` from your laptop while training.

---

## 5) URLs (replace `<IP>` with 192.5.86.170 if that is the node with NodePort routing)

| Service | URL |
|---------|-----|
| MLflow UI | `http://<IP>:30601` |
| Model API | `http://<IP>:30608` (e.g. `/metadata`, `/predict`) |

**Security group:** allow **TCP 30601** and **30608** (and any extra NodePorts you add) from where you browse/curl.

---

## 6) OpenStack / Terraform (optional)

If you want Terraform to open ports, add rules to the same security group as the DMS instance (example values — adjust names):

```hcl
resource "openstack_networking_secgroup_rule_v2" "mms_mlflow" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 30601
  port_range_max    = 30601
  remote_ip_prefix  = var.allowed_api_cidr
  security_group_id = openstack_networking_secgroup_v2.dms.id
}

resource "openstack_networking_secgroup_rule_v2" "mms_api" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 30608
  port_range_max    = 30608
  remote_ip_prefix  = var.allowed_api_cidr
  security_group_id = openstack_networking_secgroup_v2.dms.id
}
```

(Use your real `security_group_id` and CIDR.)

---

## Chameleon object store (S3 API) instead of MinIO

Chameleon’s object store is **Swift** with an **S3-compatible API** on port **7480**. MLflow and this repo’s code use **boto3** (`MLFLOW_S3_ENDPOINT_URL`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`), same as MinIO.

### Folder layout in your container (`serve/` as team root)

Pick one **Swift container** name — that becomes the **S3 bucket** name (e.g. `proj26-obj-store`). There are no real nested folders; `/` is a **prefix** inside object keys.

Example artifact root:

`s3://proj26-obj-store/serve/mlflow-artifacts`

After MLflow runs, keys look like:

```text
proj26-obj-store   (Swift container = S3 bucket)
└── serve/
    └── mlflow-artifacts/
        └── <experiment_id>/
            └── <run_id>/
                └── artifacts/
                    └── model/
                        └── ...
```

Add other prefixes under **`serve/`** for non-MLflow data (e.g. `serve/exports/...`) in the same bucket.

Set this in the overlay ConfigMap patch as:

`MLFLOW_ARTIFACTS_DESTINATION: s3://<container>/serve/mlflow-artifacts`

### Region endpoints

- **CHI@UC:** `https://chi.uc.chameleoncloud.org:7480`
- **CHI@TACC:** `https://chi.tacc.chameleoncloud.org:7480`

### Credentials (not OpenStack password)

Create **EC2 / S3** credentials (used by boto3):

```bash
source ~/secrets/app-cred-nidhish-mac-openrc.sh   # or your RC file
openstack ec2 credentials create
```

Put the **Access** string in Kubernetes secret key **`MINIO_ROOT_USER`** and the **Secret** string in **`MINIO_ROOT_PASSWORD`** (the manifests map those to `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`).

### Swift container must exist

```bash
openstack container create proj26-obj-store   # if it does not exist yet
```

The startup script will call S3 **`CreateBucket`** if the bucket is missing; on Chameleon it is safer to create the container explicitly if you hit permission quirks.

### Deploy overlay (no MinIO pod)

1. Edit **`infra/k8s/overlays/chameleon-s3/patch-config-chameleon.yaml`**: set your Swift container name and the correct **7480** URL for your site (UC vs TACC).
2. Apply secrets (Postgres password + EC2 keys as above).
3. Build and apply (the overlay references parent YAML; use relaxed load rules or pipe):

```bash
kubectl kustomize infra/k8s/overlays/chameleon-s3 \
  --load-restrictor LoadRestrictionsNone | kubectl apply -f -
```

From the repo root; run against the same path on your machine.

### boto3 + Ceph checksum quirk

Manifests set **`AWS_REQUEST_CHECKSUM_CALCULATION=WHEN_REQUIRED`** and **`AWS_RESPONSE_CHECKSUM_VALIDATION=WHEN_REQUIRED`** on MLflow, model-serve, and the seed Job to avoid **`MissingContentLength`** issues with Chameleon’s S3 gateway (see community reports for MLflow + Chameleon). The repo pins **boto3 1.35.x** in images for the same reason.

### Local Docker Compose

Point **`MLFLOW_S3_ENDPOINT_URL`** at the **7480** URL, set **`MLFLOW_ARTIFACTS_DESTINATION`** like above, and export the same EC2 access/secret as **`AWS_ACCESS_KEY_ID`** / **`AWS_SECRET_ACCESS_KEY`**. For in-cluster MinIO, leave the default compose files as they are.

---

## GitHub Actions (build → GHCR → k3s)

Workflow: **`.github/workflows/deploy.yml`**. On every push to **`main`**, it builds **`linux/amd64`** images, pushes to **`ghcr.io/<lowercase-github-owner>/mealie-model-serve-{mlflow,api}`** (tags **`:<12-char-sha>`** and **`:latest`**), then SSHes to your VM and runs **`kubectl set image`** for `mms-mlflow` and `mms-model-serve` in namespace **`mms`**.

### One-time: GitHub repo settings

1. **Actions → General → Workflow permissions:** allow **Read and write** (so `GITHUB_TOKEN` can push packages).
2. **Repository secrets** (Settings → Secrets and variables → Actions):

| Secret | Purpose |
|--------|--------|
| `SSH_HOST` | VM floating IP (e.g. `192.5.86.170`) |
| `SSH_USER` | Login user (e.g. `cc`) |
| `SSH_PRIVATE_KEY_B64` | **Recommended:** one-line base64 of the private key: `base64 < ~/.ssh/gha-mms-deploy \| tr -d '\n'` then paste into the secret |
| `SSH_PRIVATE_KEY` | Optional fallback: multiline PEM (if SSH still fails, use B64 only) |

Optional (only if GHCR packages are **private**):

| Secret | Purpose |
|--------|--------|
| `GHCR_PULL_TOKEN` | PAT with **`read:packages`** |
| `GHCR_PULL_USERNAME` | GitHub username that owns the PAT (defaults to lowercase owner if unset) |

3. After the first workflow run, open **Packages** on GitHub and set **`mealie-model-serve-api` / `mealie-model-serve-mlflow`** to **Public** if you want pulls without a cluster pull secret.

### One-time: cluster must already run MMS

Apply manifests once (MinIO or Chameleon overlay) so **`Deployment/mms-mlflow`** and **`Deployment/mms-model-serve`** exist. The pipeline only swaps images.

### Automating private GHCR (recommended)

1. **GitHub Actions secrets** **`GHCR_PULL_TOKEN`** + **`GHCR_PULL_USERNAME`** (PAT owner, `read:packages`, SSO authorized for the org if needed).  
   Every deploy then **recreates `ghcr-pull`** and **patches `imagePullSecrets`** on `mms-mlflow` and `mms-model-serve` — safe for a **new VM** or after **`kubectl apply`** resets.

2. **New cluster / manual bootstrap** (after `kubectl apply -k infra/k8s/` and workloads exist):

   ```bash
   export GHCR_USERNAME=nidhish1
   read -s GHCR_PAT && echo
   KUBECTL="sudo k3s kubectl" ./scripts/k8s-bootstrap-ghcr-auth.sh
   ```

3. **Bake `imagePullSecrets` into Git** (optional): add **`patches/ghcr-imagepull.yaml`** to **`infra/k8s/kustomization.yaml`** under `patches:` (see comment in that file). You must create **`ghcr-pull`** before pods schedule, or they stay pending.

4. **Public GHCR packages** → skip pull secret entirely (simplest for class projects).

### Private GHCR: imagePullSecrets (manual one-liner)

If you do **not** use `GHCR_PULL_TOKEN` in Actions, patch once (or use `scripts/k8s-bootstrap-ghcr-auth.sh`):

```bash
kubectl patch deployment mms-mlflow -n mms --type=strategic -p \
  '{"spec":{"template":{"spec":{"imagePullSecrets":[{"name":"ghcr-pull"}]}}}}'
kubectl patch deployment mms-model-serve -n mms --type=strategic -p \
  '{"spec":{"template":{"spec":{"imagePullSecrets":[{"name":"ghcr-pull"}]}}}}'
```

(Use `sudo k3s kubectl` on the VM if that is how you manage the cluster.)

### SSH and sudo

The workflow runs **`sudo k3s kubectl`** on the VM. Your user must have **passwordless sudo** (default on many Chameleon images).

---

## Troubleshooting

- **`ImagePullBackOff`:** set `imagePullSecrets` for GHCR or import images on the node.  
- **`Pending` PVCs:** check `kubectl get sc` — need `local-path`.  
- **Model serve `503` on `/readyz`:** no registry model yet — run trainer against MLflow, then restart deployment or `POST /reload`.
