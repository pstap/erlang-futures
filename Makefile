all:
	erlc -o ebin -Wall src/*.erl
run:
	erl -pa ebin
