%%--------------------------------------------------------------------
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
%% File: orber_initial_references.erl
%% 
%% Description:
%%    This file contains the CORBA::InitialReferences interface
%%
%% Creation date: 970827
%%
%%-----------------------------------------------------------------
-module(orber_initial_references).

-behaviour(gen_server).

-include_lib("orber/include/corba.hrl").

%%-----------------------------------------------------------------
%% External exports
%%-----------------------------------------------------------------
-export([start/1, shutdown/1, init/1,
	 terminate/2, handle_call/3, code_change/3, 
	 get/2, list/1, add/3, remove/2, 
	 get/1, list/0, add/2, remove/1, 
	 typeID/0, install/2, oe_is_a/1]).

%%-----------------------------------------------------------------
%% Internal exports
%%-----------------------------------------------------------------
-export([handle_cast/2, handle_info/2]).

%%-----------------------------------------------------------------
%% Mnesia Table definition record
%%-----------------------------------------------------------------
-record(orber_references, {key, objref, type}).

-define(DEBUG_LEVEL, 6).

%%-----------------------------------------------------------------
%% External interface functions
%%-----------------------------------------------------------------
start(Env) ->
    gen_server:start_link({local, 'orber_init'}, ?MODULE, Env, []).

shutdown(EO_this) ->
    gen_server:call(EO_this, stop).


install(Timeout, Options) ->
    AllTabs = mnesia:system_info(tables),
    DB_Result = case lists:member(orber_references, AllTabs) of
		    true ->
			case lists:member({local_content, true},
					  Options) of
			    true->
				mnesia:add_table_copy(orber_references,
						      node(),
						      ram_copies);
			    _ ->
				mnesia:create_table(orber_references,
						    [{attributes,
						      record_info(fields,
								  orber_references)}
						     |Options])
			end;
		    _ ->
			mnesia:create_table(orber_references,
					    [{attributes,
					      record_info(fields,
							  orber_references)}
					     |Options])	
		end,
    
    Wait = mnesia:wait_for_tables([orber_references], Timeout),
    %% Check if any error has occured yet. If there are errors, return them.
    if
	DB_Result == {atomic, ok},
	Wait == ok ->
	    ok;
	true ->
	    {error, {DB_Result, Wait}}
    end.


%%-----------------------------------------------------------------
%% InitialReferences Interface 
%%-----------------------------------------------------------------
get(Id) ->
    case read(Id) of
	{'EXCEPTION', E} ->
	    corba:raise(E);
	Result ->
	    Result
    end.

list() ->
    case list_keys() of
	{'EXCEPTION', E} ->
	    corba:raise(E);
	Result ->
	    Result
    end.


add(Id, ObjRef) ->
    case write(Id, ObjRef, external) of
	{'EXCEPTION', E} ->
	    corba:raise(E);
	Result ->
	    Result
    end.


remove(Id) ->
    case delete(Id) of
	{'EXCEPTION', E} ->
	    corba:raise(E);
	Result ->
	    Result
    end.


get(EO_this, Id) ->
    corba:call(EO_this, 'get', [Id], {{'tk_objref', 12, "object"},
				      [{"id", {'tk_string', 0}}],
				      []}).

list(EO_this) ->
    corba:call(EO_this, 'list', [], {{'tk_sequence',{"id", {'tk_string', 0}, 0}},
				     [], []}).

add(EO_this, Id, ObjRef) ->
    corba:call(EO_this, 'add', [Id, ObjRef], {'tk_boolean',
				      [{"id", {'tk_string', 0}}, {'tk_objref', 12, "object"}],
				      []}).

remove(EO_this, Id) ->
    corba:call(EO_this, 'remove', [Id], {'tk_boolean',
				      [{"id", {'tk_string', 0}}],
				      []}).

typeID() ->
    "IDL:Orber/InitialReferences:1.0".

oe_is_a("IDL:Orber/InitialReferences:1.0") ->
    true;
oe_is_a(_) ->
    false.

%%-----------------------------------------------------------------
%% Internal interface functions
%%-----------------------------------------------------------------
init([]) ->
    case mnesia:wait_for_tables(['orber_references'], infinity) of
	ok ->
	    NSObjKey = 'CosNaming_NamingContextExt':oe_create([], [{pseudo, true}]),
	    rewrite("NameService", NSObjKey),
	    ErlIfr = 'OrberApp_IFR':oe_create([], [{pseudo, true}]),
	    rewrite("OrberIFR", ErlIfr),
	    {ok, []};
	StopReason ->
	    {stop, StopReason}
    end.

terminate(Reason, State) ->
    ok.


%%-----------------------------------------------------------------
%% Handle incomming calls 
handle_call({EO_this, 'get', [Id]}, From, State) ->
    {'reply', read(Id), State};
handle_call({EO_this, 'list', []}, From, State) ->
    {'reply', list_keys(), State};

handle_call({EO_this, 'add', [Id, ObjectRef]}, From, State) ->
    {'reply', write(Id, ObjectRef, external), State};

