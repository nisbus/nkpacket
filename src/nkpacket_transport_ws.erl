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

%% @private Websocket (WS/WSS) Transport.
%%
%% For listening, we start this server and also a 'shared' nkpacket_cowboy transport.
%% When a new connection arrives, ranch creates a new process, and 
%% cowboy_init/3 is called. It it is for us, we start a new connection linked to it.
%% When a new packet arrives, we send it to the connection.
%%
%% For outbound connections, we start a normal tcp/ssl connection and let it be
%% managed by a fresh nkpacket_connection process

-module(nkpacket_transport_ws).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([get_listener/1, connect/1]).
-export([start_link/1, init/1, terminate/2, code_change/3, handle_call/3, 
         handle_cast/2, handle_info/2]).
-export([websocket_handle/3, websocket_info/3, terminate/3]).
-export([cowboy_init/3]).

-include_lib("nklib/include/nklib.hrl").
-include("nkpacket.hrl").


%% ===================================================================
%% Private
%% ===================================================================


%% @private Starts a new listening server
-spec get_listener(nkpacket:nkport()) ->
    supervisor:child_spec().

get_listener(#nkport{transp=Transp}=NkPort) when Transp==ws; Transp==wss ->
    #nkport{domain=Domain, local_ip=Ip, local_port=Port} = NkPort,
    {
        {Domain, Transp, Ip, Port, make_ref()},
        {?MODULE, start_link, [NkPort]},
        transient,
        5000,
        worker,
        [?MODULE]
    }.


%% @private Starts a new connection to a remote server
-spec connect(nkpacket:nkport()) ->
    {ok, nkpacket:nkport(), binary()} | {error, term()}.
         
connect(NkPort) ->
    #nkport{
        domain = Domain,
        transp = Transp, 
        remote_ip = Ip, 
        remote_port = Port, 
        meta = Meta
    } = NkPort,
    SocketOpts = outbound_opts(NkPort),
    TranspMod = case Transp of ws -> tcp, ranch_tcp; wss -> ranch_ssl end,
    ConnTimeout = case maps:get(connect_timeout, Meta, undefined) of
        undefined -> nkpacket_config_cache:connect_timeout(Domain);
        Timeout0 -> Timeout0
    end,
    case TranspMod:connect(Ip, Port, SocketOpts, ConnTimeout) of
        {ok, Socket} -> 
            {ok, {LocalIp, LocalPort}} = TranspMod:sockname(Socket),
            Base = #{host=>nklib_util:to_host(Ip), path=><<"/">>},
            Meta1 = maps:merge(Base, Meta),
            NkPort1 = NkPort#nkport{
                local_ip = LocalIp,
                local_port = LocalPort,
                socket = Socket,
                meta = Meta1
            },
            case nkpacket_connection_ws:start_handshake(NkPort1) of
                {ok, WsProto, Rest} -> 
                    NkPort2 = NkPort#nkport{meta=Meta1#{ws_proto=>WsProto}},
                    TranspMod:setopts(Socket, [{active, once}]),
                    {ok, NkPort2, Rest};
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} -> 
            {error, Error}
    end.


%% ===================================================================
%% gen_server
%% ===================================================================


-record(state, {
    nkport :: nkpacket:nkport(),
    protocol :: nkpacket:protocol(),
    proto_state :: term(),
    shared :: pid(),
    monitor_ref :: reference(),
    host :: binary(),
    path :: binary(),
    ws_proto :: binary()
}).


%% @private
start_link(NkPort) ->
    gen_server:start_link(?MODULE, [NkPort], []).
    

%% @private Starts transport process
-spec init(term()) ->
    nklib_util:gen_server_init(#state{}).

init([NkPort]) ->
    #nkport{
        domain = Domain,
        transp = Transp, 
        local_ip = Ip, 
        local_port = Port,
        meta = Meta,
        protocol = Protocol
    } = NkPort,
    process_flag(trap_exit, true),   %% Allow calls to terminate
    try
        % This is the port for tcp/tls and also what will be sent to cowboy_init
        NkPort1 = NkPort#nkport{
            listen_ip = Ip,
            pid = self()
        },
        case nkpacket_cowboy:start(NkPort1, ?MODULE) of
            {ok, SharedPid} -> ok;
            {error, Error} -> SharedPid = throw(Error)
        end,
        erlang:monitor(process, SharedPid),
        case Port of
            0 -> {ok, {_, _, Port1}} = nkpacket:get_local(SharedPid);
            _ -> Port1 = Port
        end,
        Base = #{host => <<"all">>, path => <<"/">>, ws_proto => <<"all">>},
        Meta2 = maps:merge(Base, Meta),
        NkPort2 = NkPort1#nkport{
            local_port = Port1,
            listen_port = Port1,
            socket = SharedPid,
            meta = Meta2
        },   
        StoredMeta = maps:with([host, path, ws_proto], Meta2),
        StoredNkPort = NkPort2#nkport{meta=StoredMeta},
        nklib_proc:put(nkpacket_transports, StoredNkPort),
        nklib_proc:put({nkpacket_listen, Domain, Protocol, Transp}, StoredNkPort),
        {ok, ProtoState} = nkpacket_util:init_protocol(Protocol, listen_init, NkPort2),
        MonRef = case Meta of
            #{monitor:=UserRef} -> erlang:monitor(process, UserRef);
            _ -> undefined
        end,
        State = #state{
            nkport = NkPort2,
            protocol = Protocol,
            proto_state = ProtoState,
            shared = SharedPid,
            monitor_ref = MonRef,
            host = maps:get(host, Meta2),
            path = maps:get(path, Meta2),
            ws_proto = maps:get(ws_proto, Meta2)
        },
        {ok, State}
    catch
        throw:TError -> 
            ?error(Domain, "could not start ~p transport on ~p:~p (~p)", 
                   [Transp, Ip, Port, TError]),
        {stop, TError}
    end.


