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
%%  This module implements the old SNMP application start method
%%  The purpose is to extract all agent app-env and convert to the 
%%  new format
%%
%% What about the restart times for the children 
%% note_store (snmpa_supervisor) and
%% net_if and mib_server (snmpa_misc_sup)?
%% 
%%-----------------------------------------------------------------

-module(snmpa_app).

-include("snmp_debug.hrl").

-export([start/1]).


start(Type) ->
    ?d("start -> entry with"
	"~n   Type: ~p", [Type]),
    Opts = application:get_all_env(snmp),
    ?d("start -> Opts: ~p", [Opts]),
    Prio           = get_priority(Opts),
    DbDir          = get_db_dir(Opts),
    LdbOpts        = get_local_db_opts(Opts),
    MibStorage     = get_mib_storage(Opts),
    MibsOpts       = get_mib_server_opts(Opts),
    SymOpts        = get_symbolic_store_opts(Opts),
    SetModule      = get_set_mechanism(Opts),
    AuthModule     = get_authentication_service(Opts),
    MultiT         = get_multi_threaded(Opts),
    Vsns           = get_versions(Opts),
    SupOpts        = get_supervisor_opts(Opts),
    ErrorReportMod = get_error_report_mod(Opts),
    AgentType      = get_agent_type(Opts),
    NewOpts = 
	case AgentType of
	    sub ->
		?d("start -> agent type: sub",[]),
		SaVerb = get_sub_agent_verbosity(Opts),
		[{agent_type,             AgentType}, 
		 {agent_verbosity,        SaVerb}, 
		 {set_mechanism,          SetModule},
		 {authentication_service, AuthModule},
		 {priority,               Prio},
		 {versions,               Vsns},
		 {db_dir,                 DbDir},
		 {multi_threaded,         MultiT},
		 {error_report_mod,       ErrorReportMod},
		 {mib_storage,            MibStorage},
		 {mib_server,             MibsOpts}, 
		 {local_db,               LdbOpts}, 
		 {supervisor,             SupOpts}, 
		 {symbolic_store,         SymOpts}];

	    master ->
		?d("start -> agent type: master",[]),
		MaVerb    = get_master_agent_verbosity(Opts),
		NoteOpts  = get_note_store_opts(Opts),
		NiOptions = get_net_if_options(Opts),
		NiOpts    = [{options, NiOptions}|get_net_if_opts(Opts)],
		AtlOpts   = get_audit_trail_log_opts(Opts),
		Mibs      = get_master_agent_mibs(Opts),
		ForceLoad = get_force_config_load(Opts),
		ConfVerb  = get_opt(verbosity, SupOpts, silence),
		ConfDir   = get_config_dir(Opts),
		ConfOpts  = [{dir,        ConfDir}, 
			     {force_load, ForceLoad},
			     {verbosity,  ConfVerb}],
		[{agent_type,             AgentType}, 
		 {agent_verbosity,        MaVerb}, 
		 {set_mechanism,          SetModule},
		 {authentication_service, AuthModule},
		 {db_dir,                 DbDir},
		 {config,                 ConfOpts}, 
		 {priority,               Prio},
		 {versions,               Vsns},
		 {multi_threaded,         MultiT},
		 {error_report_mod,       ErrorReportMod},
		 {supervisor,             SupOpts}, 
		 {mibs,                   Mibs},
		 {mib_storage,            MibStorage},
		 {symbolic_store,         SymOpts}, 
		 {note_store,             NoteOpts}, 
		 {net_if,                 NiOpts}, 
		 {mib_server,             MibsOpts}, 
		 {local_db,               LdbOpts}] ++ AtlOpts
	end,
    ?d("start -> start the agent",[]),
    snmp_app_sup:start_agent(Type, NewOpts).


%% ------------------------------------------------------------------

get_db_dir(Opts) ->
    case get_opt(snmp_db_dir, Opts) of
	{value, Dir} when list(Dir) ->
	    Dir;
	{value, Bad} ->
	    exit({bad_config, {db_dir, Bad}});
	false ->
	    exit({undefined_config, db_dir})
    end.
	    

%% --

get_priority(Opts) ->
    case get_opt(snmp_priority, Opts) of
	{value, Prio} when atom(Prio) ->
	    Prio;
	_ ->
	    normal
    end.


%% --

get_mib_storage(Opts) ->
    get_opt(snmp_mib_storage, Opts, ets).

get_mib_server_opts(Opts) ->
    Options = [{snmp_mibserver_verbosity, verbosity, silence},
	       {mibentry_override, mibentry_override, false},
	       {trapentry_override, trapentry_override, false}],
    get_opts(Options, Opts, []).


%% --

get_audit_trail_log_opts(Opts) ->
    case get_audit_trail_log(Opts) of
	false ->
	    [];
	Type ->
	    Dir  = get_audit_trail_log_dir(Opts),
	    Size = get_audit_trail_log_size(Opts),
	    AtlOpts0 = [{type,   Type},
			{dir,    Dir},
			{size,   Size},
			{repair, true}],
	    [{audit_trail_log, AtlOpts0}]
    end.

    
get_audit_trail_log(Opts) ->
    case get_opt(audit_trail_log, Opts) of
	{value, write_log}      -> write;
	{value, read_log}       -> read;
	{value, read_write_log} -> read_write;
	_                       -> false
    end.

