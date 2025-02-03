import importlib.util
import os
from typing import Callable

def dynamic_function(file_path: str, function_name: str) -> Callable:
    """
    Dynamically loads a Python module from a file and retrieves a specific function.

    Args:
        file_path (str): Path to the Python file containing the module.
        function_name (str): The name of the function to retrieve.

    Returns:
        Callable: The specified function from the loaded module.
    """
    # Get the module name from the file path
    module_name = os.path.splitext(os.path.basename(file_path))[0]

    # Create a spec from the file
    spec = importlib.util.spec_from_file_location(module_name, file_path)
    if spec is None:
        raise ImportError(f"Cannot create a module spec for {file_path}")

    # Load the module
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    # Retrieve the specified function from the loaded module
    if not hasattr(module, function_name):
        raise AttributeError(f"The module '{module_name}' does not have a function named '{function_name}'")

    return getattr(module, function_name)