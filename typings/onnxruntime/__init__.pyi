# Minimal onnxruntime stub for local type checking (pyrightconfig.json stubPath).
# custom_image_dependency_proof.py imports onnxruntime, which is packaged only
# in the Module 4 custom image. Its absence locally is the point of that proof.

__version__: str

def get_available_providers() -> list[str]: ...
