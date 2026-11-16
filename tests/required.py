"""A tool a test needs and does not find: locally the test is skipped and says "requires …"; in the required CI run
(FOXML_REQUIRE_INTEGRATION_TESTS=1, which tests/run_work_checks.py sets) it fails, so a missing tool can never pass
there as a skipped test."""
import functools
import os
import unittest

REQUIRED = os.environ.get('FOXML_REQUIRE_INTEGRATION_TESTS') == '1'


def requires(available, what):
    """For a test or a whole TestCase: as it is when `available`, else skipped with "requires <what>", or in the
    required run failed with it."""
    if available:
        return lambda test: test
    if not REQUIRED:
        return unittest.skip('requires ' + what)

    def missing(*_):
        raise AssertionError(f'requires {what}: in the required run a missing tool fails')

    def failing(test):
        if isinstance(test, type):
            test.setUpClass = classmethod(missing)
            return test
        return functools.wraps(test)(missing)
    return failing
