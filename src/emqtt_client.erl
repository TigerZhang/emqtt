%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License at
%% http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%% License for the specific language governing rights and limitations
%% under the License.
%%
%% The Original Code is eMQTT
%%
%% The Initial Developer of the Original Code is <ery.lee at gmail dot com>
%% Copyright (C) 2012 Ery Lee All Rights Reserved.

-module(emqtt_client).

-behaviour(gen_server2).

-export([start_link/0, go/3, info/1, make_msg/1]).

-export([init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    code_change/3,
    terminate/2]).

-include("emqtt.hrl").

-include("emqtt_frame.hrl").

-include("emqtt_internal.hrl").

-include_lib("elog/include/elog.hrl").

-define(CLIENT_ID_MAXLEN, 23).
-record(state, {socket,
    conn_name,
    await_recv,
    connection_state,
    conserve,
    parse_state,
    message_id,
    client_id,
    clean_sess,
    will_msg,
    keep_alive,
    awaiting_ack,
    subtopics,
    awaiting_rel,
    protocol_version,
    node_tag,
    uid}).


-define(FRAME_TYPE(Frame, Type),
    Frame = #mqtt_frame{fixed = #mqtt_frame_fixed{type = Type}}).

start_link() ->
    gen_server2:start_link(?MODULE, [], []).

go(Pid, NodeTag, Sock) ->
    gen_server2:call(Pid, {go, NodeTag, Sock}).

info(Pid) ->
    gen_server2:call(Pid, info).

init([]) ->
    random:seed(erlang:now()),
    {ok, undefined, hibernate, {backoff, 1000, 1000, 10000}}.

handle_call(duplicate_id, _From, State = #state{conn_name = ConnName, client_id = ClientId}) ->
    ?ERROR("Shutdown for duplicate clientid:~s, conn:~s", [ClientId, ConnName]),
    stop({shutdown, duplicate_id}, State);

handle_call(info, _From, #state{conn_name = ConnName,
    message_id = MsgId, client_id = ClientId} = State) ->
    Info = [{conn_name, ConnName},
        {message_id, MsgId},
        {client_id, ClientId}],
    {reply, Info, State};

handle_call({go, NodeTag, Sock}, _From, _State) ->
    process_flag(trap_exit, true),
    ok = throw_on_error(
        inet_error, fun() -> emqtt_net:tune_buffer_size(Sock) end),
    {ok, ConnStr} = emqtt_net:connection_string(Sock, inbound),
    %FIXME: merge to registry
    emqtt_client_monitor:mon(self()),
    ?INFO("accepting connection (~s)", [ConnStr]),
    {reply, ok,
        control_throttle(
            #state{socket = Sock,
            conn_name = ConnStr,
            await_recv = false,
            connection_state = running,
            conserve = false,
            parse_state = emqtt_frame:initial_state(),
            message_id = 1,
            subtopics = [],
            awaiting_ack = gb_trees:empty(),
            awaiting_rel = gb_trees:empty(),
            protocol_version = undefined,
            node_tag = NodeTag,
            uid = undefined})}.

handle_cast({suback, Frame}, #state{socket = Sock, protocol_version = ProtocolVersion} = State) ->
    GrantedQos = Frame#mqtt_frame.variable#mqtt_frame_suback.qos_table,
    ?DEBUG("GrantedQos ~p", [GrantedQos]),

    send_frame(Sock, #mqtt_frame{fixed = #mqtt_frame_fixed{type = ?SUBACK},
        variable = #mqtt_frame_suback{
            message_id = Frame#mqtt_frame.variable#mqtt_frame_suback.message_id,
            qos_table = GrantedQos}}, ProtocolVersion),
    {noreply, State};