get_audit_trail_log_dir(Opts) ->
    case get_opt(audit_trail_log_dir, Opts) of
	{value, Dir} when list(Dir) ->
	    Dir;
	{value, Bad} -> 
	    exit({bad_config, {audit_trail_log_dir, Bad}});
	_ -> 
	    exit({undefined_config, audit_trail_log_dir})
    end.

get_audit_trail_log_size(Opts) ->
    case get_opt(audit_trail_log_size, Opts) of
	{value, {MB, MF} = Sz} when integer(MB), integer(MF) ->
	    Sz;
	{value, Bad} -> 
	    exit({bad_config, {audit_trail_log_size, Bad}});
	_ -> 
	    exit({undefined_config, audit_trail_log_size})
    end.


%% --

get_master_agent_verbosity(Opts) ->
    get_opt(snmp_master_agent_verbosity, Opts, silence).


%% --

get_sub_agent_verbosity(Opts) ->
    get_opt(snmp_subagent_verbosity, Opts, silence).


%% --

get_supervisor_opts(Opts) ->
    Options = [{snmp_supervisor_verbosity, verbosity, silence}],
    get_opts(Options, Opts, []).


%% --

get_symbolic_store_opts(Opts) ->
    Options = [{snmp_symbolic_store_verbosity, verbosity, silence}],
    get_opts(Options, Opts, []).


%% --

get_note_store_opts(Opts) ->
    Options = [{snmp_note_store_verbosity, verbosity, silence}],
    get_opts(Options, Opts, []).


%% --

get_local_db_opts(Opts) ->
    Options = [{snmp_local_db_auto_repair, repair,    true}, 
	       {snmp_local_db_verbosity,   verbosity, silence}],
    get_opts(Options, Opts, []).


%% --

get_multi_threaded(Opts) ->
    case get_opt(snmp_multi_threaded, Opts) of
	{value, true} ->
	    true;
	{value, false} ->
	    false;
	_ ->
	    false
    end.

get_versions(Opts) ->
    F = fun(Ver) ->
		case get_opt(Ver, Opts) of
		    {value, true} ->
			[Ver];
		    {value, false} ->
			[];
		    _ ->
			[Ver] % Default is true
		end
	end,
    V1 = F(v1),
    V2 = F(v2),
    V3 = F(v3),
    V1 ++ V2 ++ V3.

get_set_mechanism(Opts) ->
    get_opt(set_mechanism, Opts, snmpa_set).

get_authentication_service(Opts) ->
    get_opt(authentication_service, Opts, snmpa_acm).

get_error_report_mod(Opts) ->
    case get_opt(snmp_error_report_mod, Opts) of
	{ok, Mod} when atom(Mod) -> Mod;
	_ -> snmpa_error_logger
    end.


%% --

get_net_if_opts(Opts) ->
    Options = [{snmp_net_if_module,    module,    snmpa_net_if},
	       {snmp_net_if_verbosity, verbosity, silence}],
    get_opts(Options, Opts, []).

get_net_if_options(Opts) ->
    Options = [recbuf, 
	       {req_limit,          req_limit, infinity}, 
	       {bind_to_ip_address, bind_to,   false},
	       {no_reuse_address,   no_reuse,  false}],
    get_opts(Options, Opts, []).


%% --

get_agent_type(Opts) ->
    get_opt(snmp_agent_type, Opts, master).


%% --

get_config_dir(Opts) ->
    case get_opt(snmp_config_dir, Opts) of
	{value, Dir} when list(Dir) -> Dir;
	{value, Bad} ->
	    exit({bad_config, {config_dir, Bad}});
	_ -> 
	    exit({undefined_config, config_dir})
    end.

get_master_agent_mibs(Opts) ->
    get_opt(snmp_master_agent_mibs, Opts, []).

get_force_config_load(Opts) ->
    case get_opt(force_config_load, Opts) of
	{ok, true} -> true;
	{ok, false} -> false;
	_ -> false
    end.


%% --

get_opts([], _Options, Opts) ->
    Opts;
get_opts([{Key1, Key2, Def}|KeyVals], Options, Opts) ->
    %% If not found among Options, then use default value
    case lists:keysearch(Key1, 1, Options) of
	{value, {Key1, Val}} ->
	    get_opts(KeyVals, Options, [{Key2, Val}|Opts]);
	false ->
	    get_opts(KeyVals, Options, [{Key2, Def}|Opts])
    end;
get_opts([Key|KeyVals], Options, Opts) ->
    %% If not found among Options, then ignore
    case lists:keysearch(Key, 1, Options) of
	{value, KeyVal} ->
	    get_opts(KeyVals, Options, [KeyVal|Opts]);
	false ->
	    get_opts(KeyVals, Options, Opts)
    end.
    

%% --


get_opt(Key, Opts, Def) ->
    case get_opt(Key, Opts) of
	{value, Val} ->
	    Val;
	false ->
	    Def
    end.

get_opt(Key, Opts) ->
    case lists:keysearch(Key, 1, Opts) of
	{value, {_, Val}} ->
	    {value, Val};
	false ->
	    false
    end.

% i(F) ->
%     i(F, []).

% i(F, A) ->
%     io:format("~p: " ++ F ++ "~n", [?MODULE|A]).