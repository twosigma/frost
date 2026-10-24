#!/usr/bin/env python3
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

"""Validate an RTL JSONL trace and write a provenance-bearing calibration record."""

from __future__ import annotations
import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from calibration.trace_contract import compare_summary, read_trace, summarize

parser = argparse.ArgumentParser()
parser.add_argument("--trace", type=Path, required=True)
parser.add_argument("--out", type=Path, required=True)
parser.add_argument("--rtl-commit", required=True)
parser.add_argument("--model-run", type=Path)
args = parser.parse_args()

events = read_trace(args.trace)
if events[0]["rtl_commit"] != args.rtl_commit:
    raise SystemExit("trace meta rtl_commit does not match --rtl-commit")
model = (
    json.loads(args.model_run.read_text(encoding="utf-8")) if args.model_run else None
)
record = compare_summary(summarize(events), model)
record.update(
    {
        "rtl_commit": args.rtl_commit,
        "trace": str(args.trace),
        "calibration_status": "valid trace only; fit parameters only with archived directed-case evidence",
    }
)
args.out.parent.mkdir(parents=True, exist_ok=True)
args.out.write_text(
    json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8"
)