handle_cast({puback, Frame}, #state{socket = Sock, protocol_version = ProtocolVersion} = State) ->
    send_frame(Sock, #mqtt_frame{fixed = #mqtt_frame_fixed{type = ?PUBACK},
        variable = #mqtt_frame_publish{
            message_id = Frame#mqtt_frame.variable#mqtt_frame_publish.message_id}},
        ProtocolVersion),
    {noreply, State};

handle_cast(Msg, State) ->
    {stop, {badmsg, Msg}, State}.

handle_info({route, Msg}, #state{socket = Sock, protocol_version = ProtocolVersion} = State) ->

    #mqtt_msg{retain = Retain,
    qos = Qos,
    topic = Topic,
    dup = Dup,
    message_id = MessageId,
    payload = Payload,
    encoder = Encoder} = Msg,

    Payload1 =
        if
            Encoder == undefined -> Payload;
            true -> Encoder(Payload)
        end,

    Frame = #mqtt_frame{
        fixed = #mqtt_frame_fixed{type = ?PUBLISH,
        qos = Qos,
        retain = Retain,
        dup = Dup},
        variable = #mqtt_frame_publish{topic_name = Topic,
        message_id = if
                         Qos == ?QOS_0 -> undefined;
                         true -> MessageId
                     end},
        payload = Payload1},

    send_frame(Sock, Frame, ProtocolVersion),

    if
        Qos == ?QOS_0 ->
            {noreply, State};
        true ->
            {noreply, next_msg_id(State)}
    end;

handle_info({inet_reply, _Ref, ok}, State) ->
    {noreply, State, hibernate};

