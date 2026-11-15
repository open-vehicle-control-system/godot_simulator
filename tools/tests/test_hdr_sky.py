# ruff: noqa: D102
"""Tests of reading an equirectangular Radiance HDR sky and finding its sun."""

import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import hdr_sky


def flat_hdr(rgbe_rows):
    """Return a Radiance HDR file of flat (not run-length encoded) RGBE scanlines."""
    height, width, _ = rgbe_rows.shape
    header = f"#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y {height} +X {width}\n".encode()
    return header + rgbe_rows.astype(np.uint8).tobytes()


def run_length_hdr(rgbe_rows):
    """Return a Radiance HDR file of run-length encoded scanlines, every byte a literal."""
    height, width, _ = rgbe_rows.shape
    out = bytearray(f"#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y {height} +X {width}\n".encode())
    for row in rgbe_rows.astype(np.uint8):
        out += bytes([2, 2, width >> 8, width & 255])
        for channel in range(4):
            values = row[:, channel]
            for start in range(0, width, 128):
                chunk = values[start : start + 128]
                out += bytes([len(chunk)]) + chunk.tobytes()
    return bytes(out)


class ReadTest(unittest.TestCase):
    """Reading the file."""

    def test_reads_flat_and_run_length_scanlines_alike(self):
        rgbe = np.zeros((4, 16, 4), np.uint8)
        rgbe[..., :3] = 128
        rgbe[..., 3] = 129  # 128/256 * 2^(129-128) = 1.0
        rgbe[1, 3] = (128, 64, 32, 131)
        for name, content in (("flat", flat_hdr(rgbe)), ("run-length", run_length_hdr(rgbe))):
            with tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "sky.hdr"
                path.write_bytes(content)

                image = hdr_sky.read(path)

            self.assertEqual(image.shape, (4, 16, 3), name)
            self.assertTrue(np.allclose(image[0, 0], 1.0), name)
            self.assertTrue(np.allclose(image[1, 3], [4.0, 2.0, 1.0]), name)


class SunTest(unittest.TestCase):
    """Where the sun is in the panorama."""

    def test_the_brightest_spot_gives_the_suns_elevation(self):
        image = np.ones((180, 360, 3), np.float32)
        image[49, 90] = 1000.0  # row 49 of 180: from 41 to 40 degrees above the horizon

        self.assertAlmostEqual(hdr_sky.sun_elevation_deg(image), 40.5)


if __name__ == "__main__":
    unittest.main()
