#!/usr/bin/env python3
"""Prove the custom image ships the packaged dependency.

Emits CUSTOM_IMAGE_DEPENDENCY_PROOF_OK only when the dependency imports without
a runtime install. On the standard image the import fails and no marker prints,
which the harness reports as the expected standard-image failure.
"""

from __future__ import annotations

import json

import onnxruntime as ort

SUCCESS_MARKER = "CUSTOM_IMAGE_DEPENDENCY_PROOF_OK"


def main() -> None:
    payload = {
        "available_providers": ort.get_available_providers(),
        "marker": SUCCESS_MARKER,
        "onnxruntime_version": ort.__version__,
    }
    print(json.dumps(payload, sort_keys=True))
    print(SUCCESS_MARKER)


if __name__ == "__main__":
    main()