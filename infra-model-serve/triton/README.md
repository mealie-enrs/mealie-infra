# Triton Inference Server (infrastructure-level serving option)

Use this when you want **dynamic batching**, **concurrent model instances**, and a **non–FastAPI** inference front-end on Chameleon.

This directory contains:

- `model_repository/food-classifier/config.pbtxt`
- no actual `model.onnx`; you need to supply that yourself from MLflow artifacts or another ONNX export workflow

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

## Run on Chameleon (CPU example)

```bash
cd infra-model-serve/triton
docker run --rm -d --name triton-mms \
  --network mealie-model-serve-net \
  -p 8000:8000 -p 8001:8001 -p 8002:8002 \
  -v "$PWD/model_repository:/models" \
  nvcr.io/nvidia/tritonserver:24.01-py3-min \
  tritonserver --model-repository=/models --log-verbose=0
```

Hit `http://<node-ip>:8000/v2/health/ready`. Use Triton’s HTTP/gRPC clients for inference (different JSON shape than this repo’s FastAPI `/predict`).

## Evaluation

Compare **p50/p95** and **throughput** against the FastAPI + ONNX Runtime serving path using the same hardware class, and record the results in your benchmark notes or report.

**Note:** Pulling `nvcr.io` images may require accepting NVIDIA’s terms on their site; use a Chameleon GPU instance if you enable CUDA backends.
