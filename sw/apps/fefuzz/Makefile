#    Copyright (c) 2026 John Goodacre.
# fefuzz: seeded front-end fuzzer (sync #20 item 7). FE_SEED picks the program, FE_TARGET its size.
FE_SEED ?= 1
FE_TARGET ?= 6000
SRC_C := ../../lib/src/uart.c main.c
EXTRA_ASM_SRC := fe_gen.S
include ../../common/common.mk

fe_gen.S fe_expect.h &: fe_gen.py FORCE
	python3 $< $(call shell_quote,$(FE_SEED)) fe_gen.S fe_expect.h $(call shell_quote,$(FE_TARGET))
