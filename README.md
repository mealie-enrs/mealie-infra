# Mealie Infra on Chameleon

This repository contains two infrastructure paths:

- [infra-dms/](infra-dms/) for the data management service (DMS)
- [infra-model-serve/](infra-model-serve/) for MLflow, artifact storage, and model serving

The stacks can be deployed on separate k3s VMs, or on the same cluster if you understand the port, storage, and GPU implications.

## Start Here

- DMS detailed bring-up: [infra-dms/README.md](infra-dms/README.md)
- Model-serve detailed bring-up: [infra-model-serve/k8s/DEPLOY.md](infra-model-serve/k8s/DEPLOY.md)
- Optional Triton serving path: [infra-model-serve/triton/README.md](infra-model-serve/triton/README.md)
- Repo file map: [infra-file-guide.md](infra-file-guide.md)
- Sizing notes: [infra-requirements-table.md](infra-requirements-table.md)

## Repo Layout

### DMS

- `infra-dms/terraform/`: provisions a Chameleon VM, security group, and floating IP
- `infra-dms/k8s/docker/`: deploys `api`, `worker`, `scheduler`, `postgres`, `redis`, and `metabase`

### Model Serve

- `infra-model-serve/terraform/`: provisions a Chameleon VM, security group, and floating IP
- `infra-model-serve/k8s/`: deploys `postgres`, `minio`, `mlflow`, `mms-model-serve`, and supporting jobs
- `infra-model-serve/k8s/overlays/chameleon-s3/`: replaces in-cluster MinIO with Chameleon object storage
- `infra-model-serve/docker-compose*.yml`: local Compose variants for the model-serve stack
- `infra-model-serve/triton/`: optional Triton Inference Server assets and notes

## Shared Prerequisites

Before bringing up either stack, make sure you have:

- Terraform `>= 1.6`
- `openstack` CLI installed and authenticated in your shell
- `ssh` and `scp`
- `kubectl`
- `kustomize` if you want to override image names without editing YAML directly

Important repo-level note:

- this repo does not contain the application Dockerfiles for DMS or model-serve, so image build steps depend on the corresponding application repo or prebuilt images

## Quick Start

### DMS

1. Follow [infra-dms/README.md](infra-dms/README.md).
2. Provision the VM with `infra-dms/terraform`.
3. Configure kubeconfig from the Terraform output floating IP.
4. Apply the DMS manifests with:

```bash
kubectl apply -k infra-dms/k8s/docker
```

### Model Serve

1. Follow [infra-model-serve/k8s/DEPLOY.md](infra-model-serve/k8s/DEPLOY.md).
2. Provision the VM with `infra-model-serve/terraform`, or reuse an existing k3s cluster and open ports `30601` and `30608`.
3. Configure kubeconfig from the Terraform output floating IP.
4. Apply either:

```bash
kubectl apply -k infra-model-serve/k8s
```

for the default in-cluster MinIO path, or:

```bash
kubectl kustomize infra-model-serve/k8s/overlays/chameleon-s3 \
  --load-restrictor LoadRestrictionsNone | kubectl apply -f -
```

for the Chameleon S3 overlay.

### Optional Triton Path

If you want to evaluate Triton as an alternative inference front-end instead of the FastAPI-based model-serve deployment, see:

- [infra-model-serve/triton/README.md](infra-model-serve/triton/README.md)

That path is optional and separate from the default `infra-model-serve/k8s/` deployment.

## Important Differences Between The Stacks

- DMS is a CPU-oriented app stack and exposes its API on NodePort `30080`.
- Model serve exposes MLflow on `30601` and the serving API on `30608`.
- The current `infra-model-serve/k8s/model-serve.yaml` requests `nvidia.com/gpu: 1` and constrains scheduling to specific GPU hostnames. Review that file before assuming the stack will schedule on an arbitrary cluster.
- The current `infra-model-serve/k8s/kustomization.yaml` also includes `job-train-food-classifier.yaml`, which can remain `Pending` if your cluster does not provide the expected GPU training nodes.

## Operational Notes

- Do not assume a floating IP is permanent. Re-check `terraform output -raw floating_ip` before running SSH, `scp`, or NodePort commands.
- If you change `ssh_user` in a stack’s `terraform.tfvars`, use that user consistently in all SSH and kubeconfig copy steps.
- If you deploy private images, you may need to add Kubernetes `imagePullSecrets`.
