"""Tests for image encoding in the Python client SDK."""

import base64

from aod_client.client import _encode_images


def test_encode_images_bytes():
    """Raw bytes are base64-encoded correctly."""
    raw = b"\x89PNG\r\n"
    images = [{"data": raw, "media_type": "image/png"}]
    result = _encode_images(images)
    assert len(result) == 1
    assert result[0]["media_type"] == "image/png"
    assert result[0]["data"] == base64.b64encode(raw).decode("ascii")


def test_encode_images_already_b64():
    """Already-encoded strings pass through unchanged."""
    encoded = base64.b64encode(b"hello").decode("ascii")
    images = [{"data": encoded, "media_type": "image/jpeg"}]
    result = _encode_images(images)
    assert result[0]["data"] == encoded


def test_encode_images_multiple():
    """Multiple images are all encoded."""
    raw1 = b"\x00\x01"
    raw2 = b"\x02\x03"
    images = [
        {"data": raw1, "media_type": "image/png"},
        {"data": raw2, "media_type": "image/gif"},
    ]
    result = _encode_images(images)
    assert len(result) == 2
    assert result[0]["data"] == base64.b64encode(raw1).decode("ascii")
    assert result[1]["data"] == base64.b64encode(raw2).decode("ascii")
    assert result[1]["media_type"] == "image/gif"


def test_encode_images_empty():
    """Empty list returns empty list."""
    assert _encode_images([]) == []
