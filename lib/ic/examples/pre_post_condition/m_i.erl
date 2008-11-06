%%------------------------------------------------------------
%%
%% Implementation stub file
%% 
%% Target: m_i
%% Source: /ldisk/daily_build/otp_prebuild_r12b.2008-11-05_12/otp_src_R12B-5/lib/ic/examples/pre_post_condition/ex.idl
%% IC vsn: 4.2.19
%% 
%% This file is automatically generated. DO NOT EDIT IT.
%%
%%------------------------------------------------------------

-module(m_i).
-ic_compiled("4_2_19").


%% Interface functions
-export([f/2, f/3, g/2]).
-export([g/3]).

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



%%%% Operation: f
%% 
%%   Returns: RetVal
%%
f(OE_THIS, I) ->
    corba:call(OE_THIS, f, [I], ?MODULE).

f(OE_THIS, OE_Options, I) ->
    corba:call(OE_THIS, f, [I], ?MODULE, OE_Options).

%%%% Operation: g
%% 
%%   Returns: RetVal
%%
g(OE_THIS, I) ->
    corba:cast(OE_THIS, g, [I], ?MODULE).

g(OE_THIS, OE_Options, I) ->
    corba:cast(OE_THIS, g, [I], ?MODULE, OE_Options).

%%------------------------------------------------------------
%%
%% Inherited Interfaces
%%
%%------------------------------------------------------------
oe_is_a("IDL:m/i:1.0") -> true;
oe_is_a(_) -> false.

%%------------------------------------------------------------
%%
%% Interface TypeCode
%%
%%------------------------------------------------------------
oe_tc(f) -> 
	{tk_short,[tk_short],[]};
oe_tc(g) -> 
	{tk_void,[tk_long],[]};
oe_tc(_) -> undefined.

oe_get_interface() -> 
	[{"g", oe_tc(g)},
	{"f", oe_tc(f)}].




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
    "IDL:m/i:1.0".


%%------------------------------------------------------------
%%
%% Object creation functions.
%%
%%------------------------------------------------------------

oe_create() ->
    corba:create(?MODULE, "IDL:m/i:1.0").

oe_create_link() ->
    corba:create_link(?MODULE, "IDL:m/i:1.0").

oe_create(Env) ->
    corba:create(?MODULE, "IDL:m/i:1.0", Env).

oe_create_link(Env) ->
    corba:create_link(?MODULE, "IDL:m/i:1.0", Env).

oe_create(Env, RegName) ->
    corba:create(?MODULE, "IDL:m/i:1.0", Env, RegName).

oe_create_link(Env, RegName) ->
    corba:create_link(?MODULE, "IDL:m/i:1.0", Env, RegName).

%%------------------------------------------------------------
%%
%% Init & terminate functions.
%%
%%------------------------------------------------------------

init(Env) ->
%% Call to implementation init
    corba:handle_init(m_i_impl, Env).

terminate(Reason, State) ->
    corba:handle_terminate(m_i_impl, Reason, State).


%%%% Operation: f
%% 
%%   Returns: RetVal
%%
handle_call({_, OE_Context, f, [I]}, _, OE_State) ->
  corba:handle_call(m_i_impl, f, [I], OE_State, OE_Context, false, false, {tracer,
                                                                           pre}, {tracer,
                                                                                  post}, ?MODULE);



%%%% Standard gen_server call handle
%%
handle_call(stop, _, State) ->
    {stop, normal, ok, State};

handle_call(_, _, State) ->
    {reply, catch corba:raise(#'BAD_OPERATION'{minor=1163001857, completion_status='COMPLETED_NO'}), State}.
%%%% Operation: g
%% 
%%   Returns: RetVal
%%
handle_cast({_, OE_Context, g, [I]}, OE_State) ->
    corba:handle_cast(m_i_impl, g, [I], OE_State, OE_Context, false, {tracer,
                                                                      pre}, {tracer,
                                                                             pre}, ?MODULE);



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
    corba:handle_code_change(m_i_impl, OldVsn, State, Extra).

