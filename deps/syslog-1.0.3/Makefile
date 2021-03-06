PROJECT = syslog
ROOT = ../..

EBINS = $(shell find $(ROOT)/deps/lager-* -maxdepth 2 -name ebin -print)
PA = $(foreach EBIN,$(EBINS),-pa $(EBIN))

ERLC_OPTS += +debug_info +warn_export_all $(PA)

.PHONY: all compile clean

all: compile

MODULES = $(shell ls src/*.erl | sed 's/src\///;s/\.erl/,/' | sed '$$s/.$$//')

compile: ebin/$(PROJECT).app priv/syslog_drv.so
	@cat src/$(PROJECT).app.src \
		| sed 's/{modules, \[\]}/{modules, \[$(MODULES)\]}/' \
		> ebin/$(PROJECT).app
	-@$(MAKE) ebin/$(PROJECT).app

ebin/$(PROJECT).app: src/*.erl
	@mkdir -p ebin/
	erlc -v $(ERLC_OPTS) -o ebin/ -pa ebin/ $?

USR_INCLUDE := $(wildcard $(shell dirname `which erl`)/../erts-*/include)
ifeq ($(USR_INCLUDE),)
	USR_INCLUDE = /usr/lib/erlang/usr/include
endif

ERL_INTERFACE := $(shell find $(USR_INCLUDE)/../../ -type d -name "erl_interface-*" -print)
ifeq ($(ERL_INTERFACE),)
# 3.7.9 is R15B03-1
# Change to 3.7.20 for 17.5
	ERL_INTERFACE := $(USR_INCLUDE)/../../lib/erl_interface-3.7.9
endif

priv/syslog_drv.so: c_src/syslog_drv.c
	@mkdir -p priv/
	gcc  -I$(USR_INCLUDE) -I$(ERL_INTERFACE)/include -L$(ERL_INTERFACE)/lib -fpic -shared c_src/syslog_drv.c -o priv/syslog_drv.so -lerl_interface -lei

compile-test: test/$(PROJECT).app
	@cat src/$(PROJECT).app.src \
		| sed 's/{modules, \[\]}/{modules, \[$(MODULES)\]}/' \
		> test/$(PROJECT).app
	-@$(MAKE) test/$(PROJECT).app

test/$(PROJECT).app: src/*.erl
	@mkdir -p test/
	erlc -v $(ERLC_OPTS) -DTEST -o test/ -pa test/ $?

clean:
	rm -f ebin/*
	rm -f priv/*.so
	rm -f test/*.beam test/$(PROJECT).app
	rm -f erl_crash.dump

test: clean compile-test eunit

eunit: compile-test
	erl -noshell -pa test -eval "eunit:test([$(MODULES)], [verbose])" -s init stop
