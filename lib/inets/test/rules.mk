#-*-makefile-*-   ; force emacs to enter makefile-mode
# ----------------------------------------------------
# Make include file for otp
#
# Copyright (C) 1996, Ericsson Telecommunications
# Author: Lars Thorsen
# ----------------------------------------------------
.SUFFIXES: .hrl .erl .jam .beam 


# ----------------------------------------------------
#	Common macros
# ----------------------------------------------------
DEFAULT_TARGETS =  opt debug instr release release_docs clean docs

# ----------------------------------------------------
#	Erlang language section
# ----------------------------------------------------
EMULATOR = beam
ifeq ($(findstring vxworks,$(TARGET)),vxworks)
# VxWorks object files should be compressed.
# Other object files should have debug_info.
ERL_COMPILE_FLAGS += +compressed
else
ifdef BOOTSTRAP
ERL_COMPILE_FLAGS += +slim
else
ERL_COMPILE_FLAGS += +debug_info
endif
endif
ERLC_WFLAGS = -W
ERLC = erlc $(ERLC_WFLAGS) $(ERLC_FLAGS)
ERL.beam =  erl.beam -boot start_clean
ERL.jam = erl -boot start_clean
ERL = $(ERL.$(EMULATOR))

ifeq ($(EBIN),)
EBIN = .
endif

ESRC = .


$(EBIN)/%.jam: $(ESRC)/%.erl
	$(ERLC) -bjam $(ERL_FLAGS) $(ERL_COMPILE_FLAGS) -o$(EBIN) $<

$(EBIN)/%.beam: $(ESRC)/%.erl
	$(ERLC) -bbeam $(ERL_FLAGS) $(ERL_COMPILE_FLAGS) -o$(EBIN) $<

.erl.jam:
	$(ERLC) -bjam $(ERL_FLAGS) $(ERL_COMPILE_FLAGS) -o$(dir $@) $<

.erl.beam:
	$(ERLC) -bbeam $(ERL_FLAGS) $(ERL_COMPILE_FLAGS) -o$(dir $@) $<





