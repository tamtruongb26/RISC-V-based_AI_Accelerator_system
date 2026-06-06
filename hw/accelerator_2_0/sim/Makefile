# ============================================================================
# Makefile — RAAS accelerator RTL unit simulation (xsim CLI, board-independent)
#
# Chạy testbench bằng Vivado xsim ở chế độ batch (không cần board, không GUI).
# Mỗi target: xvlog -> xelab -> xsim -runall, tự bắt PASS/FAIL.
#
# Dùng:
#   make sim-pe          # 1 module
#   make sim-all         # toàn bộ Phase 0
#   make clean
#
# Override Vivado path nếu cần:
#   make sim-all VIVADO_DIR=/path/to/Vivado
# ============================================================================

SHELL := /bin/bash

VIVADO_DIR ?= /home/tam/Documents/app/2025.2.1/Vivado
SETTINGS   := $(VIVADO_DIR)/settings64.sh

ROOT  := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../../..)
HDL   := $(ROOT)/hw/accelerator_2_0/hdl
TB    := $(ROOT)/hw/accelerator_2_0/tb
BUILD := $(ROOT)/build/sim
MEM   := $(HDL)/sigmoid_rom.mem

# run_sim(name, srcs, need_mem)
#   name     : tên target = tên file tb ($(name)_tb.sv) = top module ($(name)_tb)
#   srcs     : danh sách file HDL nguồn
#   need_mem : non-empty nếu cần copy sigmoid_rom.mem vào dir sim (readmemh tương đối)
define run_sim
	@echo "── sim: $(1) ───────────────────────────────────────────────"
	@rm -rf $(BUILD)/$(1) && mkdir -p $(BUILD)/$(1)
	$(if $(3),@cp -f $(MEM) $(BUILD)/$(1)/,)
	@cd $(BUILD)/$(1) && . $(SETTINGS) >/dev/null 2>&1 && \
	  xvlog -sv $(2) $(TB)/$(1)_tb.sv > xvlog.log 2>&1 && \
	  xelab $(1)_tb -s $(1)_sim --timescale 1ns/1ps > xelab.log 2>&1 && \
	  xsim $(1)_sim -runall > xsim.log 2>&1; \
	  if grep -q "TESTS PASSED" $(BUILD)/$(1)/xsim.log; then \
	    echo "[PASS] $(1)"; \
	  else \
	    echo "[FAIL] $(1)  (log: build/sim/$(1)/xsim.log)"; \
	    tail -25 $(BUILD)/$(1)/xvlog.log $(BUILD)/$(1)/xelab.log $(BUILD)/$(1)/xsim.log; \
	    exit 1; \
	  fi

endef

.PHONY: sim-all sim-pe sim-data_path sim-post_proc sim-accelerator_top sim-scratchpad sim-accumulator clean

sim-scratchpad:
	$(call run_sim,scratchpad,$(HDL)/scratchpad.v,)

sim-accumulator:
	$(call run_sim,accumulator,$(HDL)/accumulator.v,)

sim-im2col:
	$(call run_sim,im2col,$(HDL)/im2col.v,)

sim-fault_injector:
	$(call run_sim,fault_injector,$(HDL)/fault_injector.v,)

sim-tmr_voter:
	$(call run_sim,tmr_voter,$(HDL)/tmr_voter.v,)

sim-ecc_secded:
	$(call run_sim,ecc_secded,$(HDL)/ecc_secded.v,)

sim-tmr_register:
	$(call run_sim,tmr_register,$(HDL)/tmr_register.v $(HDL)/fault_injector.v $(HDL)/tmr_voter.v,)

sim-pe:
	$(call run_sim,pe,$(HDL)/pe.v,)

sim-data_path:
	$(call run_sim,data_path,$(HDL)/pe.v $(HDL)/data_path.v,)

sim-post_proc:
	$(call run_sim,post_proc,$(HDL)/sigmoid_lookup.v $(HDL)/post_proc.v,1)

sim-accelerator_top:
	$(call run_sim,accelerator_top,$(wildcard $(HDL)/*.v),1)

sim-all: sim-pe sim-data_path sim-post_proc sim-scratchpad sim-accumulator sim-im2col sim-fault_injector sim-tmr_voter sim-ecc_secded sim-tmr_register sim-accelerator_top
	@echo ""
	@echo "════════════════════════════════════════════════════════════"
	@echo " Toàn bộ unit sim Phase 0 PASS"
	@echo "════════════════════════════════════════════════════════════"

clean:
	rm -rf $(BUILD)
