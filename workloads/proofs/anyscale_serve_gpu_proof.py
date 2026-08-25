#!/usr/bin/env python3
"""Ray Serve GPU deployment used to prove the private service path.

Returns GPU_SERVE_SERVICE_PROOF_OK in its response body. The harness probes the
private service endpoint and treats that marker in the response as the proof.
"""

from __future__ import annotations

from typing import Any

from build_train_serve_common import (
    GPU_SERVE_SERVICE_SUCCESS_MARKER,
    cuda_visible_devices,
    load_json_env,
    prediction_response,
    require_gpu_assignment,
    use_gpu_requested,
)
from ray import serve
from starlette.requests import Request

RAY_ACTOR_OPTIONS = {"num_cpus": 1}
if use_gpu_requested():
    RAY_ACTOR_OPTIONS["num_gpus"] = 1


@serve.deployment(ray_actor_options=RAY_ACTOR_OPTIONS, num_replicas=1)
class PipelineProofService:
    def __init__(self) -> None:
        self.payload = load_json_env("GPU_TRAIN_MODEL_JSON")
        require_gpu_assignment(use_gpu_requested())

    async def __call__(self, request: Request) -> dict[str, Any]:
        if request.method == "GET":
            return {
                "cuda_visible_devices": cuda_visible_devices(),
                "marker": GPU_SERVE_SERVICE_SUCCESS_MARKER,
                "metrics": self.payload["metrics"],
            }

        body = await request.json()
        response = prediction_response(
            self.payload,
            float(body["x1"]),
            float(body["x2"]),
        )
        return {
            **response,
            "cuda_visible_devices": cuda_visible_devices(),
            "marker": GPU_SERVE_SERVICE_SUCCESS_MARKER,
            "metrics": self.payload["metrics"],
        }


app = PipelineProofService.bind()