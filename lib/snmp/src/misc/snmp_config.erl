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
-module(snmp_config).

-include_lib("kernel/include/file.hrl").
-include("snmp_types.hrl").

-export([config/0]).
-export([write_agent_snmp_files/7, write_agent_snmp_files/12,

	 write_agent_snmp_conf/5, 
	 write_agent_snmp_context_conf/1, 
	 write_agent_snmp_community_conf/1, 
	 write_agent_snmp_standard_conf/2, 
	 write_agent_snmp_target_addr_conf/4, 
	 write_agent_snmp_target_params_conf/2, 
	 write_agent_snmp_notify_conf/2, 
	 write_agent_snmp_usm_conf/5, 
	 write_agent_snmp_vacm_conf/3, 

	 write_manager_snmp_files/8,
	 write_manager_snmp_conf/5, 
	 write_manager_snmp_users_conf/2, 
	 write_manager_snmp_agents_conf/2, 
	 write_manager_snmp_usm_conf/2
 	 
	]).

-export([write_agent_config/3, 
	 write_agent_context_config/3, 
	 write_agent_community_config/3, 
	 write_agent_standard_config/3, 
	 write_agent_target_addr_config/3, 
	 write_agent_target_params_config/3, 
	 write_agent_notify_config/3, 
	 write_agent_vacm_config/3, 
	 write_agent_usm_config/3, 

	 write_manager_config/3,
	 write_manager_users_config/3,
	 write_manager_agents_config/3,
	 write_manager_usm_config/3
	]).

-export([write_manager_snmp_conf2/5,
	 write_manager_snmp_agents_conf2/2,
	 write_manager_snmp_users_conf2/2,
	 write_manager_snmp_usm_conf2/2]).


%%----------------------------------------------------------------------
%% Handy SNMP configuration
%%----------------------------------------------------------------------

config() ->
    case (catch config2()) of
	ok ->
	    ok;
	{error, Reason} ->
	    {error, Reason};
	E ->
	    {error, {failed, E}}
    end.


config2() ->
    intro(),
    SysAgentConfig = 
	case config_agent() of
	    [] ->
		[];
	    SAC ->
		[{agent, SAC}]
	end,
    SysMgrConfig   = 
	case config_manager() of
	    [] ->
		[];
	    SMC ->
		[{manager, SMC}]
	end,
    config_sys(SysAgentConfig ++ SysMgrConfig),
    ok.


intro() ->
    i("~nSimple SNMP configuration tool (version ~s)", [?version]),
    i("------------------------------------------------"),
    i("Note: Non-trivial configurations still has to be"),
    i("      done manually. IP addresses may be entered "),
    i("      as dront.ericsson.se (UNIX only) or"),
    i("      123.12.13.23"),
    i("------------------------------------------------"),
    ok.


config_agent() ->
    case (catch snmp_agent2()) of
	ok ->
	    [];
	{ok, SysConf} ->
	    SysConf;
	{error, Reason} ->
	    error(Reason);
	{'EXIT', Reason} ->
	    error(Reason);
	E ->
	    error({agent_config_failed, E})
    end.

snmp_agent2() ->
    case ask("~nConfigure an agent (y/n)?", "y", fun verify_yes_or_no/1) of
	yes ->
	    {Vsns, ConfigDir, SysConf} = config_agent_sys(),
	    config_agent_snmp(ConfigDir, Vsns),
	    {ok, SysConf};
	no ->
	    ok
    end.


config_manager() ->
    case (catch config_manager2()) of
	ok ->
	    [];
	{ok, SysConf} ->
	    SysConf;
	{error, Reason} ->
	    error(Reason);
	{'EXIT', Reason} ->
	    error(Reason);
	E ->
	    error({manager_config_failed, E})
    end.

config_manager2() ->
    case ask("~nConfigure a manager (y/n)?", "y", fun verify_yes_or_no/1) of
	yes ->
	    {Vsns, ConfigDir, SysConf} = config_manager_sys(),
 	    config_manager_snmp(ConfigDir, Vsns),
	    {ok, SysConf};
	no ->
	    ok
    end.


config_sys(SysConfig) ->
    i("~n--------------------"),
    {ok, DefDir} = file:get_cwd(),
    ConfigDir = ask("Configuration directory for system file (absolute path)?",
		    DefDir, fun verify_dir/1),    
    write_sys_config_file(ConfigDir, SysConfig).


%% -------------------

config_agent_sys() ->
    i("~nAgent system config: "
      "~n--------------------"),
    Prio = ask("1. Agent process priority (low/normal/high)", 
	       "normal", fun verify_prio/1),
    Vsns = ask("2. What SNMP version(s) should be used "
	       "(1,2,3,1&2,1&2&3,2&3)?", "3", fun verify_versions/1),
    %% d("Vsns: ~p", [Vsns]),
    {ok, DefDir} = file:get_cwd(),
    ConfigDir = ask("3. Configuration directory (absolute path)?", DefDir, 
		    fun verify_dir/1),
    ConfigVerb = ask("4. Config verbosity "
		     "(silence/info/log/debug/trace)?", 
		     "silence",
		     fun verify_verbosity/1),
    DbDir     = ask("5. Database directory (absolute path)?", DefDir, 
		    fun verify_dir/1),
    MibStorageType = ask("6. Mib storage type (ets/dets/mnesia)?", "ets",
			 fun verify_mib_storage_type/1),
    MibStorage = 
	case MibStorageType of
	    ets ->
		ets;
	    dets ->
		DetsDir = ask("6b. Mib storage directory (absolute path)?",
			      DefDir, fun verify_dir/1),
		DetsAction = ask("6c. Mib storage [dets] database start "
				 "action "
				 "(default/clear/keep)?", 
				 "default", fun verify_mib_storage_action/1),
		case DetsAction of
		    default ->
			{dets, DetsDir};
		    _ ->
			{dets, DetsDir, DetsAction}
		end;
	    mnesia ->
% 		Nodes = ask("Mib storage nodes?", "none", 
% 			    fun verify_mib_storage_nodes/1),
		Nodes = [],
		MnesiaAction = ask("6b. Mib storage [mnesia] database start "
				   "action "
				   "(default/clear/keep)?", 
				   "default", fun verify_mib_storage_action/1),
		case MnesiaAction of
		    default ->
			{mnesia, Nodes};
		    _ ->
			{mnesia, Nodes, MnesiaAction}
		end
	end,
    SymStoreVerb = ask("7. Symbolic store verbosity "
		       "(silence/info/log/debug/trace)?", "silence",
		       fun verify_verbosity/1),
    LocalDbVerb = ask("8. Local DB verbosity "
		       "(silence/info/log/debug/trace)?", "silence",
		       fun verify_verbosity/1),
    LocalDbRepair = ask("9. Local DB repair (true/false/force)?", "true",
			fun verify_dets_repair/1),
    LocalDbAutoSave = ask("10. Local DB auto save (infinity/milli seconds)?", 
			  "5000", fun verify_dets_auto_save/1),
    ErrorMod = ask("11. Error report module?", "snmpa_error_logger", fun verify_module/1),
    Type = ask("12. Agent type (master/sub)?", "master", 
	       fun verify_agent_type/1),
    AgentConfig = 
	case Type of 
	    master ->
		MasterAgentVerb = ask("13. Master-agent verbosity "
				      "(silence/info/log/debug/trace)?", 
				      "silence",
				      fun verify_verbosity/1),
		ForceLoad = ask("14. Shall the agent re-read the "
				"configuration files during startup ~n"
				"    (and ignore the configuration "
				"database) (true/false)?", "true", 
				fun verify_bool/1),
		MultiThreaded = ask("15. Multi threaded agent (true/false)?", 
				    "false",
				    fun verify_bool/1),
		MeOverride = ask("16. Check for duplicate mib entries when "
				 "installing a mib (true/false)?", "false",
				 fun verify_bool/1),
		TrapOverride = ask("17. Check for duplicate trap names when "
				   "installing a mib (true/false)?", "false",
				   fun verify_bool/1),
		MibServerVerb = ask("18. Mib server verbosity "
				    "(silence/info/log/debug/trace)?", 
				    "silence",
				    fun verify_verbosity/1),
		NoteStoreVerb = ask("19. Note store verbosity "
				    "(silence/info/log/debug/trace)?", 
				    "silence",
				    fun verify_verbosity/1),
		NoteStoreTimeout = ask("20. Note store GC timeout?", "30000",
				       fun verify_timeout/1),
		ATL = 
		    case ask("21. Shall the agent use an audit trail log "
			     "(y/n)?",
			     "n", fun verify_yes_or_no/1) of
			yes ->
			    ATLType = ask("21b. Audit trail log type "
					  "(write/read_write)?",
					  "read_write", fun verify_atl_type/1),
			    ATLDir = ask("21c. Where to store the "
					 "audit trail log?",
					 DefDir, fun verify_dir/1),
			    ATLMaxFiles = ask("21d. Max number of files?", 
					      "10", 
					      fun verify_pos_integer/1),
			    ATLMaxBytes = ask("21e. Max size (in bytes) "
					      "of each file?", 
					      "10240", 
					      fun verify_pos_integer/1),
			    ATLSize = {ATLMaxBytes, ATLMaxFiles},
			    ATLRepair = ask("21f. Audit trail log repair "
					    "(true/false/truncate)?", "true",
					    fun verify_atl_repair/1),
			    [{audit_trail_log, [{type,   ATLType},
						{dir,    ATLDir},
						{size,   ATLSize},
						{repair, ATLRepair}]}];
			no ->
			    []
		    end,
		NetIfMod = ask("22. Which network interface module shall be used?",
			       "snmpa_net_if", fun verify_module/1),
		NetIfVerb = ask("23. Network interface verbosity "
				"(silence/info/log/debug/trace)?", "silence",
				fun verify_verbosity/1),
		NetIfBindTo = ask("24. Bind the agent IP address "
				  "(true/false)?",
				  "false", fun verify_bool/1),
		NetIfNoReuse = ask("25. Shall the agents IP address and port "
				   "be not reusable (true/false)?",
				   "false", fun verify_bool/1),
		NetIfReqLimit = ask("26. Agent request limit "
				    "(used for flow control) "
				    "(infinity/pos integer)?", "infinity",
				    fun verify_netif_req_limit/1),
		NetIf = 
		    case ask("27. Receive buffer size of the agent (in bytes) "
			     "(default/pos integer)?", "default", 
			     fun verify_netif_recbuf/1) of
			default ->
			    [{module,    NetIfMod},
			     {verbosity, NetIfVerb},
			     {options,   [{bind_to,   NetIfBindTo},
					  {no_reuse,  NetIfNoReuse},
					  {req_limit, NetIfReqLimit}]}];
			NetIfRecbuf ->
			    [{module,    NetIfMod},
			     {verbosity, NetIfVerb},
			     {options,   [{recbuf,    NetIfRecbuf},
					  {bind_to,   NetIfBindTo},
					  {no_reuse,  NetIfNoReuse},
					  {req_limit, NetIfReqLimit}]}]
		    end,
		[{agent_type,      master},
		 {agent_verbosity, MasterAgentVerb},
		 {config,          [{dir,        ConfigDir}, 
				    {force_load, ForceLoad},
				    {verbosity,  ConfigVerb}]},
		 {multi_threaded,  MultiThreaded},
		 {mib_server,      [{mibentry_override,  MeOverride},
				    {trapentry_override, TrapOverride},
				    {verbosity,          MibServerVerb}]},
		 {note_store,      [{timeout,   NoteStoreTimeout},
				    {verbosity, NoteStoreVerb}]},
		 {net_if, NetIf}] ++ ATL;
	    sub ->
		SubAgentVerb = ask("13. Sub-agent verbosity "
				   "(silence/info/log/debug/trace)?", 
				   "silence",
				   fun verify_verbosity/1),
		[{agent_type,      sub},
		 {agent_verbosity, SubAgentVerb},
		 {config,          [{dir, ConfigDir}]}]
	end,
    SysConfig = 
	[{priority,    Prio},
	 {versions,    Vsns},
	 {db_dir,      DbDir},
	 {mib_storage, MibStorage},
	 {symbolic_store, [{verbosity, SymStoreVerb}]},
	 {local_db, [{repair,    LocalDbRepair},
		     {auto_save, LocalDbAutoSave},
		     {verbosity, LocalDbVerb}]},
	 {error_report_module, ErrorMod}] ++ AgentConfig,
    {Vsns, ConfigDir, SysConfig}.


