%%%-------------------------------------------------------------------
%%% File    : tftp_engine.erl
%%% Author  : Hakan Mattsson <hakan@erix.ericsson.se>
%%% Description : Protocol engine for trivial FTP
%%%
%%% Created : 18 May 2004 by Hakan Mattsson <hakan@erix.ericsson.se>
%%%-------------------------------------------------------------------

-module(tftp_engine).

%%%-------------------------------------------------------------------
%%% Interface
%%%-------------------------------------------------------------------

%% application internal functions
-export([
	 daemon_start/1,
	 client_start/4,
	 info/1
	]).

%% module internal
-export([
	 daemon_init/1, 
	 server_init/2, 
	 client_init/2,
	 wait_for_msg/3
	]).

%% sys callback functions
-export([
	 system_continue/3,
	 system_terminate/4,
	 system_code_change/4
	]).

-include("tftp.hrl").

%%%-------------------------------------------------------------------
%%% Info
%%%-------------------------------------------------------------------

info(ToPid) when pid(ToPid) ->
    Type = process,
    Ref = erlang:monitor(Type, ToPid),
    ToPid ! {info, self()},
    receive
	{info, FromPid, Info} when FromPid == ToPid ->
	    erlang:demonitor(Ref),
	    Info;
	{'DOWN', Ref, Type, FromPid, _Reason} when FromPid == ToPid ->
	    undefined
    after timer:seconds(10) ->
	    timeout
    end.

%%%-------------------------------------------------------------------
%%% Daemon
%%%-------------------------------------------------------------------

%% Returns {ok, Port}
daemon_start(Options) when list(Options) ->
    Config = tftp_lib:parse_config(Options),
    proc_lib:start_link(?MODULE, daemon_init, [Config], infinity).

