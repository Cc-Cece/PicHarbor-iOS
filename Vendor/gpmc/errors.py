"""Credential-safe error codes shared by platform adapters."""
import requests

from .deadline import DeadlineExceeded
from .exceptions import AuthenticationError, ProtocolError


class OperationCancelled(Exception):
    pass


def known_integer(value):
    return value if type(value) is int and value >= 0 else None


def classify(error):
    if isinstance(error, DeadlineExceeded):
        return error.code
    if isinstance(error, OperationCancelled):
        return "CANCELLED"
    if isinstance(error, ProtocolError):
        return str(error)
    # Match known provider failures without returning exception text to the UI.
    value = str(error)
    for marker, code in (
        ("encrypted auth token", "ENCRYPTED_TOKEN"), ("TokenEncrypted", "ENCRYPTED_TOKEN"),
        ("MissingDroidguard", "DEVICE_VERIFICATION"), ("device verification", "DEVICE_VERIFICATION"),
        ("NeedsBrowser", "LOGIN_REQUIRED"), ("browser sign-in", "LOGIN_REQUIRED"),
        ("fresh browser sign-in", "LOGIN_REQUIRED"), ("BadAuthentication", "LOGIN_REQUIRED"),
        ("rejected the credential", "LOGIN_REQUIRED"),
    ):
        if marker in value:
            return code
    if isinstance(error, AuthenticationError):
        return "LOGIN_REQUIRED"
    if isinstance(error, requests.HTTPError):
        status = error.response.status_code if error.response is not None else 0
        return "LOGIN_REQUIRED" if status in (401, 403) else "RATE_LIMITED" if status == 429 else "NETWORK_ERROR"
    if isinstance(error, requests.RequestException):
        return "NETWORK_ERROR"
    if isinstance(error, OSError) or "SecurityException" in type(error).__name__:
        return "FILE_ACCESS"
    return "ENGINE_ERROR"
