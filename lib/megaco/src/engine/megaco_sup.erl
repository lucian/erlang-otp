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
%%----------------------------------------------------------------------
%% Purpose: The top supervisor for the Megaco/H.248 application
%%----------------------------------------------------------------------

-module(megaco_sup).

-behaviour(application).
-behaviour(supervisor).

%% public
-export([start/0, start/2, stop/1]).
-export([start_sup_child/1, stop_sup_child/1]).

%% internal
-export([init/1]).

%% debug
-export([supervisor_timeout/1]).


%% -define(d(F,A), io:format("~p~p:" ++ F ++ "~n", [self(),?MODULE|A])).
-define(d(F,A), ok).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% application and supervisor callback functions

start(normal, Args) ->
    ?d("start(normal) -> entry with"
	"~n   Args: ~p", [Args]),
    SupName = {local, ?MODULE},
    case supervisor:start_link(SupName, ?MODULE, [Args]) of
	{ok, Pid} ->
	    {ok, Pid, {normal, Args}};
	Error -> 
	    Error
    end;
start(_, _) ->
    {error, badarg}.

start() ->
    ?d("start -> entry", []),
    SupName = {local,?MODULE},
    supervisor:start_link(SupName, ?MODULE, []).

stop(_StartArgs) ->
    ok.

init([]) -> % Supervisor
    init();
init([[]]) -> % Application
    init();
init(BadArg) ->
    ?d("init -> entry when"
	"~n   BadArg: ~p",[BadArg]),
    {error, {badarg, BadArg}}.

init() ->
    ?d("init -> entry", []),
    Flags = {one_for_one, 0, 1},
    Sups = [sup_spec(megaco_misc_sup), 
	    sup_spec(megaco_trans_sup), 
	    worker_spec(megaco_config,  [gen_server]),
	    worker_spec(megaco_monitor, [gen_server])],
    ?d("init -> done when"
	"~n   Flags: ~p"
	"~n   Sups:  ~p", [Flags, Sups]),
    {ok, {Flags, Sups}}.


start_sup_child(Name) ->
    ?d("start_sup_child -> entry with Name: ~p", [Name]),
    Spec = sup_spec(Name),
    supervisor:start_child(?MODULE, Spec).


stop_sup_child(Name) ->
    ?d("stop_sup_child -> entry with Name: ~p", [Name]),
    ok = supervisor:terminate_child(?MODULE, Name),
    ok = supervisor:delete_child(?MODULE, Name).
    


sup_spec(Name) ->
    {Name, {Name, start, []}, permanent, 2000, supervisor,[Name, supervisor]}.
    
worker_spec(Name, Modules) ->
    {Name, {Name, start_link, []}, permanent, 2000, worker, [Name] ++ Modules}.

-ifdef(debug_shutdown).
supervisor_timeout(_KillAfter) -> timer:hours(500).
-else.
supervisor_timeout(KillAfter) -> KillAfter.
-endif.    


