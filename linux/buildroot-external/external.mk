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
# This external tree adds no custom Buildroot packages of its own: the FROST
# Linux MVP is just an upstream kernel (6.18.7) + a busybox initramfs + a
# post-image packaging step. The wildcard include below is the standard
# BR2_EXTERNAL hook so that any future board/frost packages are picked up
# automatically without editing this file.
include $(sort $(wildcard $(BR2_EXTERNAL_FROST_PATH)/package/*/*.mk))
