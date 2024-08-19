-include Makefile.local

# NOTE(z64): You'll have to get this path for your system yourself and override it
CACHE_PATH ?= ~/.cache/crystal/home-lune-git-kagi-dispatch-main.cr

# NOTE(z64): For `time` usage below
SHELL := /bin/bash

.PHONY: all
all: lib main
	nm --size-sort --print-size $(CACHE_PATH)/_main.o0.o | tail -n10

main: main.cr
	time crystal build main.cr -p -s # --emit=llvm-ir

lib: shard.lock

shard.lock: shard.yml
	shards install
