# Minimal ray.data stub for local type checking (pyrightconfig.json stubPath).
# Covers only the surface used by the build and train job proofs. Ray is
# installed in the Anyscale runtime, not in the repo venv.

from collections.abc import Iterable
from typing import Any

class Dataset:
    def count(self) -> int: ...
    def take_all(self) -> list[Any]: ...

def from_items(items: Iterable[Any]) -> Dataset: ...
