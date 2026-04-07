# Triton Inference Server (infrastructure-level serving option)

Use this when you want **dynamic batching**, **concurrent model instances**, and a **non–FastAPI** inference front-end on Chameleon.

This directory contains:

- `model_repository/food-classifier/config.pbtxt`
- no actual `model.onnx`; you need to supply that yourself from MLflow artifacts or another ONNX export workflow

## Prerequisites

Before starting Triton, make sure you have:

- Docker available on the host where you will run Triton
- a real ONNX model copied to `infra-model-serve/triton/model_repository/food-classifier/1/model.onnx`
- the input/output names in `config.pbtxt` aligned with that ONNX model

If you want Triton to join the same local Docker network as the model-serve Compose control plane, make sure the Docker network `mealie-model-serve-net` already exists. You can get that network by starting the local control plane, or by creating it manually:

```bash
docker network create mealie-model-serve-net
```

## Layout

```text
model_repository/
  food-classifier/
    config.pbtxt    # provided; edit I/O names to match your ONNX
    1/
      model.onnx    # you copy from MLflow artifact or trainer output
```

The provided `config.pbtxt` currently expects an ONNX model with:

- input `float_input`
- outputs `output_probability` and `output_label`

If your exported ONNX uses different names or shapes, edit `config.pbtxt` before starting Triton.

Triton will not become ready unless `model_repository/food-classifier/1/model.onnx` exists and matches that config.

## Run Standalone

Use this if you only want to run Triton by itself and do not need it on the shared local model-serve Docker network:

```bash
cd infra-model-serve/triton
docker run --rm -d --name triton-mms \
  -p 8000:8000 -p 8001:8001 -p 8002:8002 \
  -v "$PWD/model_repository:/models" \
  nvcr.io/nvidia/tritonserver:24.01-py3-min \
  tritonserver --model-repository=/models --log-verbose=0
```

If Docker is running on your local machine, the readiness endpoint is:

`http://localhost:8000/v2/health/ready`

If Docker is running on a remote VM, replace `localhost` with that host’s reachable IP address.

## Run On Shared Local Model-Serve Network

Use this only if you intentionally want Triton attached to the same Docker network used by the local model-serve Compose stack:

```bash
cd infra-model-serve/triton
docker run --rm -d --name triton-mms \
  --network mealie-model-serve-net \
  -p 8000:8000 -p 8001:8001 -p 8002:8002 \
  -v "$PWD/model_repository:/models" \
  nvcr.io/nvidia/tritonserver:24.01-py3-min \
  tritonserver --model-repository=/models --log-verbose=0
```

If Docker is local, use `http://localhost:8000/v2/health/ready`. If Docker is running on a remote host, use that host’s IP instead.

Use Triton’s HTTP or gRPC clients for inference; Triton does not expose the same `/predict` API shape as this repo’s FastAPI serving path.

## Evaluation

Compare **p50/p95** and **throughput** against the FastAPI + ONNX Runtime serving path using the same hardware class, and record the results in your benchmark notes or report.

**Note:** Pulling `nvcr.io` images may require accepting NVIDIA’s terms on their site; use a Chameleon GPU instance if you enable CUDA backends.
