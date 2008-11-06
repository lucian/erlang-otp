%%------------------------------------------------------------
%%
%% Implementation stub file
%% 
%% Target: CosEventChannelAdmin_ConsumerAdmin
%% Source: /ldisk/daily_build/otp_prebuild_r12b.2008-11-05_12/otp_src_R12B-5/lib/cosEvent/src/CosEventChannelAdmin.idl
%% IC vsn: 4.2.19
%% 
%% This file is automatically generated. DO NOT EDIT IT.
%%
%%------------------------------------------------------------

-module('CosEventChannelAdmin_ConsumerAdmin').
-ic_compiled("4_2_19").


%% Interface functions
-export([obtain_push_supplier/1, obtain_push_supplier/2, obtain_pull_supplier/1]).
-export([obtain_pull_supplier/2]).

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



%%%% Operation: obtain_push_supplier
%% 
%%   Returns: RetVal
%%
obtain_push_supplier(OE_THIS) ->
    corba:call(OE_THIS, obtain_push_supplier, [], ?MODULE).

obtain_push_supplier(OE_THIS, OE_Options) ->
    corba:call(OE_THIS, obtain_push_supplier, [], ?MODULE, OE_Options).

%%%% Operation: obtain_pull_supplier
%% 
%%   Returns: RetVal
%%
obtain_pull_supplier(OE_THIS) ->
    corba:call(OE_THIS, obtain_pull_supplier, [], ?MODULE).

obtain_pull_supplier(OE_THIS, OE_Options) ->
    corba:call(OE_THIS, obtain_pull_supplier, [], ?MODULE, OE_Options).

%%------------------------------------------------------------
%%
%% Inherited Interfaces
%%
%%------------------------------------------------------------
oe_is_a("IDL:omg.org/CosEventChannelAdmin/ConsumerAdmin:1.0") -> true;
oe_is_a(_) -> false.

%%------------------------------------------------------------
%%
%% Interface TypeCode
%%
%%------------------------------------------------------------
oe_tc(obtain_push_supplier) -> 
	{{tk_objref,"IDL:omg.org/CosEventChannelAdmin/ProxyPushSupplier:1.0",
                    "ProxyPushSupplier"},
         [],[]};
oe_tc(obtain_pull_supplier) -> 
	{{tk_objref,"IDL:omg.org/CosEventChannelAdmin/ProxyPullSupplier:1.0",
                    "ProxyPullSupplier"},
         [],[]};
oe_tc(_) -> undefined.

oe_get_interface() -> 
	[{"obtain_pull_supplier", oe_tc(obtain_pull_supplier)},
	{"obtain_push_supplier", oe_tc(obtain_push_supplier)}].




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
    "IDL:omg.org/CosEventChannelAdmin/ConsumerAdmin:1.0".


%%------------------------------------------------------------
%%
%% Object creation functions.
%%
%%------------------------------------------------------------

oe_create() ->
    corba:create(?MODULE, "IDL:omg.org/CosEventChannelAdmin/ConsumerAdmin:1.0").

oe_create_link() ->
    corba:create_link(?MODULE, "IDL:omg.org/CosEventChannelAdmin/ConsumerAdmin:1.0").

oe_create(Env) ->
    corba:create(?MODULE, "IDL:omg.org/CosEventChannelAdmin/ConsumerAdmin:1.0", Env).

oe_create_link(Env) ->
    corba:create_link(?MODULE, "IDL:omg.org/CosEventChannelAdmin/ConsumerAdmin:1.0", Env).

oe_create(Env, RegName) ->
    corba:create(?MODULE, "IDL:omg.org/CosEventChannelAdmin/ConsumerAdmin:1.0", Env, RegName).

oe_create_link(Env, RegName) ->
    corba:create_link(?MODULE, "IDL:omg.org/CosEventChannelAdmin/ConsumerAdmin:1.0", Env, RegName).

%%------------------------------------------------------------
%%
%% Init & terminate functions.
%%
%%------------------------------------------------------------

init(Env) ->
%% Call to implementation init
    corba:handle_init('CosEventChannelAdmin_ConsumerAdmin_impl', Env).

terminate(Reason, State) ->
    corba:handle_terminate('CosEventChannelAdmin_ConsumerAdmin_impl', Reason, State).


%%%% Operation: obtain_push_supplier
%% 
%%   Returns: RetVal
%%
handle_call({_, OE_Context, obtain_push_supplier, []}, _, OE_State) ->
  corba:handle_call('CosEventChannelAdmin_ConsumerAdmin_impl', obtain_push_supplier, [], OE_State, OE_Context, false, false);

%%%% Operation: obtain_pull_supplier
%% 
%%   Returns: RetVal
%%
handle_call({_, OE_Context, obtain_pull_supplier, []}, _, OE_State) ->
  corba:handle_call('CosEventChannelAdmin_ConsumerAdmin_impl', obtain_pull_supplier, [], OE_State, OE_Context, false, false);



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
handle_info(_, State) ->
    {noreply, State}.


code_change(OldVsn, State, Extra) ->
    corba:handle_code_change('CosEventChannelAdmin_ConsumerAdmin_impl', OldVsn, State, Extra).

