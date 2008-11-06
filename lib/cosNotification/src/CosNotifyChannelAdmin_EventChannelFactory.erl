%%------------------------------------------------------------
%%
%% Implementation stub file
%% 
%% Target: CosNotifyChannelAdmin_EventChannelFactory
%% Source: /ldisk/daily_build/otp_prebuild_r12b.2008-11-05_12/otp_src_R12B-5/lib/cosNotification/src/CosNotifyChannelAdmin.idl
%% IC vsn: 4.2.19
%% 
%% This file is automatically generated. DO NOT EDIT IT.
%%
%%------------------------------------------------------------

-module('CosNotifyChannelAdmin_EventChannelFactory').
-ic_compiled("4_2_19").


%% Interface functions
-export([create_channel/3, create_channel/4, get_all_channels/1]).
-export([get_all_channels/2, get_event_channel/2, get_event_channel/3]).

%% Type identification function
-export([typeID/0]).

%% Used to start server
-export([oe_create/0, oe_create_link/0, oe_create/1]).
-export([oe_create_link/1, oe_create/2, oe_create_link/2]).

%% TypeCode Functions and inheritance
-export([oe_tc/1, oe_is_a/1, oe_get_interface/0]).

%% gen server export stuff
-behaviour(gen_server).
-export([init/1, terminate/2, handle_call/3]).
-export([handle_cast/2, handle_info/2, code_change/3]).

-include_lib("orber/include/corba.hrl").


%%------------------------------------------------------------
%%
%% Object interface functions.
%%
%%------------------------------------------------------------



%%%% Operation: create_channel
%% 
%%   Returns: RetVal, Id
%%   Raises:  CosNotification::UnsupportedQoS, CosNotification::UnsupportedAdmin
%%
create_channel(OE_THIS, Initial_qos, Initial_admin) ->
    corba:call(OE_THIS, create_channel, [Initial_qos, Initial_admin], ?MODULE).

create_channel(OE_THIS, OE_Options, Initial_qos, Initial_admin) ->
    corba:call(OE_THIS, create_channel, [Initial_qos, Initial_admin], ?MODULE, OE_Options).

%%%% Operation: get_all_channels
%% 
%%   Returns: RetVal
%%
get_all_channels(OE_THIS) ->
    corba:call(OE_THIS, get_all_channels, [], ?MODULE).

get_all_channels(OE_THIS, OE_Options) ->
    corba:call(OE_THIS, get_all_channels, [], ?MODULE, OE_Options).

%%%% Operation: get_event_channel
%% 
%%   Returns: RetVal
%%   Raises:  CosNotifyChannelAdmin::ChannelNotFound
%%
get_event_channel(OE_THIS, Id) ->
    corba:call(OE_THIS, get_event_channel, [Id], ?MODULE).

get_event_channel(OE_THIS, OE_Options, Id) ->
    corba:call(OE_THIS, get_event_channel, [Id], ?MODULE, OE_Options).

%%------------------------------------------------------------
%%
%% Inherited Interfaces
%%
%%------------------------------------------------------------
oe_is_a("IDL:omg.org/CosNotifyChannelAdmin/EventChannelFactory:1.0") -> true;
oe_is_a(_) -> false.

%%------------------------------------------------------------
%%
%% Interface TypeCode
%%
%%------------------------------------------------------------
oe_tc(create_channel) -> 
	{{tk_objref,"IDL:omg.org/CosNotifyChannelAdmin/EventChannel:1.0",
                    "EventChannel"},
         [{tk_sequence,{tk_struct,"IDL:omg.org/CosNotification/Property:1.0",
                                  "Property",
                                  [{"name",{tk_string,0}},{"value",tk_any}]},
                       0},
          {tk_sequence,{tk_struct,"IDL:omg.org/CosNotification/Property:1.0",
                                  "Property",
                                  [{"name",{tk_string,0}},{"value",tk_any}]},
                       0}],
         [tk_long]};
oe_tc(get_all_channels) -> 
	{{tk_sequence,tk_long,0},[],[]};
oe_tc(get_event_channel) -> 
	{{tk_objref,"IDL:omg.org/CosNotifyChannelAdmin/EventChannel:1.0",
                    "EventChannel"},
         [tk_long],
         []};
