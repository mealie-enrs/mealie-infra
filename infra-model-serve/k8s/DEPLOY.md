# Model Serve on Chameleon

This document covers the current `infra-model-serve/` path in this repo.

It applies to two deployment patterns:

- a dedicated model-serve VM provisioned with `infra-model-serve/terraform`
- an existing k3s cluster, including the DMS cluster, if you open ports `30601` and `30608` and the cluster satisfies the GPU scheduling requirements

## What This Stack Deploys

The default base bundle at `infra-model-serve/k8s/` deploys:

- `postgres`
- `minio`
- `mlflow` on NodePort `30601`
- `mms-model-serve` on NodePort `30608`
- `job-train-food-classifier`

The Chameleon S3 overlay at `infra-model-serve/k8s/overlays/chameleon-s3/` replaces in-cluster MinIO with Chameleon object storage and includes `job-seed-toy-model.yaml` instead of the training job.

## Important Constraints

Read these before applying anything:

- this repo does not contain `Dockerfile.mlflow` or `Dockerfile.serving`, so image builds must happen in the application repo or come from prebuilt images
- `infra-model-serve/k8s/model-serve.yaml` currently requests `nvidia.com/gpu: 1` and restricts scheduling to hostnames `nc01` through `nc38`
- `infra-model-serve/k8s/job-train-food-classifier.yaml` currently requests `nvidia.com/gpu: 1` and restricts scheduling to hostnames `gigaio02` through `gigaio06`
- if your cluster does not expose those nodes or GPUs, `mms-model-serve` and the training job will stay `Pending` until you edit those manifests
- the base `kustomization.yaml` includes `job-train-food-classifier.yaml`; remove it from `infra-model-serve/k8s/kustomization.yaml` before apply if you do not want that job created
- `mms-model-serve` will not become ready until a model exists at the configured `MODEL_URI`, which defaults to `models:/food-classifier@staging`

## 1) Provision Infrastructure

Skip this section if you are reusing an existing k3s cluster.

From the repo root:

```bash
cd infra-model-serve/terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars for your environment
terraform init
terraform plan -out tfplan
terraform apply tfplan
```

Important notes:

- `reservation_id` is required by the current Terraform implementation because the VM is created with `openstack server create --hint reservation=<UUID>`
- replace placeholder values in `terraform.tfvars`, especially `os_application_credential_id`, `os_application_credential_secret`, `reservation_id`, `allowed_ssh_cidr`, and `allowed_mms_cidr`
- `allowed_ssh_cidr` must include the public IP you will SSH from
- `allowed_mms_cidr` must include the public IP or CIDR that should reach MLflow on `30601` and the model API on `30608`
- the default SSH user is `cc`; if you change `ssh_user`, use that user in all SSH and `scp` commands
- the stack does not create a separate OpenStack block volume; if the instance exposes a secondary disk, cloud-init mounts it for k3s local storage

Before `terraform apply`, load your OpenStack auth environment, for example:

```bash
source /path/to/app-cred-openrc.sh
```

Terraform outputs:

- the floating IP
- an SSH command
- a kubeconfig copy command

Do not assume the floating IP is permanent. If the instance is reprovisioned or the floating IP is reassigned, resolve the current address again before using SSH, `scp`, or NodePort URLs:

```bash
cd infra-model-serve/terraform
terraform output -raw floating_ip
```

## 2) Wait For k3s And Configure kubectl

`terraform apply` waits for the VM to become `ACTIVE`, but k3s is installed afterward by cloud-init. Wait for bootstrap to finish before copying kubeconfig:

```bash
ssh <ssh-user>@<floating-ip> 'sudo cloud-init status --wait && sudo systemctl is-active k3s && sudo test -f /etc/rancher/k3s/k3s.yaml'
```

Use the value of `ssh_user` from `terraform.tfvars`. If you did not change it, the default is `cc`.

Copy kubeconfig from the VM and rewrite the server endpoint to the floating IP:

```bash
mkdir -p ~/.kube
scp <ssh-user>@<floating-ip>:/etc/rancher/k3s/k3s.yaml ~/.kube/mms-k3s.yaml

# macOS
sed -i '' "s/127.0.0.1/<floating-ip>/g" ~/.kube/mms-k3s.yaml

# Linux
# sed -i "s/127.0.0.1/<floating-ip>/g" ~/.kube/mms-k3s.yaml

export KUBECONFIG=~/.kube/mms-k3s.yaml
kubectl get nodes
```

If the floating IP changes later, update `~/.kube/mms-k3s.yaml` with the new address before using `kubectl` again.

If you are reusing an existing cluster, use that cluster’s kubeconfig instead.

## 3) Choose An Image Strategy

The current base `infra-model-serve/k8s/kustomization.yaml` rewrites the manifest image names to:

- `mealie-model-serve-mlflow:latest`
- `mealie-model-serve-api:latest`

and sets `imagePullPolicy: IfNotPresent` on the two deployments. That means the default path expects images to already exist on the node.

### Option A: Preload local images into k3s

Use this if you have image tarballs from the application repo:

```bash
docker save mealie-model-serve-mlflow:latest | ssh <ssh-user>@<floating-ip> 'sudo k3s ctr images import -'
docker save mealie-model-serve-api:latest | ssh <ssh-user>@<floating-ip> 'sudo k3s ctr images import -'
```

