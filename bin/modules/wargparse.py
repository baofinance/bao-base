#!/usr/bin/env python3
import sys
import argparse
import json
import traceback
import os

# Set up a logging handler that writes to the debug stream.
import logging
logging.basicConfig(
                    level=50-int(os.environ.get('LOGGING_LEVEL'))*10 or None,
                    format='%(asctime)s - %(levelname)s - %(message)s',
                    handlers=[logging.StreamHandler(os.fdopen(int(os.environ.get('LOGGING_FILE_DESCRIPTOR')) or 1, 'w'))])

class StoreWithOriginAction(argparse._StoreAction):
    def __init__(self,
                 option_strings,
                 dest,
                 default=None,
                 **kwargs):
        # logging.debug(f"StoreWithOrigin.__init__({option_strings}, {dest}, {default}")
        default_origin = kwargs.pop('names')[0]
        super(argparse._StoreAction, self).__init__(
            option_strings=option_strings,
            dest=dest,
            default={'value': default, 'origin': None, 'default_origin': default_origin},
            **kwargs)

    def __call__(self, parser, namespace, values, option_string=None):
        logging.debug(f"StoreWithOriginAction.__call__({self.dest}, {values}, {option_string})")
        if values == self.default:
            setattr(namespace, self.dest, self.default)
        else:
            setattr(namespace, self.dest, {'value': values, 'origin': option_string})

class StoreConstWithOriginAction(argparse._StoreConstAction):
    def __init__(self,
                 option_strings,
                 dest,
                 const=None,
                 default=None,
                 required=False,
                 help=None,
                 metavar=None,
                 **kwargs):
        # logging.debug(f"StoreConstWithOrigin.__init__({option_strings}, {dest}, {const}, {default}")
        super(argparse._StoreConstAction, self).__init__(
            option_strings=option_strings,
            dest=dest,
            nargs=0,
            const=const,
            default={'value': default, 'origin': None, 'default_origin': kwargs['names'][0]},
            required=required,
            help=help)

    def __call__(self, parser, namespace, values, option_string=None):
        # logging.debug(f"StoreConstWithOriginAction.__call__(...{values}, {option_string})")
        setattr(namespace, self.dest, {'value': self.const, 'origin': option_string})


class StoreTrueWithOriginAction(StoreConstWithOriginAction):
    # set the default to true
    def __init__(self,
                 option_strings,
                 dest,
                 default=False,
                 required=False,
                 help=None,
                 **kwargs):
        super(StoreTrueWithOriginAction, self).__init__(
            option_strings=option_strings,
            dest=dest,
            const=True,
            default=default,
            required=required,
            help=help,
            **kwargs)


class StoreFalseWithOriginAction(StoreConstWithOriginAction):
    # set the default to false
    def __init__(self,
                 option_strings,
                 dest,
                 default=True,
                 required=False,
                 help=None,
                 **kwargs):
        super(StoreConstWithOriginAction, self).__init__(
            option_strings=option_strings,
            dest=dest,
            const=False,
            default=default,
            required=required,
            help=help,
            **kwargs)

class BooleanOptionalWithOriginAction(argparse.BooleanOptionalAction):
    def __init__(self,
                 option_strings,
                 dest,
                 default=None,
                 type=None,
                 choices=None,
                 required=None,
                 help=None,
                 metavar=None,
                 **kwargs):
        logging.debug(f"BooleanOptionalWithOriginAction.__init__()...")
        logging.debug(f"default={default}")
        super(argparse.BooleanOptionalAction, self).__init__(
            option_strings=option_strings,
            dest=dest,
            nargs=0,
            default={'value': default, 'origin': None, 'default_origin': kwargs["names"][0]},
            type=type,
            choices=choices,
            required=required,
            help=help,
            metavar=metavar)

    def __call__(self, parser, namespace, values, option_string=None):
        logging.debug(f"BooleanOptionalWithOriginAction.__call__()...")
        logging.debug(f"values={values}")
        logging.debug(f"option_string={option_string}")
        if option_string in self.option_strings:
            setattr(namespace, self.dest, {'value': not option_string.startswith('--no-'), 'origin': option_string})


# class AppendWithOriginAction(argparse._AppendAction):
# class AppendConstWithOriginAction...
# class ExtendWithOrignAction(AppendWithOriginAction):

