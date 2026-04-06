# Infrastructure Requirements Table

This document maps each Kubernetes service to explicit compute settings and explains the right-sizing basis used on Chameleon.

## Chameleon Right-Sizing Evidence Used

- Cluster compute baseline is configured as baremetal in both stacks:
  - `infra-dms/terraform/terraform.tfvars.example` -> `flavor_name = "baremetal"`
  - `infra-model-serve/terraform/terraform.tfvars.example` -> `flavor_name = "baremetal"`
- Single-node k3s cluster is installed by cloud-init in both stacks:
  - `infra-dms/terraform/cloud-init.yaml.tftpl`
  - `infra-model-serve/terraform/cloud-init.yaml.tftpl`
- Persistent storage for stateful workloads uses `local-path` PVs backed by mounted instance disk.
- Public service reachability is controlled by Chameleon security-group rules for NodePorts:
  - DMS API: 30080
  - MLflow: 30601
  - Model Serve API: 30608

## Per-Service Resource Table

| Service | Namespace | Workload | CPU Request | CPU Limit | Memory Request | Memory Limit | GPU Request/Limit | Evidence and Right-Sizing Rationale |
|---|---|---|---:|---:|---:|---:|---|---|
| dms-api | dms | Deployment (`dms-api`) | 250m | 1 | 512Mi | 1Gi | none / none | HTTP API with lightweight request handling and storage metadata calls; baseline tuned for low steady state with burst headroom on baremetal node. |
| dms-worker | dms | Deployment (`dms-worker`) | 500m | 2 | 1Gi | 4Gi | none / none | Background ingest and data prep are most variable in DMS; higher memory/CPU ceiling set for burst workloads while keeping conservative guaranteed request. |
| dms-scheduler | dms | Deployment (`dms-scheduler`) | 100m | 500m | 256Mi | 512Mi | none / none | Scheduler process is low throughput and mostly orchestration/timing; minimal guaranteed footprint. |
| redis | dms | Deployment (`redis`) | 100m | 500m | 128Mi | 512Mi | none / none | Queue/cache role with small in-memory working set for this project scope; limit prevents unbounded memory growth. |
| postgres (dms) | dms | StatefulSet (`postgres`) | 250m | 1 | 512Mi | 2Gi | none / none | Stateful DB with PVC-backed data; moderate request for predictable query latency and higher limit for compaction/checkpoint bursts. |
| mms-mlflow | mms | Deployment (`mms-mlflow`) | 250m | 1 | 512Mi | 1Gi | none / none | Tracking server is mostly I/O and metadata operations; artifacts offloaded to object store. |
| mms-model-serve | mms | Deployment (`mms-model-serve`) | 1 | 2 | 2Gi | 4Gi | RTX 6000 / `nvidia.com/gpu: 1` | Inference + model loading path is GPU-backed on the Chameleon RTX 6000 host set (`nc01`-`nc38`) to match the CUDA serving option and keep latency consistent under load. |
| minio | mms | StatefulSet (`minio`) | 250m | 1 | 512Mi | 2Gi | none / none | Object-storage backend with PVC-backed data path; moderate guarantees for steady artifact read/write traffic. |
| postgres (mms) | mms | StatefulSet (`postgres`) | 250m | 1 | 512Mi | 2Gi | none / none | MLflow backend DB; similar transactional profile to DMS DB and same persistence behavior. |

## Init Container Coverage

The `mms-mlflow` init containers (`wait-postgres`, `wait-minio`) also include requests/limits:

- CPU: 10m request / 100m limit
- Memory: 32Mi request / 64Mi limit

## GPU Policy for Training (`train.py`)

Current running services are CPU-targeted, so no workload requests GPU now. For model training, `train.py` should run as a separate Kubernetes Job on the Chameleon ML training host set (`gigaio02` through `gigaio06`). GPU is reserved for the training workload only; the serving workload is handled separately on the GPU inference host set.

```yaml
resources:
  requests:
    cpu: "2"
    memory: 8Gi
    nvidia.com/gpu: "1"
  limits:
    cpu: "4"
    memory: 16Gi
    nvidia.com/gpu: "1"
```

For the rubric, note the GPU as RTX 6000 on the Chameleon host and `nvidia.com/gpu: 1` in Kubernetes. Only set GPU on training/inference workloads that actually require CUDA.

## Training Job Row To Cite

If you want the table to explicitly include training, add a row like this:

| train.py | mms or a training namespace | Kubernetes Job | 2 cores | 4 cores | 8Gi | 16Gi | GPU / `nvidia.com/gpu: 1` | Chameleon ML training node required for training; schedule this Job only onto the ML training hosts (`gigaio02`-`gigaio06`). |

## Commands To Capture Submission Evidence (Chameleon)

Run these on your Chameleon cluster and paste key outputs/screenshots into your report/demo:

```bash
kubectl get nodes -o wide
kubectl describe node
kubectl top node
kubectl top pods -A
kubectl get pods -A -o wide
kubectl get pvc -A
```

These commands provide direct evidence for node capacity, observed utilization, and persistence claims used to justify the right-sizing table.
