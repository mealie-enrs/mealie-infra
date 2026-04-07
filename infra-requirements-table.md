# Q2.1 Infrastructure Requirements Table

This table lists the CPU, memory, and GPU requests and limits currently set in the Kubernetes manifests for the DMS stack and for the base model-serve stack, along with the brief Chameleon evidence used to justify those values.

The numbers below are taken directly from the current manifest files under `infra-dms/k8s/docker/` and `infra-model-serve/k8s/`. Where the Chameleon S3 overlay changes the running workloads, that difference is called out separately below.

## Chameleon Evidence Used For Right-Sizing

- Both Terraform stacks launch Chameleon instances with `flavor_name = "baremetal"`, which means the reservation determines the actual hardware and Kubernetes requests must be chosen to fit within a full physical node rather than a small cloud VM.
- Chameleon documents CHI@UC `compute_skylake` nodes as Dell R740 servers with two 12-core Intel Xeon Skylake CPUs and `192 GiB` RAM. That hardware is used here as the CPU-only sizing baseline; the manifests themselves do not pin the DMS or control-plane pods to a specific CPU node family, so the exact host still depends on the reservation.
- The inference deployment is pinned to hostnames `nc01` through `nc38`. Chameleon’s public materials show RTX 6000 GPU nodes are part of the CHI@UC hardware pool, so that is the evidence used here to treat the serving deployment as a one-GPU workload with moderate CPU and RAM beside it.
- The training job is pinned to `gigaio02` through `gigaio06`. Chameleon documents CHI@UC `compute_gigaio` nodes as `512 GB` RAM servers attached by default to `1` Nvidia A100 GPU per node, so the training job also requests exactly one GPU and only a small fraction of host CPU and RAM.

## DMS Services

| Service | Workload | CPU request | CPU limit | Memory request | Memory limit | GPU request / limit | Chameleon right-sizing evidence |
|---|---|---:|---:|---:|---:|---|---|
| `dms-api` | Deployment | `250m` | `500m` | `512Mi` | `1Gi` | none / none | CPU-only API tier on a 24-core, 192 GiB Chameleon Skylake node. Request is deliberately small for steady HTTP traffic but leaves 2x burst headroom in the limit. |
| `dms-worker` | Deployment | `500m` | `2` | `1Gi` | `4Gi` | none / none | Heaviest DMS service because it handles background ingest and preprocessing. Request stays modest relative to Chameleon node capacity, but the higher limit leaves room for bursty jobs without reserving a large fixed slice of the node. |
| `dms-scheduler` | Deployment | `100m` | `250m` | `256Mi` | `512Mi` | none / none | Periodic orchestration workload. Minimal request is appropriate because it is not data-plane heavy and only needs enough guaranteed CPU and RAM to stay responsive. |
| `redis` | Deployment | `100m` | `250m` | `256Mi` | `512Mi` | none / none | Small queue/cache footprint for this project scope. The request is intentionally low because it runs on the same bare-metal host as the rest of DMS and mostly holds transient queue state. |
| `postgres` | StatefulSet | `500m` | `1` | `1Gi` | `2Gi` | none / none | Stateful database gets a larger guaranteed floor than Redis and the scheduler because Chameleon local-path storage is used for persistent data and the DB needs predictable latency under checkpoint and query bursts. |
| `metabase` | Deployment | `250m` | `500m` | `512Mi` | `1Gi` | none / none | User-facing analytics UI bundled with the DMS manifest set. Sized like the API tier because it is interactive but lightweight compared with the worker and database. |

DMS long-running total requests: `1.7` CPU, `3.5 GiB` RAM, `0` GPU.

That total excludes init containers and is still small relative to a standard CHI@UC CPU bare-metal node such as `compute_skylake` (`24` CPU cores, `192 GiB` RAM), which is why the requests are conservative and the limits are mainly there for temporary bursts rather than steady-state reservation.

## Model-Serve Services