oe_tc(_) -> undefined.

oe_get_interface() -> 
	[{"get_event_channel", oe_tc(get_event_channel)},
	{"get_all_channels", oe_tc(get_all_channels)},
	{"create_channel", oe_tc(create_channel)}].




%%------------------------------------------------------------
%%
%% Object server implementation.
%%
%%------------------------------------------------------------


%%------------------------------------------------------------
%%
%% Function for fetching the interface type ID.
%%
%%------------------------------------------------------------

typeID() ->
    "IDL:omg.org/CosNotifyChannelAdmin/EventChannelFactory:1.0".


%%------------------------------------------------------------
%%
%% Object creation functions.
%%
%%------------------------------------------------------------

oe_create() ->
    corba:create(?MODULE, "IDL:omg.org/CosNotifyChannelAdmin/EventChannelFactory:1.0").

oe_create_link() ->
    corba:create_link(?MODULE, "IDL:omg.org/CosNotifyChannelAdmin/EventChannelFactory:1.0").

oe_create(Env) ->
    corba:create(?MODULE, "IDL:omg.org/CosNotifyChannelAdmin/EventChannelFactory:1.0", Env).

oe_create_link(Env) ->
    corba:create_link(?MODULE, "IDL:omg.org/CosNotifyChannelAdmin/EventChannelFactory:1.0", Env).

oe_create(Env, RegName) ->
    corba:create(?MODULE, "IDL:omg.org/CosNotifyChannelAdmin/EventChannelFactory:1.0", Env, RegName).

oe_create_link(Env, RegName) ->
    corba:create_link(?MODULE, "IDL:omg.org/CosNotifyChannelAdmin/EventChannelFactory:1.0", Env, RegName).

%%------------------------------------------------------------
%%
%% Init & terminate functions.
%%
%%------------------------------------------------------------

init(Env) ->
%% Call to implementation init
    corba:handle_init('CosNotifyChannelAdmin_EventChannelFactory_impl', Env).

terminate(Reason, State) ->
    corba:handle_terminate('CosNotifyChannelAdmin_EventChannelFactory_impl', Reason, State).


%%%% Operation: create_channel
%% 
%%   Returns: RetVal, Id
%%   Raises:  CosNotification::UnsupportedQoS, CosNotification::UnsupportedAdmin
%%
handle_call({OE_THIS, OE_Context, create_channel, [Initial_qos, Initial_admin]}, OE_From, OE_State) ->
  corba:handle_call('CosNotifyChannelAdmin_EventChannelFactory_impl', create_channel, [Initial_qos, Initial_admin], OE_State, OE_Context, OE_THIS, OE_From);

%%%% Operation: get_all_channels
%% 
%%   Returns: RetVal
%%
handle_call({OE_THIS, OE_Context, get_all_channels, []}, OE_From, OE_State) ->
  corba:handle_call('CosNotifyChannelAdmin_EventChannelFactory_impl', get_all_channels, [], OE_State, OE_Context, OE_THIS, OE_From);

%%%% Operation: get_event_channel
%% 
%%   Returns: RetVal
%%   Raises:  CosNotifyChannelAdmin::ChannelNotFound
%%
handle_call({OE_THIS, OE_Context, get_event_channel, [Id]}, OE_From, OE_State) ->
  corba:handle_call('CosNotifyChannelAdmin_EventChannelFactory_impl', get_event_channel, [Id], OE_State, OE_Context, OE_THIS, OE_From);



%%%% Standard gen_server call handle
%%
handle_call(stop, _, State) ->
    {stop, normal, ok, State};

handle_call(_, _, State) ->
    {reply, catch corba:raise(#'BAD_OPERATION'{minor=1163001857, completion_status='COMPLETED_NO'}), State}.


%%%% Standard gen_server cast handle
%%
handle_cast(stop, State) ->
    {stop, normal, State};

handle_cast(_, State) ->
    {noreply, State}.


%%%% Standard gen_server handles
%%
handle_info(Info, State) ->
    corba:handle_info('CosNotifyChannelAdmin_EventChannelFactory_impl', Info, State).


code_change(OldVsn, State, Extra) ->
    corba:handle_code_change('CosNotifyChannelAdmin_EventChannelFactory_impl', OldVsn, State, Extra).

