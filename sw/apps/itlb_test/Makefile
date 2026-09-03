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

# Sv39 fetch-translation directed test (Phase 3 M5).
SRC_C := main.c
# Page-aligned code pages that the S/U-mode cases execute through non-identity
# mappings. They are placed statically, so the test needs no runtime code copies
# and runs under the fetch-fuzz shape as well.
EXTRA_ASM_SRC := pages.S
include ../../common/common.mk
