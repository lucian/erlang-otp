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
-module(etop).
-author('siri@erix.ericsson.se').

-export([start/0, start/1, config/2, stop/0, dump/1, help/0]).
%% Internal
-export([update/1]).
-export([loadinfo/1, meminfo/2, getopt/2, dbgout/2]).

-include("etop.hrl").
-include("etop_defs.hrl").

-define(change_at_runtime_config,[lines,interval,sort,accumulate]).

help() ->
    io:format(
      "Usage of the erlang top program~n"
      "Options are set as command line parameters as in -node a@host -..~n"
      "or as parameter to etop:start([{node, a@host}, {...}])~n"
      "Options are:~n"
      "  node        atom       Required   The erlang node to measure ~n"
      "  port        integer    The used port, NOTE: due to a bug this program~n"
      "                         will hang if the port is not avaiable~n"
      "  accumulate  boolean    If true execution time is accumulated ~n"
      "  lines       integer    Number of displayed processes~n"
      "  interval    integer    Display update interval in secs~n"
      "  sort        runtime | reductions | memory | msg_q~n"
      "                         What information to sort by~n"
      "                         Default: runtime (reductions if tracing=off)~n"
      "  output      graphical | text~n"
      "                         How to present results~n"
      "                         Default: graphical~n"
      "  tracing     on | off   etop uses the erlang trace facility, and thus~n"
      "                         no other tracing is possible on the node while~n"
      "                         etop is running, unless this option is set to~n"
      "                         'off'. Also helpful if the etop tracing causes~n"
      "                         too high load on the measured node.~n"
      "                         With tracing off, runtime is not measured!~n"
      "  setcookie   string     Only applicable on operating system command~n"
      "                         line. Set cookie for the etop node, must be~n"
      "                         same as the cookie for the measured node.~n"
      "                         This is not an etop parameter~n"
     ).

stop() ->
    case whereis(etop_server) of
	undefined -> not_started;
	Pid when pid(Pid) -> etop_server ! stop
    end.

config(Key,Value) ->
    case check_runtime_config(Key,Value) of
	ok ->
	    etop_server ! {config,{Key,Value}},
	    ok;
	error -> 
	    {error,illegal_opt}
    end.
check_runtime_config(lines,L) when integer(L),L>0 -> ok;
check_runtime_config(interval,I) when integer(I),I>0 -> ok;
check_runtime_config(sort,S) when S=:=runtime; 
				  S=:=reductions; 
				  S=:=memory; 
				  S=:=msg_q -> ok;
check_runtime_config(accumulate,A) when A=:=true; A=:=false -> ok;
check_runtime_config(_Key,_Value) -> error.

dump(File) ->
    case file:open(File,[write]) of
	{ok,Fd} -> etop_server ! {dump,Fd};
	Error -> Error
    end.

start() ->
    start([]).
    
