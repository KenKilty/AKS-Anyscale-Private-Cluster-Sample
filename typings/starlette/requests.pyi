# Minimal Starlette stub for local type checking (pyrightconfig.json stubPath).
# Covers only the Request surface used by anyscale_serve_gpu_proof.py, which
# runs in the Anyscale Ray Serve runtime rather than the repo venv.

from typing import Any

class Request:
    method: str

    async def json(self) -> dict[str, Any]: ...
