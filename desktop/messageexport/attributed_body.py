"""Extracts plain text from message.attributedBody.

Newer macOS/iOS versions often leave message.text empty and store the text in
attributedBody, an NSAttributedString serialized in Apple's "typedstream" format.
"""

from __future__ import annotations


def decode_attributed_body(data: bytes) -> str | None:
    for marker in (b"NSString", b"NSMutableString"):
        text = _extract(data, marker)
        if text is not None:
            return text
    return None


def _extract(data: bytes, marker: bytes) -> str | None:
    start = data.find(marker)
    if start < 0:
        return None
    i = start + len(marker)
    limit = min(len(data), i + 16)
    while i < limit and data[i] != 0x2B:  # '+'
        i += 1
    if i >= limit:
        return None
    i += 1
    if i >= len(data):
        return None
    tag = data[i]
    if tag == 0x81:
        if i + 2 >= len(data):
            return None
        length = int.from_bytes(data[i + 1 : i + 3], "little")
        i += 3
    elif tag == 0x82:
        if i + 4 >= len(data):
            return None
        length = int.from_bytes(data[i + 1 : i + 5], "little")
        i += 5
    else:
        length = tag
        i += 1
    if length <= 0 or i + length > len(data):
        return None
    return data[i : i + length].decode("utf-8", errors="replace")