handle_info({inet_async, Sock, _Ref, {ok, Data}}, #state{socket = Sock} = State) ->
    process_received_bytes(
        Data, control_throttle(State#state{await_recv = false}));

handle_info({inet_async, _Sock, _Ref, {error, Reason}}, State) ->
    network_error(Reason, State);

handle_info({inet_reply, _Sock, {error, Reason}}, State) ->
    ?ERROR("sock error: ~p~n", [Reason]),
    {noreply, State};

handle_info(keep_alive_timeout, #state{keep_alive = KeepAlive} = State) ->
    case emqtt_keep_alive:state(KeepAlive) of
        idle ->
            ?INFO("keep_alive timeout: ~p", [State#state.client_id]),
            {stop, normal, State};
        active ->
            KeepAlive1 = emqtt_keep_alive:reset(KeepAlive),
            {noreply, State#state{keep_alive = KeepAlive1}}
    end;

handle_info(Info, State) ->
    {stop, {badinfo, Info}, State}.

terminate(_Reason, #state{client_id = ClientId, keep_alive = KeepAlive, uid = Uid}) ->
    ok = emqtt_registry:unregister({ClientId, Uid}),
    emqtt_keep_alive:cancel(KeepAlive),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

throw_on_error(E, Thunk) ->
    case Thunk() of
        {error, Reason} -> throw({E, Reason});
        {ok, Res} -> Res;
        Res -> Res
    end.

async_recv(Sock, Length, infinity) when is_port(Sock) ->
    prim_inet:async_recv(Sock, Length, -1);

async_recv(Sock, Length, Timeout) when is_port(Sock) ->
    prim_inet:async_recv(Sock, Length, Timeout).

%-------------------------------------------------------
% receive and parse tcp data
%-------------------------------------------------------
process_received_bytes(<<>>, State) ->
    {noreply, State};

process_received_bytes(Bytes,
    State = #state{parse_state = ParseState,
        conn_name = ConnStr, protocol_version = ProtocolVersion}) ->
    ?INFO("~p~n", [Bytes]),
    case emqtt_frame:parse(Bytes, ParseState, ProtocolVersion) of
        {more, ParseState1} ->
            {noreply,
                control_throttle(State#state{parse_state = ParseState1}),
                hibernate};
        {ok, Frame, Rest} ->
            State2 = case Frame#mqtt_frame.fixed#mqtt_frame_fixed.type of
                         ?CONNECT ->
                             State#state{
                                client_id = Frame#mqtt_frame.variable#mqtt_frame_connect.client_id,
                                protocol_version = Frame#mqtt_frame.variable#mqtt_frame_connect.proto_ver
                             };
                         _ ->
                             State
                     end,
            case process_frame(Bytes, Frame, State2) of
                {ok, State1} ->
                    PS = emqtt_frame:initial_state(),
                    process_received_bytes(
                        Rest,
                        State1#state{parse_state = PS});
                {err, Reason, State1} ->
                    ?ERROR("MQTT protocol error ~p for connection ~p~n", [Reason, ConnStr]),
                    stop({shutdown, Reason}, State1);
                {stop, State1} ->
                    stop(normal, State1)
            end;
        {error, Error} ->
            ?ERROR("MQTT detected framing error ~p for connection ~p~n", [ConnStr, Error]),
            stop({shutdown, Error}, State)
    end.

clientid_to_uid(ClientId) ->
    %% TODO determine uid from client id
    ResovedUid = case application:get_env(uid_url) of
        {ok, Url} ->
            Http_url = lists:append(Url, ClientId),
            {ok, {{_Version, ReturnCode, _ReasonPhrase}, _Headers, Body}} = httpc:request(Http_url),
            case ReturnCode of
                200 ->
                    ?INFO("Get Uid: ~p~n", [Body]),
                    Uid = list_to_integer(Body),
                    case Uid of
                        -1 ->
                            ?ERROR("Uid is not existed: ~p~n", [ClientId]),
                            {error, <<"uid is not existed">>};
                        -2 ->
                            ?ERROR("Server error: ~p~n", [Uid]),
                            {error, <<"server error">>};
                        _0ther ->
                            {ok, Uid}
                    end;
                _Other ->
                    ?ERROR("Uncacthed case: ~p~n", [ReturnCode]),
                    {error, Body}
            end;
        _ ->
            {error, <<"no uid_url configured">>}
    end,
    case ResovedUid of
        {error, Error} ->
            case application:get_env(forced_correct_uid) of
            {ok, true} ->
                {error, Error};
            _ ->
                %% generate a random uid
                Uid2 = random:uniform(16#000fffffffffffff),
                ?ERROR("Generate a random uid ~p", [Uid2]),
                {ok, Uid2}
            end;
        {ok, _} ->
            ResovedUid
    end.

process_frame(Bytes, Frame = #mqtt_frame{fixed = #mqtt_frame_fixed{type = Type}},
    State = #state{client_id = ClientId, keep_alive = KeepAlive,
        protocol_version = ProtocolVersion, node_tag = NodeTag,
        uid = Uid}) ->
    KeepAlive1 = emqtt_keep_alive:activate(KeepAlive),
    case validate_frame(Type, Frame) of
        ok ->
            ?INFO("frame from ~s: ~p", [ClientId, Frame]),
            %% TODO: configure option for switching handler
            Key = erlang:integer_to_binary(Type),
            ?INFO("forward to mq: key[~p]", [Key]),
            {Uid2, State2} = make_sure_uid(Uid, ClientId, State),
            case {Uid2, State2} of
                {error, Error} ->
                    {error, Error};
                _ ->
                    forward_package_to_mq(NodeTag, ProtocolVersion, Uid2, ClientId, Bytes, Key, State2),
                    handle_retained(Type, Frame),
                    case command_handle_locally(Type) of
                        true ->
                            process_request(Type, Frame, State2#state{keep_alive = KeepAlive1});
                        false ->
                            {ok, State2#state{keep_alive = KeepAlive1}}
                    end
            end;
    %% process_request(Type, Frame, State#state{keep_alive=KeepAlive1});
        {error, Reason} ->
            {err, Reason, State}
    end.

forward_package_to_mq(NodeTag, ProtocolVersion, Uid2, ClientId, Bytes, Key, State2) ->
    BytesWithHeader = internal_package_pb:encode_internalpackage({
        internalpackage,
        0, 0, 0, 0,
        NodeTag,
        ProtocolVersion, % protocol version
        Uid2, list_to_binary(ClientId),
        Bytes}),
    case msgbus_amqp_proxy:send(Key, list_to_binary(BytesWithHeader)) of
        ok ->
            {ok, State2};
        {_, Reason1} ->
            ?CRITICAL("forward to mq failed: key[~p] ClientId[~p] Reason[~p]",
                [Key, ClientId, Reason1]),
            {err, Reason1, State2};
        Else ->
            io:format("Uncacthed case: ~p~n", [Else]),
            {ok, State2}
    end.

make_sure_uid(Uid, ClientId, State) ->
    case Uid of
        undefined ->
            case clientid_to_uid(ClientId) of
                {ok, Uid3} ->
                    {Uid3, State#state{uid = Uid3}};
                {error, Error} ->
                    {error, Error}
            end;
        _ -> {Uid, State}
    end.

command_handle_locally(?CONNECT) -> true;
command_handle_locally(?DISCONNECT) -> true;
command_handle_locally(?PINGREQ) -> true;
command_handle_locally(_) -> false.

process_request(?CONNECT,
    #mqtt_frame{variable = #mqtt_frame_connect{
            username = Username,
            password = Password,
            proto_ver = ProtoVersion,
            clean_sess = _CleanSess,
            keep_alive = AlivePeriod,
            client_id = ClientId} = Var},
    #state{socket = Sock, protocol_version = ProtocolVersion,
        uid = Uid} = State) ->
    {ReturnCode, State1} =
        case {(ProtoVersion =:= ?MQTT_PROTO_MAJOR) or (ProtoVersion =:= ?CLOS_MQTT_PROTO_MAJAR),
            valid_client_id(ClientId)} of
            {false, _} ->
                {?CONNACK_PROTO_VER, State};
            {_, false} ->
                {?CONNACK_INVALID_ID, State};
            _ ->
                case emqtt_auth:check(Username, Password) of
                    false ->
                        ?ERROR_MSG("MQTT login failed - no credentials"),
                        {?CONNACK_CREDENTIALS, State};
                    true ->
                        ?INFO("connect from clientid: ~s, ~p, ~p", [ClientId, Uid, AlivePeriod]),
                        ok = emqtt_registry:register({ClientId, Uid}, self()),
                        KeepAlive = emqtt_keep_alive:new(AlivePeriod * 3000, keep_alive_timeout),
                        {?CONNACK_ACCEPT,
                            State#state{will_msg = make_will_msg(Var),
                            client_id = ClientId,
                            keep_alive = KeepAlive,
                            protocol_version = ProtoVersion}}
                end
        end,
    send_frame(Sock, #mqtt_frame{fixed = #mqtt_frame_fixed{type = ?CONNACK},
    variable = #mqtt_frame_connack{
        return_code = ReturnCode}}, ProtocolVersion),
    {ok, State1};

process_request(?PUBLISH, Frame = #mqtt_frame{
        fixed = #mqtt_frame_fixed{qos = ?QOS_0}}, State) ->
    emqtt_router:publish(make_msg(Frame)),
    {ok, State};

process_request(?PUBLISH,
    Frame = #mqtt_frame{
            fixed = #mqtt_frame_fixed{qos = ?QOS_1},
            variable = #mqtt_frame_publish{message_id = MsgId}},
    State = #state{socket = Sock, protocol_version = ProtocolVersion}) ->
    emqtt_router:publish(make_msg(Frame)),
    send_frame(Sock, #mqtt_frame{fixed = #mqtt_frame_fixed{type = ?PUBACK},
    variable = #mqtt_frame_publish{message_id = MsgId}}, ProtocolVersion),
    {ok, State};

process_request(?PUBLISH,
    Frame = #mqtt_frame{
            fixed = #mqtt_frame_fixed{qos = ?QOS_2},
            variable = #mqtt_frame_publish{message_id = MsgId}},
    State = #state{socket = Sock, protocol_version = ProtocolVersion}) ->
    emqtt_router:publish(make_msg(Frame)),
    put({msg, MsgId}, pubrec),
    send_frame(Sock, #mqtt_frame{fixed = #mqtt_frame_fixed{type = ?PUBREC},
    variable = #mqtt_frame_publish{message_id = MsgId}}, ProtocolVersion),

    {ok, State};

process_request(?PUBACK, #mqtt_frame{}, State) ->
    %TODO: fixme later
    {ok, State};

process_request(?PUBREC, #mqtt_frame{
        variable = #mqtt_frame_publish{message_id = MsgId}},
    State = #state{socket = Sock, protocol_version = ProtocolVersion}) ->
    %TODO: fixme later
    send_frame(Sock,
        #mqtt_frame{fixed = #mqtt_frame_fixed{type = ?PUBREL},
        variable = #mqtt_frame_publish{message_id = MsgId}}, ProtocolVersion),
    {ok, State};

process_request(?PUBREL,
    #mqtt_frame{
            variable = #mqtt_frame_publish{message_id = MsgId}},
    State = #state{socket = Sock, protocol_version = ProtocolVersion}) ->
    erase({msg, MsgId}),
    send_frame(Sock,
        #mqtt_frame{fixed = #mqtt_frame_fixed{type = ?PUBCOMP},
        variable = #mqtt_frame_publish{message_id = MsgId}}, ProtocolVersion),
    {ok, State};

process_request(?PUBCOMP, #mqtt_frame{
        variable = #mqtt_frame_publish{message_id = _MsgId}},
    State = #state{socket = _Sock, protocol_version = _ProtocolVersion}) ->
    %TODO: fixme later
    {ok, State};

process_request(?SUBSCRIBE,
    #mqtt_frame{
            variable = #mqtt_frame_subscribe{message_id = MessageId,
                topic_table = Topics},
            payload = undefined},
    #state{socket = Sock, protocol_version = ProtocolVersion} = State) ->

    [emqtt_router:subscribe({Name, Qos}, self()) ||
        #mqtt_topic{name = Name, qos = Qos} <- Topics],

    GrantedQos = [Qos || #mqtt_topic{qos = Qos} <- Topics],

    send_frame(Sock, #mqtt_frame{fixed = #mqtt_frame_fixed{type = ?SUBACK},
    variable = #mqtt_frame_suback{
        message_id = MessageId,
        qos_table = GrantedQos}}, ProtocolVersion),

    {ok, State};

process_request(?UNSUBSCRIBE,
    #mqtt_frame{
            variable = #mqtt_frame_subscribe{message_id = MessageId,
                topic_table = Topics},
            payload = undefined},
    #state{socket = Sock, client_id = _ClientId, protocol_version = ProtocolVersion} = State) ->

    [emqtt_router:unsubscribe(Name, self()) || #mqtt_topic{name = Name} <- Topics],

    send_frame(Sock, #mqtt_frame{fixed = #mqtt_frame_fixed{type = ?UNSUBACK},
    variable = #mqtt_frame_suback{message_id = MessageId}}, ProtocolVersion),

    {ok, State};

process_request(?PINGREQ, #mqtt_frame{},
    #state{socket = Sock, keep_alive = KeepAlive,
        protocol_version = ProtocolVersion} = State) ->
    %?INFO("PINGREQ...",[]),
    %Keep alive timer
    KeepAlive1 = emqtt_keep_alive:reset(KeepAlive),
    send_frame(Sock, #mqtt_frame{fixed = #mqtt_frame_fixed{type = ?PINGRESP}},
        ProtocolVersion),
    {ok, State#state{keep_alive = KeepAlive1}};

process_request(?DISCONNECT, #mqtt_frame{}, State = #state{client_id = ClientId}) ->
    ?INFO("~s disconnected", [ClientId]),
    {stop, State}.

next_msg_id(State = #state{message_id = 16#ffff}) ->
    State#state{message_id = 1};
next_msg_id(State = #state{message_id = MsgId}) ->
    State#state{message_id = MsgId + 1}.

maybe_clean_sess(false, _Conn, _ClientId) ->
    % todo: establish subscription to deliver old unacknowledged messages
    ok.

%%----------------------------------------------------------------------------

make_will_msg(#mqtt_frame_connect{will_flag = false}) ->
    undefined;
make_will_msg(#mqtt_frame_connect{will_retain = Retain,
    will_qos = Qos,
    will_topic = Topic,
    will_msg = Msg}) ->
    #mqtt_msg{retain = Retain,
    qos = Qos,
    topic = Topic,
    dup = false,
    payload = Msg}.

send_will_msg(#state{will_msg = undefined}) ->
    ignore;
send_will_msg(#state{will_msg = WillMsg}) ->
    emqtt_router:publish(WillMsg).

send_frame(Sock, Frame, ProtocolVersion) ->
    erlang:port_command(Sock, emqtt_frame:serialise(Frame, ProtocolVersion)).

%%----------------------------------------------------------------------------
network_error(Reason,
    State = #state{conn_name = ConnStr}) ->
    ?INFO("MQTT detected network error '~p' for ~p", [Reason, ConnStr]),
    send_will_msg(State),
    % todo: flush channel after publish
    stop({shutdown, conn_closed}, State).

run_socket(State = #state{connection_state = blocked}) ->
    State;
run_socket(State = #state{await_recv = true}) ->
    State;
run_socket(State = #state{socket = Sock}) ->
    async_recv(Sock, 0, infinity),
    State#state{await_recv = true}.

control_throttle(State = #state{connection_state = Flow,
    conserve = Conserve}) ->
    case {Flow, Conserve} of
        {running, true} -> State#state{connection_state = blocked};
        {blocked, false} -> run_socket(State#state{
            connection_state = running});
        {_, _} -> run_socket(State)
    end.

stop(Reason, State) ->
    {stop, Reason, State}.

valid_client_id(ClientId) ->
    ClientIdLen = length(ClientId),
    1 =< ClientIdLen andalso ClientIdLen =< ?CLIENT_ID_MAXLEN.

handle_retained(?PUBLISH, #mqtt_frame{fixed = #mqtt_frame_fixed{retain = false}}) ->
    ignore;

handle_retained(?PUBLISH, #mqtt_frame{
        fixed = #mqtt_frame_fixed{retain = true},
        variable = #mqtt_frame_publish{topic_name = Topic},
        payload = <<>>}) ->
    emqtt_retained:delete(Topic);

handle_retained(?PUBLISH, Frame = #mqtt_frame{
        fixed = #mqtt_frame_fixed{retain = true},
        variable = #mqtt_frame_publish{topic_name = Topic}}) ->
    emqtt_retained:insert(Topic, make_msg(Frame));

handle_retained(_, _) ->
    ignore.

validate_frame(?PUBLISH, #mqtt_frame{variable = #mqtt_frame_publish{topic_name = Topic}}) ->
    case emqtt_topic:validate({publish, Topic}) of
        true -> ok;
        false -> {error, badtopic}
    end;

validate_frame(?UNSUBSCRIBE, #mqtt_frame{variable = #mqtt_frame_subscribe{topic_table = Topics}}) ->
    ErrTopics = [Topic || #mqtt_topic{name = Topic, qos = _Qos} <- Topics,
        not emqtt_topic:validate({subscribe, Topic})],
    case ErrTopics of
        [] -> ok;
        _ -> ?ERROR("error topics: ~p", [ErrTopics]), {error, badtopic}
    end;

validate_frame(?SUBSCRIBE, #mqtt_frame{variable = #mqtt_frame_subscribe{topic_table = Topics}}) ->
    ErrTopics = [Topic || #mqtt_topic{name = Topic, qos = Qos} <- Topics,
        not (emqtt_topic:validate({subscribe, Topic}) and (Qos < 3))],
    case ErrTopics of
        [] -> ok;
        _ -> ?ERROR("error topics: ~p", [ErrTopics]), {error, badtopic}
    end;

validate_frame(_Type, _Frame) ->
    ok.

make_msg(#mqtt_frame{
        fixed = #mqtt_frame_fixed{qos = Qos,
            retain = Retain,
            dup = Dup},
        variable = #mqtt_frame_publish{topic_name = Topic,
            message_id = MessageId},
        payload = Payload}) ->
    #mqtt_msg{retain = Retain,
    qos = Qos,
    topic = Topic,
    dup = Dup,
    message_id = MessageId,
    payload = Payload}.