config_agent_snmp(Dir, Vsns) ->
    i("~nAgent snmp config: "
      "~n------------------"),
    AgentName  = guess_agent_name(),
    EngineName = guess_engine_name(),
    SysName    = ask("1. System name (sysName standard variable)", 
		     AgentName, fun verify_system_name/1),
    EngineID   = ask("2. Engine ID (snmpEngineID standard variable)", 
		      EngineName, fun verify_engine_id/1),
    MMS        = ask("3. Max message size?", "484", 
		     fun verify_max_message_size/1),
    AgentUDP   = ask("4. The UDP port the agent listens to. "
		     "(standard 161)",
		     "4000", fun verify_port_number/1),
    Host       = host(),
    AgentIP    = ask("5. IP address for the agent (only used as id ~n"
		     "   when sending traps)", Host, fun verify_address/1),
    ManagerIP  = ask("6. IP address for the manager (only this manager ~n"
		     "   will have access to the agent, traps are sent ~n"
		     "   to this one)", Host, fun verify_address/1),
    TrapUdp    = ask("7. To what UDP port at the manager should traps ~n"
		     "   be sent (standard 162)?", "5000", 
		     fun verify_port_number/1),
    SecType    = ask("8. Do you want a none- minimum- or semi-secure"
		     " configuration? ~n"
		     "   Note that if you chose v1 or v2, you won't get any"
		     " security for these~n"
		     "   requests (none, minimum, semi)", "minimum", 
		    fun verify_sec_type/1),
    Passwd = 
	case lists:member(v3, Vsns) and (SecType /= none) of
	    true ->
		ensure_crypto_started(),
		ask("8b. Give a password of at least length 8. It is used to "
		    "generate ~n"
		    "    private keys for the configuration: ",
		    mandatory, fun verify_passwd/1);
	    false ->
		""
	end,
    NotifType  =
	case lists:member(v1, Vsns) of
	    true ->
		Overwrite = ask("9. Current configuration files will "
				"now be overwritten. "
				"Ok (y/n)?", "y", fun verify_yes_or_no/1),
		case Overwrite of
		    no ->
			error(overwrite_not_allowed);
		    yes ->
			ok
		end,
		trap;
	    false ->
		NT = ask("9. Should notifications be sent as traps or informs "
			 "(trap/inform)?", "trap", fun verify_notif_type/1),
		Overwrite = ask("10. Current configuration files will "
				"now be overwritten. "
				"Ok (y/n)?", "y", fun verify_yes_or_no/1),
		case Overwrite of
		    no ->
			error(overwrite_not_allowed);
		    yes ->
			ok
		end,
		NT
	end,
    case (catch write_agent_snmp_files(Dir, 
				       Vsns, ManagerIP, TrapUdp, 
				       AgentIP, AgentUDP,
				       SysName, NotifType, SecType, 
				       Passwd, EngineID, MMS)) of
	ok ->
	   i("~n- - - - - - - - - - - - -"),
	   i("Info: 1. SecurityName \"initial\" has noAuthNoPriv read access~n"
	     "         and authenticated write access to the \"restricted\"~n"
	     "         subtree."),
	   i("      2. SecurityName \"all-rights\" has noAuthNoPriv "
	     "read/write~n"
	     "         access to the \"internet\" subtree."),
	   i("      3. Standard traps are sent to the manager."),
	   case lists:member(v1, Vsns) or lists:member(v2, Vsns) of
	       true ->
		   i("      4. Community \"public\" is mapped to security name"
		     " \"initial\"."),
		   i("      5. Community \"all-rights\" is mapped to security"
		     " name \"all-rights\".");
	       false ->
		   ok
	   end,
	   i("The following agent files were written: agent.conf, "
	     "community.conf,~n"
	     "standard.conf, target_addr.conf, "
	     "target_params.conf, ~n"
	     "notify.conf" ++
	     case lists:member(v3, Vsns) of
		 true -> ", vacm.conf and usm.conf";
		 false -> " and vacm.conf"
	     end),
	   i("- - - - - - - - - - - - -"),
	   ok;
	E -> 
	    error({failed_writing_files, E})
    end.


%% -------------------

config_manager_sys() ->
    i("~nManager system config: "
      "~n----------------------"),
    Prio = ask("1. Manager process priority (low/normal/high)", 
	       "normal", fun verify_prio/1),
     {ok, DefDir} = file:get_cwd(),
    Vsns = ask("2. What SNMP version(s) should be used "
	       "(1,2,3,1&2,1&2&3,2&3)?", "3", fun verify_versions/1),
    ConfigDir = ask("3. Configuration directory (absolute path)?", DefDir, 
		    fun verify_dir/1),
    ConfigVerb = ask("4. Config verbosity "
			"(silence/info/log/debug/trace)?", 
			"silence",
			fun verify_verbosity/1),
    ConfigDbDir = ask("5. Database directory (absolute path)?", 
		      DefDir, fun verify_dir/1),
    ConfigDbRepair = ask("6. Database repair "
			 "(true/false/force)?", "true",
			 fun verify_dets_repair/1),
    ConfigDbAutoSave = ask("7. Database auto save "
			   "(infinity/milli seconds)?", 
			   "5000", fun verify_dets_auto_save/1),
    ServerVerb = ask("8. Server verbosity "
			"(silence/info/log/debug/trace)?", 
			"silence",
			fun verify_verbosity/1),
    ServerTimeout = ask("9. Server GC timeout?", "30000",
			   fun verify_timeout/1),    
    NoteStoreVerb = ask("10. Note store verbosity "
			"(silence/info/log/debug/trace)?", 
			"silence",
			fun verify_verbosity/1),
    NoteStoreTimeout = ask("11. Note store GC timeout?", "30000",
			   fun verify_timeout/1),    
    NetIfMod = ask("12. Which network interface module shall be used?",
		   "snmpm_net_if", fun verify_module/1),
    NetIfVerb = ask("13. Network interface verbosity "
		    "(silence/info/log/debug/trace)?", "silence",
		    fun verify_verbosity/1),
    NetIfBindTo = ask("14. Bind the manager IP address "
		      "(true/false)?",
		      "false", fun verify_bool/1),
    NetIfNoReuse = ask("15. Shall the manager IP address and port "
		       "be not reusable (true/false)?",
		       "false", fun verify_bool/1),
    NetIf = 
	case ask("16. Receive buffer size of the manager (in bytes) "
		 "(default/pos integer)?", "default", 
		 fun verify_netif_recbuf/1) of
	    default ->
		[{module,    NetIfMod},
		 {verbosity, NetIfVerb},
		 {options,   [{bind_to,  NetIfBindTo},
			      {no_reuse, NetIfNoReuse}]}];
	    NetIfRecbuf ->
		[{module,    NetIfMod},
		 {verbosity, NetIfVerb},
		 {options,   [{recbuf,   NetIfRecbuf},
			      {bind_to,  NetIfBindTo},
			      {no_reuse, NetIfNoReuse}]}]
	end,
    ATL = 
	case ask("17. Shall the manager use an audit trail log "
		 "(y/n)?",
		 "n", fun verify_yes_or_no/1) of
	    yes ->
		ATLDir = ask("17b. Where to store the "
			     "audit trail log?",
			     DefDir, fun verify_dir/1),
		ATLMaxFiles = ask("17c. Max number of files?", 
				  "10", 
				  fun verify_pos_integer/1),
		ATLMaxBytes = ask("17d. Max size (in bytes) "
				  "of each file?", 
				  "10240", 
				  fun verify_pos_integer/1),
		ATLSize = {ATLMaxBytes, ATLMaxFiles},
		ATLRepair = ask("17e. Audit trail log repair "
				"(true/false/truncate)?", "true",
				fun verify_atl_repair/1),
		[{audit_trail_log, [{dir,    ATLDir},
				    {size,   ATLSize},
				    {repair, ATLRepair}]}];
	    no ->
		[]
	end,
    DefUser = 
	case ask("18. Do you wish to assign a default user [yes] or use~n"
		 "    the default settings [no] (y/n)?", "n", 
		 fun verify_yes_or_no/1) of
	    yes ->
		DefUserMod = ask("18b. Default user module?", 
				 "snmpm_user_default",
				 fun verify_module/1),
		DefUserData = ask("18c. Default user data?", "undefined",
				  fun verify_user_data/1),
		[{def_user_mod,  DefUserMod},
		 {def_user_data, DefUserData}];
	    no ->
		[]
	end,
    SysConfig = 
	[{priority,   Prio},
	 {versions,   Vsns},
	 {config,     [{dir,       ConfigDir}, 
		       {verbosity, ConfigVerb},
		       {db_dir,    ConfigDbDir},
		       {repair,    ConfigDbRepair},
		       {auto_save, ConfigDbAutoSave}]},
	 {mibs,       []},
	 {server,     [{timeout,   ServerTimeout},
		       {verbosity, ServerVerb}]},
	 {note_store, [{timeout,   NoteStoreTimeout},
		       {verbosity, NoteStoreVerb}]},
	 {net_if,     NetIf}] ++ ATL ++ DefUser,
    {Vsns, ConfigDir, SysConfig}.


config_manager_snmp(Dir, Vsns) ->
    i("~nManager snmp config: "
      "~n--------------------"),
    EngineName = guess_engine_name(),
    EngineID   = ask("1. Engine ID (snmpEngineID standard variable)", 
		      EngineName, fun verify_engine_id/1),
    MMS        = ask("2. Max message size?", "484", 
		     fun verify_max_message_size/1),
    Host       = host(),
    IP         = ask("3. IP address for the manager (only used as id ~n"
		     "   when sending requests)",
		     Host, fun verify_address/1),
    Port       = ask("4. Port number (standard 162)?", "5000", 
		     fun verify_port_number/1),
    Users      = config_manager_snmp_users([]),
    Agents     = config_manager_snmp_agents([]),
    Usms       = config_manager_snmp_usms([]),
    Overwrite = ask("8. Current configuration files will now be overwritten. "
		    "Ok (y/n)?", "y", fun verify_yes_or_no/1),
    case Overwrite of
	no ->
	    error(overwrite_not_allowed);
	yes ->
	    ok
    end,
    case (catch write_manager_snmp_files(Dir, 
					 IP, Port, MMS, EngineID, 
					 Users, Agents, Usms)) of
	ok ->
	   i("~n- - - - - - - - - - - - -"),
	   i("The following manager files were written: "
	     "manager.conf, agents.conf " ++ 
	     case lists:member(v3, Vsns) of
		 true ->
		     ", users.conf and usm.conf";
		 false ->
		     " and users.conf"
	     end),
	   i("- - - - - - - - - - - - -"),
	    ok;
	E ->
	    error({failed_writing_files, E})
    end.
	     

config_manager_snmp_users(Users) ->
    case ask("5. Configure a user of this manager (y/n)?",
	     "y", fun verify_yes_or_no/1) of
	yes ->
	    User = config_manager_snmp_user(),
	    config_manager_snmp_users([User|Users]);
	no ->
	    lists:reverse(Users)
    end.

config_manager_snmp_user() ->
    UserId   = ask("5b. User id?", mandatory, 
		   fun verify_user_id/1),
    UserMod  = ask("5c. User callback module?", mandatory, 
		   fun verify_module/1),
    UserData = ask("5d. User (callback) data?", "undefined",
		   fun verify_user_data/1),
    {UserId, UserMod, UserData}.
    

config_manager_snmp_agents(Agents) ->
    case ask("6. Configure an agent handled by this manager (y/n)?",
	     "y", fun verify_yes_or_no/1) of
	yes ->
	    Agent = config_manager_snmp_agent(),
	    config_manager_snmp_agents([Agent|Agents]);
	no ->
	    lists:reverse(Agents)
    end.

config_manager_snmp_agent() ->
    UserId     = ask("6b. User id?", mandatory, 
		     fun verify_user_id/1),
    TargetName = ask("6c. Target name?", guess_agent_name(),
		     fun verify_system_name/1),
    Version    = ask("6d. Version (1/2/3)?", "1",
	             fun verify_version/1),
    Comm       = ask("6e. Community string ?", "public",
	             fun verify_community/1),
    EngineID   = ask("6f. Engine ID (snmpEngineID standard variable)", 
	             guess_engine_name(), fun verify_engine_id/1),
    IP         = ask("6g. IP address for the agent", host(), 
	             fun verify_address/1),
    Port       = ask("6h. The UDP port the agent listens to. "
	             "(standard 161)", "4000", fun verify_port_number/1),
    Timeout    = ask("6i. Retransmission timeout (infinity/pos integer)?",
	             "infinity", fun verify_retransmission_timeout/1),    
    MMS        = ask("6j. Max message size?", "484", 
	             fun verify_max_message_size/1),
    SecModel   = ask("6k. Security model (any/v1/v2c/usm)?", "any", 
	             fun verify_sec_model/1),
    SecName    = ask("6l. Security name?", "\"initial\"", 
	             fun verify_sec_name/1),
    SecLevel   = ask("6m. Security level (noAuthNoPriv/authNoPriv/authPriv)?",
	             "noAuthNoPriv", fun verify_sec_level/1),
    {UserId,
     TargetName, Comm, IP, Port, EngineID, Timeout, MMS, 
     Version, SecModel, SecName, SecLevel}.


