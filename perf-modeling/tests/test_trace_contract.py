# Copyright (c) 2026 John Goodacre.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Tests for the trace contract validator."""

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from calibration.trace_contract import read_trace, summarize


class TraceContractTest(unittest.TestCase):
    """Check that read_trace accepts valid traces and rejects malformed ones."""

    def write(self, rows):
        """Write rows to a temporary JSONL file that the test removes."""
        descriptor, filename = tempfile.mkstemp(suffix=".jsonl")
        os.close(descriptor)
        path = Path(filename)
        path.write_text("\n".join(json.dumps(row) for row in rows), encoding="utf-8")
        self.addCleanup(path.unlink)
        return path

    def test_accepts_minimal_ordered_trace(self):
        """A meta record, an AXI request, and a retirement summarize correctly."""
        trace = self.write(
            [
                {
                    "cycle": 0,
                    "event": "meta",
                    "source": "tb",
                    "rtl_commit": "abc",
                    "clock_domain": "cpu",
                    "memory_configuration": "behavioral",
                },
                {
                    "cycle": 2,
                    "event": "axi_request",
                    "source": "axi",
                    "axi_id": 3,
                    "address": "0x80000000",
                    "is_write": False,
                    "bytes": 64,
                },
                {"cycle": 7, "event": "retire", "source": "rob", "uops": 2},
            ]
        )
        data = summarize(read_trace(trace))
        self.assertEqual(data["cycles_observed"], 8)
        self.assertEqual(data["retired_uops"], 2)

    def test_rejects_non_line_axi_transfer(self):
        """An AXI request that is not a 64-byte line is rejected."""
        trace = self.write(
            [
                {
                    "cycle": 0,
                    "event": "meta",
                    "source": "tb",
                    "rtl_commit": "abc",
                    "clock_domain": "cpu",
                    "memory_configuration": "behavioral",
                },
                {
                    "cycle": 1,
                    "event": "axi_request",
                    "source": "axi",
                    "axi_id": 3,
                    "address": "0",
                    "is_write": False,
                    "bytes": 32,
                },
            ]
        )
        with self.assertRaises(ValueError):
            read_trace(trace)


if __name__ == "__main__":
    unittest.main()
