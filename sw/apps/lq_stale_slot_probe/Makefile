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

# Directed repro of a load-queue cached-slot hazard: a flushed cached load
# whose response is still outstanding keeps its slot (drained on arrival),
# and a second partial flush must not judge that dead slot by its stale ROB
# tag and clear the issued bit of the live load now occupying its queue
# entry (iter.S has the instruction shape). Either tier: the probed loads
# always target cached DDR.
EXTRA_ASM_SRC := iter.S
SRC_C := ../../lib/src/uart.c main.c
include ../../common/common.mk
