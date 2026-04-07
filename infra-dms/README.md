# Infra: DMS on Chameleon

This repository contains the infrastructure for the DMS stack under `infra-dms/`:

- `infra-dms/terraform/`: provisions one Chameleon VM, a security group, and a floating IP
- `infra-dms/k8s/docker/`: deploys the DMS runtime roles (`api`, `worker`, `scheduler`) plus `postgres`, `redis`, and `metabase`

## Prerequisites

Before bringing the stack up, make sure you have:

- Terraform `>= 1.6`
- `openstack` CLI installed and authenticated in your shell
- `ssh` and `scp`
- `kubectl`
- `kustomize` if you want to update image tags without editing YAML directly
- a published DMS application image in a registry the VM can pull from

This repo does not contain the DMS application `Dockerfile`. Build the app image from the DMS application repo, or use the image already referenced by the manifests if it is pullable from your node.

## 1) Provision infrastructure with Terraform

From the repo root:

```bash
cd infra-dms/terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars for your project values
terraform init
terraform plan -out tfplan
terraform apply tfplan
```

Required inputs are defined in `infra-dms/terraform/variables.tf`.

Important notes:

- `reservation_id` is required by the current Terraform implementation because the VM is created with `openstack server create --hint reservation=<UUID>`
- `ssh_key_name` must already exist as an OpenStack keypair
- replace the placeholder values in `terraform.tfvars`, especially `os_application_credential_id`, `os_application_credential_secret`, `reservation_id`, `allowed_ssh_cidr`, and `allowed_api_cidr`
- `allowed_ssh_cidr` must include the public IP you will SSH from, or you will lock yourself out of the VM
- `allowed_api_cidr` must include the public IP or CIDR that should be allowed to reach `http://<floating-ip>:30080`
- the default SSH user is `cc`; change `ssh_user` if your chosen image uses a different user
- this stack does not currently create a separate OpenStack block volume; if the instance exposes a secondary disk, cloud-init mounts it for k3s local storage, otherwise persistent volumes remain on the root disk

Before `terraform apply`, ensure your OpenStack auth environment is loaded, for example:

```bash
source /path/to/app-cred-openrc.sh
```

After apply, Terraform outputs:

- the VM floating IP
- an SSH command
- a kubeconfig copy command

Do not assume the floating IP is permanent. If the instance is reprovisioned or the floating IP is reassigned, resolve the current address again before running any SSH, `scp`, `curl`, or kubeconfig rewrite steps:

```bash
cd infra-dms/terraform
terraform output -raw floating_ip
```

## 2) Wait for k3s bootstrap to finish

`terraform apply` waits for the VM to become `ACTIVE`, but k3s is installed afterward by cloud-init. Wait for bootstrap to finish before copying kubeconfig:

```bash
ssh <ssh-user>@<floating-ip> 'sudo cloud-init status --wait && sudo systemctl is-active k3s && sudo test -f /etc/rancher/k3s/k3s.yaml'
```

Use the value of `ssh_user` from `terraform.tfvars`. If you did not change it, the default is `cc`.

## 3) Configure kubectl

Copy kubeconfig from the VM and rewrite the server endpoint to the floating IP:

```bash
mkdir -p ~/.kube
scp <ssh-user>@<floating-ip>:/etc/rancher/k3s/k3s.yaml ~/.kube/dms-k3s.yaml

# macOS
sed -i '' "s/127.0.0.1/<floating-ip>/g" ~/.kube/dms-k3s.yaml

# Linux
# sed -i "s/127.0.0.1/<floating-ip>/g" ~/.kube/dms-k3s.yaml

export KUBECONFIG=~/.kube/dms-k3s.yaml
kubectl get nodes
```

If the floating IP changes later, update `~/.kube/dms-k3s.yaml` with the new address before using `kubectl` again.

## 4) Build and push the DMS app image

Build the image from the DMS application repo, not from this infrastructure repo:

```bash
docker build -t ghcr.io/<org>/dms-app:<tag> .
docker push ghcr.io/<org>/dms-app:<tag>
```

If you intentionally want to use the image already referenced by the manifests, and that image is pullable from your node, you can skip this build/push step and leave the image unchanged.

The Kubernetes manifests currently reference `ghcr.io/nidhish1/dms-app:latest`. To override that image via Kustomize:

```bash
cd infra-dms/k8s/docker
kustomize edit set image ghcr.io/nidhish1/dms-app=ghcr.io/<org>/dms-app:<tag>
cd ../../..
```

If you do not have `kustomize`, replace `ghcr.io/nidhish1/dms-app:latest` manually in:

- `infra-dms/k8s/docker/api.yaml`
- `infra-dms/k8s/docker/worker.yaml`
- `infra-dms/k8s/docker/scheduler.yaml`

The current manifests do not define `imagePullSecrets`, so the image should be anonymously pullable unless you extend the manifests.

## 5) Configure runtime secrets and config

Create the Kubernetes secret from the template:

```bash
cp infra-dms/k8s/docker/secrets.example.yaml /tmp/dms-secrets.yaml
# edit values in /tmp/dms-secrets.yaml
kubectl apply -f /tmp/dms-secrets.yaml
```

At minimum, fill in:

- `DATABASE_PASSWORD`
- `SWIFT_AUTH_URL`
- `SWIFT_APP_CREDENTIAL_ID`
- `SWIFT_APP_CREDENTIAL_SECRET`
- `KAGGLE_USERNAME`
- `KAGGLE_KEY`

Non-secret runtime values live in `infra-dms/k8s/docker/configmap.yaml`. If your Swift container names differ from the defaults, update:

- `SWIFT_USER_UPLOADS_CONTAINER`
- `SWIFT_TRAINING_CONTAINER`

## 6) Deploy to Kubernetes

```bash
kubectl apply -k infra-dms/k8s/docker
kubectl -n dms get pods
kubectl -n dms get pvc
```

Useful rollout checks:

```bash
kubectl -n dms rollout status deployment/dms-api
kubectl -n dms rollout status deployment/dms-worker
kubectl -n dms rollout status deployment/dms-scheduler
```

## 7) Validate access

The API is exposed via NodePort `30080` and is reachable only from the CIDR allowed by `allowed_api_cidr`:

```bash
curl http://<floating-ip>:30080/healthz
```

`metabase.yaml` is included in the default Kustomize bundle, but Terraform currently opens only SSH and API port `30080` in the security group. To access Metabase, either port-forward it:

```bash
kubectl -n dms port-forward svc/metabase 30081:3000
```

Then open `http://localhost:30081` in your browser.

or extend the Terraform security-group rules to allow NodePort `30081`.

Inside Metabase, connect to the in-cluster PostgreSQL database using:

- Host: `postgres`
- Port: `5432`
- Database: `dms`
- Username: `dms`
- Password: the `DATABASE_PASSWORD` value from `dms-secrets`

## 8) Optional sample ingest job

The sample ingest job is not part of the default Kustomize bundle. If you want to run it after the base stack is healthy:

```bash
kubectl apply -f infra-dms/k8s/docker/food101-sample-ingest.yaml
kubectl -n dms logs job/food101-sample-ingest -f
```

This job uses the same `dms-secrets` and `dms-config` objects as the main stack.

## 9) Scale later

Increase worker throughput:

```bash
kubectl -n dms scale deployment/dms-worker --replicas=3
```

Increase API replicas:

```bash
kubectl -n dms scale deployment/dms-api --replicas=2
```