### Option B: Use a real registry

If you have published images in a registry, update the Kustomize image rules:

```bash
cd infra-model-serve/k8s
kustomize edit set image ghcr.io/your-org/mealie-model-serve-mlflow=ghcr.io/<org>/mealie-model-serve-mlflow:<tag>
kustomize edit set image ghcr.io/your-org/mealie-model-serve-api=ghcr.io/<org>/mealie-model-serve-api:<tag>
cd ../..
```

If the registry is private, add Kubernetes `imagePullSecrets` as needed.

## 4) Configure Secrets

Create the secret from the template:

```bash
cp infra-model-serve/k8s/secrets.example.yaml /tmp/mms-secrets.yaml
# edit values in /tmp/mms-secrets.yaml
kubectl apply -f /tmp/mms-secrets.yaml
```

At minimum, set:

- `DATABASE_PASSWORD`
- `MINIO_ROOT_USER`
- `MINIO_ROOT_PASSWORD`
- `MLFLOW_BACKEND_STORE_URI`

The password inside `MLFLOW_BACKEND_STORE_URI` must match `DATABASE_PASSWORD`.

## 5) Choose Your Storage Backend

### Option A: Default MinIO path

The base bundle uses `infra-model-serve/k8s/configmap.yaml`, which points MLflow and serving to in-cluster MinIO at `http://minio:9000`.

Apply the bundle with:

```bash
kubectl apply -k infra-model-serve/k8s
```

Useful checks:

```bash
kubectl -n mms get pods
kubectl -n mms get pvc
kubectl -n mms rollout status deployment/mms-mlflow --timeout=300s
kubectl -n mms rollout status deployment/mms-model-serve --timeout=300s
```

Notes:

- if you left `job-train-food-classifier.yaml` in the Kustomization and your cluster does not satisfy its GPU affinity, that job may stay `Pending`
- if your cluster does not satisfy `mms-model-serve` GPU affinity, the serving deployment may stay `Pending`

### Option B: Chameleon object store overlay

The overlay at `infra-model-serve/k8s/overlays/chameleon-s3/` removes MinIO and points MLflow and serving at Chameleon’s S3-compatible API on port `7480`.

Before apply:

1. Create or choose a Swift container:

```bash
openstack container create <swift-container-name>
```

2. Create EC2/S3 credentials:

```bash
openstack ec2 credentials create
```

3. Put the access key in secret key `MINIO_ROOT_USER` and the secret key in `MINIO_ROOT_PASSWORD`.
4. Edit `infra-model-serve/k8s/overlays/chameleon-s3/patch-config-chameleon.yaml` for your Swift container name and site endpoint.
5. If needed, review:
   - `patch-hostaliases-chi-uc.yaml`
   - `patch-hostnetwork-egress.yaml`
   - `patch-deployment-recreate.yaml`

Apply the overlay with:

```bash
kubectl apply -f /tmp/mms-secrets.yaml
kubectl kustomize infra-model-serve/k8s/overlays/chameleon-s3 \
  --load-restrictor LoadRestrictionsNone | kubectl apply -f -
```

The overlay includes `job-seed-toy-model.yaml`, so it seeds a placeholder model as part of the apply path.

Important note:

- `job-seed-toy-model.yaml` uses `image: mealie-model-serve-api:latest`; if you are using registry images instead of preloaded local images, update that job image before applying the overlay

## 6) Register Or Seed A Model

`mms-model-serve` expects `MODEL_URI=models:/food-classifier@staging` by default.

You have three options:

- run your normal training workflow against MLflow
- apply `infra-model-serve/k8s/job-train-food-classifier.yaml` on a compatible GPU cluster
- apply `infra-model-serve/k8s/job-seed-toy-model.yaml` to register a toy ONNX model

Example seed job flow:

```bash
kubectl apply -f infra-model-serve/k8s/job-seed-toy-model.yaml
kubectl -n mms wait --for=condition=complete job/mms-seed-toy-model --timeout=300s
kubectl -n mms logs job/mms-seed-toy-model
```

Important note:

- `job-seed-toy-model.yaml` uses `image: mealie-model-serve-api:latest`; if you are using registry images instead of preloaded local images, update that file before applying it

## 7) Validate Access

MLflow is exposed on NodePort `30601`:

Open `http://<floating-ip>:30601` in your browser.

The serving API is exposed on NodePort `30608`:

```bash
curl http://<floating-ip>:30608/healthz
curl http://<floating-ip>:30608/readyz
```

If `readyz` returns an error, check whether:

- `mms-model-serve` is still `Pending` because of GPU or hostname affinity
- no model has been registered yet at `models:/food-classifier@staging`

## 8) Troubleshooting

- `ImagePullBackOff`: the node cannot pull the image you referenced; either import local images with `k3s ctr images import` or add registry auth
- `Pending` PVCs: check that `local-path` exists with `kubectl get sc`
- `mms-model-serve` `Pending`: the cluster does not satisfy the GPU request or hostname affinity in `infra-model-serve/k8s/model-serve.yaml`
- `mms-train-food-classifier` `Pending`: the cluster does not satisfy the GPU request or hostname affinity in `infra-model-serve/k8s/job-train-food-classifier.yaml`
- `readyz` fails after the pod starts: register or seed a model first
