#    Copyright (c) 2026 John Goodacre.
# fefuzz: seeded front-end fuzzer (sync #20 item 7). FE_SEED picks the program, FE_TARGET its size.
FE_SEED ?= 1
FE_TARGET ?= 6000
SRC_C := ../../lib/src/uart.c main.c
EXTRA_ASM_SRC := fe_gen.S
GEN_OUT := $(shell python3 fe_gen.py $(FE_SEED) fe_gen.S fe_expect.h $(FE_TARGET) 2>&1 >/dev/null)
include ../../common/common.mk
