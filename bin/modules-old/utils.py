import os

def shorten(path, max_length):
    """
    Shorten a file path by progressively removing parts of the path and truncating the filename,
    inserting ellipses (`...`) to indicate omitted sections.

    Args:
        path (str): The original file path.
        max_length (int): The maximum allowed length for the path.

    Returns:
        str: The shortened file path.
    """
    if len(path) <= max_length:
        return path

    directory = os.path.dirname(path)
    filename = os.path.basename(path)

    if len(filename) > max_length:
        return filename[:max_length - 3] + "..."

    directory_parts = directory.split(os.sep)
    while len(directory_parts) > 0:
        shortened_dir = os.sep.join(directory_parts) + os.sep + "..."
        shortened_path = os.path.join(shortened_dir, filename)
        if len(shortened_path) <= max_length:
            return shortened_path
        directory_parts.pop()

    if len(filename) > max_length:
        return filename[:max_length - 3] + "..."

    return filename
