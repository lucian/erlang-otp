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
%% File: orber_iiop_socketsup.erl
%% Author: Lars Thorsen
%% 
%% Description:
%%    This file contains the supervisor for the socket accept processes.
%%
%% Creation date: 990525
%%
%%-----------------------------------------------------------------
-module(orber_iiop_socketsup).

-behaviour(supervisor).


%%-----------------------------------------------------------------
%% External exports
%%-----------------------------------------------------------------
-export([start/2, start_accept/2]).

%%-----------------------------------------------------------------
%% Internal exports
%%-----------------------------------------------------------------
-export([init/1, terminate/2]).

%%-----------------------------------------------------------------
%% External interface functions
%%-----------------------------------------------------------------
%%-----------------------------------------------------------------
%% Func: start/2
%%-----------------------------------------------------------------
start(sup, Opts) ->
    supervisor:start_link({local, orber_iiop_socketsup}, orber_iiop_socketsup,
			  {sup, Opts});
start(_A1, _A2) -> 
    ok.


%%-----------------------------------------------------------------
%% Server functions
%%-----------------------------------------------------------------
%%-----------------------------------------------------------------
%% Func: init/1
%%-----------------------------------------------------------------
init({sup, _Opts}) ->
    SupFlags = {simple_one_for_one, 500, 100},
    ChildSpec = [
		 {name3, {orber_iiop_net_accept, start, []}, temporary, 
		  10000, worker, [orber_iiop_net_accept]}
		],
    {ok, {SupFlags, ChildSpec}};
init(_Opts) ->
    {ok, []}.


%%-----------------------------------------------------------------
%% Func: terminate/2
%%-----------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%-----------------------------------------------------------------
%% Func: start_connection/1
%%-----------------------------------------------------------------
start_accept(Type, Listen) ->
    supervisor:start_child(orber_iiop_socketsup, [Type, Listen]).

