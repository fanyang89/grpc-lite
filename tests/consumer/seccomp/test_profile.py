#!/usr/bin/env python3
"""Guard the exact security delta used by run_cmake_c.sh."""

import json
from pathlib import Path
import unittest

from allow_io_uring import consumer_profile


class ConsumerSeccompProfileTest(unittest.TestCase):
    def setUp(self):
        self.source = Path(__file__).with_name("moby-default.json").read_bytes()

    def test_only_io_uring_is_added_to_pinned_default_deny_profile(self):
        original = json.loads(self.source)
        derived = consumer_profile(self.source)
        self.assertEqual(original["defaultAction"], "SCMP_ACT_ERRNO")
        self.assertEqual(original["defaultErrnoRet"], 1)
        added = derived["syscalls"].pop()
        self.assertEqual(added, {
            "names": ["io_uring_setup", "io_uring_enter", "io_uring_register"],
            "action": "SCMP_ACT_ALLOW",
        })
        self.assertEqual(derived, original)
        for rule in original["syscalls"]:
            self.assertTrue(set(rule["names"]).isdisjoint(added["names"]))

    def test_modified_profile_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
            consumer_profile(self.source.replace(b"SCMP_ACT_ERRNO", b"SCMP_ACT_ALLOW", 1))


if __name__ == "__main__":
    unittest.main()
