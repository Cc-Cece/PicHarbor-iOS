"""Bounded original-file access evidence shared by mobile adapters.

No media body is consumed. This is access/length evidence, not a deletion policy.
"""
from contextlib import nullcontext
import re
from urllib.parse import urljoin, urlparse

from .db_update_parser import _get_nested


def allowed_url(url):
    try:
        parsed = urlparse(url)
        return (parsed.scheme == "https" and parsed.username is None and parsed.password is None
                and parsed.port in (None, 443) and any(
                    parsed.hostname == suffix or (parsed.hostname or "").endswith("." + suffix)
                    for suffix in ("google.com", "googleusercontent.com", "googlevideo.com")))
    except (TypeError, ValueError):
        return False


def original_access(api, key, expected, *, checkpoint=lambda: None, measured=lambda stage: nullcontext()):
    if type(expected) is not int or expected <= 0:
        return False
    checkpoint()
    with measured("original_url"):
        url = _get_nested(api.get_download_urls(key), "1", "5", "2", "6")
    if isinstance(url, bytes):
        try:
            url = url.decode("utf-8")
        except UnicodeDecodeError:
            return False
    if not isinstance(url, str) or not allowed_url(url):
        return False
    with api._new_session() as session:
        for method in ("HEAD", "GET"):
            current = url
            for _ in range(6):
                checkpoint()
                if not allowed_url(current):
                    return False
                headers = {"Accept-Encoding": "identity"}
                if method == "GET":
                    headers["Range"] = "bytes=0-0"
                with measured("original_head" if method == "HEAD" else "original_range"), session.request(
                    method, current, headers=headers, allow_redirects=False, stream=True, timeout=(15, 30)
                ) as response:
                    if response.status_code in (301, 302, 303, 307, 308):
                        current = urljoin(current, response.headers.get("Location", ""))
                        continue
                    length = response.headers.get("Content-Length", "")
                    # A server without HEAD support may return 501; try a one-byte GET.
                    if method == "HEAD" and (response.status_code in (400, 403, 405, 501)
                                             or (response.status_code == 200 and not length.isdigit())):
                        break
                    if response.status_code == 429 or response.status_code >= 500:
                        response.raise_for_status()
                    if response.status_code == 206:
                        match = re.fullmatch(r"bytes 0-0/(\d+)", response.headers.get("Content-Range", ""))
                        length = match.group(1) if match else ""
                    return response.status_code in (200, 206) and length.isdigit() and int(length) == expected
            else:
                return False
    return False