class CountWithOriginAction(argparse._CountAction):
    def __init__(self,
                 option_strings,
                 dest,
                 default=None,
                 required=False,
                 help=None,
                 **kwargs):
        super(argparse._CountAction, self).__init__(
            option_strings=option_strings,
            dest=dest,
            nargs=0,
            default={'value': default, 'origin': None, 'default_origin': kwargs['names'][0]},
            required=required,
            help=help)

    def __call__(self, parser, namespace, values, option_string=None):
        logging.debug(f"CountWithOriginAction.__call__({self.dest},{values},{option_string})...")
        current = getattr(namespace, self.dest, {})
        current_value = current.get('value') or 0
        current_origin = current.get('origin') or ''
        logging.debug(f"current value={current_value}, origin={current_origin}")
        setattr(namespace, self.dest, {
            'value': current_value + 1,
            'origin': option_string if not current_origin else f"{current_origin} {option_string}"
        })


class RichArgumentParser:
    def __init__(self, spec):
        """Initialize parser with a JSON specification"""
        logging.debug(f"spec={spec}")
        # try:
        spec_obj = json.loads(spec) if isinstance(spec, str) else spec
        # except json.JSONDecodeError:
        #     print(json.dumps({"error": "Invalid JSON specification"}))
        #     sys.exit(1)
        # logging.debug(f"spec_obj={spec_obj}")

        # self.parser = argparse.ArgumentParser(**parser_config)
        parser_kwargs = {k: v for k, v in spec_obj.items() if k != 'arguments'}
        parser_kwargs.setdefault('allow_abbrev', False)
        self.parser = argparse.ArgumentParser(**parser_kwargs)

        # override the default actions, to collect the origin
        self.parser.register('action', None, StoreWithOriginAction)
        self.parser.register('action', 'store', StoreWithOriginAction)
        self.parser.register('action', 'store_true', StoreTrueWithOriginAction)
        self.parser.register('action', 'store_false', StoreFalseWithOriginAction)
        self.parser.register('action', 'store_boolean', BooleanOptionalWithOriginAction)
        self.parser.register('action', 'boolean_optional', BooleanOptionalWithOriginAction)
        self.parser.register('action', 'store_count', CountWithOriginAction)
        self.parser.register('action', 'count', CountWithOriginAction)

        for arg_spec in spec_obj.get('arguments', []):
            logging.debug(f"arg_spec={arg_spec}.")
            self.parser.add_argument(*arg_spec['names'], **arg_spec) # leave names in for default values


    def parse_args(self, args):
        """
        Parse arguments and return rich metadata

        Args:
            args: List of command line arguments to parse
            return_dict: If True, returns Python dict instead of formatted string
        """
        # logging.debug(f"parse_args({args})...")
        try:
            parsed, unknown = self.parser.parse_known_args(args)
        except Exception as e:
            print(json.dumps({"error": str(e)}))
            sys.exit(1)
        logging.debug(f"known='{parsed}'")
        logging.debug(f"unknown='{unknown}'")

        return {"known": vars(parsed), "unknown": unknown}

def main():
    logging.debug(f"wargparse({sys.argv[1:]})...")
    if sys.argv[1] in ['-h', '--help']:
        example = {
            "prog": "the program",
            "usage": "my usage",
            "description": "Example program",
            "epilog": "that's all folks",
            "arguments": [
                {
                    "names": ["input"],
                    "help": "Input file",
                    # "required": True
                },
                {
                    "names": ["-o", "--output"],
                    "help": "Output file",
                    # "type": str,
                    "default": "output.txt"
                },
                {
                    "names": ["-v", "--verbose"],
                    "action": "count",
                    # "default": 0,
                    "help": "Increase verbosity"
                },
                {
                    "names": ["--mode"],
                    "choices": ["fast", "slow"],
                    "default": "fast",
                    "help": "Processing mode"
                }
            ]
        }
        print(json.dumps(
            {"usage": "wargparse.py 'JSON_SPEC' arg1 arg2 ...\n",
             "example_spec": example}, indent=2))
    else:
        parser = RichArgumentParser(sys.argv[1] if len(sys.argv) and len(sys.argv[1]) > 1 else '{}')
        result = parser.parse_args(sys.argv[2:] if len(sys.argv) > 2 else [])
        logging.debug(f"wargparse()->{result}")
        print(json.dumps(result))

if __name__ == '__main__':
    try:
        main()
    except Exception:
        traceback.print_exc()  # Print the full traceback to stderr
        sys.exit(1)
