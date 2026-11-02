# Defaults also cover existing .config files created before I-cache options.
ICACHE_LINES ?= $(if $(CONFIG_ICACHE_LINES),$(CONFIG_ICACHE_LINES),16)
ICACHE_BLOCK_BYTES ?= $(if $(CONFIG_ICACHE_BLOCK_BYTES),$(CONFIG_ICACHE_BLOCK_BYTES),4)

ifneq ($(words $(ICACHE_LINES)),1)
  $(error ICACHE_LINES must be one power of two between 1 and 4096)
endif
ifeq ($(filter $(ICACHE_LINES),1 2 4 8 16 32 64 128 256 512 1024 2048 4096),)
  $(error ICACHE_LINES must be a power of two between 1 and 4096)
endif
ifneq ($(words $(ICACHE_BLOCK_BYTES)),1)
  $(error ICACHE_BLOCK_BYTES must be one power of two between 4 and 256)
endif
ifeq ($(filter $(ICACHE_BLOCK_BYTES),4 8 16 32 64 128 256),)
  $(error ICACHE_BLOCK_BYTES must be a power of two between 4 and 256)
endif

# The synthesis readers use these same effective settings.
export ICACHE_LINES ICACHE_BLOCK_BYTES