| Service | Workload | CPU request | CPU limit | Memory request | Memory limit | GPU request / limit | Chameleon right-sizing evidence |
|---|---|---:|---:|---:|---:|---|---|
| `mms-mlflow` | Deployment | `250m` | `1` | `512Mi` | `1Gi` | none / none | MLflow is metadata and artifact-tracking heavy, not GPU-bound. Its request is small because artifacts are stored externally and the service mostly handles HTTP and database operations. |
| `mms-model-serve` | Deployment | `1` | `2` | `2Gi` | `4Gi` | `nvidia.com/gpu: 1` / `nvidia.com/gpu: 1` | Pinned to Chameleon `nc01`-`nc38` RTX 6000 hosts. Requesting exactly one GPU matches Kubernetes whole-device scheduling on Chameleon GPU nodes. CPU and RAM stay moderate because one Uvicorn worker serves one loaded model replica. |
| `minio` | StatefulSet | `250m` | `1` | `512Mi` | `2Gi` | none / none | Local artifact/object store. Sized similarly to Postgres because it is persistent and I/O-oriented, but it does not need a GPU and does not justify a large fixed reservation on a small bare-metal cluster. |
| `postgres` | StatefulSet | `250m` | `1` | `512Mi` | `2Gi` | none / none | MLflow backend database. Moderate request is enough for metadata traffic while keeping room on the node for the inference service. |

Model-serve long-running total requests: `1.75` CPU, `3.5 GiB` RAM, `1` GPU.

That total excludes the init containers and the separate training job. On CPU and memory alone, the control-plane asks are modest; the dominant scheduling constraint is the single requested GPU on `mms-model-serve`, which correctly claims one whole Chameleon GPU device for the inference replica.

## Chameleon S3 Overlay Differences

If you deploy `infra-model-serve/k8s/overlays/chameleon-s3/` instead of the base model-serve bundle:

- `minio` is not deployed in the cluster; the overlay points MLflow and serving at external Chameleon object storage instead.
- `job-train-food-classifier.yaml` is replaced by `job-seed-toy-model.yaml`.
- `job-seed-toy-model.yaml` currently sets no `resources:` block at all, so its CPU, memory, and GPU requests and limits are unspecified in the current manifest.
- The overlay also replaces the `mms-mlflow` init container list, removing `wait-minio` and leaving a `wait-postgres` init container with no `resources:` block in the current patch.

With that overlay, the model-serve long-running in-cluster total becomes `1.5` CPU, `3 GiB` RAM, and `1` GPU, excluding the remaining init container and the seed job.

## Supporting Init Containers In The Base Bundle

`mms-mlflow` also uses two small init containers, `wait-postgres` and `wait-minio`, each with:

- CPU: `10m` request / `100m` limit
- Memory: `32Mi` request / `64Mi` limit

These are intentionally tiny because they only block startup until dependencies answer on the network.

## Batch Workload Included By Default

| Workload | Type | CPU request | CPU limit | Memory request | Memory limit | GPU request / limit | Chameleon right-sizing evidence |
|---|---|---:|---:|---:|---:|---|---|
| `mms-train-food-classifier` | Job | `2` | `4` | `8Gi` | `16Gi` | `nvidia.com/gpu: 1` / `nvidia.com/gpu: 1` | Included in the base `infra-model-serve/k8s/kustomization.yaml` unless you remove it before apply. It is pinned to Chameleon `gigaio02`-`gigaio06` nodes, which Chameleon documents as `compute_gigaio` servers with `512 GB` RAM and one A100 GPU per node by default, so one-GPU training with `8-16 GiB` RAM is conservative and leaves substantial host headroom. |

## Why These Values Are Reasonable On Chameleon

- In the reference Terraform deployment in this repo, each stack is provisioned onto one Chameleon bare-metal node. The right-sizing goal was therefore to keep guaranteed requests low enough to fit comfortably on one physical host while still protecting the database, worker, and serving paths from starvation. If the DMS bundle and the base model-serve bundle are co-located on one cluster, the combined long-running request is `3.45` CPU, `7 GiB` RAM, and `1` GPU, excluding init containers and the separate training job.
- CPU-only services were generally kept in the `100m` to `500m` request range, with larger requests only for the heavier paths (`dms-worker`, both Postgres instances, and the GPU-backed serving pod's companion CPU/RAM allocation).
- GPU is requested only for workloads explicitly scheduled onto GPU-capable Chameleon nodes: once for the inference service on the RTX 6000-backed serving pool and once for the training job on the GigaIO/A100 pool. No CPU-only service requests a GPU.

## Chameleon Sources Cited

1. Bare-metal flavor behavior: https://chameleoncloud.readthedocs.io/en/v1.0/technical/baremetal.html
2. CHI@UC Skylake node capacity: https://www.chameleoncloud.org/news/new-chameleon-hardware-available/
3. CHI@UC RTX 6000 node presence and maintenance notes: https://blog.chameleoncloud.org/posts/chameleon-changelog-for-august-2024/
4. CHI@UC GigaIO node and A100 capacity: https://blog.chameleoncloud.org/posts/composible-hardware-on-chameleon-now/