%% @private
-spec handle_call(term(), nklib_util:gen_server_from(), #state{}) ->
    nklib_util:gen_server_call(#state{}).

handle_call(get_nkport, _From, #state{nkport=NkPort}=State) ->
    {reply, {ok, NkPort}, State};

handle_call(get_local, _From, #state{nkport=NkPort}=State) ->
    {reply, nkpacket:get_local(NkPort), State};

handle_call(get_user, _From, #state{nkport=NkPort}=State) ->
    {reply, nkpacket:get_user(NkPort), State};

handle_call({check, ReqHost, ReqPath, ReqProto, Ip, Port, Pid}, _From, State) ->
    #state{host=Host, path=Path, ws_proto=Proto, nkport=NkPort} = State,
    lager:warning("WS INIT: ~p, ~p, ~p, ~p, ~p, ~p: ~p", 
                  [ReqHost, ReqPath, ReqProto, Host, Path, Proto,
                  nkpacket_util:check_paths(ReqPath, Path)]),
    case 
        (Host == <<"all">> orelse ReqHost==Host) andalso
        nkpacket_util:check_paths(ReqPath, Path) andalso
        (Proto == <<"all">> orelse ReqProto==Proto)
    of
        false ->
            {reply, next, State};
        true ->
            #nkport{domain=Domain, meta=Meta} = NkPort,
            Meta1 = maps:with(?CONN_LISTEN_OPTS, 
                                Meta#{host=>Host, path=>ReqPath, ws_proto=>Proto}),
            NkPort1 = NkPort#nkport{
                remote_ip = Ip,
                remote_port = Port,
                meta = Meta1,
                socket = Pid
            },
            % Connection will monitor listen process (unsing 'pid' and 
            % the cowboy process (using 'socket')
            case nkpacket_connection:start(NkPort1) of
                {ok, #nkport{pid=ConnPid}=NkPort2} ->
                    ?debug(Domain, "WS listener accepted connection: ~p", 
                          [NkPort2]),
                    {reply, {ok, ConnPid, Proto}, State};
                {error, Error} ->
                    ?notice(Domain, "WS listener did not accepted connection:"
                            " ~p", [Error]),
                    {reply, next, State}
            end
    end;

handle_call(Msg, From, State) ->
    case call_protocol(listen_handle_call, [Msg, From], State) of
        undefined -> {noreply, State};
        {ok, State1} -> {noreply, State1};
        {stop, Reason, State1} -> {stop, Reason, State1}
    end.


%% @private
-spec handle_cast(term(), #state{}) ->
    nklib_util:gen_server_cast(#state{}).

handle_cast(stop, State) ->
    {stop, normal, State};

handle_cast(Msg, State) ->
    case call_protocol(listen_handle_cast, [Msg], State) of
        undefined -> {noreply, State};
        {ok, State1} -> {noreply, State1};
        {stop, Reason, State1} -> {stop, Reason, State1}
    end.


%% @private
-spec handle_info(term(), #state{}) ->
    nklib_util:gen_server_info(#state{}).

handle_info({'DOWN', MRef, process, _Pid, _Reason}, #state{monitor_ref=MRef}=State) ->
    {stop, normal, State};

handle_info({'DOWN', _MRef, process, Pid, Reason}, #state{shared=Pid}=State) ->
    % lager:warning("WS received SHARED stop"),
    {stop, Reason, State};

handle_info(Msg, State) ->
    case call_protocol(listen_handle_info, [Msg], State) of
        undefined -> {noreply, State};
        {ok, State1} -> {noreply, State1};
        {stop, Reason, State1} -> {stop, Reason, State1}
    end.


%% @private
-spec code_change(term(), #state{}, term()) ->
    nklib_util:gen_server_code_change(#state{}).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% @private
-spec terminate(term(), #state{}) ->
    nklib_util:gen_server_terminate().

terminate(Reason, State) ->  
    catch call_protocol(listen_stop, [Reason], State),
    ok.



% %% ===================================================================
% %% Shared callbacks
% %% ===================================================================


%% @private Called from nkpacket_transport_tcp:execute/2, inside
%% cowboy's connection process
-spec cowboy_init(#nkport{}, cowboy_req:req(), list()) ->
    term().

cowboy_init(Pid, Req, Env) ->
    ReqHost = cowboy_req:host(Req),
    ReqPath = cowboy_req:path(Req),
    Hd = <<"sec-websocket-protocol">>,
    ReqProto = cowboy_req:parse_header(Hd, Req, []),
    {Ip, Port} = cowboy_req:peer(Req),
    Check = {check, ReqHost, ReqPath, ReqProto, Ip, Port, self()},
    case catch gen_server:call(Pid, Check, infinity) of
        {ok, ConnPid, Proto} ->
            Req1 = case Proto of
                <<"all">> -> Req;
                _ -> cowboy_req:set_resp_header(Hd, Proto, Req)
            end,
            cowboy_websocket:upgrade(Req1, Env, nkpacket_transport_ws, 
                                     ConnPid, infinity, run);
        next ->
            next;
        {'EXIT', _} ->
            next
    end.



% %% ===================================================================
% %% Cowboy's callbacks
% %% ===================================================================


%% @private
-spec websocket_handle({text | binary | ping | pong, binary()}, Req, State) ->
    {ok, Req, State} |
    {ok, Req, State, hibernate} |
    {reply, cow_ws:frame() | [cow_ws:frame()], Req, State} |
    {reply, cow_ws:frame() | [cow_ws:frame()], Req, State, hibernate} | 
    {stop, Req, State}
    when Req::cowboy_req:req(), State::any().

websocket_handle({text, Msg}, Req, ConnPid) ->
    nkpacket_connection:incoming(ConnPid, {text, Msg}),
    {ok, Req, ConnPid};

websocket_handle({binary, Msg}, Req, ConnPid) ->
    nkpacket_connection:incoming(ConnPid, {binary, Msg}),
    {ok, Req, ConnPid};

websocket_handle(ping, Req, ConnPid) ->
    {reply, pong, Req, ConnPid};

websocket_handle({ping, Body}, Req, ConnPid) ->
    {reply, {pong, Body}, Req, ConnPid};

websocket_handle(pong, Req, ConnPid) ->
    {ok, Req, ConnPid};

websocket_handle({pong, Body}, Req, ConnPid) ->
    nkpacket_connection:incoming(ConnPid, {pong, Body}),
    {ok, Req, ConnPid};

websocket_handle(Other, Req, ConnPid) ->
    lager:warning("WS Handler received unexpected ~p", [Other]),
    {stop, Req, ConnPid}.


%% @private
-spec websocket_info(any(), Req, State) ->
    {ok, Req, State} |
    {ok, Req, State, hibernate} |
    {reply, cow_ws:frame() | [cow_ws:frame()], Req, State} |
    {reply, cow_ws:frame() | [cow_ws:frame()], Req, State, hibernate} |
    {stop, Req, State}
    when Req::cowboy_req:req(), State::any().

websocket_info({nkpacket_send, Frames}, Req, State) ->
    {reply, Frames, Req, State};

websocket_info(nkpacket_stop, Req, State) ->
    {stop, Req, State};

websocket_info(Info, Req, State) ->
    lager:error("Module ~p received unexpected info ~p", [?MODULE, Info]),
    {ok, Req, State}.


%% @private
terminate(Reason, _Req, ConnPid) ->
    lager:debug("WS process terminate: ~p", [Reason]),
    nkpacket_connection:stop(ConnPid, normal),
    ok.



%% ===================================================================
%% Util
%% ===================================================================



%% @private Gets socket options for outbound connections
-spec outbound_opts(#nkport{}) ->
    list().

outbound_opts(#nkport{transp=ws}) ->
    [binary, {active, false}, {nodelay, true}, {keepalive, true}, {packet, raw}];

outbound_opts(#nkport{transp=wss, meta=Opts}) ->
    case code:priv_dir(nkpacket) of
        PrivDir when is_list(PrivDir) ->
            DefCert = filename:join(PrivDir, "cert.pem"),
            DefKey = filename:join(PrivDir, "key.pem");
        _ ->
            DefCert = "",
            DefKey = ""
    end,
    Cert = maps:get(certfile, Opts, DefCert),
    Key = maps:get(keyfile, Opts, DefKey),
    lists:flatten([
        binary, {active, false}, {nodelay, true}, {keepalive, true}, {packet, raw},
        case Cert of "" -> []; _ -> {certfile, Cert} end,
        case Key of "" -> []; _ -> {keyfile, Key} end
    ]).




%% ===================================================================
%% Util
%% ===================================================================

%% @private
call_protocol(Fun, Args, State) ->
    nkpacket_util:call_protocol(Fun, Args, State, #state.protocol).


%% @private


