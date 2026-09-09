# Clock-domain-crossing primitives (no vendor instances)

# Two-flop level synchronizer
$(ROOT)/hw/rtl/lib/cdc/cdc_sync.sv

# Asynchronous-assert, synchronous-release reset
$(ROOT)/hw/rtl/lib/cdc/cdc_reset_sync.sv

# Gray-coded event counter with an epoch rebase
$(ROOT)/hw/rtl/lib/cdc/cdc_gray_count.sv
