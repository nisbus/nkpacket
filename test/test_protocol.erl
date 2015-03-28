%% -------------------------------------------------------------------
%%
%% Copyright (c) 2015 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc TEST Protocol behaviour

-module(test_protocol).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(nkpacket_protocol).

-export([transports/1, default_port/1]).
-export([conn_init/1, conn_parse/2, conn_unparse/2, conn_stop/2]).
-export([conn_handle_call/3, conn_handle_cast/2, conn_handle_info/2]).
-export([listen_init/1, listen_parse/4, listen_stop/2]).
-export([listen_handle_call/3, listen_handle_cast/2, listen_handle_info/2]).

-include("nkpacket.hrl").

%% ===================================================================
%% Types
%% Types
%% ===================================================================





-spec transports(nklibt:scheme()) ->
    [nkpacket:transport()].

transports(_) -> [udp, tcp, tls, sctp, ws, wss].

-spec default_port(nkpacket:transport()) ->
    inet:port_number().

default_port(udp) -> 1234;
default_port(tcp) -> 1235;
default_port(tls) -> 1236;
default_port(sctp) -> 1237;
default_port(ws) -> 1238;
default_port(wss) -> 1239;
default_port(_) -> invalid.



%% ===================================================================
%% Listen callbacks
%% ===================================================================


-record(listen_state, {
	pid,
	ref,
	nkport
}).


-spec listen_init(nkpacket:nkport()) ->
	#listen_state{}.

listen_init(NkPort) ->
	lager:notice("Protocol LISTEN init: ~p (~p)", [NkPort, self()]),
	State = case NkPort#nkport.meta of
		#{test:={Pid, Ref}} -> #listen_state{pid=Pid, ref=Ref, nkport=NkPort};
		_ -> #listen_state{nkport=NkPort}
	end,
	maybe_reply(listen_init, State),
	State.


listen_handle_call(Msg, _From, State) ->
	lager:warning("Unexpected call: ~p", [Msg]),
	{ok, State}.


listen_handle_cast(Msg, State) ->
	lager:warning("Unexpected cast: ~p", [Msg]),
	{ok, State}.


listen_handle_info(Msg, State) ->
	lager:warning("Unexpected info: ~p", [Msg]),
	{ok, State}.

listen_parse(Ip, Port, Data, State) ->
	lager:notice("LISTEN Parsing fromm ~p:~p: ~p", [Ip, Port, Data]),
	maybe_reply({listen_parse, Data}, State),
	{ok, State}.

listen_stop(Reason, State) ->
	lager:notice("LISTEN  stop: ~p, ~p", [Reason, State]),
	maybe_reply(listen_stop, State),
	ok.


%% ===================================================================
%% Conn callbacks
%% ===================================================================


-record(conn_state, {
	pid,
	ref,
	nkport
}).

-spec conn_init(nkpacket:nkport()) ->
	#conn_state{}.

conn_init(NkPort) ->
	lager:notice("Protocol CONN init: ~p (~p)", [NkPort, self()]),
	State = case NkPort#nkport.meta of
		#{test:={Pid, Ref}} -> #conn_state{pid=Pid, ref=Ref, nkport=NkPort};
		_ -> #conn_state{nkport=NkPort}
	end,
	maybe_reply(conn_init, State),
	State.


conn_parse({text, Data}, State) ->
	lager:notice("Parsing WS TEXT: ~p", [Data]),
	maybe_reply({parse, {text, Data}}, State),
	{ok, State};

conn_parse({binary, Data}, State) ->
	Msg = erlang:binary_to_term(Data),
	lager:notice("Parsing WS BIN: ~p", [Msg]),
	maybe_reply({parse, {binary, Msg}}, State),
	{ok, State};

conn_parse(close, State) ->
	{ok, State};

conn_parse(pong, State) ->
	{ok, State};

conn_parse({pong, Payload}, State) ->
	lager:notice("Parsing WS PONG: ~p", [Payload]),
	maybe_reply({pong, Payload}, State),
	{ok, State};

conn_parse(Data, State) ->
	Msg = erlang:binary_to_term(Data),
	lager:notice("Parsing: ~p", [Msg]),
	maybe_reply({parse, Msg}, State),
	{ok, State}.

conn_unparse({nkraw, Msg}, #conn_state{nkport=NkPort}=State) ->
	lager:notice("UnParsing RAW: ~p, ~p", [Msg, NkPort]),
	maybe_reply({unparse, Msg}, State),
	{ok, Msg, State};

conn_unparse(Msg, #conn_state{nkport=NkPort}=State) ->
	lager:notice("UnParsing: ~p, ~p", [Msg, NkPort]),
	maybe_reply({unparse, Msg}, State),
	{ok, erlang:term_to_binary(Msg), State}.

conn_handle_call(Msg, _From, State) ->
	lager:warning("Unexpected call: ~p", [Msg]),
	{ok, State}.


conn_handle_cast(Msg, State) ->
	lager:warning("Unexpected cast: ~p", [Msg]),
	{ok, State}.


conn_handle_info(Msg, State) ->
	lager:warning("Unexpected info: ~p", [Msg]),
	{ok, State}.

conn_stop(Reason, State) ->
	lager:notice("CONN stop: ~p", [Reason]),
	maybe_reply(conn_stop, State),
	ok.



% unparse(Msg, NkPort) ->
% 	lager:notice("Quick UnParsing: ~p, ~p", [Msg, NkPort]),
% 	{ok, erlang:term_to_binary(Msg)}.



%% ===================================================================
%% Parse and Unparse
%% ===================================================================










%% ===================================================================
%% Util
%% ===================================================================


maybe_reply(Msg, #listen_state{pid=Pid, ref=Ref}) when is_pid(Pid) -> Pid ! {Ref, Msg};
maybe_reply(Msg, #conn_state{pid=Pid, ref=Ref}) when is_pid(Pid) -> Pid ! {Ref, Msg};
maybe_reply(_, _) -> ok.