config_manager_snmp_usms(Usms) ->
    case ask("7. Configure an usm user handled by this manager (y/n)?",
	     "y", fun verify_yes_or_no/1) of
	yes ->
	    Usm = config_manager_snmp_usm(),
	    config_manager_snmp_usms([Usm|Usms]);
	no ->
	    lists:reverse(Usms)
    end.

config_manager_snmp_usm() ->
    EngineID = ask("7a. Engine ID", guess_engine_name(), 
		   fun verify_engine_id/1),
    UserName = ask("7b. User name?", mandatory, fun verify_usm_name/1),
    SecName  = ask("7c. Security name?", UserName,
		   fun verify_usm_sec_name/1),
    AuthP    = ask("7d. Authentication protocol (no/sha/md5)?", "no",
		   fun verify_usm_auth_protocol/1),
    AuthKey  = ask_auth_key("7e", AuthP), 
    PrivP    = ask("7d. Priv protocol (no/des)?", "no",
		   fun verify_usm_priv_protocol/1),
    PrivKey  = ask_priv_key("7f", PrivP), 
    {EngineID, UserName,
     SecName, AuthP, AuthKey, PrivP, PrivKey}.


ask_auth_key(_Prefix, usmNoAuthProtocol) ->
    "";
ask_auth_key(Prefix, usmHMACSHAAuthProtocol) ->
    ask(Prefix ++ "  Authentication [sha] key (length 0 or 20)?", "\"\"",
	fun verify_usm_auth_sha_key/1);
ask_auth_key(Prefix, usmHMACMD5AuthProtocol) ->
    ask(Prefix ++ "  Authentication [md5] key (length 0 or 16)?", "\"\"",
	fun verify_usm_auth_md5_key/1).

ask_priv_key(_Prefix, usmNoPrivProtocol) ->
    "";
ask_priv_key(Prefix, usmDESPrivProtocol) ->
    ask(Prefix ++ "  Priv [des] key (length 0 or 16)?", "\"\"",
	fun verify_usm_priv_des_key/1).


%% ------------------------------------------------------------------

verify_yes_or_no("y") ->
    {ok, yes};
verify_yes_or_no("yes") ->
    {ok, yes};
verify_yes_or_no("n") ->
    {ok, no};
verify_yes_or_no("no") ->
    {ok, no};
verify_yes_or_no(YON) ->
    {error, "invalid yes or no: " ++ YON}.


verify_prio("low") ->
    {ok, low};
verify_prio("normal") ->
    {ok, normal};
verify_prio("high") ->
    {ok, high};
verify_prio(Prio) ->
    {error, "invalid process priority: " ++ Prio}.


verify_system_name(Name) -> {ok, Name}.


verify_engine_id(Name) -> {ok, Name}.


verify_max_message_size(MMS) ->
    case (catch list_to_integer(MMS)) of
	I when integer(I), I >= 484 ->
	    {ok, I};
	I when integer(I) ->
	    {error, "invalid max message size (must be atleast 484): " ++ MMS};
	_ ->
	    {error, "invalid max message size: " ++ MMS}
    end.
	
 
verify_port_number(P) ->
    case (catch list_to_integer(P)) of
	N when integer(N), N > 0 ->
	    {ok, N};
	_ ->
	    {error, "invalid port number: " ++ P}
    end.


verify_versions("1")     -> {ok, [v1]};
verify_versions("2")     -> {ok, [v2]};
verify_versions("3")     -> {ok, [v3]};
verify_versions("1&2")   -> {ok, [v1,v2]};
verify_versions("1&3")   -> {ok, [v1,v3]};
verify_versions("2&3")   -> {ok, [v2,v3]};
verify_versions("1&2&3") -> {ok, [v1,v2,v3]};
verify_versions(V)       -> {error, "incorrect version(s): " ++ V}.

verify_version("1")     -> {ok, v1};
verify_version("2")     -> {ok, v2};
verify_version("3")     -> {ok, v3};
verify_version(V)       -> {error, "incorrect version: " ++ V}.

    
verify_passwd(Passwd) when length(Passwd) >= 8 ->
    {ok, Passwd};
verify_passwd(_P) ->
    {error, "invalid password"}.


