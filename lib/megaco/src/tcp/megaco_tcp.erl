%%
%% ``The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved via the world wide web at http://www.erlang.org/.
%% 
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%% 
%% The Initial Developer of the Original Code is Ericsson Utvecklings AB.
%% Portions created by Ericsson are Copyright 1999, Ericsson Utvecklings
%% AB. All Rights Reserved.''
%% 
%%     $Id$
%%
%%-----------------------------------------------------------------
%%
%% Purpose: 
%%      Interface the TPKT (TCP/IP) transport module for Megaco/H.248
%%
%%-----------------------------------------------------------------
-module(megaco_tcp).

-behaviour(gen_server).

%%-----------------------------------------------------------------
%% Include files
%%-----------------------------------------------------------------
-include_lib("megaco/include/megaco.hrl").
-include_lib("megaco/src/tcp/megaco_tcp.hrl"). 

%%-----------------------------------------------------------------
%% External exports
%%-----------------------------------------------------------------
-export([
	 start_transport/0, %% Start TPKT transport service
	 listen/2,          %% Starts a new listener socket
	 connect/2,         %% Used on client side to connect server
	 socket/1,          %% Returns the inet socket
	 send_message/2,    %% Used to send data on connection
	 block/1,           %% Used to block the socket for incomming
	                    %% messages
	 unblock/1,         %% Used to unblock the node
	 close/1            %% Used on both sides to close connection
	]).

%%-----------------------------------------------------------------
%% Internal exports
%%-----------------------------------------------------------------
-export([
	 start_link/1,       %% Start TCP/IP net server
	 init/1,             %%
	 terminate/2, 
	 handle_call/3, 
	 handle_cast/2, 
	 handle_info/2, 
	 code_change/3,
	 start_connection/2
	]).
%%-----------------------------------------------------------------
%% Server state record
%%-----------------------------------------------------------------
-record(state, {supervisor_pid, linkdb}).

%%-----------------------------------------------------------------
%% External interface functions
%%-----------------------------------------------------------------
%%-----------------------------------------------------------------
%% Func: start_transport/0
%% Description: Starts the TPKT transport service
%%-----------------------------------------------------------------
start_transport() ->
    megaco_tcp_sup:start_link().

%%-----------------------------------------------------------------
%% Func: listen/2
%% Description: Starts new TPKT listener sockets
%%-----------------------------------------------------------------
listen(SupPid, Parameters) ->
    ProcList = supervisor:which_children(SupPid),
    case lists:keysearch(megaco_tcp, 1, ProcList) of
	{value, {_Name, Pid, _Type, _Modules}} ->
	    gen_server:call(Pid, {add_listener, Parameters}, infinity);
	false ->
	    {error, no_tcp_server}
    end.	    

