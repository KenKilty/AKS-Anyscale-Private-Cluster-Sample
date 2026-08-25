# Minimal Ray stub for local type checking (pyrightconfig.json stubPath).
# Covers only the surface used by the proof payloads. Ray is installed in the
# Anyscale runtime, not in the repo venv.

from collections.abc import Callable, Sequence
from typing import Any, Generic, TypeVar, overload

from . import data as data
from . import serve as serve
from . import train as train

_R = TypeVar("_R")
_T = TypeVar("_T")


class ObjectRef(Generic[_T]): ...


class RemoteFunction(Generic[_R]):
    def remote(self, *args: Any, **kwargs: Any) -> ObjectRef[_R]: ...


@overload
def remote(__function: Callable[..., _R], /) -> RemoteFunction[_R]: ...
@overload
def remote(
    __function: None = ...,
    /,
    *,
    num_cpus: float | None = ...,
    num_gpus: float | None = ...,
    **options: Any,
) -> Callable[[Callable[..., _R]], RemoteFunction[_R]]: ...


def init(
    *,
    address: str | None = ...,
    ignore_reinit_error: bool = ...,
    **options: Any,
) -> None: ...


@overload
def get(object_ref: ObjectRef[_T], /, *, timeout: float | None = ...) -> _T: ...
@overload
def get(object_refs: Sequence[ObjectRef[_T]], /, *, timeout: float | None = ...) -> list[_T]: ...


def cluster_resources() -> dict[str, float]: ...
def shutdown() -> None: ...
