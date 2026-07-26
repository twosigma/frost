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

# FROST BR2_EXTERNAL makefile.
#
# The wildcard include below is the standard BR2_EXTERNAL hook: every package
# under package/<pkg>/<pkg>.mk is picked up automatically. Current packages:
#   frost-stress — userspace boot stress payload run from the overlay inittab
#                  (prints the FROST_USERSPACE_STRESS_PASS token CI asserts).
include $(sort $(wildcard $(BR2_EXTERNAL_FROST_PATH)/package/*/*.mk))