start(Opts) ->
    process_flag(trap_exit, true),
    Config1 = handle_args(init:get_arguments() ++ Opts, #opts{}),
    Config2 = Config1#opts{server=self()},
    dbgout("Config = ~p ~n", [Config2]),

    %% Connect to the node we want to look at
    Node = getopt(node, Config2),
    case net_adm:ping(Node) of
	pang ->
	    io:format("Error Couldn't connect to node ~p ~n~n", [Node]),
	    help(),
	    exit("connection error");
	pong ->
	    check_runtime_tools_vsn(Node)
    end,

    %% Maybe set up the tracing
    Config3 = 
	if Config2#opts.tracing == on ->
		etop_tr:setup_tracer(Config2);
	   true -> 
		if Config2#opts.sort == runtime -> Config2#opts{sort=reductions};
		   true -> Config2
		end
	end,
    AccumTab = ets:new(accum_tab,
		       [set,public,{keypos,#etop_proc_info.pid}]),
    Config4 = Config3#opts{accum_tab=AccumTab},

    %% Start the output server
    Out = spawn_link(Config4#opts.out_mod, init, [Config4]),
    Config5 = Config4#opts{out_proc = Out},       
    

    dbgout("Config = ~p ~n", [Config5]),
    init_data_handler(Config5),
    ok.

check_runtime_tools_vsn(Node) ->
    case rpc:call(Node,observer_backend,vsn,[]) of
	{ok,Vsn} -> check_vsn(Vsn);
        _ -> exit("Faulty version of runtime_tools on remote node")
    end.
check_vsn(_Vsn) -> ok.
%check_vsn(_Vsn) -> exit("Faulty version of runtime_tools on remote node").
    

%% Handle the incoming data

init_data_handler(Config) ->
    register(etop_server,self()),    
    Reader = 
	if Config#opts.tracing == on -> etop_tr:reader(Config);
	   true -> undefined
    end,
    data_handler(Reader, Config).

data_handler(Reader, Opts) ->
    receive
	stop ->
	    stop(Opts),
	    ok;
	{config,{Key,Value}} ->
	    data_handler(Reader,putopt(Key,Value,Opts));
	{dump,Fd} ->
	    Opts#opts.out_proc ! {dump,Fd},
	    data_handler(Reader,Opts);
	{'EXIT', EPid, Reason} when EPid == Opts#opts.out_proc ->
	    case Reason of
		normal -> ok;
		_ -> io:format("Output server crashed: ~p~n",[Reason])
	    end,
	    stop(Opts),
	    out_proc_stopped;
	{'EXIT', Reader, eof} ->
	    io:format("Lost connection to node ~p exiting~n", [Opts#opts.node]),
	    stop(Opts),
	    connection_lost;
	M ->
	    dbgout("~p GOT MSG ~p ~n", [etop_server, M]),
	    data_handler(Reader, Opts)
    end.

stop(Opts) ->
    (Opts#opts.out_mod):stop(Opts#opts.out_proc),
    if Opts#opts.tracing == on -> etop_tr:stop_tracer(Opts);
       true -> ok
    end,
    unregister(etop_server).
    
update(#opts{store=Store,node=Node,tracing=Tracing}=Opts) ->
    Pid = spawn_link(Node,observer_backend,etop_collect,[self()]),
    Info = receive {Pid,I} -> I 
	   after 1000 -> exit(connection_lost)
	   end,
    #etop_info{procinfo=ProcInfo} = Info,
    ProcInfo1 = 
	if Tracing == on ->
		PI=lists:map(fun(PI=#etop_proc_info{pid=P}) -> 
				     case ets:lookup(Store,P) of
					 [{P,T}] -> PI#etop_proc_info{runtime=T};
					 [] -> PI
				     end
			     end,
			     ProcInfo),
		PI;	   
	   true -> 
		lists:map(fun(PI) -> PI#etop_proc_info{runtime='-'} end,ProcInfo)
	end,
    ProcInfo2 = sort(Opts,ProcInfo1),
    Info#etop_info{procinfo=ProcInfo2}.    

sort(Opts,PI) ->
    Tag = get_tag(Opts#opts.sort),
    PI1 = if Opts#opts.accum -> 
		  PI;
	     true -> 
		  AccumTab = Opts#opts.accum_tab,
		  lists:map(
		    fun(#etop_proc_info{pid=Pid,reds=Reds,runtime=RT}=I) -> 
			    NewI = 
				case ets:lookup(AccumTab,Pid) of
				    [#etop_proc_info{reds=OldReds,
						     runtime='-'}] -> 
					I#etop_proc_info{reds=Reds-OldReds,
							 runtime='-'};
				    [#etop_proc_info{reds=OldReds,
						     runtime=OldRT}] -> 
					I#etop_proc_info{reds=Reds-OldReds,
							 runtime=RT-OldRT};
				    [] -> 
					I
				end,
			    ets:insert(AccumTab,I),
			    NewI
		    end,
		    PI)
	  end,
    PI2 = lists:reverse(lists:keysort(Tag,PI1)),
    lists:sublist(PI2,Opts#opts.lines).

get_tag(runtime) -> #etop_proc_info.runtime;
get_tag(memory) -> #etop_proc_info.mem;
get_tag(reductions) -> #etop_proc_info.reds;
get_tag(msg_q) -> #etop_proc_info.mq.
    

%%%%% Debug 
dbgout(Str, Opts) ->
    %%io:format("DBG ", []),    
    if 
	?debug_out == true->
	    io:format(Str, Opts);
       true  ->
	    ignore
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Configuration Management

getopt(What, Config) when record(Config, opts) ->
    case What of 
	node  -> Config#opts.node;
	port  -> Config#opts.port;
	accum -> Config#opts.accum;
	intv  -> Config#opts.intv;
	lines  -> Config#opts.lines;
	sort -> Config#opts.sort;
	width -> Config#opts.width;
	height-> Config#opts.height;

	store -> Config#opts.store;
	host  -> Config#opts.host
    end.

putopt(Key, Value, Config) when record(Config, opts) ->
    Config1 = handle_args([{Key,Value}],Config),
    Config1#opts.out_proc ! {config,{Key,Value},Config1},
    Config1.

handle_args([{node, [NodeString]}| R], Config) when list(NodeString) ->
    Node = list_to_atom(NodeString),
    NewC = Config#opts{node = Node},
    handle_args(R, NewC);
handle_args([{node, Node} |R], Config) when atom(Node) ->
    NewC = Config#opts{node = Node},
    handle_args(R, NewC);
handle_args([{port, Port}| R], Config) when integer(Port) ->
    NewC = Config#opts{port=Port},
    handle_args(R, NewC);
handle_args([{port, [Port]}| R], Config) when list(Port) ->
    NewC = Config#opts{port= list_to_integer(Port)},
    handle_args(R, NewC);
handle_args([{interval, Time}| R], Config) when integer(Time)->
    NewC = Config#opts{intv=Time*1000},
    handle_args(R, NewC);
handle_args([{interval, [Time]}| R], Config) when list(Time)->
    NewC = Config#opts{intv=list_to_integer(Time)*1000},
    handle_args(R, NewC);
handle_args([{lines, Lines}| R], Config) when integer(Lines) ->
    NewC = Config#opts{lines=Lines},
    handle_args(R, NewC);
handle_args([{lines, [Lines]}| R], Config) when list(Lines) ->
    NewC = Config#opts{lines= list_to_integer(Lines)},
    handle_args(R, NewC);
handle_args([{accumulate, Bool}| R], Config) when atom(Bool) ->
    NewC = Config#opts{accum=Bool},
    handle_args(R, NewC);
handle_args([{accumulate, [Bool]}| R], Config) when list(Bool) ->
    NewC = Config#opts{accum= list_to_atom(Bool)},
    handle_args(R, NewC);
handle_args([{sort, Sort}| R], Config) when atom(Sort) ->
    NewC = Config#opts{sort=Sort},
    handle_args(R, NewC);
handle_args([{sort, [Sort]}| R], Config) when list(Sort) ->
    NewC = Config#opts{sort= list_to_atom(Sort)},
    handle_args(R, NewC);
handle_args([{output, Output}| R], Config) when atom(Output) ->
    NewC = Config#opts{out_mod=output(Output)},
    handle_args(R, NewC);
handle_args([{output, [Output]}| R], Config) when list(Output) ->
    NewC = Config#opts{out_mod= output(list_to_atom(Output))},
    handle_args(R, NewC);
handle_args([{tracing, OnOff}| R], Config) when atom(OnOff) ->
    NewC = Config#opts{tracing=OnOff},
    handle_args(R, NewC);
handle_args([{tracing, [OnOff]}| R], Config) when list(OnOff) ->
    NewC = Config#opts{tracing=list_to_atom(OnOff)},
    handle_args(R, NewC);

handle_args([_| R], C) ->
    handle_args(R, C);
handle_args([], C) ->
    C.

output(graphical) -> etop_gui;
output(text) -> etop_txt.


loadinfo(SysI) ->
    #etop_info{n_procs = Procs, 
	       run_queue = RQ, 
	       now = Now,
	       wall_clock = {_, WC}, 
	       runtime = {_, RT}} = SysI,
    Cpu = round(100*RT/WC),
    Clock = io_lib:format("~2.2.0w:~2.2.0w:~2.2.0w",
			 tuple_to_list(element(2,calendar:now_to_datetime(Now)))),
    {Cpu,Procs,RQ,Clock}.

meminfo(MemI, [Tag|Tags]) -> 
    [round(get_mem(Tag, MemI)/1024)|meminfo(MemI, Tags)];
meminfo(_MemI, []) -> [].

get_mem(Tag, MemI) ->
    case lists:keysearch(Tag, 1, MemI) of
	{value, {Tag, I}} -> I;			       %these are in bytes
	_ -> 0
    end.

