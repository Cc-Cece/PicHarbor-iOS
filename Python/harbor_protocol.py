"""Compatibility import; implementation maintained only in the gpmc repository."""
import sys
from gpmc import protocol as _implementation
sys.modules[__name__] = _implementation
