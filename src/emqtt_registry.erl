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

-module(emqtt_registry).

-include("emqtt.hrl").
-include("emqtt_frame.hrl").

-include_lib("elog/include/elog.hrl").

-export([start_link/0, 
		size/0,
		register/2,
		unregister/1]).

-behaviour(gen_server).

-export([init/1,
		 handle_call/3,
		 handle_cast/2,
		 handle_info/2,
         terminate/2,
		 code_change/3]).

-record(state, {}).

-define(SERVER, ?MODULE).

%%----------------------------------------------------------------------------

start_link() ->
    gen_server2:start_link({local, ?SERVER}, ?MODULE, [], []).

size() ->
	ets:info(client, size).

register({ClientId, Uid}, Pid) ->
    gen_server2:cast(?SERVER, {register, {ClientId, Uid}, Pid}).

unregister({ClientId, Uid}) ->
    gen_server2:cast(?SERVER, {unregister, {ClientId, Uid}}).

%%----------------------------------------------------------------------------

init([]) ->
	ets:new(client, [set, protected, named_table]),
    ets:new(uid, [set, protected, named_table]),
	?INFO("~p is started.", [?MODULE]),
    {ok, #state{}}. % clientid -> {pid, monitor}

%%--------------------------------------------------------------------------
handle_call(Req, _From, State) ->
    {stop, {badreq, Req}, State}.

handle_cast({register, {ClientId, Uid}, Pid}, State) ->
	case ets:lookup(client, ClientId) of
	[{_, {OldPid, MRef}}] ->
		catch gen_server2:call(OldPid, duplicate_id),
		erlang:demonitor(MRef);
	[] ->
		ignore
	end,
    ProcessInfo = {Pid, erlang:monitor(process, Pid)},
	ets:insert(client, {ClientId, ProcessInfo}),
    ets:insert(uid, {Uid, ProcessInfo}),
    {noreply, State};

handle_cast({unregister, {ClientId, Uid}}, State) ->
	case ets:lookup(client, ClientId) of
	[{_, {_Pid, MRef}}] ->
		erlang:demonitor(MRef),
		ets:delete(client, ClientId);
	[] ->
		ignore
	end,
    case ets:lookup(uid, Uid) of
        [{_, {_, _}}] ->
            ets:delete(uid, Uid);
        [] ->
            ignore
    end,
	{noreply, State};

handle_cast({package_from_mq, InternalPackage}, State) ->
    {internalpackage, _FromIp, _FromPort, _ToIp, _ToPort,
        _FromTag, ProtocolVersion, Uid, ClientId, MqttPackage}
        = internal_package_pb:decode_internalpackage(InternalPackage),
    lager:log(info, self(), "mqtt package ~p", [MqttPackage]),
    case parse_frame_simple(MqttPackage, ProtocolVersion) of
        ignore ->
            ignore;
        Frame ->
%%     {ok, Frame, _} = emqtt_frame:parse(MqttPackage, none),
%%     Retain = Frame#mqtt_frame.fixed#mqtt_frame_fixed.retain,
%%     Qos = Frame#mqtt_frame.fixed#mqtt_frame_fixed.qos,
%%     Dup = Frame#mqtt_frame.fixed#mqtt_frame_fixed.dup,
            lager:log(info, self(), "mqtt frame ~p", [Frame]),
            Type = Frame#mqtt_frame.fixed#mqtt_frame_fixed.type,

            lager:log(info, self(), "package_from_mq ~p", [Type]),

            if
                Type == ?PUBLISH ->
                    case ets:lookup(uid, Uid) of
                        [{_, {Pid, _MRef}}] ->
                            Pid ! {route, emqtt_client:make_msg(Frame)};
                        [] ->
                            ignore
                    end;
                Type == ?PUBACK ->
                    case ets:lookup(uid, Uid) of
                        [{_, {Pid, _MRef}}] ->
                            gen_server:cast(Pid, {puback, Frame});
                        [] ->
                            ignore
                    end;
                Type == ?SUBACK ->
                    case ets:lookup(uid, Uid) of
                        [{_, {Pid, _MRef}}] ->
                            gen_server:cast(Pid, {suback, Frame});
                        [] ->
                            ignore
                    end;
                true ->
                    ignore
            end
    end,
    {noreply, State};

handle_cast(Msg, State) ->
    {stop, {badmsg, Msg}, State}.

parse_frame_simple(MqttPackage, ProtocolVersion) ->
    <<Type:4, Dup:1, QoS:2, Retain:1, Length:8, Variable/binary>> = MqttPackage,
    lager:log(info, self(), "Type: ~p", [Type]),
    case emqtt_frame:parse_frame(Variable,
        #mqtt_frame_fixed{type = Type, dup = Dup, qos = QoS, retain = Retain},
        ProtocolVersion,
        Length) of
        {ok, Frame, _} ->
            Frame;
        Else ->
            lager:log(error, self(), "pase frame error: ~p", [Else]),
            ignore
    end.

handle_info({'DOWN', MRef, process, DownPid, _Reason}, State) ->
	ets:match_delete(client, {'_', {DownPid, MRef}}),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

