#!/usr/bin/env python3
"""Main entry point for maul when executed as a module."""

import os
import sys
from .run import main

# Simply call run.main() function - centralize all configuration there
if __name__ == '__main__':
    sys.exit(main())
