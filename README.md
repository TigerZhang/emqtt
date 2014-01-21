# Moved to https://bitbucket.org/msgbus/emqtt

emqtt
=====

erlang mqtt broker.

requires
========

erlang R15B+ 

git client

build
=======

make

release
=======

make generate

deloy
=====

cp -R rel/emqtt $INSTALL_DIR

# config

1. node_tag. frontend server 标签，用来做 rabbitmq route key 后缀，每个 frontend server 的 node_tag 必须不同。

start
======

cd $INSTALL_DRI/emqtt

./bin/emqtt console

or

./bin/emqtt start

status
======

./bin/emqtt_ctl status

stop
====

./bin/emqtt stop

logs
====

log/*

design
=====

https://github.com/emqtt/emqtt/wiki

author
=====

Ery Lee <ery.lee at gmail dot com>


license
======

The emqtt broker is licensed under the MOZILLA PUBLIC LICENSE Version 1.1. 

The files below copied from rabbitmq: 

credit_flow.erl

file_handle_cache.erl

gen_server2.erl

priority_queue.erl

supervisor2.erl

tcp_acceptor.erl

tcp_acceptor_sup.erl

tcp_listener.erl

tcp_listener_sup.erl

any questions regarding licensing, please contact ery.lee at gmail dot com.
