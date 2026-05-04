##############################################################################
# UVM regression Makefile.
#
# Targets:
#   make regress       run full regression from scripts/test_list.f,
#                      merge coverage, write regress_out/summary.txt
#   make compile       compile DUT + UVM TB once (workLib_uvm/)
#   make test T=name   run a single test (alias for scripts/simulate.sh)
#   make cov           re-print merged coverage summary (after a regression)
#   make clean         remove workLib_uvm, regress_out, ucdbs, html
#
# Parallelism: regress.sh dispatches per-test jobs via xargs -P. Override
# with `make regress JOBS=4`. Compile is serial; only one workLib_uvm.
##############################################################################

JOBS ?= $(shell nproc)
T    ?= fft_smoke_test
SEED ?= 1

.PHONY: regress compile test cov clean help

help:
	@echo "Targets: regress | compile | test T=<name> SEED=<n> | cov | clean"

regress:
	JOBS=$(JOBS) bash scripts/regress.sh

compile:
	bash scripts/compile.sh

test: compile
	@mkdir -p regress_out/$(T)_seed$(SEED)
	bash -c 'source ./setup.sh && \
	  bash scripts/simulate.sh $(T) $(SEED) regress_out/$(T)_seed$(SEED)'
	@bash scripts/parse_log.sh regress_out/$(T)_seed$(SEED)/transcript

cov:
	@if [ -f regress_out/merged.ucdb ]; then \
	  vcover report -summary regress_out/merged.ucdb; \
	  echo "HTML: regress_out/cov_html/index.html"; \
	else \
	  echo "no merged.ucdb — run 'make regress' first"; exit 1; \
	fi

clean:
	rm -rf workLib_uvm regress_out cov_html fft_cov.ucdb \
	       fft_ref.so transcript vsim_stacktrace.vstf \
	       modelsim.ini tr_db.log
