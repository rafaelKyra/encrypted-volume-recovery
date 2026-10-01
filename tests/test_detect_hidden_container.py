#!/usr/bin/env python3
"""Tests for the pure logic of detect-hidden-container.py.

No root, no zuluCrypt, no device-mapper: these cover the parts that run before any
probe is made - where a cover file legitimately ends, and which offsets are tried.
The probe itself (zuluCrypt-cli opening a candidate) is NOT covered here.

    python3 -m unittest tests/test_detect_hidden_container.py -v
"""
import importlib.util, io, os, random, struct, tempfile, unittest, zipfile
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "hidden-container" / "detect-hidden-container.py"
spec = importlib.util.spec_from_file_location("detect", SCRIPT)
d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)
KB, MB, GB = d.KB, d.MB, d.GB


def junk(n, seed=1):
    r = random.Random(seed)
    return bytes(r.getrandbits(8) for _ in range(n))


def box(kind: bytes, payload: bytes) -> bytes:
    return struct.pack(">I", 8 + len(payload)) + kind + payload


class HostEnd(unittest.TestCase):
    def check(self, data: bytes, fn, expected: int, extra=0):
        with tempfile.TemporaryFile() as f:
            f.write(data + junk(extra)); f.flush()
            self.assertEqual(fn(f, len(data) + extra), expected)

    def test_mp4_ends_after_last_top_level_box_even_with_appended_bytes(self):
        host = box(b"ftyp", b"isom" + b"\0" * 8) + box(b"mdat", junk(5000)) + box(b"moov", junk(300))
        self.check(host, d.end_mp4, len(host), extra=2_000_000)

    def test_mp4_with_moov_first_is_handled_the_same(self):
        host = box(b"ftyp", b"isom" + b"\0" * 8) + box(b"moov", junk(300)) + box(b"mdat", junk(5000))
        self.check(host, d.end_mp4, len(host), extra=500_000)

    def test_avi_riff_chain(self):
        riff = lambda body: b"RIFF" + struct.pack("<I", 4 + len(body)) + b"AVI " + body
        host = riff(junk(1000)) + riff(junk(500))
        self.check(host, d.end_riff, len(host), extra=100_000)

    def test_zip_end_is_found_even_when_appended_data_pushes_it_far_from_eof(self):
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as z:
            z.writestr("a.txt", "hello" * 100)
        host = buf.getvalue()
        # appended data must not contain an EOCD signature of its own
        extra = junk(3_000_000, seed=7).replace(b"PK\x05\x06", b"PK\x05\x07")
        with tempfile.TemporaryFile() as f:
            f.write(host + extra); f.flush()
            self.assertEqual(d.end_zip(f, len(host) + len(extra)), len(host))

    def test_unknown_extension_gives_none(self):
        with tempfile.NamedTemporaryFile(suffix=".bin") as f:
            f.write(junk(4096)); f.flush()
            self.assertIsNone(d.host_end(f.name))


class Candidates(unittest.TestCase):
    """The offset is the original cover size rounded UP to its own KB/MB/GB tier;
    the container is a whole number of MB; the file is grown in 1024-byte chunks."""

    def model(self, cover, n_mb, r=0):
        off = d.tier_round(cover)
        return off, off + n_mb * MB + r

    def test_true_offset_is_among_candidates_when_cover_end_is_known(self):
        rng = random.Random(3)
        for _ in range(60):
            cover = rng.randrange(80 * KB, 300 * MB)
            n = rng.randrange(4, 400)
            r = rng.randrange(0, 1024)
            off, size = self.model(cover, n, r)
            self.assertIn(off, d.candidates(size, cover), (cover, n, r))

    def test_true_offset_is_found_without_knowing_the_cover_format(self):
        rng = random.Random(4)
        for _ in range(60):
            cover = rng.randrange(80 * KB, 300 * MB)
            n = rng.randrange(4, 400)
            off, size = self.model(cover, n, rng.randrange(0, 1024))
            self.assertIn(off, d.candidates(size, None), (cover, n))

    def test_older_container_in_a_stack_is_still_reachable(self):
        cover = 37 * MB + 12345
        off1, size1 = self.model(cover, 20)
        off2, size2 = self.model(size1, 30)       # second container appended on top
        cands = d.candidates(size2, None)
        self.assertIn(off2, cands)
        self.assertIn(off1, cands)

    def test_candidates_are_unique_positive_and_inside_the_file(self):
        size = 500 * MB + 99
        c = d.candidates(size, 120 * MB)
        self.assertEqual(len(c), len(set(c)))
        self.assertTrue(all(0 < o < size for o in c))

    def test_report_candidate_counts(self):
        """Not an assertion about speed: it prints the measured counts so the
        documentation can quote real numbers instead of the design intent."""
        rows = []
        for label, cover, n in (("100 MB", 60 * MB, 40), ("1 GB", 600 * MB, 424), ("8 GB", 5 * GB, 3072)):
            off, size = self.model(cover, n)
            rows.append((label, size, len(d.candidates(size, None)), len(d.candidates(size, cover))))
        for label, size, blind, known in rows:
            print(f"\n  file {label:>6} ({size:>13,} B): {blind:>6} candidates blind, {known:>6} with known cover end")


if __name__ == "__main__":
    unittest.main(verbosity=2)
