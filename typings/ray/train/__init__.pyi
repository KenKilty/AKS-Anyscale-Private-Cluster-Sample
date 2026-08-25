# Minimal ray.train stub for local type checking (pyrightconfig.json stubPath).
# Covers only the surface used by anyscale_train_gpu_job_proof.py. Ray is
# installed in the Anyscale runtime, not in the repo venv.

from collections.abc import Iterable
from typing import Any

class ScalingConfig:
    def __init__(self, *, num_workers: int, use_gpu: bool) -> None: ...

class DatasetShard:
    def iter_rows(self) -> Iterable[dict[str, Any]]: ...

def get_dataset_shard(name: str) -> DatasetShard: ...
def report(metrics: dict[str, Any]) -> None: ...
