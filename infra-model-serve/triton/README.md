# Triton Inference Server (infrastructure-level serving option)

Use this when you want **dynamic batching**, **concurrent model instances**, and a **non–FastAPI** inference front-end on Chameleon.

## Layout

```text
model_repository/
  food-classifier/
    config.pbtxt    # provided; edit I/O names to match your ONNX
    1/
      model.onnx    # you copy from MLflow artifact or trainer output
```

Sklearn-exported Iris ONNX often uses `float_input`, `output_probability`, `output_label`. The toy linear model in `trainer/toy_random_onnx.py` uses `float_input` → `logits` — adjust `config.pbtxt` accordingly.

## Run on Chameleon (CPU example)

```bash
docker run --rm -d --name triton-mms \
  --network mealie-model-serve-net \
  -p 8000:8000 -p 8001:8001 -p 8002:8002 \
  -v "$PWD/model_repository:/models" \
  nvcr.io/nvidia/tritonserver:24.01-py3-min \
  tritonserver --model-repository=/models --log-verbose=0
```

Hit `http://<node-ip>:8000/v2/health/ready`. Use Triton’s HTTP/gRPC clients for inference (different JSON shape than this repo’s FastAPI `/predict`).

## Evaluation

Compare **p50/p95** and **throughput** against FastAPI + ONNX Runtime using the same hardware class. Record in `SERVING_OPTIONS.md`.

**Note:** Pulling `nvcr.io` images may require accepting NVIDIA’s terms on their site; use a Chameleon GPU instance if you enable CUDA backends.
