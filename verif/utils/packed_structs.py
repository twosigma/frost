#    Copyright 2026 Two Sigma Open Source, LLC
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.

"""Pack and unpack declaration-ordered SystemVerilog struct fields."""

from collections.abc import Mapping


def pack_struct(
    fields: list[tuple[str, int]],
    values: Mapping[str, int | bool],
) -> int:
    """Pack MSB-first fields, masking each value to its declared width.

    Missing fields default to zero; extra keys are ignored. One-bit values
    are masked as integers, so a value of 2 contributes zero rather than True.
    """
    packed = 0
    offset = sum(width for _, width in fields)
    for name, width in fields:
        offset -= width
        raw = int(values.get(name, 0))
        packed |= (raw & ((1 << width) - 1)) << offset
    return packed


def unpack_struct(fields: list[tuple[str, int]], packed: int) -> dict[str, int | bool]:
    """Unpack MSB-first fields, returning one-bit fields as booleans."""
    result: dict[str, int | bool] = {}
    offset = sum(width for _, width in fields)
    for name, width in fields:
        offset -= width
        raw = (packed >> offset) & ((1 << width) - 1)
        result[name] = bool(raw) if width == 1 else raw
    return result
