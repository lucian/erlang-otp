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
%% Purpose: Define the protocol options for Megaco/H.248 IP connections
%%-----------------------------------------------------------------

%%----------------------------------------------------------------------
%% IP options
%%----------------------------------------------------------------------
-record(megaco_tcp,
	{host,
	 port,
	 options = [],
	 socket,
	 proxy_pid,
	 receive_handle,
	 module = megaco
	}).


-define(GC_MSG_LIMIT,1000).
-define(HEAP_SIZE(S),5000 + 2*(S)).


%%----------------------------------------------------------------------
%% Event Trace
%%----------------------------------------------------------------------

-define(tcp_debug(TcpRec, Label, Contents),
	?tcp_report_debug(TcpRec,
			  megaco_tcp,
			  megaco_tcp,
			  Label,
			  Contents)).

-define(tcp_report(Level, TcpRec, From, To, Label, Contents),
        if
            list(Contents) ->
                megaco:report_event(Level, From, To, Label,
				    [{line, ?MODULE, ?LINE}, TcpRec | Contents]);
            true ->
                ok = error_logger:format("~p(~p): Bad arguments to et:
"
                                         "report(~p, ~p, ~p, ~p, ~p, ~p)~n",
                                         [?MODULE, ?LINE,
                                          Level, TcpRec, From, To, Label, Contents])
        end).

-define(tcp_report_important(C, From, To, Label, Contents), 
	?tcp_report(20, C, From, To, Label, Contents)).
-define(tcp_report_verbose(C,   From, To, Label, Contents), 
	?tcp_report(40, C, From, To, Label, Contents)).
-define(tcp_report_debug(C,     From, To, Label, Contents), 
	?tcp_report(60, C, From, To, Label, Contents)).
-define(tcp_report_trace(C,     From, To, Label, Contents), 
	?tcp_report(80, C, From, To, Label, Contents)).

