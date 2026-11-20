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

# Ray tracer: renders a scene (scene_sunset.inc) of reflective spheres in fixed-point
# arithmetic, streams the pixel rows to the UART and checks the frame's CRC
# against the reference that host_reference.c computes.
# RAYTRACE_SIZE=full (76x44 pixels, the demonstration image) or small (24x12).
SRC_C := ../../lib/src/uart.c raytrace.c

RAYTRACE_SIZE ?= small
ifeq ($(RAYTRACE_SIZE),full)
RAYTRACE_DIMS := -DRT_WIDTH=76 -DRT_HEIGHT=44 -DRT_SAMPLES=1
else ifeq ($(RAYTRACE_SIZE),small)
RAYTRACE_DIMS := -DRT_WIDTH=24 -DRT_HEIGHT=12 -DRT_SAMPLES=1
else
$(error RAYTRACE_SIZE must be full or small)
endif

EXTRA_CFLAGS += $(RAYTRACE_DIMS)

include ../../common/common.mk
