# Python Tests for Bao Base

This directory contains Python tests for Bao Base using pytest. These tests are alternative implementations of the BATS tests but with the benefits of:

1. **Better Mocking**: Complex mocking is easier in Python than in BATS
2. **Improved Assertions**: More detailed and flexible assertions
3. **Better Readability**: No need to escape Python code in Bash strings
4. **Debugging Support**: Full Python debugger support
5. **Clear Error Reporting**: Proper Python stack traces

## Running the Tests

From the project root directory, run:

```bash
# Run all Python tests
yarn test:python

# Run a specific test file
yarn test:python test/bin/test_anvil.py

# Run a specific test
yarn test:python test/bin/test_anvil.py::test_format_call_result
```

## Test Structure

- `conftest.py`: Contains test configuration and fixtures
- `utils.py`: Utility functions for tests
- `test_*.py`: Test files corresponding to BATS tests

## Adding New Tests

When adding new tests:

1. Use pytest fixtures for common setup/teardown
2. Use proper mocking instead of subprocess calls where possible
3. Include assertions that verify specific behaviors
4. Keep tests isolated and independent