verify_dir(Dir) ->
    case filename:pathtype(Dir) of
	absolute -> 
	    case file:read_file_info(Dir) of
		{ok, #file_info{type = directory}} ->
		    {ok, snmp_misc:ensure_trailing_dir_delimiter(Dir)};
		{ok, _FileInfo} ->
		    {error, Dir ++ " is not a directory"};
		_ ->
		    {error, "invalid directory: " ++ Dir}
	    end;
	_E -> 
	    {error, "invalid directory (not absolute): " ++ Dir}
    end.
	    

verify_notif_type("trap")   -> {ok, trap};
verify_notif_type("inform") -> {ok, inform};
verify_notif_type(NT)       -> {error, "invalid notifcation type: " ++ NT}.


verify_sec_type("none")    -> {ok, none};
verify_sec_type("minimum") -> {ok, minimum};
verify_sec_type("semi")    -> {ok, semi};
verify_sec_type(ST)        -> {error, "invalid security type: " ++ ST}.

    
verify_address(A) ->
    case (catch snmp_misc:ip(A)) of
	{ok, IP} ->
	     {ok, tuple_to_list(IP)};
	{error, _} ->
	    {error, "invalid address: " ++ A};
	_E ->
	    {error, "invalid address: " ++ A}
    end.


verify_mib_storage_type("m") ->
    {ok, mnesia};
verify_mib_storage_type("mnesia") ->
    {ok, mnesia};
verify_mib_storage_type("d") ->
    {ok, dets};
verify_mib_storage_type("dets") ->
    {ok, dets};
verify_mib_storage_type("e") ->
    {ok, ets};
verify_mib_storage_type("ets") ->
    {ok, ets};
verify_mib_storage_type(T) ->
    {error, "invalid mib storage type: " ++ T}.

verify_mib_storage_action("default") ->
    {ok, default};
verify_mib_storage_action("clear") ->
    {ok, clear};
verify_mib_storage_action("keep") ->
    {ok, keep};
verify_mib_storage_action(A) ->
    {error, "invalid mib storage action: " ++ A}.


verify_verbosity("silence") ->
    {ok, silence};
verify_verbosity("info") ->
    {ok, info};
verify_verbosity("log") ->
    {ok, log};
verify_verbosity("debug") ->
    {ok, debug};
verify_verbosity("trace") ->
    {ok, trace};
verify_verbosity(V) ->
    {error, "invalid verbosity: " ++ V}.


verify_dets_repair("true") ->
    {ok, true};
verify_dets_repair("false") ->
    {ok, false};
verify_dets_repair("force") ->
    {ok, force};
verify_dets_repair(R) ->
    {error, "invalid repair: " ++ R}.

verify_dets_auto_save("infinity") ->
    {ok, infinity};
verify_dets_auto_save(I0) ->
    case (catch list_to_integer(I0)) of
	I when integer(I), I > 0 ->
	    {ok, I};
	_ -> 
	    {error, "invalid auto save timeout time: " ++ I0}
    end.


%% I know that this is a little of the edge, but...
verify_module(M0) ->
    case (catch list_to_atom(M0)) of
	M when atom(M) ->
	    {ok, M};
	_ ->
	    {error, "invalid module: " ++ M0}
    end.
	 

verify_agent_type("master") ->
    {ok, master};
verify_agent_type("sub") ->
    {ok, sub};
verify_agent_type(AT) ->
    {error, "invalid agent type: " ++ AT}.


verify_bool("true") ->
    {ok, true};
verify_bool("false") ->
    {ok, false};
verify_bool(B) ->
    {error, "invalid boolean: " ++ B}.


verify_timeout(T0) ->
    case (catch list_to_integer(T0)) of
	T when integer(T), T > 0 ->
	    {ok, T};
	_ ->
	    {error, "invalid timeout time: '" ++ T0 ++ "'"}
    end.


verify_retransmission_timeout("infinity") ->
    {ok, infinity};
verify_retransmission_timeout([${|R] = Timer) ->
    case lists:reverse(R) of
	[$}|R2] ->
	    case string:tokens(lists:reverse(R2), ", ") of
		[WaitForStr, FactorStr, IncrStr, RetryStr] ->
		    WaitFor = incr_timer_value(WaitForStr, 1),
		    Factor  = incr_timer_value(FactorStr,  1),
		    Incr    = incr_timer_value(IncrStr,    0),
		    Retry   = incr_timer_value(RetryStr,   0),
		    {ok, {WaitFor, Factor, Incr, Retry}};
		_ ->
		    {error, "invalid retransmission timer: '" ++ Timer ++ "'"}
	    end;
	_ ->
	    {error, "invalid retransmission timer: '" ++ Timer ++ "'"}
    end;
verify_retransmission_timeout(T0) ->
    case (catch list_to_integer(T0)) of
	T when integer(T), T > 0 ->
	    {ok, T};
	_ ->
	    {error, "invalid timeout time: '" ++ T0 ++ "'"}
    end.

incr_timer_value(Str, Min) ->
    case (catch list_to_integer(Str)) of
	I when integer(I), I >= Min ->
	    I;
	I when integer(I) ->
	    E = lists:flatten(io_lib:format("invalid incremental timer value "
					    "(min value is ~w): " ++ Str, 
					    [Min])),
	    error(E);
	_ ->
	    error("invalid incremental timer value: " ++ Str)
    end.
	 

%% verify_atl_type("read") ->
%%     {ok, read};
verify_atl_type("write") ->
    {ok, write};
verify_atl_type("read_write") ->
    {ok, read_write};
verify_atl_type(T) ->
    {error, "invalid log type: " ++ T}.

verify_atl_repair("true") ->
    {ok, true};
verify_atl_repair("false") ->
    {ok, false};
verify_atl_repair("truncate") ->
    {ok, truncate};
verify_atl_repair(R) ->
    {error, "invalid audit trail log repair: " ++ R}.


verify_pos_integer(I0) ->
    case (catch list_to_integer(I0)) of
	I when integer(I), I > 0 ->
	    {ok, I};
	_ ->
	    {error, "invalid integer value: " ++ I0}
    end.


verify_netif_req_limit("infinity") ->
    {ok, infinity};
verify_netif_req_limit(I0) ->
    case (catch list_to_integer(I0)) of
	I when integer(I), I > 0 ->
	    {ok, I};
	_ ->
	    {error, "invalid network interface request limit: " ++ I0}
    end.

verify_netif_recbuf("default") ->
    {ok, default};
verify_netif_recbuf(I0) ->
    case (catch list_to_integer(I0)) of
	I when integer(I), I > 0 ->
	    {ok, I};
	_ ->
	    {error, "invalid network interface recbuf size: " ++ I0}
    end.


verify_user_id(UserId) when list(UserId) ->
    case (catch list_to_atom(UserId)) of
	A when atom(A) ->
	    {ok, A};
	_ ->
	    {error, "invalid user id: " ++ UserId}
    end;
verify_user_id(UserId) when atom(UserId) ->
    {ok, UserId};
verify_user_id(UserId) ->
    E = lists:flatten(io_lib:format("invalid user id: ~p", [UserId])),
    {error, E}.

verify_user_data("undefined") ->
    {ok, undefined};
verify_user_data(UserData) ->
    {ok, UserData}.


verify_community("\"\"") ->
    {ok, ""};
verify_community(Comm) ->
    {ok, Comm}.


% verify_context_name("\"\"") ->
%     {ok, ""};
% verify_context_name(Ctx) ->
%     {ok, Ctx}.


% verify_mp_model("v1") ->
%     {ok, v1};
% verify_mp_model("v2c") ->
%     {ok, v2c};
% verify_mp_model("v3") ->
%     {ok, v3};
% verify_mp_model(M) ->
%     {error, "invalid mp model: " ++ M}.


verify_sec_model("any") ->
    {ok, any};
verify_sec_model("v1") ->
    {ok, v1};
verify_sec_model("v2c") ->
    {ok, v2c};
verify_sec_model("usm") ->
    {ok, usm};
verify_sec_model(M) ->
    {error, "invalid sec model: " ++ M}.

verify_sec_name("\"initial\"") ->
    {ok, "initial"};
verify_sec_name(N) ->
    {ok, N}.


verify_sec_level("noAuthNoPriv") ->
    {ok, noAuthNoPriv};
verify_sec_level("authNoPriv") ->
    {ok, authNoPriv};
verify_sec_level("authPriv") ->
    {ok, authPriv};
verify_sec_level(L) ->
    {error, "invalid sec level: " ++ L}.


verify_usm_name(Name) ->
    {ok, Name}.

verify_usm_sec_name(Name) ->
    {ok, Name}.


verify_usm_auth_protocol("no") ->
    {ok, usmNoAuthProtocol};
verify_usm_auth_protocol("sha") ->
    {ok, usmHMACSHAAuthProtocol};
verify_usm_auth_protocol("md5") ->
    {ok, usmHMACMD5AuthProtocol};
verify_usm_auth_protocol(AuthP) ->
    {error, "invalid auth protocol: " ++ AuthP}.

verify_usm_auth_sha_key(Key) ->
    verify_usm_key("auth sha", Key, 20).

verify_usm_auth_md5_key(Key) ->
    verify_usm_key("auth md5", Key, 16).

verify_usm_priv_protocol("no") ->
    {ok, usmNoPrivProtocol};
verify_usm_priv_protocol("des") ->
    {ok, usmDESPrivProtocol};
verify_usm_priv_protocol(AuthP) ->
    {error, "invalid priv protocol: " ++ AuthP}.

verify_usm_priv_des_key(Key) ->
    verify_usm_key("priv des", Key, 16).

verify_usm_key(_What, "\"\"", _ExpectLength) ->
    {ok, ""};
verify_usm_key(_What, Key, ExpectLength) when length(Key) == ExpectLength ->
    {ok, Key};
verify_usm_key(What, [$[|RestKey] = Key0, ExpectLength) ->
    case lists:reverse(RestKey) of
	[$]|RevRestKey] ->
	    Key1 = lists:reverse(RevRestKey),
	    verify_usm_key2(What, Key1, ExpectLength);
	_ ->
	    %% Its not a list ([...]) and its not the correct length, ...
	    {error, "invalid " ++ What ++ " key length: " ++ Key0}
    end;
verify_usm_key(What, Key, ExpectLength) ->
    verify_usm_key2(What, Key, ExpectLength).
    
verify_usm_key2(What, Key0, ExpectLength) ->
    case string:tokens(Key0, [$,]) of
	Key when length(Key) == ExpectLength ->
	    convert_usm_key(Key, []);
	_ ->
	    {error, "invalid " ++ What ++ " key length: " ++ Key0}
    end.
    
convert_usm_key([], Acc) ->
    {ok, lists:reverse(Acc)};
convert_usm_key([I|Is], Acc) ->
    case (catch list_to_integer(I)) of
	Int when integer(Int) ->
	    convert_usm_key(Is, [Int|Acc]);
	_Err ->
	    {error, "invalid key number: " ++ I}
    end.

	     
% ip(Host) ->
%     case catch snmp_misc:ip(Host) of
% 	{ok, IPtuple} -> tuple_to_list(IPtuple);
% 	{error, Reason} -> throw({error, Reason});
% 	_Q -> throw({error, {"ip conversion failed", Host}})
%     end.

% make_ip(Str) ->
%     case catch snmp_misc:ip(Str) of
% 	{ok, IPtuple} -> tuple_to_list(IPtuple);
% 	_Q -> ip(Str)
%     end.


print_q(Q, mandatory) ->
    io:format(Q ++ " ",[]);
print_q(Q, Default) when list(Default) ->
    io:format(Q ++ " [~s] ",[Default]).

%% Defval = string() | mandatory
ask(Q, Default, Verify) when list(Q), function(Verify) ->
    print_q(Q, Default),
    PrelAnsw = io:get_line(''),
    Answer = 
	case remove_newline(PrelAnsw) of
	    "" when Default /= mandatory -> Default;
	    "" -> ask(Q, Default, Verify);
	    A -> A
    end,
    case (catch Verify(Answer)) of
	{ok, Answer2} ->
	    Answer2;
	{error, ReasonStr} ->
	    i("ERROR: " ++ ReasonStr),
	    ask(Q, Default, Verify)
    end.


host() ->
    case (catch inet:gethostname()) of
	{ok, Name} ->
	    case (catch inet:getaddr(Name, inet)) of
		{ok, Addr} when tuple(Addr) ->
		    lists:flatten(
		      io_lib:format("~w.~w.~w.~w", tuple_to_list(Addr)));
		_ ->
		    "127.0.0.1"
	    end;
	_ -> 
	    "127.0.0.1"
    end.

guess_agent_name() ->
    case os:type() of
	{unix, _} ->
	    lists:append(remove_newline(os:cmd("echo $USER")), "'s agent");
	{_,_} -> "my agent"
    end.

guess_engine_name() ->
    case os:type() of
	{unix, _} ->
	    lists:append(remove_newline(os:cmd("echo $USER")), "'s engine");
	{_,_} -> "my engine"
    end.

% guess_user_id() ->
%     case os:type() of
% 	{unix, _} ->
% 	    lists:append(remove_newline(os:cmd("echo $USER")), "'s user");
% 	{_,_} -> "user_id"
%     end.

    
remove_newline(Str) -> 
    lists:delete($\n, Str).


%%======================================================================
%% File generation
%%======================================================================

%%----------------------------------------------------------------------
%% Dir: string()  (ex: "../conf/")
%% ManagerIP, AgentIP: [int(),int(),int(),int()]
%% TrapUdp, AgentUDP: integer()
%% SysName: string()
%%----------------------------------------------------------------------
write_agent_snmp_files(Dir, Vsns, ManagerIP, TrapUdp, 
		       AgentIP, AgentUDP, SysName) 
  when list(Dir), list(Vsns), list(ManagerIP), integer(TrapUdp), 
       list(AgentIP), integer(AgentUDP), list(SysName) ->
    write_agent_snmp_files(Dir, Vsns, ManagerIP, TrapUdp, AgentIP, AgentUDP,
			   SysName, "trap", none, "", "agentEngine", 484).

%% 
%% ----- Agent config files generator functions -----
%% 

write_agent_snmp_files(Dir, Vsns, ManagerIP, TrapUdp, AgentIP, AgentUDP, 
		       SysName, NotifType, SecType, Passwd, EngineID, MMS) ->
    write_agent_snmp_conf(Dir, AgentIP, AgentUDP, EngineID, MMS),
    write_agent_snmp_context_conf(Dir),
    write_agent_snmp_community_conf(Dir),
    write_agent_snmp_standard_conf(Dir, SysName),
    write_agent_snmp_target_addr_conf(Dir, ManagerIP, TrapUdp, Vsns),
    write_agent_snmp_target_params_conf(Dir, Vsns),
    write_agent_snmp_notify_conf(Dir, NotifType),
    write_agent_snmp_usm_conf(Dir, Vsns, EngineID, SecType, Passwd),
    write_agent_snmp_vacm_conf(Dir, Vsns, SecType),
    ok.


%% 
%% ------ agent.conf ------
%% 

write_agent_snmp_conf(Dir, AgentIP, AgentUDP, EngineID, MMS) -> 
    Comment = 
"%% This file defines the Agent local configuration info\n"
"%% The data is inserted into the snmpEngine* variables defined\n"
"%% in SNMP-FRAMEWORK-MIB, and the intAgent* variables defined\n"
"%% in OTP-SNMPEA-MIB.\n"
"%% Each row is a 2-tuple:\n"
"%% {AgentVariable, Value}.\n"
"%% For example\n"
"%% {intAgentUDPPort, 4000}.\n"
"%% The ip address for the agent is sent as id in traps.\n"
"%% {intAgentIpAddress, [127,42,17,5]}.\n"
"%% {snmpEngineID, \"agentEngine\"}.\n"
"%% {snmpEngineMaxMessageSize, 484}.\n"
"%%\n\n",
    Hdr = header() ++ Comment, 
    Conf = [{intAgentUDPPort,          AgentUDP}, 
	    {intAgentIpAddress,        AgentIP},
	    {snmpEngineID,             EngineID},
	    {snmpEngineMaxMessageSize, MMS}],
    write_agent_config(Dir, Hdr, Conf).

write_agent_config(Dir, Hdr, Conf) 
  when list(Dir), list(Hdr), list(Conf) ->
    Verify = fun()    -> verify_agent_conf(Conf)           end,
    Write  = fun(Fid) -> write_agent_conf(Fid, Hdr, Conf)  end,
    write_config_file(Dir, "agent.conf", Verify, Write).
    
verify_agent_conf([]) ->
    ok;
verify_agent_conf([H|T]) ->
    snmp_framework_mib:check_agent(H),
    verify_agent_conf(T);
verify_agent_conf(X) ->
    throw({error, {invalid_agent_conf, X}}).

write_agent_conf(Fid, "", Conf) ->
    write_agent_conf(Fid, Conf);
write_agent_conf(Fid, Hdr, Conf) ->
    io:format(Fid, "~s~n", [Hdr]),
    write_agent_conf(Fid, Conf).

write_agent_conf(_Fid, []) ->
    ok;
write_agent_conf(Fid, [H|T]) ->
    do_write_agent_conf(Fid, H),
    write_agent_conf(Fid, T).

do_write_agent_conf(Fid, {intAgentIpAddress = Tag, Val}) ->
    io:format(Fid, "{~w, ~w}.~n", [Tag, Val]);
do_write_agent_conf(Fid,{intAgentUDPPort = Tag, Val} ) ->
    io:format(Fid, "{~w, ~w}.~n", [Tag, Val]);
do_write_agent_conf(Fid,{intAgentMaxPacketSize = Tag, Val} ) ->
    io:format(Fid, "{~w, ~w}.~n", [Tag, Val]);
do_write_agent_conf(Fid,{snmpEngineMaxMessageSize = Tag, Val} ) ->
    io:format(Fid, "{~w, ~w}.~n", [Tag, Val]);
do_write_agent_conf(Fid,{snmpEngineID = Tag, Val} ) ->
    io:format(Fid, "{~w, \"~s\"}.~n", [Tag, Val]).


%% 
%% ------ context.conf ------
%% 

write_agent_snmp_context_conf(Dir) ->
    Comment = 
"%% This file defines the contexts known to the agent.\n"
"%% The data is inserted into the vacmContextTable defined\n"
"%% in SNMP-VIEW-BASED-ACM-MIB.\n"
"%% Each row is a string:\n"
"%% ContextName.\n"
"%%\n"
"%% The empty string is the default context.\n"
"%% For example\n"
"%% \"bridge1\".\n"
"%% \"bridge2\".\n"
"%%\n\n",
    Hdr = header() ++ Comment,
    Conf = [""],
    write_agent_context_config(Dir, Hdr, Conf).

write_agent_context_config(Dir, Hdr, Conf) 
  when list(Dir), list(Hdr), list(Conf) ->
    Verify = fun()    -> verify_agent_context_conf(Conf)           end,
    Write  = fun(Fid) -> write_agent_context_conf(Fid, Hdr, Conf)  end,
    write_config_file(Dir, "context.conf", Verify, Write).

verify_agent_context_conf([]) ->
    ok;
verify_agent_context_conf([H|T]) ->
    snmp_framework_mib:check_context(H),
    verify_agent_context_conf(T);
verify_agent_context_conf(X) ->
    throw({error, {invalid_context_conf, X}}).

write_agent_context_conf(Fid, "", Conf) ->
    write_agent_context_conf(Fid, Conf);
write_agent_context_conf(Fid, Hdr, Conf) ->
    io:format(Fid, "~s~n", [Hdr]),
    write_agent_context_conf(Fid, Conf).
    
write_agent_context_conf(_Fid, []) ->
    ok;
write_agent_context_conf(Fid, [H|T]) ->
    io:format(Fid, "\"~s\".~n", [H]),
    write_agent_context_conf(Fid, T);
write_agent_context_conf(_Fid, X) ->
    throw({error, {invalid_context_conf, X}}).

    
%% 
%% ------ community.conf ------
%% 

write_agent_snmp_community_conf(Dir) ->
    Comment = 
"%% This file defines the community info which maps to VACM parameters.\n"
"%% The data is inserted into the snmpCommunityTable defined\n"
"%% in SNMP-COMMUNITY-MIB.\n"
"%% Each row is a 5-tuple:\n"
"%% {CommunityIndex, CommunityName, SecurityName, ContextName, TransportTag}.\n"
"%% For example\n"
"%% {\"1\", \"public\", \"initial\", \"\", \"\"}.\n"
"%% {\"2\", \"secret\", \"secret_name\", \"\", \"tag\"}.\n"
"%% {\"3\", \"bridge1\", \"initial\", \"bridge1\", \"\"}.\n"
"%%\n\n",
    Hdr = header() ++ Comment,
    Conf = [{"public", "public", "initial", "", ""}, 
	    {"all-rights", "all-rights", "all-rights", "", ""}, 
	    {"standard trap", "standard trap", "initial", "", ""}], 
    write_agent_community_config(Dir, Hdr, Conf).

write_agent_community_config(Dir, Hdr, Conf)
  when list(Dir), list(Hdr), list(Conf) ->
    Verify = fun()    -> verify_agent_community_conf(Conf)           end,
    Write  = fun(Fid) -> write_agent_community_conf(Fid, Hdr, Conf)  end,
    write_config_file(Dir, "community.conf", Verify, Write).

verify_agent_community_conf([]) ->
    ok;
verify_agent_community_conf([H|T]) ->
    snmp_community_mib:check_community(H),
    verify_agent_community_conf(T);
verify_agent_community_conf(X) ->
    throw({error, {invalid_community_conf, X}}).

write_agent_community_conf(Fid, "", Conf) ->
    write_agent_community_conf(Fid, Conf);
write_agent_community_conf(Fid, Hdr, Conf) ->
    io:format(Fid, "~s~n", [Hdr]),
    write_agent_community_conf(Fid, Conf).

write_agent_community_conf(_Fid, []) ->
    ok;
write_agent_community_conf(Fid, [H|T]) ->
    do_write_agent_community_conf(Fid, H),
    write_agent_community_conf(Fid, T).

do_write_agent_community_conf(Fid, 
			      {Idx, Name, SecName, CtxName, TranspTag}) ->
    io:format(Fid, "{\"~s\", \"~s\", \"~s\", \"~s\", \"~s\"}.~n", 
	      [Idx, Name, SecName, CtxName, TranspTag]).
    

%% 
%% ------ standard.conf ------
%% 

write_agent_snmp_standard_conf(Dir, SysName) ->
    Comment = 
"%% This file defines the STANDARD-MIB info.\n"
"%% Each row is a 2-tuple:\n"
"%% {StandardVariable, Value}.\n"
"%% For example\n"
"%% {sysDescr, \"Erlang SNMP agent\"}.\n"
"%% {sysObjectID, [1,2,3]}.\n"
"%% {sysContact, \"{mbj,eklas}@erlang.ericsson.se\"}.\n"
"%% {sysName, \"test\"}.\n"
"%% {sysLocation, \"erlang\"}.\n"
"%% {sysServices, 72}.\n"
"%% {snmpEnableAuthenTraps, enabled}.\n"
"%%\n\n",
    Hdr = header() ++ Comment,
    Conf = [{sysDescr,              "Erlang SNMP agent"},
	    {sysObjectID,           [1,2,3]},
	    {sysContact,            "{mbj,eklas}@erlang.ericsson.se"},
	    {sysLocation,           "erlang"}, 
	    {sysServices,           72}, 
	    {snmpEnableAuthenTraps, enabled},
	    {sysName,               SysName}],
    write_agent_standard_config(Dir, Hdr, Conf).

write_agent_standard_config(Dir, Hdr, Conf) 
  when list(Dir), list(Hdr), list(Conf) ->
    Verify = fun()    -> verify_agent_standard_conf(Conf)           end,
    Write  = fun(Fid) -> write_agent_standard_conf(Fid, Hdr, Conf)  end,
    write_config_file(Dir, "standard.conf", Verify, Write).

verify_agent_standard_conf([]) ->
    ok;
verify_agent_standard_conf([H|T]) ->
    snmp_standard_mib:check_standard(H),
    verify_agent_standard_conf(T);
verify_agent_standard_conf(X) ->
    throw({error, {invalid_standard_conf, X}}).

write_agent_standard_conf(Fid, "", Conf) ->
    write_agent_standard_conf(Fid, Conf);
write_agent_standard_conf(Fid, Hdr, Conf) ->
    io:format(Fid, "~s~n", [Hdr]),
    write_agent_standard_conf(Fid, Conf).

write_agent_standard_conf(_Fid, []) ->
    ok;
write_agent_standard_conf(Fid, [H|T]) ->
    do_write_agent_standard_conf(Fid, H),
    write_agent_standard_conf(Fid, T).

do_write_agent_standard_conf(Fid, {sysDescr = Tag,    Val}) -> 
    io:format(Fid, "{~w, \"~s\"}.~n", [Tag, Val]);
do_write_agent_standard_conf(Fid, {sysObjectID = Tag, Val}) -> 
    io:format(Fid, "{~w, ~w}.~n", [Tag, Val]);
do_write_agent_standard_conf(Fid, {sysContact = Tag,  Val}) -> 
    io:format(Fid, "{~w, \"~s\"}.~n", [Tag, Val]);
do_write_agent_standard_conf(Fid, {sysName = Tag,     Val}) -> 
    io:format(Fid, "{~w, \"~s\"}.~n", [Tag, Val]);
do_write_agent_standard_conf(Fid, {sysLocation = Tag, Val}) -> 
    io:format(Fid, "{~w, \"~s\"}.~n", [Tag, Val]);
do_write_agent_standard_conf(Fid, {sysServices = Tag, Val}) -> 
    io:format(Fid, "{~w, ~w}.~n", [Tag, Val]);
do_write_agent_standard_conf(Fid, {snmpEnableAuthenTraps = Tag, Val}) ->
    io:format(Fid, "{~w, ~w}.~n", [Tag, Val]).


%% 
%% ------ target_addr.conf ------
%% 

write_agent_snmp_target_addr_conf(Dir, ManagerIp, UDP, Vsns) -> 
    Comment = 
"%% This file defines the target address parameters.\n"
"%% The data is inserted into the snmpTargetAddrTable defined\n"
"%% in SNMP-TARGET-MIB, and in the snmpTargetAddrExtTable defined\n"
"%% in SNMP-COMMUNITY-MIB.\n"
"%% Each row is a 9-tuple:\n"
"%% {Name, Ip, Udp, Timeout, RetryCount, TagList, ParamsName, EngineId,\n"
"%%        TMask, MaxMessageSize}.\n"
"%% The EngineId value is only used if Inform-Requests are sent to this\n"
"%% target.  If Informs are not sent, this value is ignored, and can be\n"
"%% e.g. an empty string.  However, if Informs are sent, it is essential\n"
"%% that the value of EngineId matches the value of the target's\n"
"%% actual snmpEngineID.\n"
"%% For example\n"
"%% {\"1.2.3.4 v1\", [1,2,3,4], 162, \n"
"%%  1500, 3, \"std_inform\", \"otp_v2\", \"\",\n"
"%%  [127,0,0,0],  2048}.\n"
"%%\n\n",
    Hdr = header() ++ Comment,
    Conf = [{mk_ip(ManagerIp, Vsn), ManagerIp, UDP, 
	     1500, 3, "std_trap", 
	     lists:flatten(io_lib:format("target_~w", [Vsn])), 
	     "", [], 2048} || Vsn <- Vsns], 
    write_agent_target_addr_config(Dir, Hdr, Conf).

mk_ip([A,B,C,D], Vsn) ->
    lists:flatten(io_lib:format("~w.~w.~w.~w ~w", [A,B,C,D,Vsn])).

write_agent_target_addr_config(Dir, Hdr, Conf) 
  when list(Dir), list(Hdr), list(Conf) ->
    Verify = fun()    -> verify_agent_target_addr_conf(Conf)           end,
    Write  = fun(Fid) -> write_agent_target_addr_conf(Fid, Hdr, Conf)  end,
    write_config_file(Dir, "target_addr.conf", Verify, Write).

verify_agent_target_addr_conf([]) ->
    ok;
verify_agent_target_addr_conf([H|T]) ->
    snmp_target_mib:check_target_addr(H),
    verify_agent_target_addr_conf(T);
verify_agent_target_addr_conf(X) ->
    throw({error, {invalid_target_addr_conf, X}}).

write_agent_target_addr_conf(Fid, "", Conf) ->
    write_agent_target_addr_conf(Fid, Conf);
write_agent_target_addr_conf(Fid, Hdr, Conf) ->
    io:format(Fid, "~s~n", [Hdr]),
    write_agent_target_addr_conf(Fid, Conf).

write_agent_target_addr_conf(_Fid, []) ->
    ok;
write_agent_target_addr_conf(Fid, [H|T]) ->
    do_write_agent_target_addr_conf(Fid, H),
    write_agent_target_addr_conf(Fid, T).

do_write_agent_target_addr_conf(Fid, 
				{Name, Ip, Udp, 
				 Timeout, RetryCount, TagList, 
				 ParamsName, EngineId,
				 TMask, MaxMessageSize}) ->
    io:format(Fid, "{\"~s\", ~w, ~w, ~w, ~w, ~w, \"~s\", \"~s\", ~w, ~w}.~n", 
	      [Name, Ip, Udp, Timeout, RetryCount, TagList, 
	       ParamsName, EngineId, TMask, MaxMessageSize]).


%% 
%% ------ target_params.conf ------
%% 

write_agent_snmp_target_params_conf(Dir, Vsns) -> 
    Comment = 
"%% This file defines the target parameters.\n"
"%% The data is inserted into the snmpTargetParamsTable defined\n"
"%% in SNMP-TARGET-MIB.\n"
"%% Each row is a 5-tuple:\n"
"%% {Name, MPModel, SecurityModel, SecurityName, SecurityLevel}.\n"
"%% For example\n"
"%% {\"target_v3\", v3, usm, \"\", noAuthNoPriv}.\n"
"%%\n\n",
    Hdr = header() ++ Comment,
    Conf = [fun(V) ->
		    MP = if V == v1 -> v1;
			    V == v2 -> v2c;
			    V == v3 -> v3
			 end,
		    SM = if V == v1 -> v1;
			    V == v2 -> v2c;
			    V == v3 -> usm
			 end,
		    Name = lists:flatten(
			     io_lib:format("target_~w", [V])),
		    {Name, MP, SM, "initial", noAuthNoPriv}
	    end(Vsn) || Vsn <- Vsns],
    write_agent_target_params_config(Dir, Hdr, Conf).

write_agent_target_params_config(Dir, Hdr, Conf) 
  when list(Dir), list(Hdr), list(Conf) ->
    Verify = fun()    -> verify_agent_target_params_conf(Conf)           end,
    Write  = fun(Fid) -> write_agent_target_params_conf(Fid, Hdr, Conf)  end,
    write_config_file(Dir, "target_params.conf", Verify, Write).

verify_agent_target_params_conf([]) ->
    ok;
verify_agent_target_params_conf([H|T]) ->
    snmp_target_mib:check_target_params(H),
    verify_agent_target_params_conf(T);
verify_agent_target_params_conf(X) ->
    throw({error, {invalid_target_params_conf, X}}).

write_agent_target_params_conf(Fid, "", Conf) ->
    write_agent_target_params_conf(Fid, Conf);
write_agent_target_params_conf(Fid, Hdr, Conf) ->
    io:format(Fid, "~s~n", [Hdr]),
    write_agent_target_params_conf(Fid, Conf).

write_agent_target_params_conf(_Fid, []) ->
    ok;
write_agent_target_params_conf(Fid, [H|T]) ->
    do_write_agent_target_params_conf(Fid, H),
    write_agent_target_params_conf(Fid, T).

do_write_agent_target_params_conf(Fid, 
				  {Name, MpModel, 
				   SecModel, SecName, SecLevel}) ->
    io:format(Fid, "{\"~s\", ~w, ~w, \"~s\", ~w}.~n", 
	      [Name, MpModel, SecModel, SecName, SecLevel]).


%% 
%% ------ notify.conf ------
%% 

write_agent_snmp_notify_conf(Dir, NotifyType) -> 
    Comment = 
"%% This file defines the notification parameters.\n"
"%% The data is inserted into the snmpNotifyTable defined\n"
"%% in SNMP-NOTIFICATION-MIB.\n"
"%% The Name is used as CommunityString for v1 and v2c.\n"
"%% Each row is a 3-tuple:\n"
"%% {Name, Tag, Type}.\n"
"%% For example\n"
"%% {\"standard trap\", \"std_trap\", trap}.\n"
"%% {\"standard inform\", \"std_inform\", inform}.\n"
"%%\n\n",
    Hdr = header() ++ Comment, 
    Conf = [{"stadard_trap", "std_trap", NotifyType}],
    write_agent_notify_config(Dir, Hdr, Conf).

write_agent_notify_config(Dir, Hdr, Conf) 
  when list(Dir), list(Hdr), list(Conf) ->
    Verify = fun()    -> verify_agent_notify_conf(Conf)           end,
    Write  = fun(Fid) -> write_agent_notify_conf(Fid, Hdr, Conf)  end,
    write_config_file(Dir, "notify.conf", Verify, Write).

verify_agent_notify_conf([]) ->
    ok;
verify_agent_notify_conf([H|T]) ->
    snmp_notification_mib:check_notify(H),
    verify_agent_notify_conf(T);
verify_agent_notify_conf(X) ->
    throw({error, {invalid_notify_conf, X}}).

write_agent_notify_conf(Fid, "", Conf) ->
    write_agent_notify_conf(Fid, Conf);
write_agent_notify_conf(Fid, Hdr, Conf) ->
    io:format(Fid, "~s~n", [Hdr]),
    write_agent_notify_conf(Fid, Conf).

write_agent_notify_conf(_Fid, []) ->
    ok;
write_agent_notify_conf(Fid, [H|T]) ->
    do_write_agent_notify_conf(Fid, H),
    write_agent_notify_conf(Fid, T).

do_write_agent_notify_conf(Fid, {Name, Tag, Type}) ->
    io:format(Fid, "{\"~s\", \"~s\", ~w}.~n", [Name, Tag, Type]).


%% 
%% ------ usm.conf ------
%% 

write_agent_snmp_usm_conf(Dir, Vsns, EngineID, SecType, Passwd) -> 
    case lists:member(v3, Vsns) of
	false -> ok;
	true -> write_agent_snmp_usm_conf(Dir, EngineID, SecType, Passwd)
    end.

write_agent_snmp_usm_conf(Dir, EngineID, SecType, Passwd) -> 
    Comment = 
"%% This file defines the security parameters for the user-based\n"
"%% security model.\n"
"%% The data is inserted into the usmUserTable defined\n"
"%% in SNMP-USER-BASED-SM-MIB.\n"
"%% Each row is a 14-tuple:\n"
"%% {EngineID, UserName, SecName, Clone, AuthP, AuthKeyC, OwnAuthKeyC,\n"
"%%  PrivP, PrivKeyC, OwnPrivKeyC, Public, AuthKey, PrivKey}.\n"
"%% For example\n"
"%% {\"agentEngine\", \"initial\", \"initial\", zeroDotZero,\n"
"%%  usmNoAuthProtocol, \"\", \"\", usmNoPrivProtocol, \"\", \"\", \"\",\n"
"%%  \"\", \"\"}.\n"
"%%\n\n",
    Hdr = header() ++ Comment,
    Conf = write_agent_snmp_usm_conf2(EngineID, SecType, Passwd),
    write_agent_usm_config(Dir, Hdr, Conf).

write_agent_snmp_usm_conf2(EngineID, none, _Passwd) ->
    [{EngineID, "initial", "initial", zeroDotZero, 
      usmNoAuthProtocol, "", "", 
      usmNoPrivProtocol, "", "", 
      "", "", ""}];
write_agent_snmp_usm_conf2(EngineID, SecType, Passwd) ->
    Secret16 = agent_snmp_mk_secret(md5, Passwd, EngineID),
    Secret20 = agent_snmp_mk_secret(sha, Passwd, EngineID),
    {PrivProt, PrivSecret} = 
	case SecType of
	    minimum ->
		{usmNoPrivProtocol, ""};
	    semi ->
		{usmDESPrivProtocol, Secret16}
	end,
    [{EngineID, "initial", "initial", zeroDotZero, 
      usmHMACMD5AuthProtocol, "", "", 
      PrivProt, "", "", 
      "", Secret16, PrivSecret},
     
     {EngineID, "templateMD5", "templateMD5", zeroDotZero, 
      usmHMACMD5AuthProtocol, "", "", 
      PrivProt, "", "", 
      "", Secret16, PrivSecret}, 

     {EngineID, "templateSHA", "templateSHA", zeroDotZero, 
      usmHMACSHAAuthProtocol, "", "", 
      PrivProt, "", "", 
      "", Secret20, PrivSecret}].

write_agent_usm_config(Dir, Hdr, UsmConf) 
  when list(Dir), list(Hdr), list(UsmConf) ->
    ensure_started(crypto),
    Verify = fun()    -> verify_usm(UsmConf)          end, 
    Write  = fun(Fid) -> write_usm(Fid, Hdr, UsmConf) end, 
    write_config_file(Dir, "usm.conf", Verify, Write).

verify_usm([]) ->
    ok;
verify_usm([H|T]) ->
    snmp_user_based_sm_mib:check_usm(H),
    verify_usm(T);
verify_usm(X) ->
    throw({error, {invalid_usm, X}}).

write_usm(Fid, "", Conf) ->
    write_usm(Fid, Conf);
write_usm(Fid, Hdr, Conf) ->
    io:format(Fid, "~s~n", [Hdr]),
    write_usm(Fid, Conf).

write_usm(_Fid, []) ->
    ok;
write_usm(Fid, [H|T]) ->
    do_write_usm(Fid, H),
    write_usm(Fid, T).

do_write_usm(Fid, 
	     {EngineID, UserName, SecName, Clone, 
	      AuthP, AuthKeyC, OwnAuthKeyC,
	      PrivP, PrivKeyC, OwnPrivKeyC, 
	      Public, AuthKey, PrivKey}) ->
    io:format(Fid, "{", []),
    io:format(Fid, "\"~s\", ", [EngineID]),
    io:format(Fid, "\"~s\", ", [UserName]),
    io:format(Fid, "\"~s\", ", [SecName]),
    io:format(Fid, "~w, ",     [Clone]),
    io:format(Fid, "~w, ",     [AuthP]),
    do_write_usm2(Fid, AuthKeyC, ", "), 
    do_write_usm2(Fid, OwnAuthKeyC, ", "),
    io:format(Fid, "~w, ",     [PrivP]),
    do_write_usm2(Fid, PrivKeyC, ", "),
    do_write_usm2(Fid, OwnPrivKeyC, ", "),
    do_write_usm2(Fid, Public, ", "),
    do_write_usm2(Fid, AuthKey, ", "),
    do_write_usm2(Fid, PrivKey, ""),
    io:format(Fid, "}.~n", []).

do_write_usm2(Fid, "", P) ->
    io:format(Fid, "\"\"~s", [P]);
do_write_usm2(Fid, X, P) ->
    io:format(Fid, "~w~s", [X, P]).


%% 
%% ------ vacm.conf ------
%% 

write_agent_snmp_vacm_conf(Dir, Vsns, SecType) ->
    Comment = 
"%% This file defines the Mib Views.\n"
"%% The data is inserted into the vacm* tables defined\n"
"%% in SNMP-VIEW-BASED-ACM-MIB.\n"
"%% Each row is one of 3 tuples; one for each table in the MIB:\n"
"%% {vacmSecurityToGroup, SecModel, SecName, GroupName}.\n"
"%% {vacmAccess, GroupName, Prefix, SecModel, SecLevel, Match, RV, WV, NV}.\n"
"%% {vacmViewTreeFamily, ViewIndex, ViewSubtree, ViewStatus, ViewMask}.\n"
"%% For example\n"
"%% {vacmSecurityToGroup, v2c, \"initial\", \"initial\"}.\n"
"%% {vacmSecurityToGroup, usm, \"initial\", \"initial\"}.\n"
"%%  read/notify access to system\n"
"%% {vacmAccess, \"initial\", \"\", any, noAuthNoPriv, exact,\n"
"%%              \"system\", \"\", \"system\"}.\n"
"%% {vacmViewTreeFamily, \"system\", [1,3,6,1,2,1,1], included, null}.\n"
"%% {vacmViewTreeFamily, \"exmib\", [1,3,6,1,3], included, null}."
" % for EX1-MIB\n"
"%% {vacmViewTreeFamily, \"internet\", [1,3,6,1], included, null}.\n"
"%%\n\n",
    Hdr = lists:flatten(header()) ++ Comment,
    Groups = 
	lists:foldl(
	  fun(V, Acc) ->
		  [{vacmSecurityToGroup, vacm_ver(V), 
		    "initial",    "initial"},
		   {vacmSecurityToGroup, vacm_ver(V), 
		    "all-rights", "all-rights"}|
		   Acc]
	  end, [], Vsns),
    Acc = 
	[{vacmAccess, "initial", "", any, noAuthNoPriv, exact, 
	  "restricted", "", "restricted"}, 
	 {vacmAccess, "initial", "", usm, authNoPriv, exact, 
	  "internet", "internet", "internet"}, 
	 {vacmAccess, "initial", "", usm, authPriv, exact, 
	  "internet", "internet", "internet"}, 
	 {vacmAccess, "all-rights", "", any, noAuthNoPriv, exact, 
	  "internet", "internet", "internet"}],
    VTF0 = 
	case SecType of
	    none ->
		[{vacmViewTreeFamily, 
		  "restricted", [1,3,6,1], included, null}];
	    minimum ->
		[{vacmViewTreeFamily, 
		  "restricted", [1,3,6,1], included, null}];
	    semi ->
		[{vacmViewTreeFamily, 
		  "restricted", [1,3,6,1,2,1,1], included, null},
		 {vacmViewTreeFamily, 
		  "restricted", [1,3,6,1,2,1,11], included, null},
		 {vacmViewTreeFamily, 
		  "restricted", [1,3,6,1,6,3,10,2,1], included, null},
		 {vacmViewTreeFamily, 
		  "restricted", [1,3,6,1,6,3,11,2,1], included, null},
		 {vacmViewTreeFamily, 
		  "restricted", [1,3,6,1,6,3,15,1,1], included, null}]
	end,
    VTF = VTF0 ++ [{vacmViewTreeFamily,"internet",[1,3,6,1],included,null}],
    write_agent_vacm_config(Dir, Hdr, Groups ++ Acc ++ VTF).

write_agent_vacm_config(Dir, Hdr, VacmConf) 
  when list(Dir), list(Hdr), list(VacmConf) ->
    Verify = fun()    -> verify_vacm(VacmConf)          end, 
    Write  = fun(Fid) -> write_vacm(Fid, Hdr, VacmConf) end, 
    write_config_file(Dir, "vacm.conf", Verify, Write).

verify_vacm([]) ->
    ok;
verify_vacm([H|T]) ->
    snmp_view_based_acm_mib:check_vacm(H),
    verify_vacm(T);
verify_vacm(X) ->
    throw({error, {invalid_vacm, X}}).

write_vacm(Fid, "", Conf) ->
    write_vacm(Fid, Conf);
write_vacm(Fid, Hdr, Conf) ->
    io:format(Fid, "~s~n", [Hdr]),
    write_vacm(Fid, Conf).

write_vacm(_Fid, []) ->
    ok;
write_vacm(Fid, [H|T]) ->
    do_write_vacm(Fid, H),
    write_vacm(Fid, T).

do_write_vacm(Fid, 
	      {vacmSecurityToGroup, 
	       SecModel, SecName, GroupName}) ->
    io:format(Fid, "{vacmSecurityToGroup, ~w, \"~s\", \"~s\"}.~n", 
	      [SecModel, SecName, GroupName]);
do_write_vacm(Fid, 
	      {vacmAccess, 
	       GroupName, Prefix, SecModel, SecLevel, Match, RV, WV, NV}) ->
    io:format(Fid, "{vacmAccess, \"~s\", \"~s\", ~w, ~w, ~w, "
	      "\"~s\", \"~s\", \"~s\"}.~n", 
	      [GroupName, Prefix, SecModel, SecLevel, 
	       Match, RV, WV, NV]);
do_write_vacm(Fid, 
	      {vacmViewTreeFamily, 
	       ViewIndex, ViewSubtree, ViewStatus, ViewMask}) ->
    io:format(Fid, "{vacmViewTreeFamily, \"~s\", ~w, ~w, ~w}.~n", 
	      [ViewIndex, ViewSubtree, ViewStatus, ViewMask]).

vacm_ver(v1) -> v1;
vacm_ver(v2) -> v2c;
vacm_ver(v3) -> usm.
     

%% 
%% ----- Manager config files generator functions -----
%% 

write_manager_snmp_files(Dir, IP, Port, MMS, EngineID, 
			 Users, Agents, Usms) ->
    write_manager_snmp_conf(Dir, IP, Port, MMS, EngineID),
    write_manager_snmp_users_conf(Dir, Users),
    write_manager_snmp_agents_conf(Dir, Agents),
    write_manager_snmp_usm_conf(Dir, Usms),  
    ok.


%% 
%% ------ manager.conf ------
%% 

write_manager_snmp_conf(Dir, IP, Port, MMS, EngineID) -> 
    Comment = 
"%% This file defines the Manager local configuration info\n"
"%% Each row is a 2-tuple:\n"
"%% {Variable, Value}.\n"
"%% For example\n"
"%% {port,             5000}.\n"
"%% {address,          [127,42,17,5]}.\n"
"%% {engine_id,        \"agentEngine\"}.\n"
"%% {max_message_size, 484}.\n"
"%%\n\n",
    {ok, Fid} = file:open(filename:join(Dir,"manager.conf"),write),
    ok = io:format(Fid, 
		   "~s~s\n"
		   "{port,             ~w}.\n"
		   "{address,          ~w}.\n"
		   "{engine_id,        \"~s\"}.\n"
		   "{max_message_size, ~w}.\n",
		   [header(), Comment, Port, IP, EngineID, MMS]),
    file:close(Fid).

write_manager_snmp_conf2(Dir, IP, Port, MMS, EngineID) -> 
    Comment = 
"%% This file defines the Manager local configuration info\n"
"%% Each row is a 2-tuple:\n"
"%% {Variable, Value}.\n"
"%% For example\n"
"%% {port,             5000}.\n"
"%% {address,          [127,42,17,5]}.\n"
"%% {engine_id,        \"managerEngine\"}.\n"
"%% {max_message_size, 484}.\n"
"%%\n\n",
    Hdr = header() ++ Comment,
    Conf = [{port,             Port}, 
            {address,          IP}, 
	    {engine_id,        EngineID}, 
	    {max_message_size, MMS}], 
    write_manager_config(Dir, Hdr, Conf).

write_manager_config(Dir, Hdr, Conf) 
  when list(Dir), list(Hdr), list(Conf) ->
    Verify = fun()    -> verify_manager_conf(Conf)           end,
    Write  = fun(Fid) -> write_manager_conf(Fid, Hdr, Conf)  end,
    write_config_file(Dir, "manager.conf", Verify, Write).
    
verify_manager_conf([]) ->
    ok;
verify_manager_conf([H|T]) ->
    snmpm_config:check_manager_config(H),
    verify_manager_conf(T);
verify_manager_conf(X) ->
    throw({error, {invalid_manager_conf, X}}).

write_manager_conf(Fid, "", Conf) ->
    write_manager_conf(Fid, Conf);
write_manager_conf(Fid, Hdr, Conf) ->
    io:format(Fid, "~s~n", [Hdr]),
    write_manager_conf(Fid, Conf).
    
write_manager_conf(_Fid, []) ->
    ok;
write_manager_conf(Fid, [H|T]) ->
    do_write_manager_conf(Fid, H),
    write_manager_conf(Fid, T).

do_write_manager_conf(Fid, {address = Tag, Val}) ->
    io:format(Fid, "{~w, ~w}.~n", [Tag, Val]);
do_write_manager_conf(Fid,{port = Tag, Val} ) ->
    io:format(Fid, "{~w, ~w}.~n", [Tag, Val]);
do_write_manager_conf(Fid,{engine_id = Tag, Val} ) ->
    io:format(Fid, "{~w, \"~s\"}.~n", [Tag, Val]);
do_write_manager_conf(Fid,{max_message_size = Tag, Val} ) ->
    io:format(Fid, "{~w, ~w}.~n", [Tag, Val]).


%% 
%% ------ users.conf ------
%% 

write_manager_snmp_users_conf(Dir, Users) ->
    Comment = 
"%% This file defines the users the manager handles\n"
"%% Each row is a 3-tuple:\n"
"%% {UserId, UserMod, UserData}.\n"
"%% For example\n"
"%% {kalle, kalle_callback_user_mod, \"dummy\"}.\n"
"%%\n\n",
    {ok, Fid} = file:open(filename:join(Dir,"users.conf"),write),
    ok = io:format(Fid, "~s~s", [header(),Comment]),
    F = fun({UserId, UserMod, UserData}) ->
		ok = io:format(Fid, "{~w, ~w, ~p}.~n", 
			       [UserId, UserMod, UserData])
	end,
    lists:foreach(F, Users),
    file:close(Fid).

write_manager_snmp_users_conf2(Dir, Users) ->
    Comment = 
"%% This file defines the users the manager handles\n"
"%% Each row is a 3-tuple:\n"
"%% {UserId, UserMod, UserData}.\n"
"%% For example\n"
"%% {kalle, kalle_callback_user_mod, \"dummy\"}.\n"
"%%\n\n",
    Hdr = header() ++ Comment,
    write_manager_users_config(Dir, Hdr, Users).

write_manager_users_config(Dir, Hdr, Users) 
  when list(Dir), list(Hdr), list(Users) ->
    Verify = fun()    -> verify_manager_users_conf(Users)          end,
    Write  = fun(Fid) -> write_manager_users_conf(Fid, Hdr, Users) end,
    write_config_file(Dir, "users.conf", Verify, Write).

verify_manager_users_conf([]) ->
    ok;
verify_manager_users_conf([H|T]) ->
    snmpm_config:check_user_config(H),
    verify_manager_users_conf(T);
verify_manager_users_conf(X) ->
    throw({error, {invalid_manager_users_conf, X}}).

write_manager_users_conf(Fid, "", Conf) ->
    write_manager_users_conf(Fid, Conf);
write_manager_users_conf(Fid, Hdr, Conf) ->
    io:format(Fid, "~s~n", [Hdr]),
    write_manager_users_conf(Fid, Conf).
    
write_manager_users_conf(_Fid, []) ->
    ok;
write_manager_users_conf(Fid, [H|T]) ->
    do_write_manager_users_conf(Fid, H),
    write_manager_users_conf(Fid, T).

do_write_manager_users_conf(Fid, {Id, Mod, Data}) ->
    io:format(Fid, "{~w, ~w, ~w}.~n", [Id, Mod, Data]).


%% 
%% ------ agents.conf ------
%% 

write_manager_snmp_agents_conf(Dir, Agents) ->
    Comment = 
"%% This file defines the agents the manager handles\n"
"%% Each row is a 12-tuple:\n"
"%% {UserId, \n"
"%%  TargetName, Comm, Ip, Port, EngineID, Timeout, \n"
"%%  MaxMessageSize, Version, SecModel, SecName, SecLevel}\n"
"%%\n\n",
    {ok, Fid} = file:open(filename:join(Dir,"agents.conf"),write),
    ok = io:format(Fid, "~s~s", [header(),Comment]),
    F = fun({UserId,
	     TargetName, Comm, Ip, Port, EngineID, Timeout, MMS,
	     Version, SecModel, SecName, SecLevel}) ->
		ok = io:format(Fid, 
			       "{~w, ~n"
			       " \"~s\", \"~s\", ~w, ~w, \"~s\", ~n"
			       " ~w, ~w, ~n"
			       " ~w, ~w, \"~s\", ~w}.~n", 
			       [UserId, 
				TargetName, Comm, Ip, Port, EngineID, 
				Timeout, MMS, 
				Version, SecModel, SecName, SecLevel])
	end,
    lists:foreach(F, Agents),
    file:close(Fid).

write_manager_snmp_agents_conf2(Dir, Agents) ->
    Comment = 
"%% This file defines the agents the manager handles\n"
"%% Each row is a 12-tuple:\n"
"%% {UserId, \n"
"%%  TargetName, Comm, Ip, Port, EngineID, Timeout, \n"
"%%  MaxMessageSize, Version, SecModel, SecName, SecLevel}\n"
"%%\n\n",
    Hdr = header() ++ Comment, 
    write_manager_agents_config(Dir, Hdr, Agents).

write_manager_agents_config(Dir, Hdr, Agents) 
  when list(Dir), list(Hdr), list(Agents) ->
    Verify = fun()    -> verify_manager_agents_conf(Agents)          end,
    Write  = fun(Fid) -> write_manager_agents_conf(Fid, Hdr, Agents) end,
    write_config_file(Dir, "agents.conf", Verify, Write).

verify_manager_agents_conf([]) ->
    ok;
verify_manager_agents_conf([H|T]) ->
    snmpm_config:check_agent_config(H),
    verify_manager_agents_conf(T);
verify_manager_agents_conf(X) ->
    throw({error, {invalid_manager_agents_conf, X}}).

write_manager_agents_conf(Fid, "", Conf) ->
    write_manager_agents_conf(Fid, Conf);
write_manager_agents_conf(Fid, Hdr, Conf) ->
    io:format(Fid, "~s~n", [Hdr]),
    write_manager_agents_conf(Fid, Conf).
    
write_manager_agents_conf(_Fid, []) ->
    ok;
write_manager_agents_conf(Fid, [H|T]) ->
    do_write_manager_agent_conf(Fid, H),
    write_manager_agents_conf(Fid, T).

do_write_manager_agent_conf(Fid, 
			    {UserId, 
			     TargetName, Comm, Ip, Port, EngineID, 
			     Timeout, MaxMessageSize, Version, 
			     SecModel, SecName, SecLevel} = A) ->
    io:format(Fid, "{~w, \"~s\", \"~s\", ~w, ~w, \"~s\", ~w, ~w, ~w, ~w, \"~s\", ~w}.~n", [UserId, TargetName, Comm, Ip, Port, EngineID, Timeout, MaxMessageSize, Version, SecModel, SecName, SecLevel]).


%% 
%% ------ usm.conf -----
%% 

write_manager_snmp_usm_conf(Dir, Usms) ->
    Comment = 
"%% This file defines the usm users the manager handles\n"
"%% Each row is a 6 or 7-tuple:\n"
"%% {EngineID, UserName, AuthP, AuthKey, PrivP, PrivKey}\n"
"%% {EngineID, UserName, SecName, AuthP, AuthKey, PrivP, PrivKey}\n"
"%%\n\n",
    {ok, Fid} = file:open(filename:join(Dir,"usm.conf"),write),
    ok = io:format(Fid, "~s~s", [header(),Comment]),
    F = fun({EngineID, UserName, SecName, AuthP, AuthKey, PrivP, PrivKey}) ->
		ok = io:format(Fid, 
			       "{\"~s\", \"~s\", \"~s\", ~n"
			       " ~w, ~w, ~n"
			       " ~w, ~w}.~n", 
			       [EngineID, UserName, SecName, 
				AuthP, AuthKey, PrivP, PrivKey])
	end,
    lists:foreach(F, Usms),
    file:close(Fid).

write_manager_snmp_usm_conf2(Dir, Usms) ->
    Comment = 
"%% This file defines the usm users the manager handles\n"
"%% Each row is a 6 or 7-tuple:\n"
"%% {EngineID, UserName, AuthP, AuthKey, PrivP, PrivKey}\n"
"%% {EngineID, UserName, SecName, AuthP, AuthKey, PrivP, PrivKey}\n"
"%%\n\n",
    Hdr = header() ++ Comment,
    write_manager_usm_config(Dir, Hdr, Usms).

write_manager_usm_config(Dir, Hdr, Users) 
  when list(Dir), list(Hdr), list(Users) ->
    Verify = fun()    -> verify_manager_usm_conf(Users)          end,
    Write  = fun(Fid) -> write_manager_usm_conf(Fid, Hdr, Users) end,
    write_config_file(Dir, "usm.conf", Verify, Write).

verify_manager_usm_conf([]) ->
    ok;
verify_manager_usm_conf([H|T]) ->
    snmpm_config:check_usm_user_config(H),
    verify_manager_usm_conf(T);
verify_manager_usm_conf(X) ->
    throw({error, {invalid_manager_usm_conf, X}}).

write_manager_usm_conf(Fid, "", Conf) ->
    write_manager_usm_conf(Fid, Conf);
write_manager_usm_conf(Fid, Hdr, Conf) ->
    io:format(Fid, "~s~n", [Hdr]),
    write_manager_usm_conf(Fid, Conf).
    
write_manager_usm_conf(_Fid, []) ->
    ok;
write_manager_usm_conf(Fid, [H|T]) ->
    do_write_manager_usm_conf(Fid, H),
    write_manager_usm_conf(Fid, T).

do_write_manager_usm_conf(Fid, 
			  {EngineID, UserName, 
			   AuthP, AuthKey, PrivP, PrivKey}) ->
    io:format(Fid, "{\"~s\", \"~s\", ~w, ~w, ~w, ~w}.~n", 
	      [EngineID, UserName, AuthP, AuthKey, PrivP, PrivKey]);
do_write_manager_usm_conf(Fid, 
			  {EngineID, UserName, SecName, 
			   AuthP, AuthKey, PrivP, PrivKey}) ->
    io:format(Fid, "{\"~s\", \"~s\", \"~s\", �~w, ~w, ~w, ~w}.~n", 
	      [EngineID, UserName, SecName, AuthP, AuthKey, PrivP, PrivKey]).


%% 
%% -------------------------------------------------------------------------
%% 

write_sys_config_file(Dir, Services) ->
    {ok, Fid} = file:open(filename:join(Dir,"sys.config"),write),
    ok = io:format(Fid, "~s", [header()]),
    ok = io:format(Fid, "[{snmp, ~n", []),
    ok = io:format(Fid, "  [~n", []),
    write_sys_config_file_services(Fid, Services),
    ok = io:format(Fid, "  ]~n", []),
    ok = io:format(Fid, " }~n", []),
    ok = io:format(Fid, "].~n", []),
    ok.

write_sys_config_file_services(Fid, [Service]) ->
    write_sys_config_file_service(Fid, Service),
    ok = io:format(Fid, "~n", []),
    ok;
write_sys_config_file_services(Fid, [Service|Services]) ->
    write_sys_config_file_service(Fid, Service),
    ok = io:format(Fid, ", ~n", []),
    write_sys_config_file_services(Fid, Services).

write_sys_config_file_service(Fid, {Service, Opts}) ->
    ok = io:format(Fid, "   {~w,~n", [Service]),
    ok = io:format(Fid, "    [~n", []),
    write_sys_config_file_service_opts(Fid, Service, Opts),
    ok = io:format(Fid, "    ]~n", []),
    ok = io:format(Fid, "   }", []),
    true.

write_sys_config_file_service_opts(Fid, agent, Opts) ->
    write_sys_config_file_agent_opts(Fid, Opts);
write_sys_config_file_service_opts(Fid, manager, Opts) ->
    write_sys_config_file_manager_opts(Fid, Opts).


write_sys_config_file_agent_opts(Fid, [Opt]) ->
    write_sys_config_file_agent_opt(Fid, Opt),
    ok = io:format(Fid, "~n", []),
    ok;
write_sys_config_file_agent_opts(Fid, [Opt|Opts]) ->
    write_sys_config_file_agent_opt(Fid, Opt),
    ok = io:format(Fid, ", ~n", []),
    write_sys_config_file_agent_opts(Fid, Opts).


write_sys_config_file_agent_opt(Fid, {mibs, []}) ->
    ok = io:format(Fid, "     {mibs, []}", []);
write_sys_config_file_agent_opt(Fid, {priority, Prio}) ->
    ok = io:format(Fid, "     {priority, ~w}", [Prio]);
write_sys_config_file_agent_opt(Fid, {error_report_mod, Mod}) ->
    ok = io:format(Fid, "     {error_report_mod, ~w}", [Mod]);
write_sys_config_file_agent_opt(Fid, {versions, Vsns}) ->
    ok = io:format(Fid, "     {versions, ~w}", [Vsns]);
write_sys_config_file_agent_opt(Fid, {multi_threaded, B}) ->
    ok = io:format(Fid, "     {multi_threaded, ~w}", [B]);
write_sys_config_file_agent_opt(Fid, {config, Opts}) ->
    ok = io:format(Fid, "     {config, [", []),
    write_sys_config_file_agent_config_opts(Fid, Opts),
    ok = io:format(Fid, "}", []);
write_sys_config_file_agent_opt(Fid, {db_dir, Dir}) ->
    ok = io:format(Fid, "     {db_dir, \"~s\"}", [Dir]);
write_sys_config_file_agent_opt(Fid, {mib_storage, ets}) ->
    ok = io:format(Fid, "     {mib_storage, ets}", []);
write_sys_config_file_agent_opt(Fid, {mib_storage, {dets, Dir}}) ->
    ok = io:format(Fid, "     {mib_storage, {dets, \"~s\"}}", [Dir]);
write_sys_config_file_agent_opt(Fid, {mib_storage, {dets, Dir, Act}}) ->
    ok = io:format(Fid, "     {mib_storage, {dets, \"~s\", ~w}}", 
		   [Dir, Act]);
write_sys_config_file_agent_opt(Fid, {mib_storage, {mnesia, Nodes}}) ->
    ok = io:format(Fid, "     {mib_storage, {mnesia, ~w}}", [Nodes]);
write_sys_config_file_agent_opt(Fid, {mib_storage, {mnesia, Nodes, Act}}) ->
    ok = io:format(Fid, "     {mib_storage, {mnesia, ~w, ~w}}", 
		   [Nodes, Act]);
write_sys_config_file_agent_opt(Fid, {local_db, Opts}) ->
    ok = io:format(Fid, "     {local_db, ~w}", [Opts]);
write_sys_config_file_agent_opt(Fid, {note_store, Opts}) ->
    ok = io:format(Fid, "     {note_store, ~w}", [Opts]);
write_sys_config_file_agent_opt(Fid, {symbolic_store, Opts}) ->
    ok = io:format(Fid, "     {symbolic_store, ~w}", [Opts]);
write_sys_config_file_agent_opt(Fid, {agent_type, Type}) ->
    ok = io:format(Fid, "     {agent_type, ~w}", [Type]);
write_sys_config_file_agent_opt(Fid, {agent_verbosity, Verb}) ->
    ok = io:format(Fid, "     {agent_verbosity, ~w}", [Verb]);
write_sys_config_file_agent_opt(Fid, {audit_trail_log, Opts}) ->
    ok = io:format(Fid, "     {audit_trail_log, [", []),
    write_sys_config_file_agent_atl_opts(Fid, Opts),
    ok = io:format(Fid, "}", []);
write_sys_config_file_agent_opt(Fid, {net_if, Opts}) ->
    ok = io:format(Fid, "     {net_if, ~w}", [Opts]);
write_sys_config_file_agent_opt(Fid, {mib_server, Opts}) ->
    ok = io:format(Fid, "     {mib_server, ~w}", [Opts]);
write_sys_config_file_agent_opt(Fid, {Key, Val}) ->
    ok = io:format(Fid, "     {~w, ~w}", [Key, Val]).
    

%% Mandatory option dir, means that this is never empty:
write_sys_config_file_agent_config_opts(Fid, [Opt]) ->
    write_sys_config_file_agent_config_opt(Fid, Opt),
    ok = io:format(Fid, "]", []),
    ok;
write_sys_config_file_agent_config_opts(Fid, [Opt|Opts]) ->
    write_sys_config_file_agent_config_opt(Fid, Opt),
    ok = io:format(Fid, ", ", []),
    write_sys_config_file_agent_config_opts(Fid, Opts).
    
write_sys_config_file_agent_config_opt(Fid, {dir, Dir}) ->
    ok = io:format(Fid, "{dir, \"~s\"}", [Dir]);
write_sys_config_file_agent_config_opt(Fid, {force_load, Bool}) ->
    ok = io:format(Fid, "{force_load, ~w}", [Bool]);
write_sys_config_file_agent_config_opt(Fid, {verbosity, Verb}) ->
    ok = io:format(Fid, "{verbosity, ~w}", [Verb]).


%% This is only present if there is atleast one option
write_sys_config_file_agent_atl_opts(Fid, [Opt]) ->
    write_sys_config_file_agent_atl_opt(Fid, Opt),
    ok = io:format(Fid, "]", []),
    ok;
write_sys_config_file_agent_atl_opts(Fid, [Opt|Opts]) ->
    write_sys_config_file_agent_atl_opt(Fid, Opt),
    ok = io:format(Fid, ", ", []),
    write_sys_config_file_agent_atl_opts(Fid, Opts).
    
write_sys_config_file_agent_atl_opt(Fid, {dir, Dir}) ->
    ok = io:format(Fid, "{dir, \"~s\"}", [Dir]);
write_sys_config_file_agent_atl_opt(Fid, {type, Type}) ->
    ok = io:format(Fid, "{type, ~w}", [Type]);
write_sys_config_file_agent_atl_opt(Fid, {size, Size}) ->
    ok = io:format(Fid, "{size, ~w}", [Size]);
write_sys_config_file_agent_atl_opt(Fid, {repair, Rep}) ->
    ok = io:format(Fid, "{repair, ~w}", [Rep]).


write_sys_config_file_manager_opts(Fid, [Opt]) ->
    write_sys_config_file_manager_opt(Fid, Opt),
    ok = io:format(Fid, "~n", []),
    ok;
write_sys_config_file_manager_opts(Fid, [Opt|Opts]) ->
    write_sys_config_file_manager_opt(Fid, Opt),
    ok = io:format(Fid, ", ~n", []),
    write_sys_config_file_manager_opts(Fid, Opts).


write_sys_config_file_manager_opt(Fid, {mibs, []}) ->
    ok = io:format(Fid, "     {mibs, []}", []);
write_sys_config_file_manager_opt(Fid, {priority, Prio}) ->
    ok = io:format(Fid, "     {priority, ~w}", [Prio]);
write_sys_config_file_manager_opt(Fid, {versions, Vsns}) ->
    ok = io:format(Fid, "     {versions, ~w}", [Vsns]);
write_sys_config_file_manager_opt(Fid, {config, Opts}) ->
    ok = io:format(Fid, "     {config, [", []),
    write_sys_config_file_manager_config_opts(Fid, Opts),
    ok = io:format(Fid, "}", []);
write_sys_config_file_manager_opt(Fid, {server, Opts}) ->
    ok = io:format(Fid, "     {server, ~w}", [Opts]);
write_sys_config_file_manager_opt(Fid, {note_store, Opts}) ->
    ok = io:format(Fid, "     {note_store, ~w}", [Opts]);
write_sys_config_file_manager_opt(Fid, {audit_trail_log, Opts}) ->
    ok = io:format(Fid, "     {audit_trail_log, [", []),
    write_sys_config_file_manager_atl_opts(Fid, Opts),
    ok = io:format(Fid, "}", []);
write_sys_config_file_manager_opt(Fid, {net_if, Opts}) ->
    ok = io:format(Fid, "     {net_if, ~w}", [Opts]);
write_sys_config_file_manager_opt(Fid, {Key, Val}) ->
    ok = io:format(Fid, "     {~w, ~w}", [Key, Val]).
    
%% Mandatory option dir, means that this is never empty:
write_sys_config_file_manager_config_opts(Fid, [Opt]) ->
    write_sys_config_file_manager_config_opt(Fid, Opt),
    ok = io:format(Fid, "]", []),
    ok;
write_sys_config_file_manager_config_opts(Fid, [Opt|Opts]) ->
    write_sys_config_file_manager_config_opt(Fid, Opt),
    ok = io:format(Fid, ", ", []),
    write_sys_config_file_manager_config_opts(Fid, Opts).
    
write_sys_config_file_manager_config_opt(Fid, {dir, Dir}) ->
    ok = io:format(Fid, "{dir, \"~s\"}", [Dir]);
write_sys_config_file_manager_config_opt(Fid, {db_dir, Dir}) ->
    ok = io:format(Fid, "{db_dir, \"~s\"}", [Dir]);
write_sys_config_file_manager_config_opt(Fid, {repair, Rep}) ->
    ok = io:format(Fid, "{repair, ~w}", [Rep]);
write_sys_config_file_manager_config_opt(Fid, {auto_save, As}) ->
    ok = io:format(Fid, "{auto_save, ~w}", [As]);
write_sys_config_file_manager_config_opt(Fid, {verbosity, Verb}) ->
    ok = io:format(Fid, "{verbosity, ~w}", [Verb]).


%% This is only present if there is atleast one option
write_sys_config_file_manager_atl_opts(Fid, [Opt]) ->
    write_sys_config_file_manager_atl_opt(Fid, Opt),
    ok = io:format(Fid, "]", []),
    ok;
write_sys_config_file_manager_atl_opts(Fid, [Opt|Opts]) ->
    write_sys_config_file_manager_atl_opt(Fid, Opt),
    ok = io:format(Fid, ", ", []),
    write_sys_config_file_manager_atl_opts(Fid, Opts).
    
write_sys_config_file_manager_atl_opt(Fid, {dir, Dir}) ->
    ok = io:format(Fid, "{dir, \"~s\"}", [Dir]);
write_sys_config_file_manager_atl_opt(Fid, {type, Type}) ->
    ok = io:format(Fid, "{type, ~w}", [Type]);
write_sys_config_file_manager_atl_opt(Fid, {size, Size}) ->
    ok = io:format(Fid, "{size, ~w}", [Size]);
write_sys_config_file_manager_atl_opt(Fid, {repair, Rep}) ->
    ok = io:format(Fid, "{repair, ~w}", [Rep]).


header() ->
    {Y,Mo,D} = date(),
    {H,Mi,S} = time(),
    io_lib:format("%% This file was generated by "
		  "snmp_config (version-~s) ~w-~2.2.0w-~2.2.0w "
		  "~2.2.0w:~2.2.0w:~2.2.0w\n",
		  [?version,Y,Mo,D,H,Mi,S]).


write_config_file(Dir, FileName, Verify, Write) 
  when list(Dir), list(FileName), function(Verify), function(Write) ->
    (catch do_write_config_file(Dir, FileName, Verify, Write)).

do_write_config_file(Dir, FileName, Verify, Write) ->
    Verify(),
    case file:open(filename:join(Dir, FileName),write) of
	{ok, Fid} ->
	    Write(Fid),
	    file:close(Fid),
	    ok;
	Error ->
	    Error
    end.


agent_snmp_mk_secret(Alg, Passwd, EngineID) ->
    snmp_usm:passwd2localized_key(Alg, Passwd, EngineID).


ensure_crypto_started() ->
    i("making sure crypto server is started..."),
    ensure_started(crypto).

ensure_started(App) ->
    case (catch App:start()) of
	ok ->
	    ok;
	{error, {already_started, App}} ->
	    ok;
	E ->
	    error({failed_starting, App, E})
    end.


%% -------------------------------------------------------------------------

% d(F, A) ->
%     i("DBG: " ++ F, A).

i(F) ->
    i(F, []).

i(F, A) ->
    io:format(F ++ "~n", A).

error(R) ->
    throw({error, R}).