%%-----------------------------------------------------------------
%% Func: connect
%% Description: Function is used when opening an TCP socket 
%%              at the MG side when trying to connect an MGC
%%-----------------------------------------------------------------
connect(SupPid, Parameters) ->
    Mand = [host, port, receive_handle],
    case parse_options(Parameters, #megaco_tcp{}, Mand) of
	{ok, TcpRec} ->
	    IpOpt = [binary, {packet, tpkt}, {active, once} |
		     TcpRec#megaco_tcp.options],

            %%------------------------------------------------------
            %% Connect the other side
	    case catch gen_tcp:connect(TcpRec#megaco_tcp.host, 
				       TcpRec#megaco_tcp.port, 
				       IpOpt) of
		{ok, Socket} ->
                    %%----------------------------------------------
                    %% Socket up start a new control process
		    case start_connection(SupPid, 
					  TcpRec#megaco_tcp{socket = Socket}) 
			of
			{ok, Pid} ->
			    gen_tcp:controlling_process(Socket, Pid),
			    {ok, Socket, Pid};
			{error, Reason} ->
			    {error, Reason}
		    end;
		{error, Reason} ->
		    Error = {error, {gen_tcp_connect, Reason}},
		    ?tcp_debug(TcpRec, "tcp connect failed", [Error]),
		    Error;
		{'EXIT', _Reason} = Exit ->
		    Error = {error, {gen_tcp_connect, Exit}},
		    ?tcp_debug(TcpRec, "tcp connect failed", [Error]),
		    Error
	    end;
	{error, _Reason} = Error->
	    ?tcp_debug(#megaco_tcp{}, "tcp connect failed",
		       [Error, {options, Parameters}]),
	    Error
    end.

%%-----------------------------------------------------------------
%% Func: send_message
%% Description: Function is used for sending data on the TCP socket
%%-----------------------------------------------------------------
send_message(Socket, Data) ->
    gen_tcp:send(Socket, add_tpkt_header(Data)).


%%-----------------------------------------------------------------
%% Func: block
%% Description: Function is used for blocking incomming messages
%%              on the TCP socket
%%-----------------------------------------------------------------
block(Socket) ->
    ?tcp_debug({socket, Socket}, "tcp block", []),
    inet:setopts(Socket, [{active, false}]).

%%-----------------------------------------------------------------
%% Func: unblock
%% Description: Function is used for blocking incomming messages
%%              on the TCP socket
%%-----------------------------------------------------------------
unblock(Socket) ->
    ?tcp_debug({socket, Socket}, "tcp unblock", []),
    inet:setopts(Socket, [{active, once}]).

%%-----------------------------------------------------------------
%% Func: close
%% Description: Function is used for closing the TCP socket
%%-----------------------------------------------------------------
close(Socket) ->
    ?tcp_debug({socket, Socket}, "tcp close", []),
    gen_tcp:close(Socket).

%%-----------------------------------------------------------------
%% Func: socket
%% Description: Returns the inet socket
%%-----------------------------------------------------------------
socket(Socket) ->
    Socket.

%%-----------------------------------------------------------------
%% Internal Interface functions
%%-----------------------------------------------------------------
%%-----------------------------------------------------------------
%% Func: start_link/1
%% Description: Starts the net server
%%-----------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

%%-----------------------------------------------------------------
%% Func: start_connection
%% Description: Function is used for starting up a connection
%%              process
%%-----------------------------------------------------------------
start_connection(SupPid, TcpRec) ->
    ProcList = supervisor:which_children(SupPid),

    case lists:keysearch(megaco_tcp_connection_sup, 1, ProcList) of
	{value, {_Name, ConnSupPid, _Type, _Modules}} ->
	    ?tcp_debug(TcpRec, "tcp connect", []),
	    case supervisor:start_child(ConnSupPid, [TcpRec]) of
		{ok, Pid} ->
		    {ok, Pid};
		{error, Reason} ->
		    Error = {error, {controlling_process_not_started, Reason}},
		    ?tcp_debug(TcpRec, "tcp connect failed", [Error]),
		    Error
	    end;
	false ->
	    Error = {error, no_connection_supervisor},
	    ?tcp_debug(TcpRec, "tcp connect failed", [Error]),
	    Error
    end.

%%-----------------------------------------------------------------
%% Server functions
%%-----------------------------------------------------------------
%%-----------------------------------------------------------------
%% Func: init/1
%% Description: Init funcion for the supervisor
%%-----------------------------------------------------------------
init({SupPid, _}) ->
    process_flag(trap_exit, true),
    {ok, #state{supervisor_pid = SupPid}}.

%%-----------------------------------------------------------------
%% Func: terminate/1
%% Description: Termination function for the generic server
%%-----------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%-----------------------------------------------------------------
%% Internal Functions
%%-----------------------------------------------------------------
%%-----------------------------------------------------------------
%% Func: start_tcp_listener/2
%% Description: Function which parses the list of transport layers
%%              to start 
%%-----------------------------------------------------------------
start_tcp_listener(P, State) ->
    case setup(State#state.supervisor_pid, P) of
	{ok, Pid, Data} ->
	    link(Pid),
	    {reply, ok, State#state{linkdb=[{Pid, Data} | State#state.linkdb]}};
	{error, Reason} ->
	    {reply, {error, {could_not_start_listener, Reason}}, State}
    end.

%%-----------------------------------------------------------------
%% Func: handle_call/3
%% Description: Handling call messages (really just garbage)
%%-----------------------------------------------------------------
handle_call({add_listener, Parameters}, _From, State) ->
    start_tcp_listener(Parameters, State);
handle_call(Request, From, State) ->
    error_logger:error_report([{?MODULE, {garbage_call, Request, From}}]),
    {noreply, State}.

%%------------------------------------------------------------
%% Func: handle_cast/2
%% Description: Handling cast messages (really just garbage)
%%------------------------------------------------------------
handle_cast(Request, State) ->
    error_logger:error_report([{?MODULE, {garbage_cast, Request}}]),
    {noreply,  State}.

%%-----------------------------------------------------------------
%% Func: handle_info/2
%% Description: Handling non call/cast messages, eg exit messages
%%-----------------------------------------------------------------
handle_info({'EXIT', Pid, Reason}, State) when pid(Pid) ->
    %% Accept process died
    NewState = resetup(Pid, Reason, State),
    {noreply, NewState};
handle_info(Info, State) ->
    error_logger:error_report([{?MODULE, {garbage_info, Info}}]),
    {noreply,  State}.

%%-----------------------------------------------------------------
%% Func: code_change/3
%% Descrition: Handles code change messages during upgrade.
%%-----------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%-----------------------------------------------------------------
%% Internal functions
%%-----------------------------------------------------------------
%%-----------------------------------------------------------------
%% Func: setup/2
%% Description: Function is used when setting up an TCP listen 
%%              socket in the MGC
%%-----------------------------------------------------------------
setup(SupPid, Options) ->
    Mand = [port, receive_handle],
    case parse_options(Options, #megaco_tcp{}, Mand) of
	{ok, TcpRec} ->
    
            %%------------------------------------------------------
            %% Setup the listen socket
	    IpOpts = [binary, {packet, tpkt}, {active, once},
		      {reuseaddr, true} | TcpRec#megaco_tcp.options],
	    case catch gen_tcp:listen(TcpRec#megaco_tcp.port, IpOpts) of
		{ok, Listen} ->
	            %%-----------------------------------------------
	            %% Startup the accept process that will wait for 
	            %% connect attempts
		    case start_accept(SupPid, TcpRec, Listen) of
			{ok, Pid} ->
			    ?tcp_debug(TcpRec, "tcp listen setup", []),
			    {ok, Pid, {TcpRec, Listen}};
			{error, _Reason} = Error ->
			    ?tcp_debug(TcpRec, "tcp listen setup failed", 
				       [Error]),
			    Error
		    end;
		{error, Reason} ->
		    Error = {error, {gen_tcp_listen, Reason}},
		    ?tcp_debug(TcpRec, "tcp listen setup failed", [Error]),
		    Error;
		{'EXIT', _Reason} = Exit ->
		    Error = {error, {gen_tcp_listen, Exit}},
		    ?tcp_debug(TcpRec, "tcp listen setup failed", [Error]),
		    Error
	    end;
	{error, _Reason} = Error ->
	    ?tcp_debug(#megaco_tcp{}, "tcp listen setup failed",
		       [Error, {options, Options}]),
	    Error
    end.
    

%%-----------------------------------------------------------------
%% Func: resetup
%% Description: Function is used when restarting teh accept process
%%              if it died of some reason.
%%-----------------------------------------------------------------
resetup(Pid, Reason, State) ->
    case lists:keysearch(Pid, 1, State#state.linkdb) of
	{value, {Pid, {TcpRec, Listener}}} ->
	    ?tcp_debug(TcpRec, "tcp listen resetup", [{error, Reason}]),
	    unlink(Pid),
	    case start_accept(State#state.supervisor_pid, TcpRec, Listener) of
		{ok, NewPid} ->
		    link(NewPid),
		    NewList = lists:keyreplace(Pid, 1, State#state.linkdb,
					       {NewPid, {TcpRec, Listener}}),
		    State#state{linkdb=NewList};
		{error, Reason} ->
		    ?tcp_debug(TcpRec, "tcp listen resetup failed", [{error, Reason}]),
		    State
	    end;
	false ->
	    State
    end.

%%-----------------------------------------------------------------
%% Func: start_accept
%% Description: Function is used for starting up an TCP accept
%%              process
%%-----------------------------------------------------------------
start_accept(SupPid, TcpRec, Listen) ->
    case get_pid_from_supervisor(SupPid, megaco_tcp_accept_sup) of
	{ok, AcceptSupPid} ->
	    case supervisor:start_child(AcceptSupPid, 
					[{TcpRec, SupPid, Listen}]) of
		{ok, Pid} ->
		    {ok, Pid};
		{error, Reason} ->
		    {error, {accept_not_started, Reason}}
	    end;
	{error, Reason} ->
	    {error, {no_tcp_accept_sup, Reason}}
    end.

%%-----------------------------------------------------------------
%% Func: add_tpkt_header
%% Description: Function is used to add the TPKT header
%%-----------------------------------------------------------------
add_tpkt_header(Data) when binary(Data) ->
    L = size(Data) + 4,
    [3, 0, ((L) bsr 8) band 16#ff, (L) band 16#ff ,Data];
add_tpkt_header(IOList) when list(IOList) ->
    Binary = list_to_binary(IOList),
    L = size(Binary) + 4,
    [3, 0, ((L) bsr 8) band 16#ff, (L) band 16#ff , Binary].

%%-----------------------------------------------------------------
%% Func: parse_options
%% Description: Function that parses the options sent to the TCP 
%%              module.
%%-----------------------------------------------------------------
parse_options([{Tag, Val} | T], TcpRec, Mand) ->
    Mand2 = Mand -- [Tag],
    case Tag of
	port ->
	    parse_options(T, TcpRec#megaco_tcp{port = Val}, Mand2);
	host ->
	    parse_options(T, TcpRec#megaco_tcp{host = Val}, Mand2);
	tcp_options when list(Val)->
	    parse_options(T, TcpRec#megaco_tcp{options = Val}, Mand2);
	receive_handle ->
	    parse_options(T, TcpRec#megaco_tcp{receive_handle = Val}, Mand2);
	module when atom(Val) ->
	    parse_options(T, TcpRec#megaco_tcp{module = Val}, Mand2);
        _ ->
	    {error, {bad_option, {Tag, Val}}}
    end;
parse_options([], TcpRec, []) ->
    {ok, TcpRec};
parse_options([], _TcpRec, Mand) ->
    {error, {missing_options, Mand}};
parse_options(BadList, _TcpRec, _Mand) ->
    {error, {bad_option_list, BadList}}.


%%-----------------------------------------------------------------
%% Func: get_pid_from_supervisor
%% Description: Function that get a pid form a supervisor 
%%              with the help of the name.
%%-----------------------------------------------------------------
get_pid_from_supervisor(SupPid, ProcName) ->
    ProcList = supervisor:which_children(SupPid),
    %% ProcList of type [{Name, Pid, Type, Modules}| Rest]
    
    case lists:keysearch(ProcName, 1, ProcList) of
	{value, {_Name, Pid, _Type, _Modules}} ->
	    {ok, Pid};
	false ->
		{error, no_such_process}
    end.