daemon_init(Config) when record(Config, config), 
                         pid(Config#config.parent_pid) ->
    process_flag(trap_exit, true),
    case catch gen_udp:open(Config#config.udp_port, Config#config.udp_options) of
	{ok, Socket} ->
	    {ok, ActualPort} = inet:port(Socket),
	    proc_lib:init_ack({ok, self()}),
	    Config2 = Config#config{udp_socket = Socket,
				    udp_port   = ActualPort},
	    print_debug_info(Config2, daemon, open, undefined),
	    daemon_loop(Config2, 0, []);
	{error, Reason} ->
	    exit({gen_udp_open, Reason});
	Reason ->
	    exit({gen_udp_open, Reason})
    end.

daemon_loop(Config, N, Servers) ->
    receive
	{info, Pid} when pid(Pid) ->
	    ServerInfo = [{n_conn, N} | [{server, P} || P <- Servers]],
	    Info = internal_info(Config, daemon) ++ ServerInfo,
	    Pid ! {info, self(), Info},
	    daemon_loop(Config, N, Servers);
	{udp, Socket, RemoteHost, RemotePort, Bin} when binary(Bin) ->
	    inet:setopts(Socket, [{active, once}]),
	    ServerConfig = Config#config{parent_pid = self(),
					 udp_host   = RemoteHost,
					 udp_port   = RemotePort},
	    Msg = (catch tftp_lib:decode_msg(Bin)),
	    print_debug_info(ServerConfig, daemon, recv, Msg),
	    case Msg of
		Req when record(Req, tftp_msg_req), 
		         N < Config#config.max_conn ->
		    Args = [ServerConfig, Req],
		    Pid = proc_lib:spawn_link(?MODULE, server_init, Args),
		    daemon_loop(Config, N + 1, [Pid | Servers]);
		Req when record(Req, tftp_msg_req) ->
		    Reply = #tftp_msg_error{code = enospc,
					    text = "Too many connections"},
		    send_msg(ServerConfig, daemon, Reply),
		    daemon_loop(Config, N, Servers);
		{'EXIT', Reply} when record(Reply, tftp_msg_error) ->
		    send_msg(ServerConfig, daemon, Reply),
		    daemon_loop(Config, N, Servers);
		Req  ->
		    Reply = #tftp_msg_error{code = badop,
					    text = "Illegal TFTP operation"},
		    error("Daemon received: ~p", [Req]),
		    send_msg(ServerConfig, daemon, Reply),
		    daemon_loop(Config, N, Servers)
	    end;
	{system, From, Msg} ->
	    Misc = {daemon_loop, [Config, N, Servers]},
	    sys:handle_system_msg(Msg, From, Config#config.parent_pid, ?MODULE, [], Misc);
	{'EXIT', Pid, Reason} when Config#config.parent_pid == Pid ->
	    close_port(Config, daemon),
	    exit(Reason);
	{'EXIT', Pid, _Reason} = Info ->
	    case lists:member(Pid, Servers) of
		true ->
		    daemon_loop(Config, N - 1, Servers -- [Pid]);
		false ->
		    error("Daemon received: ~p", [Info]),
		    daemon_loop(Config, N, Servers)
	    end;
	Info ->
	    error("Daemon received: ~p", [Info]),
	    daemon_loop(Config, N, Servers)
    end.

%%%-------------------------------------------------------------------
%%% Server
%%%-------------------------------------------------------------------

server_init(Config, Req) when record(Config, config),
                              pid(Config#config.parent_pid),
                              record(Req, tftp_msg_req) ->
    process_flag(trap_exit, true),
    SuggestedOptions = Req#tftp_msg_req.options,
    Config2 = tftp_lib:parse_config(SuggestedOptions, Config),
    SuggestedOptions2 = Config2#config.user_options,
    Req2 = Req#tftp_msg_req{options = SuggestedOptions2},
    case open_free_port(Config2, server) of
	{ok, Config3} ->
	    Filename = Req#tftp_msg_req.filename,
	    case match_callback(Filename, Config#config.callbacks) of
		{ok, Callback} ->
		    print_debug_info(Config3, server, match, Callback),
		    case pre_verify_options(Config2, Req2) of
			ok ->
			    case callback({open, server_open}, Config3, Callback, Req2) of
				{Callback2, {ok, AcceptedOptions}} ->
				    {LocalAccess,  _} = local_file_access(Req2),
				    OptText = "Internal error. Not allowed to add new options.",
				    case post_verify_options(Config3, Req2, AcceptedOptions, OptText) of
					{ok, Config4, Req3} when AcceptedOptions /= [] ->
					    Reply = #tftp_msg_oack{options = AcceptedOptions},
					    {Config5, Callback3, Next} = 
						transfer(Config4, Callback2, Req3, Reply, LocalAccess, undefined),
					    BlockNo =
						case LocalAccess of
						    read  -> 0;
						    write -> 1
						end,
					    common_loop(Config5, Callback3, Req3, Next, LocalAccess, BlockNo);
					{ok, Config4, Req3} when LocalAccess == write ->
					    BlockNo = 0,
					    common_ack(Config4, Callback2, Req3, LocalAccess, BlockNo, undefined);
					{ok, Config4, Req3} when LocalAccess == read ->
					    BlockNo = 0,
					    common_read(Config4, Callback2, Req3, LocalAccess, BlockNo, BlockNo, undefined);
					{error, {Code, Text}} ->
					    {undefined, Error} =
						callback({abort, {Code, Text}}, Config3, Callback2, Req2),
					    send_msg(Config3, Req, Error),
					    terminate(Config3, Req2, {error, {post_verify_options, Code, Text}})
				    end;
				{undefined, #tftp_msg_error{code = Code, text = Text} = Error} ->
				    send_msg(Config3, Req, Error),
				    terminate(Config3, Req, {error, {server_open, Code, Text}})
			    end;
			{error, {Code, Text}} ->
			    {undefined, Error} =
				callback({abort, {Code, Text}}, Config2, Callback, Req2),
			    send_msg(Config2, Req, Error),
			    terminate(Config2, Req2, {error, {pre_verify_options, Code, Text}})
		    end;
		{error, #tftp_msg_error{code = Code, text = Text} = Error} ->
		    send_msg(Config3, Req, Error),
		    terminate(Config3, Req, {error, {match_callback, Code, Text}})
	    end;
	{error, Reason} ->
	    terminate(Config2, Req, {error, {gen_udp_open, Reason}})
    end.

%%%-------------------------------------------------------------------
%%% Client
%%%-------------------------------------------------------------------

%% LocalFilename = filename() | 'binary' | binary()
%% Returns {ok, LastCallbackState} | {error, Reason}
client_start(Access, RemoteFilename, LocalFilename, Options) ->
    Config = tftp_lib:parse_config(Options),
    Config2 = Config#config{parent_pid      = self(),
			    udp_socket      = undefined},
    Req = #tftp_msg_req{access         = Access, 
			filename       = RemoteFilename, 
			mode           = lookup_mode(Config2#config.user_options),
			options        = Config2#config.user_options,
			local_filename = LocalFilename},
    Args = [Config2, Req],
    case proc_lib:start_link(?MODULE, client_init, Args, infinity) of
	{ok, LastCallbackState} ->
	    {ok, LastCallbackState};
	{error, Error} ->
	    {error, Error}
    end.

client_init(Config, Req) when record(Config, config),
                              pid(Config#config.parent_pid),
                              record(Req, tftp_msg_req) ->
    process_flag(trap_exit, true),
    case open_free_port(Config, client) of
	{ok, Config2} ->
	    Req2 =
		case Config2#config.use_tsize of
		    true ->
			SuggestedOptions = Req#tftp_msg_req.options,
			SuggestedOptions2 = tftp_lib:replace_val("tsize", "0", SuggestedOptions),
			Req#tftp_msg_req{options = SuggestedOptions2};
		    false ->
			Req
		end,
	    LocalFilename = Req2#tftp_msg_req.local_filename,
	    case match_callback(LocalFilename, Config2#config.callbacks) of
		{ok, Callback} ->
		    print_debug_info(Config2, client, match, Callback),
		    client_prepare(Config2, Callback, Req2);		    
		{error, #tftp_msg_error{code = Code, text = Text}} ->
		    terminate(Config, Req, {error, {match, Code, Text}})
	    end;
	{error, Reason} ->
	    terminate(Config, Req, {error, {gen_udp_open, Reason}})
    end.

client_prepare(Config, Callback, Req) ->
    case pre_verify_options(Config, Req) of
	ok ->
	    case callback({open, client_prepare}, Config, Callback, Req) of
		{Callback2, {ok, AcceptedOptions}} ->
		    OptText = "Internal error. Not allowed to add new options.",
		    case post_verify_options(Config, Req, AcceptedOptions, OptText) of
			{ok, Config2, Req2} ->
			    {LocalAccess, _} = local_file_access(Req2),
			    {Config3, Callback3, Next} =
				transfer(Config2, Callback2, Req2, Req2, LocalAccess, undefined),
			    client_open(Config3, Callback3, Req2, Next);
			{error, {Code, Text}} ->
			    callback({abort, {Code, Text}}, Config, Callback2, Req),
			    terminate(Config, Req, {error, {post_verify_options, Code, Text}})
		    end;
		{undefined, #tftp_msg_error{code = Code, text = Text}} ->
		    terminate(Config, Req, {error, {client_prepare, Code, Text}})
	    end;
	{error, {Code, Text}} ->
	    callback({abort, {Code, Text}}, Config, Callback, Req),
	    terminate(Config, Req, {error, {pre_verify_options, Code, Text}})
    end.

client_open(Config, Callback, Req, Next) ->
    {LocalAccess, _} = local_file_access(Req),
    case Next of
	{ok, DecodedMsg, undefined} ->
	    case DecodedMsg of
		Msg when record(Msg, tftp_msg_oack) ->
		    ServerOptions = Msg#tftp_msg_oack.options,
		    OptText = "Protocol violation. Server is not allowed new options",
		    case post_verify_options(Config, Req, ServerOptions, OptText) of
			{ok, Config2, Req2} ->		    
			    {Config3, Callback2, Req3} =
				do_client_open(Config2, Callback, Req2),
			    case LocalAccess of
				read ->
				    BlockNo = 0,
				    common_read(Config3, Callback2, Req3, LocalAccess, BlockNo, BlockNo, undefined);
				write ->
				    BlockNo = 0,
				    common_ack(Config3, Callback2, Req3, LocalAccess, BlockNo, undefined)
			    end;
			{error, {Code, Text}} ->
			    {undefined, Error} =
				callback({abort, {Code, Text}}, Config, Callback, Req),
			    send_msg(Config, Req, Error),
			    terminate(Config, Req, {error, {verify_server_options, Code, Text}})
		    end;
		#tftp_msg_ack{block_no = ActualBlockNo} when LocalAccess == read ->
		    Req2 = Req#tftp_msg_req{options = []},
		    {Config2, Callback2, Req2} = do_client_open(Config, Callback, Req2),
		    ExpectedBlockNo = 0,
		    common_read(Config2, Callback2, Req2, LocalAccess, ExpectedBlockNo, ActualBlockNo, undefined);
		#tftp_msg_data{block_no = ActualBlockNo, data = Data} when LocalAccess == write ->
		    Req2 = Req#tftp_msg_req{options = []},
		    {Config2, Callback2, Req2} = do_client_open(Config, Callback, Req2),
		    ExpectedBlockNo = 1,
		    common_write(Config2, Callback2, Req2, LocalAccess, ExpectedBlockNo, ActualBlockNo, Data, undefined);
		%% #tftp_msg_error{code = Code, text = Text} when Req#tftp_msg_req.options /= [] ->
                %%     %% Retry without options
		%%     callback({abort, {Code, Text}}, Config, Callback, Req),
		%%     Req2 = Req#tftp_msg_req{options = []},
		%%     client_prepare(Config, Callback, Req2);
		#tftp_msg_error{code = Code, text = Text} ->
		    callback({abort, {Code, Text}}, Config, Callback, Req),
		    terminate(Config, Req, {error, {client_open, Code, Text}});
		{'EXIT', #tftp_msg_error{code = Code, text = Text}} ->
		    callback({abort, {Code, Text}}, Config, Callback, Req),
		    terminate(Config, Req, {error, {client_open, Code, Text}});
		Msg when tuple(Msg) ->
		    Code = badop,
		    Text = "Illegal TFTP operation",
		    {undefined, Error} =
			callback({abort, {Code, Text}}, Config, Callback, Req),
		    send_msg(Config, Req, Error),
		    terminate(Config, Req, {error, {client_open, Code, Text, element(1, Msg)}})
	    end;
	{error, #tftp_msg_error{code = Code, text = Text}} ->
	    callback({abort, {Code, Text}}, Config, Callback, Req),
	    terminate(Config, Req, {error, {client_open, Code, Text}})
    end.

do_client_open(Config, Callback, Req) ->
    case callback({open, client_open}, Config, Callback, Req) of
	{Callback2, {ok, FinalOptions}} ->
	    OptText = "Internal error. Not allowed to change options.",
	    case post_verify_options(Config, Req, FinalOptions, OptText) of
		{ok, Config2, Req2} ->
		    {Config2, Callback2, Req2};
		{error, {Code, Text}} ->
		    {undefined, Error} =
			callback({abort, {Code, Text}}, Config, Callback, Req),
		    send_msg(Config, Req, Error),
		    terminate(Config, Req, {error, {post_verify_options, Code, Text}})
	    end;
	{undefined, #tftp_msg_error{code = Code, text = Text} = Error} ->
	    send_msg(Config, Req, Error),
	    terminate(Config, Req, {error, {client_open, Code, Text}})
    end.

%%%-------------------------------------------------------------------
%%% Common loop for both client and server
%%%-------------------------------------------------------------------

common_loop(Config, Callback, Req, Next, LocalAccess, ExpectedBlockNo) ->
    case Next of
	{ok, DecodedMsg, Prepared} ->
	    case DecodedMsg of
		#tftp_msg_ack{block_no = ActualBlockNo} when LocalAccess == read ->
		    common_read(Config, Callback, Req, LocalAccess, ExpectedBlockNo, ActualBlockNo, Prepared);
		#tftp_msg_data{block_no = ActualBlockNo, data = Data} when LocalAccess == write ->
		    common_write(Config, Callback, Req, LocalAccess, ExpectedBlockNo, ActualBlockNo, Data, Prepared);
		#tftp_msg_error{code = Code, text = Text} ->
		    callback({abort, {Code, Text}}, Config, Callback, Req),
		    terminate(Config, Req, {error, {common_loop, Code, Text}});
		{'EXIT', #tftp_msg_error{code = Code, text = Text} = Error} ->
		    callback({abort, {Code, Text}}, Config, Callback, Req),
		    send_msg(Config, Req, Error),
		    terminate(Config, Req, {error, {common_loop, Code, Text}});
		Msg when tuple(Msg) ->
		    Code = badop,
		    Text = "Illegal TFTP operation",
		    {undefined, Error} =
			callback({abort, {Code, Text}}, Config, Callback, Req),
		    send_msg(Config, Req, Error),
		    terminate(Config, Req, {error, {common_loop, Code, Text, element(1, Msg)}})
	    end;
	{error, #tftp_msg_error{code = Code, text = Text} = Error} ->
	    send_msg(Config, Req, Error),
	    terminate(Config, Req, {error, {transfer, Code, Text}})
    end.

common_read(Config, _, Req, _, _, _, {terminate, Result}) ->
    terminate(Config, Req, {ok, Result});
common_read(Config, Callback, Req, LocalAccess, BlockNo, BlockNo, Prepared) ->
    case early_read(Config, Callback, Req, LocalAccess, Prepared) of
	{Callback2, {more, Data}} ->
	    do_common_read(Config, Callback2, Req, LocalAccess, BlockNo, Data, undefined);
	{undefined, {last, Data, Result}} ->
	    do_common_read(Config, undefined, Req, LocalAccess, BlockNo, Data, {terminate, Result});
	{undefined, #tftp_msg_error{code = Code, text = Text} = Reply} ->	
	    send_msg(Config, Req, Reply),
	    terminate(Config, Req, {error, {read, Code, Text}})
    end;
common_read(Config, Callback, Req, _LocalAccess, ExpectedBlockNo, ActualBlockNo, _Prepared) ->
    Code = badblk,
    Text = "Unknown transfer ID = " ++ 
	integer_to_list(ActualBlockNo) ++ "(" ++ integer_to_list(ExpectedBlockNo) ++ ")", 
    {undefined, Error} =
	callback({abort, {Code, Text}}, Config, Callback, Req),
    send_msg(Config, Req, Error),
    terminate(Config, Req, {error, {read, Code, Text}}).

do_common_read(Config, Callback, Req, LocalAccess, BlockNo, Data, Prepared) ->
    NextBlockNo = BlockNo + 1,
    Reply = #tftp_msg_data{block_no = NextBlockNo, data = Data},
    {Config2, Callback2, Next} =
	transfer(Config, Callback, Req, Reply, LocalAccess, Prepared),
    common_loop(Config2, Callback2, Req, Next, LocalAccess, NextBlockNo).

common_write(Config, _, Req, _, _, _, _, {terminate, Result}) ->
    terminate(Config, Req, {ok, Result});
common_write(Config, Callback, Req, LocalAccess, BlockNo, BlockNo, Data, undefined) ->
    case callback({write, Data}, Config, Callback, Req) of
	{Callback2, more} ->
	    common_ack(Config, Callback2, Req, LocalAccess, BlockNo, undefined);
	{undefined, {last, Result}} ->
	    Config2 = pre_terminate(Config, Req, {ok, Result}),
	    common_ack(Config2, undefined, Req, LocalAccess, BlockNo, {terminate, Result});
	{undefined, #tftp_msg_error{code = Code, text = Text} = Reply} ->
	    send_msg(Config, Req, Reply),
	    terminate(Config, Req, {error, {write, Code, Text}})
    end;
common_write(Config, Callback, Req, _, ExpectedBlockNo, ActualBlockNo, _, _) ->
    Code = badblk,
    Text = "Unknown transfer ID = " ++ 
	integer_to_list(ActualBlockNo) ++ "(" ++ integer_to_list(ExpectedBlockNo) ++ ")", 
    {undefined, Error} =
	callback({abort, {Code, Text}}, Config, Callback, Req),
    send_msg(Config, Req, Error),
    terminate(Config, Req, {error, {write, Code, Text}}).

common_ack(Config, Callback, Req, LocalAccess, BlockNo, Prepared) ->
    Reply = #tftp_msg_ack{block_no = BlockNo},
    {Config2, Callback2, Next} = 
	transfer(Config, Callback, Req, Reply, LocalAccess, Prepared),
    NextBlockNo = BlockNo + 1, 
    common_loop(Config2, Callback2, Req, Next, LocalAccess, NextBlockNo).

pre_terminate(Config, Req, Result) ->
    if
	Req#tftp_msg_req.local_filename /= undefined,
	Config#config.parent_pid /= undefined ->
	    proc_lib:init_ack(Result),
	    unlink(Config#config.parent_pid),
	    Config#config{parent_pid = undefined, polite_ack = true};
	true ->
	    Config#config{polite_ack = true}
    end.

terminate(Config, Req, Result) ->
    if
	Config#config.parent_pid == undefined ->
	    close_port(Config, client),
	    exit(normal);
	Req#tftp_msg_req.local_filename /= undefined  ->
	    %% Client
	    close_port(Config, client),
	    proc_lib:init_ack(Result),
	    unlink(Config#config.parent_pid),
	    exit(normal);
	true ->
	    %% Server
	    close_port(Config, server),
	    case Result of
		{ok, _} ->
		    exit(shutdown);
		{error, Reason} ->
		    exit(Reason)
	    end
    end.

close_port(Config, Who) ->
    case Config#config.udp_socket of
	undefined -> 
	    ignore;
	Socket    -> 
	    print_debug_info(Config, Who, close, undefined),
	    gen_udp:close(Socket)
    end.

open_free_port(Config, Who) when record(Config, config) ->
    PortOptions = Config#config.udp_options,
    case Config#config.port_policy of
	random ->
	    %% BUGBUG: Should be a random port
	    case catch gen_udp:open(0, PortOptions) of
		{ok, Socket} ->
		    Config2 = Config#config{udp_socket = Socket},
		    print_debug_info(Config2, Who, open, undefined),
		    {ok, Config2};
		{error, Reason} ->
		    {error, Reason};
		{'EXIT', _} = Reason->
		    {error, Reason}
	    end;
	{range, Port, Max} when Port =< Max ->
	    case catch gen_udp:open(Port, PortOptions) of
		{ok, Socket} ->
		    Config2 = Config#config{udp_socket = Socket},
		    print_debug_info(Config2, Who, open, undefined),
		    {ok, Config2};
		{error, eaddrinuse} ->
		    PortPolicy = {range, Port + 1, Max},
		    Config2 = Config#config{port_policy = PortPolicy},
		    open_free_port(Config2, Who);
		{error, Reason} ->
		    {error, Reason};
		{'EXIT', _} = Reason->
		    {error, Reason}
	    end;
	{range, Port, _Max} ->
	    {error, {port_range_exhausted, Port}}
    end.

%%-------------------------------------------------------------------
%% Transfer
%%-------------------------------------------------------------------

%% Returns {Config, Callback, Next}
%% Next = {ok, Reply, Next} | {error, Error}
transfer(Config, Callback, Req, Msg, LocalAccess, Prepared) ->
    IoList = tftp_lib:encode_msg(Msg),
    do_transfer(Config, Callback, Req, Msg, IoList, LocalAccess, Prepared, true).

do_transfer(Config, Callback, Req, Msg, IoList, LocalAccess, Prepared, Retry) ->
    case do_send_msg(Config, Req, Msg, IoList) of
	ok ->
	    {Callback2, Prepared2} = 
		early_read(Config, Callback, Req, LocalAccess, Prepared),
	    case wait_for_msg(Config, Callback, Req) of
		timeout when Config#config.polite_ack == true ->
		    do_send_msg(Config, Req, Msg, IoList),
		    terminate(Config, Req, Prepared2);
		timeout when Retry == true ->
		    Retry2 = false,
		    do_transfer(Config, Callback2, Req, Msg, IoList, LocalAccess, Prepared2, Retry2);
		timeout ->
		    Code = undef,
		    Text = "Transfer timed out.",
		    Error = #tftp_msg_error{code = Code, text = Text},
		    {Config, Callback, {error, Error}};
		{Config2, Reply} ->
		    {Config2, Callback2, {ok, Reply, Prepared2}}
	    end;
        {error, _Reason} when Retry == true ->
	    do_transfer(Config, Callback, Req, Msg, IoList, LocalAccess, Prepared, false);
	{error, _Reason} ->
	    Code = undef,
	    Text = "Internal error. gen_udp:send/4 failed",
	    {Config, Callback, {error, #tftp_msg_error{code = Code, text = Text}}}
    end.

send_msg(Config, Req, Msg) ->
    case catch tftp_lib:encode_msg(Msg) of
	{'EXIT', Reason} ->
	    Code = undef,
	    Text = "Internal error. Encode failed",
	    Msg2 = #tftp_msg_error{code = Code, text = Text, details = Reason},
	    send_msg(Config, Req, Msg2);
	IoList ->
	    do_send_msg(Config, Req, Msg, IoList)
    end.

do_send_msg(Config, Req, Msg, IoList) ->
    print_debug_info(Config, Req, send, Msg),
    gen_udp:send(Config#config.udp_socket,
		 Config#config.udp_host,
		 Config#config.udp_port,
		 IoList).

wait_for_msg(Config, Callback, Req) ->
    receive
	{info, Pid} when pid(Pid) ->
	    Type =
		case Req#tftp_msg_req.local_filename /= undefined of
		    true  -> client;
		    false -> server
		end,
	    Pid ! {info, self(), internal_info(Config, Type)},
	    wait_for_msg(Config, Callback, Req);
	{udp, Socket, Host, Port, Bin} when  binary(Bin),
	                                     Callback#callback.block_no == undefined ->
	    %% Client prepare
	    inet:setopts(Socket, [{active, once}]),
	    Config2 = Config#config{udp_host = Host,
				    udp_port = Port},
	    DecodedMsg = (catch tftp_lib:decode_msg(Bin)),
	    print_debug_info(Config2, Req, recv, DecodedMsg),
	    {Config2, DecodedMsg};
	{udp, Socket, Host, Port, Bin} when binary(Bin),
                                            Config#config.udp_host == Host,
	                                    Config#config.udp_port == Port ->
	    inet:setopts(Socket, [{active, once}]),
	    DecodedMsg = (catch tftp_lib:decode_msg(Bin)),
	    print_debug_info(Config, Req, recv, DecodedMsg),
	    {Config, DecodedMsg};
	{system, From, Msg} ->
	    Misc = {wait_for_msg, [Config, Callback, Req]},
	    sys:handle_system_msg(Msg, From, Config#config.parent_pid, ?MODULE, [], Misc);
	{'EXIT', Pid, Reason} when Config#config.parent_pid == Pid ->
	    Code = undef,
	    Text = "Parent exited.",
	    terminate(Config, Req, {error, {wait_for_msg, Code, Text, Reason}});
	Msg when Req#tftp_msg_req.local_filename /= undefined ->
	    error("Client received : ~p", [Msg]),
	    wait_for_msg(Config, Callback, Req);
	Msg when Req#tftp_msg_req.local_filename == undefined ->
	    error("Server received : ~p", [Msg]),
	    wait_for_msg(Config, Callback, Req)
    after Config#config.timeout * 1000 ->
	    print_debug_info(Config, Req, recv, timeout),
	    timeout
    end.

early_read(Config, Callback, Req, read, undefined)
  when Callback#callback.block_no /= undefined ->
    callback(read, Config, Callback, Req);
early_read(_Config, Callback, _Req, _LocalAccess, Prepared) ->
    {Callback, Prepared}.

%%-------------------------------------------------------------------
%% Callback
%%-------------------------------------------------------------------

callback(Access, Config, Callback, Req) ->
    {Callback2, Result} =
	do_callback(Access, Config, Callback, Req),
    print_debug_info(Config, Req, call, {Callback2, Result}),
    {Callback2, Result}.

do_callback(read, Config, Callback, Req) 
  when record(Config, config),
       record(Callback, callback),
       record(Req, tftp_msg_req) ->
    Args =  [Callback#callback.state],
    case catch apply(Callback#callback.module, read, Args) of
	{more, Bin, NewState} when binary(Bin) ->
	    BlockNo = Callback#callback.block_no + 1,
	    Count   = Callback#callback.count + size(Bin),
	    Callback2 = Callback#callback{state    = NewState, 
					  block_no = BlockNo,
					  count    = Count},
	    verify_count(Config, Callback2, Req, {more, Bin});
        {last, Data, Result} ->
	    {undefined, {last, Data, Result}};
	{error, {Code, Text}} ->
	    {undefined, #tftp_msg_error{code = Code, text = Text}};
	Details ->
	    Code = undef,
	    Text = "Internal error. File handler error.",
	    callback({abort, {Code, Text, Details}}, Config, Callback, Req)
    end;
do_callback({write, Bin}, Config, Callback, Req)
  when record(Config, config),
       record(Callback, callback),
       record(Req, tftp_msg_req),
       binary(Bin) ->
    Args =  [Bin, Callback#callback.state],
    case catch apply(Callback#callback.module, write, Args) of
	{more, NewState} ->
	    BlockNo = Callback#callback.block_no + 1,
	    Count   = Callback#callback.count + size(Bin),
	    Callback2 = Callback#callback{state    = NewState, 
					  block_no = BlockNo,
					  count    = Count}, 
	    verify_count(Config, Callback2, Req, more);
	{last, Result} ->
	    {undefined, {last, Result}};
	{error, {Code, Text}} ->
	    {undefined, #tftp_msg_error{code = Code, text = Text}};
	Details ->
	    Code = undef,
	    Text = "Internal error. File handler error.",
	    callback({abort, {Code, Text, Details}}, Config, Callback, Req)
    end;
do_callback({open, Type}, Config, Callback, Req)
  when record(Config, config),
       record(Callback, callback),
       record(Req, tftp_msg_req) ->
    {Access, Filename} = local_file_access(Req),
    {Oper, BlockNo} =
	case Type of
	    client_prepare -> {prepare, undefined};
	    client_open    -> {open, 0};
	    server_open    -> {open, 0}
	end,
    Args = [Access,
	    Filename,
	    Req#tftp_msg_req.mode,
	    Req#tftp_msg_req.options,
	    Callback#callback.state],
    case catch apply(Callback#callback.module, Oper, Args) of
	{ok, AcceptedOptions, NewState} ->
	    Callback2 = Callback#callback{state    = NewState, 
					  block_no = BlockNo, 
					  count    = 0}, 
	    {Callback2, {ok, AcceptedOptions}};
	{error, {Code, Text}} ->
	    {undefined, #tftp_msg_error{code = Code, text = Text}};
	Details ->
	    Code = undef,
	    Text = "Internal error. File handler error.",
	    callback({abort, {Code, Text, Details}}, Config, Callback, Req)
    end;
do_callback({abort, {Code, Text}}, Config, Callback, Req) ->
    Error = #tftp_msg_error{code = Code, text = Text},
    do_callback({abort, Error}, Config, Callback, Req);
do_callback({abort, {Code, Text, Details}}, Config, Callback, Req) ->
    Error = #tftp_msg_error{code = Code, text = Text, details = Details},
    do_callback({abort, Error}, Config, Callback, Req);
do_callback({abort, #tftp_msg_error{code = Code, text = Text} = Error}, Config, Callback, Req)
  when record(Config, config),
       record(Callback, callback), 
       record(Req, tftp_msg_req) ->
    Args =  [Code, Text, Callback#callback.state],
    catch apply(Callback#callback.module, abort, Args),
    {undefined, Error};
do_callback({abort, Error}, _Config, undefined, _Req) when record(Error, tftp_msg_error) ->
    {undefined, Error}.

match_callback(Filename, Callbacks) ->
    if
	Filename == binary ->
	    {ok, #callback{regexp   = "", 
			   internal = "", 
			   module   = tftp_binary,
			   state    = []}};
	binary(Filename) ->
	    {ok, #callback{regexp   = "", 
			   internal = "", 
			   module   = tftp_binary, 
			   state    = []}};  
	Callbacks == []  ->
	    {ok, #callback{regexp   = "", 
			   internal = "",
			   module   = tftp_file, 
			   state    = []}};
	true ->
	    do_match_callback(Filename, Callbacks)
    end.

do_match_callback(Filename, [C | Tail]) when record(C, callback) ->
    case catch regexp:match(Filename, C#callback.internal) of
	{match, _, _} ->
	    {ok, C};
	nomatch ->
	    do_match_callback(Filename, Tail);
	Details ->
	    Code = baduser,
	    Text = "Internal error. File handler not found",
	    {error, #tftp_msg_error{code = Code, text = Text, details = Details}}
    end;
do_match_callback(Filename, []) ->
    Code = baduser,
    Text = "Internal error. File handler not found",
    {error, #tftp_msg_error{code = Code, text = Text, details = Filename}}.

verify_count(Config, Callback, Req, Result) ->
    case Config#config.max_tsize of
	infinity ->
	    {Callback, Result};
	Max when Callback#callback.count =< Max ->
	    {Callback, Result};
	_Max ->
	    Code = enospc,
	    Text = "Too large file.",
	    callback({abort, {Code, Text}}, Config, Callback, Req)
    end.

%%-------------------------------------------------------------------
%% Miscellaneous
%%-------------------------------------------------------------------

internal_info(Config, Type) ->
    {ok, ActualPort} = inet:port(Config#config.udp_socket),
    [
     {type, Type},
     {host, Config#config.udp_host},
     {port, Config#config.udp_port},
     {local_port, ActualPort},
     {port_policy, Config#config.port_policy},
     {udp, Config#config.udp_options},
     {use_tsize, Config#config.use_tsize},
     {max_tsize, Config#config.max_tsize},
     {max_conn, Config#config.max_conn},
     {rejected, Config#config.rejected},
     {timeout, Config#config.timeout},
     {polite_ack, Config#config.polite_ack},
     {debug_level, Config#config.debug_level},
     {parent_pid, Config#config.parent_pid}
    ] ++ Config#config.user_options ++ Config#config.callbacks.

local_file_access(#tftp_msg_req{access = Access, 
				local_filename = Local, 
				filename = Filename}) ->
    case Local == undefined of
	true ->
	    %% Server side
	    {Access, Filename};
	false ->
	    %% Client side
	    case Access of
		read ->
		    {write, Local};
		write ->
		    {read, Local}
	    end
    end.

pre_verify_options(Config, Req) ->
    Options = Req#tftp_msg_req.options,
    case catch verify_reject(Config, Req, Options) of
	ok ->
	    case verify_integer("tsize", 0, Config#config.max_tsize, Options) of
		true ->
		    case verify_integer("blksize", 0, 65464, Options) of
			true ->
			    ok;
			false ->
			    {error, {badopt, "Too large blksize"}}
		    end;
		false ->
		    {error, {badopt, "Too large tsize"}}
	    end;
	{error, Reason} ->
	    {error, Reason}
    end.
    
post_verify_options(Config, Req, NewOptions, Text) ->
    OldOptions = Req#tftp_msg_req.options,
    BadOptions  = 
	[Key || {Key, _Val} <- NewOptions, 
		not lists:keymember(Key, 1, OldOptions)],
    case BadOptions == [] of
	true ->
	    {ok,
	     Config#config{timeout = lookup_timeout(NewOptions)},
	     Req#tftp_msg_req{options = NewOptions}};
	false ->
	    {error, {badopt, Text}}
    end.

verify_reject(Config, Req, Options) ->
    Access = Req#tftp_msg_req.access,
    Rejected = Config#config.rejected,
    case lists:member(Access, Rejected) of
	true ->
	    {error, {eacces, atom_to_list(Access) ++ " mode not allowed"}};
	false ->
	    [throw({error, {badopt, Key ++ " not allowed"}}) ||
		{Key, _} <- Options, lists:member(Key, Rejected)],
	    ok
    end.

lookup_timeout(Options) ->
    case lists:keysearch("timeout", 1, Options) of
	{value, {_, Val}} ->
	    list_to_integer(Val);
	false ->
	    3
    end.

lookup_mode(Options) ->
    case lists:keysearch("mode", 1, Options) of
	{value, {_, Val}} ->
	    Val;
	false ->
	    "octet"
    end.

verify_integer(Key, Min, Max, Options) ->
    case lists:keysearch(Key, 1, Options) of
	{value, {_, Val}} when list(Val) ->
	    case catch list_to_integer(Val) of
		{'EXIT', _} ->
		    false;
		Int when Int >= Min, integer(Min),
		         Max == infinity ->
		    true;
		Int when Int >= Min, integer(Min),
                         Int =< Max, integer(Max) ->
		    true;
		_ ->
		    false
	    end;
	false ->
	    true
    end.
error(F, A) ->
    ok = error_logger:format("~p(~p): " ++ F ++ "~n", [?MODULE, self() | A]).

print_debug_info(#config{debug_level = Level} = Config, Who, What, Data) ->
    if
	Level == none ->
	    ok;
	Level == all ->
	    do_print_debug_info(Config, Who, What, Data);
	What == open ->
	    do_print_debug_info(Config, Who, What, Data);
	What == close ->
	    do_print_debug_info(Config, Who, What, Data);
	Level == brief ->
	    ok;	
	What /= recv, What /= send ->
	    ok;
	record(Data, tftp_msg_data), Level == normal ->
	    ok;	 
	record(Data, tftp_msg_ack), Level == normal ->
	    ok;
	true ->
	    do_print_debug_info(Config, Who, What, Data)
    end.

do_print_debug_info(Config, Who, What, #tftp_msg_data{data = Bin} = Msg) when binary(Bin) ->
    Msg2 = Msg#tftp_msg_data{data = {bytes, size(Bin)}},
    do_print_debug_info(Config, Who, What, Msg2);
do_print_debug_info(Config, Who, What, #tftp_msg_req{local_filename = Filename} = Msg) when binary(Filename) ->
    Msg2 = Msg#tftp_msg_req{local_filename = binary},
    do_print_debug_info(Config, Who, What, Msg2);
do_print_debug_info(Config, Who, What, Data) ->
    {ok, Local} = inet:port(Config#config.udp_socket),
    Remote = Config#config.udp_port,
    Side = 
	if
	    record(Who, tftp_msg_req),
	    Who#tftp_msg_req.local_filename /= undefined ->
		client;
	    record(Who, tftp_msg_req),
	    Who#tftp_msg_req.local_filename == undefined ->
		server;
	    atom(Who) ->
		Who
	end,
    case What of
	open ->
	    io:format("~p(~p): open ~p ->  ~p\n", [Side, Local, self(), Config#config.udp_host]);
	close ->
	    io:format("~p(~p): close ~p ->  ~p\n", [Side, Local, self(), Config#config.udp_host]);
	recv ->
	    io:format("~p(~p): recv  ~p <- ~p\n", [Side, Local, Remote, Data]);
	send ->
	    io:format("~p(~p): send  ~p -> ~p\n", [Side, Local, Remote, Data]);
	match when record(Data, callback) ->
	    Mod = Data#callback.module,
	    State = Data#callback.state,
	    io:format("~p(~p): match ~p ~p => ~p\n", [Side, Local, Remote, Mod, State]);
	call ->
	    case Data of
		{Callback, _Result} when record(Callback, callback) ->
		    Mod   = Callback#callback.module,
		    State = Callback#callback.state,
		    io:format("~p(~p): call ~p ~p => ~p\n", [Side, Local, Remote, Mod, State]);
		{undefined, Result}  ->
		    io:format("~p(~p): call ~p result => ~p\n", [Side, Local, Remote, Result])
	    end
    end.


%%-------------------------------------------------------------------
%% System upgrade
%%-------------------------------------------------------------------

system_continue(_Parent, _Debug, {Fun, Args}) ->
    apply(?MODULE, Fun, Args).

system_terminate(Reason, _Parent, _Debug, {_Fun, _Args}) ->
    exit(Reason).

system_code_change({Fun, Args}, _Module, _OldVsn, _Extra) ->
    {ok, {Fun, Args}}.
