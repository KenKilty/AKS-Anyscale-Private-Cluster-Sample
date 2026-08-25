# Minimal ray.serve stub for local type checking (pyrightconfig.json stubPath).
# Covers only the deployment decorator used by anyscale_serve_gpu_proof.py. Ray
# is installed in the Anyscale runtime, not in the repo venv.

from collections.abc import Callable
from typing import Any

def deployment(**options: Any) -> Callable[[type[Any]], Any]: ...
