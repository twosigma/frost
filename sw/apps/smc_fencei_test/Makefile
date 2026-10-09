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

# Self-modifying code with fence.i. Sweeps the store-to-fence.i gap, warm and
# cold L1D (a cold line makes the patch store a write-allocate miss), and tight
# self-modify loops.
SRC_C   := ../../lib/src/uart.c main.c
include ../../common/common.mk
