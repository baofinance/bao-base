# MAUL Plugin System

## Architecture

The MAUL plugin system is organized around these key components:

### Core Infrastructure (`bin/maul/`)
- `bin/maul/core/`: Core functionality and logging
- `bin/maul/cli/`: Command-line interface and discovery
- `bin/maul/utils.py`: Utility functions used by commands
- `bin/maul/__main__.py`: Entry point for CLI execution

### Plugin Implementation (`maul/`)
- `maul/commands/`: Individual command implementations
- `maul/utils.py`: Extended utilities for commands
- `maul/exceptions.py`: Error types used throughout the system

## Command Registration

Commands are registered by decorating a class with `@register_command`:

```python
from maul.commands.base import Command, register_command

@register_command(name="example", help_text="Example command")
class ExampleCommand(Command):
    @classmethod
    def add_arguments(cls, parser):
        parser.add_argument('--option', help='An example option')

    @classmethod
    def execute(cls, args):
        cls.logger.info(f"Executing with option: {args.option}")
        # Command implementation
```

## Import Guidelines

- Command implementation files should import from `maul.utils`, not `bao_base`
- Infrastructure code should import from `bin.maul.*`
- Avoid circular imports between packages