handle_call({EO_this, 'remove', [Id]}, From, State) ->
    {'reply', delete(Id), State};
handle_call({EO_THIS, oe_get_interface, []},
            EO_From, EO_State) ->
    {'reply', [{"get", {{'tk_objref', 12, "object"},
			[{'tk_string', 0}],
			[]}},
	       {"list", {{'tk_sequence',{'tk_string', 0}, 0},
			 [],
			 []}},
	       {"add", {'tk_boolean',
			[{'tk_string', 0}, {'tk_objref', 12, "object"}],
			[]}}
	      ], EO_State};
handle_call('stop', From, State) ->
    {'stop', normal, 'ok', State};
handle_call(Req, From,State) ->
    {'reply', {'ok', 'nil', 'nil'}, State}.


%%-----------------------------------------------------------------
%% Standard gen_server cast handle
%%-----------------------------------------------------------------
handle_cast(_, State) ->
    {noreply,  State}.


%%-----------------------------------------------------------------
%% Standard gen_server handles
%%-----------------------------------------------------------------
handle_info(_, State) ->
    {noreply,  State}.

%%-----------------------------------------------------------------
%% Func: code_change/3
%%-----------------------------------------------------------------
code_change(OldVsn, State, Extra) ->
    {ok, State}.

read(Key) ->
    case mnesia:dirty_read({orber_references, Key}) of
	[] ->
	    corba:create_nil_objref();	    
	[#orber_references{objref = ObjRef}] ->
	    ObjRef;
	What ->
	    orber:dbg("[~p] orber_initial_references:lookup(~p); 
Failed to read from DB: ~p", [?LINE, Key, What], ?DEBUG_LEVEL),
	    {'EXCEPTION', #'INTERNAL'{completion_status=?COMPLETED_NO}}
    end.

write(Key, ObjRef, Type) ->
    _WF = fun() ->
		  case mnesia:wread({orber_references, Key}) of
		      [] ->
			  %% No key exists. Ok to register.
			  mnesia:write(#orber_references{key=Key, objref = ObjRef,
							 type=Type});
		      [X] ->
			  orber:dbg("[~p] orber_initial_references:write(~p);
Already bound to: ~p", [?LINE, Key, X], ?DEBUG_LEVEL),
			  false;
		      Why ->
			  %% Something else occured.
			  orber:dbg("[~p] orber_initial_references:write(~p);
Error reading from DB (~p)", [?LINE, Key, Why], ?DEBUG_LEVEL),
			  mnesia:abort({'EXCEPTION', #'INTERNAL'{completion_status=?COMPLETED_NO}})
		  end
	  end,
    case mnesia:transaction(_WF) of
	{atomic, ok} ->
	    true;
	{atomic, Result} ->
	    Result;
	{aborted, Reason} ->
	    Reason
    end.

rewrite(Key, ObjRef) ->
    rewrite(Key, ObjRef, internal).
rewrite(Key, ObjRef, Type) ->
    _WF = fun() ->
		  mnesia:write(#orber_references{key=Key, objref = ObjRef, type=Type})
	  end,
    case mnesia:transaction(_WF) of
	{atomic, ok} ->
	    true;
	{aborted, Reason} ->
	    orber:dbg("[~p] orber_initial_references:rewrite(~p);
Error over writing in DB (~p)", [?LINE, Key, Reason], ?DEBUG_LEVEL),
	    corba:raise(#'INTERNAL'{completion_status=?COMPLETED_NO})
    end.


delete(Key) ->
    _DF = fun() ->
		  case mnesia:read({orber_references, Key}) of
		      [] ->
			  %% No key exists.
			  orber:dbg("[~p] orber_initial_references:delete(~p);
Does not exist.", [?LINE, Key], ?DEBUG_LEVEL),
			  false;
		      [X] ->
			  mnesia:delete({orber_references, Key});
		      Why ->
			  %% Something else occured.
			  orber:dbg("[~p] orber_initial_references:delete(~p);
Error reading from DB (~p)", [?LINE, Key, Why], ?DEBUG_LEVEL),
			  mnesia:abort({'EXCEPTION', #'INTERNAL'{completion_status=?COMPLETED_NO}})
		  end
	  end,
    case mnesia:transaction(_DF) of
	{atomic, ok} ->
	    true;
	{atomic, Result} ->
	    Result;
	{aborted, Reason} ->
	    Reason
    end.

list_keys() ->    
    _LF = fun() -> mnesia:all_keys(orber_references) end,
    case mnesia:transaction(_LF) of
	{atomic, Result} ->
	    %% We do not want OrberIFR to exported, remove it.
	    lists:delete("OrberIFR", Result);
	{aborted, Reason} ->
	    orber:dbg("[~p] orber_initial_references:list_keys();
Error reading from DB (~p)", [?LINE, Reason], ?DEBUG_LEVEL),
	    {'EXCEPTION', #'INTERNAL'{completion_status=?COMPLETED_NO}}
    end.
