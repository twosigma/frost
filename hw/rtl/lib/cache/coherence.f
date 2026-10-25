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

# Standalone coherent endpoint library.
+incdir+$(ROOT)/hw/rtl/lib/cache
$(ROOT)/hw/rtl/lib/cache/coherence_pkg.sv
$(ROOT)/hw/rtl/lib/cache/coherence_channel.sv
$(ROOT)/hw/rtl/lib/cache/coherence_request_endpoint.sv
$(ROOT)/hw/rtl/lib/cache/coherence_home_endpoint.sv
$(ROOT)/hw/rtl/lib/cache/coherence_put_endpoint.sv
$(ROOT)/hw/rtl/lib/cache/coherence_endpoints_test_harness.sv
