# Minimal ray.train.data_parallel_trainer stub for local type checking.
# Covers only DataParallelTrainer as used by anyscale_train_gpu_job_proof.py.
# Ray is installed in the Anyscale runtime, not in the repo venv.

from collections.abc import Callable
from typing import Any

from . import ScalingConfig

class Result:
    metrics: dict[str, Any]

class DataParallelTrainer:
    def __init__(
        self,
        *,
        train_loop_per_worker: Callable[[dict[str, Any]], None],
        train_loop_config: dict[str, Any],
        scaling_config: ScalingConfig,
        datasets: dict[str, Any],
    ) -> None: ...

    def fit(self) -> Result: ...
