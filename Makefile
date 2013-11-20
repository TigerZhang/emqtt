REBAR = ./rebar -j8
all: deps compile

compile: deps
	${REBAR} compile

deps:
	${REBAR} get-deps

clean:
	${REBAR} clean

generate: compile
	${REBAR} generate -f

relclean:
	rm -rf rel/emqtt

run: generate
	./rel/emqtt/bin/emqtt console
