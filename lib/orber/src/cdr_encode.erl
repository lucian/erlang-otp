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
%% File: cdr_encode.erl
%% 
%% Description:
%%    This file contains all encoding functions for the CDR
%%    format.
%%
%% Creation date: 970115
%%
%%-----------------------------------------------------------------
-module(cdr_encode).

-include_lib("orber/include/corba.hrl").
-include_lib("orber/src/orber_iiop.hrl").

%%-----------------------------------------------------------------
%% External exports
%%-----------------------------------------------------------------
-export([enc_giop_msg_type/1, enc_request/8, enc_request_split/8, enc_reply/7,
	 enc_type/3, enc_type/5, enc_cancel_request/2,
	 enc_locate_request/3, enc_locate_reply/3, enc_locate_reply/5, 
	 enc_close_connection/1, enc_message_error/1, enc_fragment/1]).

-export([enc_reply_split/7, enc_giop_message_header/5, validate_request_body/3, 
	 validate_reply_body/3]).

%%-----------------------------------------------------------------
%% Internal exports
%%-----------------------------------------------------------------
-export([]).

%%-----------------------------------------------------------------
%% Macros
%%-----------------------------------------------------------------
-define(DEBUG_LEVEL, 9).

-define(ODD(N), (N rem 2) == 1).

%%-----------------------------------------------------------------
%% External functions
%%-----------------------------------------------------------------
%%-----------------------------------------------------------------
%% Func: enc_giop_message_header/5
%%-----------------------------------------------------------------
%% The header size is known so we know that the size will be aligned.
%% MessSize already includes the header length.
%%-----------------------------------------------------------------
enc_giop_message_header({Major,Minor}, MessType, _Flags, MessSize, Message) ->
    Type = enc_giop_msg_type(MessType),
    %% The Flag handling must be fixed, i.e., it's not correct to only use '0'.
    %% If IIOP-1.0 a boolean (FALSE == 0), otherwise, IIOP-1.1 or 1.2,
    %% an octet. The octet bits represents:
    %% * The least significant the byteorder (0 eq. big-endian)
    %% * The second least significant indicates if the message is fragmented.
    %%   If set to 0 it's not fragmented.
    %% * The most significant 6 bits are reserved. Hence, must be set to 0.
    %% Since we currently don't support fragmented messages and we always
    %% encode using big-endian it's ok to use '0' for now.
    list_to_binary([ <<"GIOP",Major:8,Minor:8,0:8,
		     Type:8,MessSize:32/big-unsigned-integer>> | Message]).

enc_byte_order(Version, Message) ->
    enc_type('tk_boolean', Version, 'false', Message, 0).

%%-----------------------------------------------------------------
%% Func: enc_parameters/2
%%-----------------------------------------------------------------
enc_parameters(_, [], [], Message, Len) ->
    {Message, Len};
enc_parameters(_, [], P, _, _) -> 
    orber:dbg("[~p] cdr_encode:encode_parameters(~p); to many parameters.", 
	      [?LINE, P], ?DEBUG_LEVEL),
    corba:raise(#'MARSHAL'{minor=(?ORBER_VMCID bor 17), completion_status=?COMPLETED_MAYBE});
enc_parameters(_, _, [], TC, _) -> 
    orber:dbg("[~p] cdr_encode:encode_parameters(~p); to few parameters.", 
	      [?LINE, TC], ?DEBUG_LEVEL),
    corba:raise(#'MARSHAL'{minor=(?ORBER_VMCID bor 17), completion_status=?COMPLETED_MAYBE});
enc_parameters(Version, [PT1 |TypeList], [ P1 | Parameters], Message, Len) ->
    {Message1, Len1} = enc_type(PT1, Version, P1, Message, Len),
    enc_parameters(Version, TypeList, Parameters, Message1, Len1).

%%-----------------------------------------------------------------
%% Func: enc_request/8
%%-----------------------------------------------------------------
%% ## NEW IIOP 1.2 ##
enc_request(Version, TargetAddress, RequestId, ResponseExpected, Op, Parameters,
	    Context, TypeCodes) when Version == {1,2} ->
    Flags            = 1, %% LTH Not correct, just placeholder
    {Message, Len}   = enc_request_id(Version, RequestId, [], ?GIOP_HEADER_SIZE),
    {Message1, Len1} = enc_response_flags(Version, ResponseExpected, Message, Len),
    {Message2, Len2} = enc_reserved(Version, {0,0,0}, Message1, Len1),
    {Message3, Len3} = enc_target_address(Version, TargetAddress, Message2, Len2),
    {Message4, Len4} = enc_operation(Version, atom_to_list(Op), Message3, Len3),
    {Message5, Len5} = enc_service_context(Version, Context, Message4, Len4),
    {Message6, Len6} = enc_request_body(Version, TypeCodes, Parameters,
					Message5, Len5),
    enc_giop_message_header(Version, 'request', Flags, Len6 - ?GIOP_HEADER_SIZE,
			    lists:reverse(Message6));
enc_request(Version, ObjectKey, RequestId, ResponseExpected, Op, Parameters,
	    Context, TypeCodes) ->
    Flags = 1, %% LTH Not correct, just placeholder
    Operation = atom_to_list(Op),
    {Message0, Len0} = enc_service_context(Version, Context, [], ?GIOP_HEADER_SIZE),
    {Message, Len} = enc_request_id(Version, RequestId, Message0, Len0),
    {Message1, Len1} = enc_response(Version, ResponseExpected, Message, Len),
    {Message1b, Len1b} =
	if
	    Version /= {1,0} ->
		enc_reserved(Version, {0,0,0}, Message1, Len1);
	    true ->
		{Message1, Len1}
	end,
    {Message2, Len2} = enc_object_key(Version, ObjectKey, Message1b, Len1b),
    {Message3, Len3} = enc_operation(Version, Operation, Message2, Len2),
    {Message4, Len4} = enc_principal(Version, Message3, Len3),
    {Message5, Len5} = enc_request_body(Version, TypeCodes, Parameters,
					Message4, Len4),
    enc_giop_message_header(Version, 'request', Flags, Len5 - ?GIOP_HEADER_SIZE,
			    lists:reverse(Message5)).

%% ## NEW IIOP 1.2 ##
enc_request_split(Version, TargetAddress, RequestId, ResponseExpected, Op, Parameters,
		  Context, TypeCodes) when Version == {1,2} ->
    Flags            = 1, %% LTH Not correct, just placeholder
    {Message, Len}   = enc_request_id(Version, RequestId, [], ?GIOP_HEADER_SIZE),
    {Message1, Len1} = enc_response_flags(Version, ResponseExpected, Message, Len),
    {Message2, Len2} = enc_reserved(Version, {0,0,0}, Message1, Len1),
    {Message3, Len3} = enc_target_address(Version, TargetAddress, Message2, Len2),
    {Message4, Len4} = enc_operation(Version, atom_to_list(Op), Message3, Len3),
    {Message5, Len5} = enc_service_context(Version, Context, Message4, Len4),
    {Body, Len6}     = enc_request_body(Version, TypeCodes, Parameters, [], Len5),
    {lists:reverse(Message5), list_to_binary(lists:reverse(Body)), 
    Len5 - ?GIOP_HEADER_SIZE, Len6-Len5, Flags};
enc_request_split(Version, ObjectKey, RequestId, ResponseExpected, Op, Parameters,
		  Context, TypeCodes) ->
    Flags = 1, %% LTH Not correct, just placeholder
    Operation = atom_to_list(Op),
    {Message0, Len0} = enc_service_context(Version, Context, [], ?GIOP_HEADER_SIZE),
    {Message, Len} = enc_request_id(Version, RequestId, Message0, Len0),
    {Message1, Len1} = enc_response(Version, ResponseExpected, Message, Len),
    {Message1b, Len1b} =
	if
	    Version /= {1,0} ->
		enc_reserved(Version, {0,0,0}, Message1, Len1);
	    true ->
		{Message1, Len1}
	end,
    {Message2, Len2} = enc_object_key(Version, ObjectKey, Message1b, Len1b),
    {Message3, Len3} = enc_operation(Version, Operation, Message2, Len2),
    {Message4, Len4} = enc_principal(Version, Message3, Len3),
    {Body, Len5}     = enc_request_body(Version, TypeCodes, Parameters, [], Len4),
    {lists:reverse(Message4), list_to_binary(lists:reverse(Body)), 
     Len4 - ?GIOP_HEADER_SIZE, Len5-Len4, Flags}.
enc_principal(Version, Mess, Len) ->
    enc_type({'tk_string', 0}, Version, atom_to_list(node()), Mess, Len).
    
enc_operation(Version, Op, Mess, Len) ->
    enc_type({'tk_string', 0}, Version, Op, Mess, Len).
    
enc_object_key(Version, ObjectKey, Mess, Len) ->
    enc_type({'tk_sequence', 'tk_octet', 0}, Version, ObjectKey, Mess, Len).

enc_reserved(Version, Reserved, Mess, Len) ->
    enc_type({'tk_array', 'tk_octet', 3}, Version, Reserved, Mess, Len).

enc_response(Version, ResponseExpected, Mess, Len) ->
    enc_type('tk_boolean', Version, ResponseExpected, Mess, Len).
    
enc_request_id(Version, RequestId, Mess, Len) ->  
    enc_type('tk_ulong', Version, RequestId, Mess, Len).

enc_service_context(Version, Context, Message, Len) ->
    Ctxs = enc_used_contexts(Version, Context, []),
    enc_type(?IOP_SERVICECONTEXT, Version, Ctxs, Message, Len).

enc_used_contexts(_Version, [], Message) ->
    Message;
enc_used_contexts({1,0}, [#'IOP_ServiceContext'{context_id=?IOP_CodeSets}|T], Ctxs) ->
    %% Not supported by 1.0, drop it.
    enc_used_contexts({1,0}, T, Ctxs);
enc_used_contexts(Version, [#'IOP_ServiceContext'{context_id=?IOP_CodeSets,
						  context_data = CodeSetCtx}|T], 
		  Ctxs) ->
    %% Encode ByteOrder
    {Bytes0, Len0} = cdr_encode:enc_type('tk_octet', Version, 0, [], 0),
    {Bytes1, _Len1} = enc_type(?CONV_FRAME_CODESETCONTEXT, Version, CodeSetCtx, 
			       Bytes0, Len0),
    Bytes = list_to_binary(lists:reverse(Bytes1)),
    enc_used_contexts(Version, T, 
		      [#'IOP_ServiceContext'{context_id=?IOP_CodeSets,
					     context_data = Bytes}|Ctxs]);
enc_used_contexts(Version, [#'IOP_ServiceContext'{context_id=?IOP_BI_DIR_IIOP,
						  context_data = BiDirCtx}|T], 
		  Ctxs) ->
    %% Encode ByteOrder
    {Bytes0, Len0} = cdr_encode:enc_type('tk_octet', Version, 0, [], 0),
    {Bytes1, _Len1} = enc_type(?IIOP_BIDIRIIOPSERVICECONTEXT, Version, BiDirCtx, 
			       Bytes0, Len0),
    Bytes = list_to_binary(lists:reverse(Bytes1)),
    enc_used_contexts(Version, T, 
		      [#'IOP_ServiceContext'{context_id=?IOP_BI_DIR_IIOP,
					     context_data = Bytes}|Ctxs]);
enc_used_contexts(Version, [#'IOP_ServiceContext'{context_id=?IOP_FT_REQUEST,
						  context_data = Ctx}|T], 
		  Ctxs) ->
    %% Encode ByteOrder
    {Bytes0, Len0} = cdr_encode:enc_type('tk_octet', Version, 0, [], 0),
    {Bytes1, _Len1} = enc_type(?FT_FTRequestServiceContext, Version, Ctx, 
			       Bytes0, Len0),
    Bytes = list_to_binary(lists:reverse(Bytes1)),
    enc_used_contexts(Version, T, 
		      [#'IOP_ServiceContext'{context_id=?IOP_FT_REQUEST,
					     context_data = Bytes}|Ctxs]);
enc_used_contexts(Version, [#'IOP_ServiceContext'{context_id=?IOP_FT_GROUP_VERSION,
						  context_data = Ctx}|T], 
		  Ctxs) ->
    %% Encode ByteOrder
    {Bytes0, Len0} = cdr_encode:enc_type('tk_octet', Version, 0, [], 0),
    {Bytes1, _Len1} = enc_type(?FT_FTGroupVersionServiceContext, Version, Ctx, 
			       Bytes0, Len0),
    Bytes = list_to_binary(lists:reverse(Bytes1)),
    enc_used_contexts(Version, T, 
		      [#'IOP_ServiceContext'{context_id=?IOP_FT_GROUP_VERSION,
					     context_data = Bytes}|Ctxs]);
enc_used_contexts(Version, [#'IOP_ServiceContext'{context_id=?IOP_SecurityAttributeService,
						  context_data = Ctx}|T], 
		  Ctxs) ->
    %% Encode ByteOrder
    {Bytes0, Len0} = cdr_encode:enc_type('tk_octet', Version, 0, [], 0),
    {Bytes1, _Len1} = enc_type(?CSI_SASContextBody, Version, Ctx, 
			       Bytes0, Len0),
    Bytes = list_to_binary(lists:reverse(Bytes1)),
    enc_used_contexts(Version, T, 
		      [#'IOP_ServiceContext'{context_id=?IOP_SecurityAttributeService,
					     context_data = Bytes}|Ctxs]);
enc_used_contexts(Version, [H|T], Ctxs) ->
    enc_used_contexts(Version, T, [H|Ctxs]).

%% ## NEW IIOP 1.2 ##
enc_target_address(Version, TargetAddr, Mess, Len) when record(TargetAddr,
							       'GIOP_TargetAddress') ->
    enc_type(?TARGETADDRESS, Version, TargetAddr, Mess, Len);
enc_target_address(Version, IORInfo, Mess, Len) when record(IORInfo, 'GIOP_IORAddressingInfo') ->
    enc_type(?TARGETADDRESS, Version, #'GIOP_TargetAddress'{label = ?GIOP_ReferenceAddr, 
							    value = IORInfo}, 
	     Mess, Len);
enc_target_address(Version, TP, Mess, Len) when record(TP, 'IOP_TaggedProfile') ->
    enc_type(?TARGETADDRESS, Version, #'GIOP_TargetAddress'{label = ?GIOP_ProfileAddr, 
							    value = TP}, 
	     Mess, Len);
enc_target_address(Version, ObjKey, Mess, Len) ->
    enc_type(?TARGETADDRESS, Version, #'GIOP_TargetAddress'{label = ?GIOP_KeyAddr, 
							    value = ObjKey}, 
	     Mess, Len).

%% FIX ME!! This is temporary, not proper flag handling.
enc_response_flags(Version, true, Mess, Len) ->
    enc_type('tk_octet', Version, 3, Mess, Len);
enc_response_flags(Version, false, Mess, Len) ->
    enc_type('tk_octet', Version, 0, Mess, Len).

%%-----------------------------------------------------------------
%% Func: enc_request_body/5
%%-----------------------------------------------------------------
enc_request_body(_, {_, [], _}, _, Message, Len) ->
    %% This case is used to avoid adding alignment even though no body will be added.
    {Message, Len};
enc_request_body(Version, {_RetType, InParameters, _OutParameters}, Parameters,
		 Message, Len) when Version == {1,2} ->
    {Message1, Len1} = enc_align(Message, Len, 8),
    enc_parameters(Version, InParameters, Parameters, Message1, Len1);
enc_request_body(Version, {_RetType, InParameters, _OutParameters}, Parameters,
		 Message, Len) ->
    enc_parameters(Version, InParameters, Parameters, Message, Len).

%%-----------------------------------------------------------------
%% Func: validate_request_body/3
%%-----------------------------------------------------------------
validate_request_body(Version, {_RetType, InParameters, _OutParameters}, Parameters) ->
    enc_parameters(Version, InParameters, Parameters, [], 0).

%%-----------------------------------------------------------------
%% Func: enc_reply/6
%%-----------------------------------------------------------------
%% ## NEW IIOP 1.2 ##
enc_reply(Version, ReqId, RepStatus, TypeCodes, Result, OutParameters, Ctx) 
  when Version == {1,2} ->
    Flags            = 1, %% LTH Not correct, just placeholder
    {Message, Len}   = enc_request_id(Version, ReqId, [], ?GIOP_HEADER_SIZE), 
    {Message1, Len1} = enc_reply_status(Version, RepStatus, Message, Len),
    {Message2, Len2} = enc_service_context(Version, Ctx, Message1, Len1),
    {Message3, Len3} = enc_reply_body(Version, TypeCodes, Result, OutParameters,
				      Message2, Len2),
    enc_giop_message_header(Version, 'reply', Flags, Len3 - ?GIOP_HEADER_SIZE,
			    lists:reverse(Message3));
enc_reply(Version, ReqId, RepStatus, TypeCodes, Result, OutParameters, Ctx) ->
    Flags            = 1, %% LTH Not correct, just placeholder
    {Message, Len}   = enc_service_context(Version, Ctx, [], ?GIOP_HEADER_SIZE),
    {Message1, Len1} = enc_request_id(Version, ReqId, Message, Len), 
    {Message2, Len2} = enc_reply_status(Version, RepStatus, Message1, Len1),
    {Message3, Len3} = enc_reply_body(Version, TypeCodes, Result, OutParameters,
				      Message2, Len2),
    enc_giop_message_header(Version, 'reply', Flags, Len3 - ?GIOP_HEADER_SIZE,
			    lists:reverse(Message3)).

%% ## NEW IIOP 1.2 ##
enc_reply_split(Version, ReqId, RepStatus, TypeCodes, Result, OutParameters, Ctx) 
  when Version == {1,2} ->
    Flags            = 1, %% LTH Not correct, just placeholder
    {Message, Len0}   = enc_request_id(Version, ReqId, [], ?GIOP_HEADER_SIZE), 
    {Message1, Len1} = enc_reply_status(Version, RepStatus, Message, Len0),
    {Message2, Len2} = enc_service_context(Version, Ctx, Message1, Len1),
    {Body, Len} = enc_reply_body(Version, TypeCodes, Result, OutParameters, [], Len2),
    {lists:reverse(Message2), list_to_binary(lists:reverse(Body)),
     Len2 - ?GIOP_HEADER_SIZE, Len-Len2, Flags};
enc_reply_split(Version, ReqId, RepStatus, TypeCodes, Result, OutParameters, Ctx) ->
    Flags            = 1, %% LTH Not correct, just placeholder
    {Message, Len0}   = enc_service_context(Version, Ctx, [], ?GIOP_HEADER_SIZE),
    {Message1, Len1} = enc_request_id(Version, ReqId, Message, Len0), 
    {Message2, Len2} = enc_reply_status(Version, RepStatus, Message1, Len1),
    {Body, Len} = enc_reply_body(Version, TypeCodes, Result, OutParameters, [], Len2),
    {lists:reverse(Message2), list_to_binary(lists:reverse(Body)), 
     Len2 - ?GIOP_HEADER_SIZE, Len-Len2, Flags}.

enc_reply_status(Version, Status, Mess, Len) ->
    L = enc_giop_reply_status_type(Status),
    enc_type('tk_ulong', Version, L, Mess, Len).

%%-----------------------------------------------------------------
%% Func: enc_reply_body/6
%%-----------------------------------------------------------------
enc_reply_body(_Version, {'tk_void', _, []}, ok, [], Message, Len) ->
    %% This case is mainly to be able to avoid adding alignment for
    %% IIOP-1.2 messages if the body should be empty, i.e., void return value and
    %% no out parameters.
    {Message, Len};
enc_reply_body(Version, {RetType, _InParameters, OutParameters}, Result, Parameters,
	       Message, Len) when Version == {1,2} ->
    {Message1, Len1} = enc_align(Message, Len, 8),
    {Message2, Len2}  = enc_type(RetType, Version, Result, Message1, Len1),
    enc_parameters(Version, OutParameters, Parameters, Message2, Len2);
enc_reply_body(Version, {RetType, _InParameters, OutParameters}, Result, Parameters,
	       Message, Len) ->
    {Message1, Len1}  = enc_type(RetType, Version, Result, Message, Len),
    enc_parameters(Version, OutParameters, Parameters, Message1, Len1).


%%-----------------------------------------------------------------
%% Func: validate_reply_body/3
%%-----------------------------------------------------------------
validate_reply_body(Version, _, {'EXCEPTION', Exception}) ->
    {TypeOfException, ExceptionTypeCode, NewExc} =
	orber_exceptions:get_def(Exception),
    {'tk_except', TypeOfException, ExceptionTypeCode, 
     (catch enc_reply_body(Version, {ExceptionTypeCode, [], []}, NewExc, [], [], 0))};
validate_reply_body(Version, {RetType, InParameters, []}, Reply) ->
    enc_reply_body(Version, {RetType, InParameters, []}, Reply,
		   [], [], 0);
validate_reply_body(Version, {RetType, InParameters, OutParameters}, Reply) 
  when tuple(Reply) ->
    [Result|Parameters] = tuple_to_list(Reply),
    enc_reply_body(Version, {RetType, InParameters, OutParameters}, Result,
		   Parameters, [], 0);
validate_reply_body(Version, {RetType, InParameters, OutParameters}, Reply) ->
    enc_reply_body(Version, {RetType, InParameters, OutParameters}, Reply, [], [], 0).

%%-----------------------------------------------------------------
%% Func: enc_cancel_request/2
%%-----------------------------------------------------------------
enc_cancel_request(Version, RequestId) ->
    Flags = 1, %% LTH Not correct, just placeholder
    {Message, Len} = enc_request_id(Version, RequestId, [],
				   ?GIOP_HEADER_SIZE),
    enc_giop_message_header(Version, 'cancel_request', Flags, Len - ?GIOP_HEADER_SIZE,
			    lists:reverse(Message)).

%%-----------------------------------------------------------------
%% Func: enc_locate_request/3
%%-----------------------------------------------------------------
%% ## NEW IIOP 1.2 ##
enc_locate_request(Version, TargetAddress, RequestId) when Version == {1,2} ->
    Flags = 1, %% LTH Not correct, just placeholder
    {Message, Len}   = enc_request_id(Version, RequestId, [], ?GIOP_HEADER_SIZE), 
    {Message1, Len1} = enc_target_address(Version, TargetAddress, Message, Len),
    enc_giop_message_header(Version, 'locate_request', Flags, Len1-?GIOP_HEADER_SIZE, 
			    lists:reverse(Message1));
enc_locate_request(Version, ObjectKey, RequestId) ->
    Flags = 1, %% LTH Not correct, just placeholder
    {Message, Len}   = enc_request_id(Version, RequestId, [], ?GIOP_HEADER_SIZE), 
    {Message1, Len1} = enc_object_key(Version, ObjectKey, Message, Len),
    enc_giop_message_header(Version, 'locate_request', Flags, Len1-?GIOP_HEADER_SIZE, 
			    lists:reverse(Message1)).

%%-----------------------------------------------------------------
%% Func: enc_locate_reply/3
%%-----------------------------------------------------------------
enc_locate_reply(Version, RequestId, LocStatus) ->
    Flags = 1, %% LTH Not correct, just placeholder
    {Message, Len} = enc_request_id(Version, RequestId, [], ?GIOP_HEADER_SIZE), 
    {Message1, Len1} = enc_locate_status(Version, LocStatus, Message, Len),
    enc_giop_message_header(Version, 'locate_reply', Flags, Len1 - ?GIOP_HEADER_SIZE, 
			    lists:reverse(Message1)).

enc_locate_reply(Version, RequestId, LocStatus, TypeCode, Data) ->
    Flags = 1, %% LTH Not correct, just placeholder
    {Message, Len} = enc_request_id(Version, RequestId, [], ?GIOP_HEADER_SIZE), 
    {Message1, Len1} = enc_locate_status(Version, LocStatus, Message, Len),
    {Message2, Len2} = enc_locate_reply_body(Version, TypeCode, Data, Message1, Len1),
    enc_giop_message_header(Version, 'locate_reply', Flags, Len2 - ?GIOP_HEADER_SIZE, 
			    lists:reverse(Message2)).

enc_locate_reply_body(Version, TypeCode, Data, Message, Len) ->
    %% In CORBA-2.3.1 the LocateReply body didn't align the body (8-octet
    %% boundry) for IIOP-1.2. This have been changed in later specs.
    %% Un-comment the line below when we want to be CORBA-2.4 compliant.
    %% But in CORB-2.6 this was changed once again (i.e. no alignment).
    %% The best solution is to keep it as is.
    enc_type(TypeCode, Version, Data, Message, Len).

enc_locate_status(Version, Status, Mess, Len) ->
    L = enc_giop_locate_status_type(Status),
    enc_type('tk_ulong', Version, L, Mess, Len).
%%-----------------------------------------------------------------
%% Func: enc_close_connection/1
%%-----------------------------------------------------------------
enc_close_connection(Version) ->
    Flags = 1, %% LTH Not correct, just placeholder
    enc_giop_message_header(Version, 'close_connection', Flags, 0, []).

%%-----------------------------------------------------------------
%% Func: enc_message_error/1
%%-----------------------------------------------------------------
enc_message_error(Version) ->
    Flags = 1, %% LTH Not correct, just placeholder
    enc_giop_message_header(Version, 'message_error', Flags, 0, []).

%%-----------------------------------------------------------------
%% Func: enc_fragment/1
%%-----------------------------------------------------------------
enc_fragment(Version) ->
    Flags = 1, %% LTH Not correct, just placeholder
    enc_giop_message_header(Version, 'message_error', Flags, 0, []).

%%-----------------------------------------------------------------
%% Func: enc_giop_msg_type
%% Args: An integer message type code
%% Returns: An atom which is the message type code name
%%-----------------------------------------------------------------
enc_giop_msg_type('request') ->  %% LTH l�gga in version ??
    0;
enc_giop_msg_type('reply') ->
    1;
enc_giop_msg_type('cancel_request') ->
    2;
enc_giop_msg_type('locate_request') ->
    3;
enc_giop_msg_type('locate_reply') ->
    4;
enc_giop_msg_type('close_connection') ->
    5;
enc_giop_msg_type('message_error') ->
    6;
enc_giop_msg_type('fragment') ->
    7.


%%-----------------------------------------------------------------
%% Func: enc_giop_reply_status_type
%% Args: An atom which is the reply status
%% Returns: An integer status code
%%-----------------------------------------------------------------
enc_giop_reply_status_type(?NO_EXCEPTION) ->
    0;
enc_giop_reply_status_type(?USER_EXCEPTION) ->
    1;
enc_giop_reply_status_type(?SYSTEM_EXCEPTION) ->
    2;
enc_giop_reply_status_type('location_forward') ->
    3;
%% ## NEW IIOP 1.2 ##
enc_giop_reply_status_type('location_forward_perm') ->
    4;
enc_giop_reply_status_type('needs_addressing_mode') ->
    5.

%%-----------------------------------------------------------------
%% Func: enc_giop_locate_status_type
%% Args: An integer status code
%% Returns: An atom which is the reply status
%%-----------------------------------------------------------------
enc_giop_locate_status_type('unknown_object') ->
    0;
enc_giop_locate_status_type('object_here') ->
    1;
enc_giop_locate_status_type('object_forward') ->
    2;
%% ## NEW IIOP 1.2 ##
enc_giop_locate_status_type('object_forward_perm') ->
    3;
enc_giop_locate_status_type('loc_system_exception') ->
    4;
enc_giop_locate_status_type('loc_needs_addressing_mode') ->
    5.

%%-----------------------------------------------------------------
%% Func: enc_type/3
%%-----------------------------------------------------------------
enc_type(Version, TypeCode, Value) ->
    {Bytes, _Len} = enc_type(TypeCode, Version, Value, [], 0),
    list_to_binary(lists:reverse(Bytes)).

%%-----------------------------------------------------------------
%% Func: enc_type/5
%%-----------------------------------------------------------------
enc_type('tk_null', _Version, null, Bytes, Len) ->
    {Bytes, Len}; 
enc_type('tk_void', _Version, ok, Bytes, Len) ->
    {Bytes, Len}; 
enc_type('tk_short', _Version, Value, Bytes, Len) ->
    {Rest, Len1} = enc_align(Bytes, Len, 2),
    {cdrlib:enc_short(Value, Rest), Len1 + 2};
enc_type('tk_long', _Version, Value, Bytes, Len) ->
    {Rest, Len1} = enc_align(Bytes, Len, 4),
    {cdrlib:enc_long(Value, Rest ), Len1 + 4};
enc_type('tk_longlong', _Version, Value, Bytes, Len) ->
    {Rest, Len1} = enc_align(Bytes, Len, 8),
    {cdrlib:enc_longlong(Value, Rest ), Len1 + 8};
enc_type('tk_ushort', _Version, Value, Bytes, Len) ->
    {Rest, Len1} = enc_align(Bytes, Len, 2),
    {cdrlib:enc_unsigned_short(Value, Rest), Len1 + 2};
enc_type('tk_ulong', _Version, Value, Bytes, Len) -> 
    {Rest, Len1} = enc_align(Bytes, Len, 4),
    {cdrlib:enc_unsigned_long(Value, Rest), Len1 + 4};
enc_type('tk_ulonglong', _Version, Value, Bytes, Len) -> 
    {Rest, Len1} = enc_align(Bytes, Len, 8),
    {cdrlib:enc_unsigned_longlong(Value, Rest), Len1 + 8};
enc_type('tk_float', _Version, Value, Bytes, Len) ->
    {Rest, Len1} = enc_align(Bytes, Len, 4),
    {cdrlib:enc_float(Value, Rest), Len1 + 4};
enc_type('tk_double', _Version, Value, Bytes, Len) ->
    {Rest, Len1} = enc_align(Bytes, Len, 8),
    {cdrlib:enc_double(Value, Rest), Len1 + 8};
enc_type('tk_boolean', _Version, Value, Bytes, Len) ->
    {cdrlib:enc_bool(Value, Bytes), Len + 1};
enc_type('tk_char', _Version, Value, Bytes, Len) ->
    {cdrlib:enc_char(Value, Bytes), Len + 1};
%% The wchar decoding can be 1, 2 or 4 bytes but for now we only accept 2.
enc_type('tk_wchar', {1,2}, Value, Bytes, Len) ->
    Bytes1 = cdrlib:enc_octet(2, Bytes),
    {cdrlib:enc_unsigned_short(Value, Bytes1), Len + 3};
enc_type('tk_wchar', _Version, Value, Bytes, Len) ->
    {Rest, Len1} = enc_align(Bytes, Len, 2),
    {cdrlib:enc_unsigned_short(Value, Rest), Len1 + 2};
enc_type('tk_octet', _Version, Value, Bytes, Len) ->
    {cdrlib:enc_octet(Value, Bytes), Len + 1};
enc_type('tk_any', Version, Any, Bytes, Len) when record(Any, any) ->
    {Rest, Len1} = enc_type('tk_TypeCode', Version, Any#any.typecode, Bytes, Len),
    enc_type(Any#any.typecode, Version, Any#any.value, Rest, Len1);
enc_type('tk_TypeCode', Version, Value, Bytes, Len) ->
    enc_type_code(Value, Version, Bytes, Len);
enc_type('tk_Principal', Version, Value, Bytes, Len) ->
    %% Set MaxLength no 0 (i.e. unlimited).
    enc_sequence(Version, Value, 0, 'tk_octet', Bytes, Len);
enc_type({'tk_objref', _IFRId, Name}, Version, Value, Bytes, Len) ->
    enc_objref(Version, Name,Value, Bytes, Len);
enc_type({'tk_struct', _IFRId, _Name, ElementList}, Version, Value, Bytes, Len) -> 
    enc_struct(Version, Value, ElementList, Bytes, Len);
enc_type({'tk_union', _IFRId, _Name, DiscrTC, Default, ElementList},
	Version, Value, Bytes, Len) ->
    enc_union(Version, Value, DiscrTC, Default, ElementList, Bytes, Len);
enc_type({'tk_enum', _IFRId, _Name, ElementList}, _Version, Value, Bytes, Len) ->
    {Rest, Len1} = enc_align(Bytes, Len, 4),
    {cdrlib:enc_enum(atom_to_list(Value), ElementList, Rest), Len1 + 4};
enc_type({'tk_string', MaxLength}, Version, Value, Bytes, Len) ->
    enc_string(Version, Value, MaxLength, Bytes, Len);
enc_type({'tk_wstring', MaxLength}, Version, Value, Bytes, Len) ->
    enc_wstring(Version, Value, MaxLength, Bytes, Len);
enc_type({'tk_sequence', ElemTC, MaxLength}, Version, Value, Bytes, Len) ->
    enc_sequence(Version, Value, MaxLength, ElemTC, Bytes, Len);
enc_type({'tk_array', ElemTC, Size}, Version, Value, Bytes, Len) -> 
    enc_array(Version, Value, Size, ElemTC, Bytes, Len);
enc_type({'tk_alias', _IFRId, _Name, TC}, Version, Value, Bytes, Len) ->
    enc_type(TC, Version, Value, Bytes, Len);
enc_type({'tk_except', IFRId, Name, ElementList}, Version, Value, Bytes, Len) ->
    enc_exception(Version, Name, IFRId, Value, ElementList, Bytes, Len);
enc_type({'tk_fixed', Digits, Scale}, Version, Value, Bytes, Len) ->
    enc_fixed(Version, Digits, Scale, Value, Bytes, Len);
enc_type(Type, _, Value, _, _) ->
    orber:dbg("[~p] cdr_encode:type(~p, ~p)~n"
	      "Incorrect TypeCode or unsupported type.", 
	      [?LINE, Type, Value], ?DEBUG_LEVEL),
    corba:raise(#'MARSHAL'{minor=(?ORBER_VMCID bor 13), completion_status=?COMPLETED_MAYBE}).




%%-----------------------------------------------------------------
%% Func: enc_fixed
%%-----------------------------------------------------------------
%% Digits eq. total number of digits.
%% Scale  eq. position of the decimal point.
%% E.g. fixed<5,2> - "123.45" eq. #fixed{digits = 5, scale = 2, value = 12345}
%% E.g. fixed<4,2> - "12.34"  eq. #fixed{digits = 4, scale = 2, value = 1234}
%% These are encoded as:
%% ## <5,2> ##  ## <4,2> ##
%%     1,2          0,1     eq. 1 octet
%%     3,4          2,3
%%     5,0xC        4,0xC
%%
%% Each number is encoded as a half-octet. Note, for <4,2> a zero is
%% added first to to be able to create "even" octets.
enc_fixed(Version, Digits, Scale, 
	  #fixed{digits = Digits, scale = Scale, value = Value}, Bytes, Len) 
  when integer(Value), integer(Digits), integer(Scale), Digits < 32, Digits >= Scale ->
    %% This isn't very efficient and we should improve it before supporting it
    %% officially.
    Odd = ?ODD(Digits),
    case integer_to_list(Value) of
	[$-|ValueList] when Odd == true ->
	    Padded = lists:duplicate((Digits-length(ValueList)), 0) ++ ValueList,
	    enc_fixed_2(Version, Digits, Scale, Padded, 
			Bytes, Len, ?FIXED_NEGATIVE);
	[$-|ValueList] ->
	    Padded = lists:duplicate((Digits-length(ValueList)), 0) ++ ValueList,
	    enc_fixed_2(Version, Digits, Scale, [0|Padded], 
			Bytes, Len, ?FIXED_NEGATIVE);
	ValueList when Odd == true ->
	    Padded = lists:duplicate((Digits-length(ValueList)), 0) ++ ValueList,
	    enc_fixed_2(Version, Digits, Scale, Padded, 
			Bytes, Len, ?FIXED_POSITIVE);
	ValueList ->
	    Padded = lists:duplicate((Digits-length(ValueList)), 0) ++ ValueList,
	    enc_fixed_2(Version, Digits, Scale, [0|Padded], 
			Bytes, Len, ?FIXED_POSITIVE)
    end;
enc_fixed(_Version, Digits, Scale, Fixed, _Bytes, _Len) ->
    orber:dbg("[~p] cdr_encode:enc_fixed(~p, ~p, ~p)~n"
	      "The supplied fixed type incorrect. Check that the 'digits' and 'scale' field~n"
	      "match the definition in the IDL-specification. The value field must be~n"
	      "a list of Digits lenght.", 
	      [?LINE, Digits, Scale, Fixed], ?DEBUG_LEVEL),
    corba:raise(#'MARSHAL'{completion_status=?COMPLETED_MAYBE}).

enc_fixed_2(_Version, _Digits, _Scale, [D1], Bytes, Len, Sign) ->
    {[<<D1:4,Sign:4>>|Bytes], Len+1};
enc_fixed_2(Version, Digits, Scale, [D1, D2|Ds], Bytes, Len, Sign) ->
    %% We could convert the ASCII-value to digit values but the bit-syntax will
    %% truncate it correctly.
    enc_fixed_2(Version, Digits, Scale, Ds, [<<D1:4,D2:4>> | Bytes], Len+1, Sign);
enc_fixed_2(_Version, Digits, Scale, Value, _Bytes, _Len, Sign) ->
    orber:dbg("[~p] cdr_encode:enc_fixed_2(~p, ~p, ~p, ~p)~n"
	      "The supplied fixed type incorrect. Most likely the 'digits' field don't match the~n"
	      "supplied value. Hence, check that the value is correct.", 
	      [?LINE, Digits, Scale, Value, Sign], ?DEBUG_LEVEL),
    corba:raise(#'MARSHAL'{completion_status=?COMPLETED_MAYBE}). 



%%-----------------------------------------------------------------
%% Func: enc_sequence/5
%%-----------------------------------------------------------------
%% This is a special case used when encoding encapsualted data, i.e., contained
%% in an octet-sequence.
enc_sequence(_Version, Sequence, MaxLength, 'tk_octet', Bytes, Len)
  when binary(Sequence) ->
    {ByteSequence, Len1} = enc_align(Bytes, Len, 4),
    Size = size(Sequence),
    if
	Size > MaxLength, MaxLength > 0 ->
	    orber:dbg("[~p] cdr_encode:enc_sequnce(~p, ~p). Sequence exceeds max.", 
		      [?LINE, Sequence, MaxLength], ?DEBUG_LEVEL),
	    corba:raise(#'MARSHAL'{minor=(?ORBER_VMCID bor 19), 
				   completion_status=?COMPLETED_MAYBE});
	true ->
	    ByteSequence1 = cdrlib:enc_unsigned_long(Size, ByteSequence),
	    {[Sequence |ByteSequence1], Len1 + 4 + Size}
    end;
enc_sequence(Version, Sequence, MaxLength, TypeCode, Bytes, Len) ->
    Length = length(Sequence),
    if
	Length > MaxLength, MaxLength > 0 ->
	    orber:dbg("[~p] cdr_encode:enc_sequnce(~p, ~p). Sequence exceeds max.", 
		      [?LINE, Sequence, MaxLength], ?DEBUG_LEVEL),
	    corba:raise(#'MARSHAL'{minor=(?ORBER_VMCID bor 19), 
				   completion_status=?COMPLETED_MAYBE});
	true ->
	    {ByteSequence, Len1} = enc_align(Bytes, Len, 4),
	    ByteSequence1 = cdrlib:enc_unsigned_long(Length, ByteSequence),
	    enc_sequence1(Version, Sequence, TypeCode, ByteSequence1, Len1 + 4)
    end.

%%-----------------------------------------------------------------
%% Func: enc_sequence1/4
%%-----------------------------------------------------------------
enc_sequence1(_Version, [], _TypeCode, Bytes, Len) ->
    {Bytes, Len};
enc_sequence1(_Version, CharSeq, 'tk_char', Bytes, Len) -> 
    {[list_to_binary(CharSeq) |Bytes], Len + length(CharSeq)};
enc_sequence1(_Version, OctetSeq, 'tk_octet', Bytes, Len) -> 
    {[list_to_binary(OctetSeq) |Bytes], Len + length(OctetSeq)};
enc_sequence1(Version, [Object| Rest], TypeCode, Bytes, Len) -> 
    {ByteSequence, Len1} = enc_type(TypeCode, Version, Object, Bytes, Len),
    enc_sequence1(Version, Rest, TypeCode, ByteSequence, Len1).

%%-----------------------------------------------------------------
%% Func: enc_array/4
%%-----------------------------------------------------------------
enc_array(Version, Array, Size, TypeCode, Bytes, Len) when size(Array) == Size ->
    Sequence = tuple_to_list(Array),
    enc_sequence1(Version, Sequence, TypeCode, Bytes, Len);
enc_array(_,Array, Size, _, _, _) ->
    orber:dbg("[~p] cdr_encode:enc_array(~p, ~p). Incorrect size.", 
	      [?LINE, Array, Size], ?DEBUG_LEVEL),
    corba:raise(#'MARSHAL'{minor=(?ORBER_VMCID bor 15), completion_status=?COMPLETED_MAYBE}).

%%-----------------------------------------------------------------
%% Func: enc_string/4
%%-----------------------------------------------------------------
enc_string(_Version, String, MaxLength, Bytes, Len) ->
    StrLen = length(String),
    if
	StrLen > MaxLength, MaxLength > 0 ->
	    orber:dbg("[~p] cdr_encode:enc_string(~p, ~p). String exceeds max.", 
		      [?LINE, String, MaxLength], ?DEBUG_LEVEL),
	    corba:raise(#'MARSHAL'{minor=(?ORBER_VMCID bor 16), 
				   completion_status=?COMPLETED_MAYBE});
	true ->
	    {ByteSequence, Len1} = enc_align(Bytes, Len, 4),
	    ByteSequence1 = cdrlib:enc_unsigned_long(StrLen + 1, ByteSequence),
	    {cdrlib:enc_octet(0, [String | ByteSequence1]), Len1 + StrLen + 5}
    end.
   

%%-----------------------------------------------------------------
%% Func: enc_wstring/4
%%-----------------------------------------------------------------
enc_wstring({1,2}, String, MaxLength, Bytes, Len) ->
    %% Encode the length of the string (ulong).
    {Bytes1, Len1} = enc_align(Bytes, Len, 4),
    %% For IIOP-1.2 the length is the total number of octets. Hence, since the wchar's
    %% we accepts is encoded as <<255, 255>> the total size is 2*length of the list.
    ListLen = length(String),
    if
	ListLen > MaxLength, MaxLength > 0 ->
	    corba:raise(#'MARSHAL'{minor=(?ORBER_VMCID bor 16), 
				   completion_status=?COMPLETED_MAYBE});
	true ->
	    StrLen = ListLen * 2,
	    Bytes2 = cdrlib:enc_unsigned_long(StrLen, Bytes1),
	    %% For IIOP-1.2 no terminating null character is used.
	    enc_sequence1({1,2}, String, 'tk_ushort', Bytes2, Len1+4)
    end;
enc_wstring(Version, String, MaxLength, Bytes, Len) ->
    %% Encode the length of the string (ulong).
    {Bytes1, Len1} = enc_align(Bytes, Len, 4),
    ListLen = length(String),
    if
	ListLen > MaxLength, MaxLength > 0 ->
	    corba:raise(#'MARSHAL'{minor=(?ORBER_VMCID bor 16), 
				   completion_status=?COMPLETED_MAYBE});
	true ->
	    StrLen = ListLen + 1,
	    Bytes2 = cdrlib:enc_unsigned_long(StrLen, Bytes1),
	    {Bytes3, Len3} = enc_sequence1(Version, String, 'tk_wchar', Bytes2, Len1+4),
	    %% The terminating null character is also a wchar.
	    {cdrlib:enc_unsigned_short(0, Bytes3), Len3+2}
    end.


%%-----------------------------------------------------------------
%% Func: enc_union/5
%%-----------------------------------------------------------------
enc_union(Version, {_, Label, Value}, DiscrTC, Default, TypeCodeList, Bytes, Len) ->
    {ByteSequence, Len1} = enc_type(DiscrTC, Version, Label, Bytes, Len),
    Label2 = stringify_enum(DiscrTC,Label),
    enc_union2(Version, {Label2, Value},TypeCodeList, Default, 
	      ByteSequence, Len1, undefined).

enc_union2(_Version, _What, [], Default, Bytes, Len, _) when Default < 0 ->
    {Bytes, Len};
enc_union2(Version, {_, Value}, [], _Default, Bytes, Len, Type) -> 
    enc_type(Type, Version, Value, Bytes, Len);
enc_union2(Version, {Label,Value} ,[{Label, _Name, Type} |_List], 
	   _Default, Bytes, Len, _) ->
    enc_type(Type, Version, Value, Bytes, Len);
enc_union2(Version, Union ,[{default, _Name, Type} |List], Default, Bytes, Len, _) ->
    enc_union2(Version, Union, List, Default, Bytes, Len, Type);
enc_union2(Version, Union,[_ | List], Default, Bytes, Len, DefaultType) ->
    enc_union2(Version, Union, List, Default, Bytes, Len, DefaultType).

stringify_enum({tk_enum, _,_,_}, Label) ->
    atom_to_list(Label);
stringify_enum(_, Label) ->
    Label.
%%-----------------------------------------------------------------
%% Func: enc_struct/4
%%-----------------------------------------------------------------
enc_struct(Version, Struct, TypeCodeList, Bytes, Len) ->
    [_Name | StructList] = tuple_to_list(Struct),
    enc_struct1(Version, StructList, TypeCodeList, Bytes, Len).

enc_struct1(_Version, [], [], Bytes, Len) ->
    {Bytes, Len};
enc_struct1(Version, [Object | Rest], [{_ElemName, ElemType} | TypeCodeList], Bytes,
	    Len) ->
    {ByteSequence, Len1} = enc_type(ElemType, Version, Object, Bytes, Len),
    enc_struct1(Version, Rest, TypeCodeList, ByteSequence, Len1).

%%-----------------------------------------------------------------
%% Func: enc_objref/4
%%-----------------------------------------------------------------
enc_objref(Version, _Name, Value, Bytes, Len) ->
     iop_ior:code(Version, Value, Bytes, Len).
      
%%-----------------------------------------------------------------
%% Func: enc_exception/5
%%-----------------------------------------------------------------
enc_exception(Version, _Name, IFRId, Value, ElementList, Bytes, Len) ->
    [_Name1, _TypeId | Args] = tuple_to_list(Value),
    {Bytes1, Len1} = enc_type({'tk_string', 0}, Version, IFRId , Bytes, Len),
    enc_exception_1(Version, Args, ElementList, Bytes1, Len1).

enc_exception_1(_Version, [], [], Bytes, Len) ->
    {Bytes, Len};
enc_exception_1(Version, [Arg |Args], [{_ElemName, ElemType} |ElementList],
		Bytes, Len) ->
    {Bytes1, Len1} = enc_type(ElemType, Version, Arg, Bytes, Len),
    enc_exception_1(Version, Args, ElementList, Bytes1, Len1).
    

%%-----------------------------------------------------------------
%% Func: enc_type_code/3
%%-----------------------------------------------------------------
enc_type_code('tk_null', Version, Message, Len) ->
    enc_type('tk_ulong', Version, 0, Message, Len);
enc_type_code('tk_void', Version, Message, Len) ->
    enc_type('tk_ulong', Version, 1, Message, Len);
enc_type_code('tk_short', Version, Message, Len) ->
    enc_type('tk_ulong', Version, 2, Message, Len);
enc_type_code('tk_long', Version, Message, Len) ->
    enc_type('tk_ulong', Version, 3, Message, Len);
enc_type_code('tk_longlong', Version, Message, Len) ->
    enc_type('tk_ulong', Version, 23, Message, Len);
enc_type_code('tk_longdouble', Version, Message, Len) ->
    enc_type('tk_ulong', Version, 25, Message, Len);
enc_type_code('tk_ushort', Version, Message, Len) ->
    enc_type('tk_ulong', Version, 4, Message, Len);
enc_type_code('tk_ulong', Version, Message, Len) ->
    enc_type('tk_ulong', Version, 5, Message, Len);
enc_type_code('tk_ulonglong', Version, Message, Len) ->
    enc_type('tk_ulong', Version, 24, Message, Len);
enc_type_code('tk_float', Version, Message, Len) ->
    enc_type('tk_ulong', Version, 6, Message, Len);
enc_type_code('tk_double', Version, Message, Len) ->
    enc_type('tk_ulong', Version, 7, Message, Len);
enc_type_code('tk_boolean', Version, Message, Len) ->
    enc_type('tk_ulong', Version, 8, Message, Len);
enc_type_code('tk_char', Version, Message, Len) ->
    enc_type('tk_ulong', Version, 9, Message, Len);
enc_type_code('tk_wchar', Version, Message, Len) ->
    enc_type('tk_ulong', Version, 26, Message, Len);
enc_type_code('tk_octet', Version, Message, Len) ->
    enc_type('tk_ulong', Version, 10, Message, Len);
enc_type_code('tk_any', Version, Message, Len) ->
    enc_type('tk_ulong', Version, 11, Message, Len);
enc_type_code('tk_TypeCode', Version, Message, Len) ->
    enc_type('tk_ulong', Version, 12, Message, Len);
enc_type_code('tk_Principal', Version, Message, Len) ->
    enc_type('tk_ulong', Version, 13, Message, Len);
enc_type_code({'tk_objref', RepId, Name}, Version, Message, Len) ->
    {Message1, Len1} = enc_type('tk_ulong', Version, 14, Message, Len),
    {Message2, _} = enc_byte_order(Version, []),
    {ComplexParams, Len2} = enc_type({'tk_struct', "", "", [{"repository ID", {'tk_string', 0}},
				    {"name", {'tk_string', 0}}]},
				     Version,
				     {"", RepId, Name},
				     Message2, 1),
    encode_complex_tc_paramters(lists:reverse(ComplexParams), Len2, Message1, Len1);
enc_type_code({'tk_struct', RepId, SimpleName, ElementList}, Version, Message, Len) ->
    %% Using SimpleName should be enough (and we avoid some overhead). 
    %% Name = ifrid_to_name(RepId),
    {Message1, Len1} = enc_type('tk_ulong', Version, 15, Message, Len),
    {Message2, _} = enc_byte_order(Version, []),
    {ComplexParams, Len2} = enc_type({'tk_struct', "", "", [{"repository ID", {'tk_string', 0}},
				    {"name", {'tk_string', 0}},
				    {"element list",
				     {'tk_sequence', {'tk_struct', "","",
						      [{"member name", {'tk_string', 0}},
						       {"member type", 'tk_TypeCode'}]},
				      0}}]},
				     Version,
				     {"", RepId, SimpleName,
				      lists:map(fun({N,T}) -> {"",N,T} end, ElementList)},
				     Message2, 1),
    encode_complex_tc_paramters(lists:reverse(ComplexParams), Len2, Message1, Len1);
enc_type_code({'tk_union', RepId, Name, DiscrTC, Default, ElementList},
	      Version, Message, Len) ->
    NewElementList =
	case check_enum(DiscrTC) of
	    true ->
		lists:map(fun({L,N,T}) -> {"",list_to_atom(L),N,T} end, ElementList);
	    false ->
		lists:map(fun({L,N,T}) -> {"",L,N,T} end, ElementList)
	end,
    {Message1, Len1} = enc_type('tk_ulong', Version, 16, Message, Len),
    {Message2, _} = enc_byte_order(Version, []),
    {ComplexParams, Len2} = enc_type({'tk_struct', "", "", [{"repository ID", {'tk_string', 0}},
				    {"name", {'tk_string', 0}},
				    {"discriminant type", 'tk_TypeCode'},
				    {"default used", 'tk_long'},
				    {"element list",
				     {'tk_sequence', {'tk_struct', "","",
						      [{"label value", DiscrTC},
						       {"member name", {'tk_string', 0}},
						       {"member type", 'tk_TypeCode'}]},
				      0}}]},
				     Version,
				     {"", RepId, Name, DiscrTC, Default, NewElementList},
				     Message2, 1),
    encode_complex_tc_paramters(lists:reverse(ComplexParams), Len2, Message1, Len1);
enc_type_code({'tk_enum', RepId, Name, ElementList}, Version, Message, Len) ->
    {Message1, Len1} = enc_type('tk_ulong', Version, 17, Message, Len),
    {Message2, _} = enc_byte_order(Version, []),
    {ComplexParams, Len2} = enc_type({'tk_struct', "", "", [{"repository ID", {'tk_string', 0}},
				    {"name", {'tk_string', 0}},
				    {"element list",
				     {'tk_sequence', {'tk_string', 0}, 0}}]},
				     Version,
				     {"", RepId, Name, ElementList},
				     Message2, 1),
    encode_complex_tc_paramters(lists:reverse(ComplexParams), Len2, Message1, Len1);
enc_type_code({'tk_string', MaxLength}, Version, Message, Len) ->
     enc_type({'tk_struct', "", "", [{"TCKind", 'tk_ulong'},
				    {"max length", 'tk_ulong'}]},
	      Version,
	      {"", 18, MaxLength},
	      Message, Len);
enc_type_code({'tk_wstring', MaxLength}, Version, Message, Len) ->
     enc_type({'tk_struct', "", "", [{"TCKind", 'tk_ulong'},
				    {"max length", 'tk_ulong'}]},
	      Version,
	      {"", 27, MaxLength},
	      Message, Len);
enc_type_code({'tk_sequence', ElemTC, MaxLength}, Version, Message, Len) ->
    {Message1, Len1} = enc_type('tk_ulong', Version, 19, Message, Len),
    {Message2, _} = enc_byte_order(Version, []),
     {ComplexParams, Len2} = enc_type({'tk_struct', "", "", [{"element type", 'tk_TypeCode'},
				    {"max length", 'tk_ulong'}]},
				      Version,
				      {"", ElemTC, MaxLength},
				      Message2, 1),
    encode_complex_tc_paramters(lists:reverse(ComplexParams), Len2, Message1, Len1);
enc_type_code({'tk_array', ElemTC, Length}, Version, Message, Len) ->
    {Message1, Len1} = enc_type('tk_ulong', Version, 20, Message, Len),
    {Message2, _} = enc_byte_order(Version, []),
    {ComplexParams, Len2} = enc_type({'tk_struct', "", "", [{"element type", 'tk_TypeCode'},
				    {"length", 'tk_ulong'}]},
				     Version,
				     {"", ElemTC, Length},
				     Message2, 1),
    encode_complex_tc_paramters(lists:reverse(ComplexParams), Len2, Message1, Len1);
enc_type_code({'tk_alias', RepId, Name, TC}, Version, Message, Len) ->
    {Message1, Len1} = enc_type('tk_ulong', Version, 21, Message, Len),
    {Message2, _} = enc_byte_order(Version, []),
    {ComplexParams, Len2} = enc_type({'tk_struct', "", "", [{"repository ID", {'tk_string', 0}},
				     {"name", {'tk_string', 0}},
				     {"TypeCode", 'tk_TypeCode'}]},
				     Version,
				     {"", RepId, Name, TC},
				     Message2, 1),
    encode_complex_tc_paramters(lists:reverse(ComplexParams), Len2, Message1, Len1);
enc_type_code({'tk_except', RepId, Name, ElementList}, Version, Message, Len) ->
    {Message1, Len1} = enc_type('tk_ulong', Version, 22, Message, Len),
    {Message2, _} = enc_byte_order(Version, []),
    {ComplexParams, Len2} = enc_type({'tk_struct', "", "", [{"repository ID", {'tk_string', 0}},
				    {"name", {'tk_string', 0}},
				    {"element list",
				     {'tk_sequence',
				      {'tk_struct', "", "",
				       [{"member name", {'tk_string', 0}},
				       {"member type", 'tk_TypeCode'}]}, 0}}]},
				     Version,
				     {"", RepId, Name,
				      lists:map(fun({N,T}) -> {"",N,T} end, ElementList)},
				     Message2, 1),
    encode_complex_tc_paramters(lists:reverse(ComplexParams), Len2, Message1, Len1);
enc_type_code({'tk_fixed', Digits, Scale}, Version, Message, Len) ->
     enc_type({'tk_struct', "", "", [{"TCKind", 'tk_ulong'},
				     {"digits", 'tk_ushort'},
				     {"scale", 'tk_short'}]},
	      Version,
	      {"", 28, Digits, Scale},
	      Message, Len);
enc_type_code({'tk_value', RepId, Name, ValueModifier, TC, ElementList}, Version, Message, Len) ->
    {Message1, Len1} = enc_type('tk_ulong', Version, 29, Message, Len),
    {Message2, _} = enc_byte_order(Version, []),
    {ComplexParams, Len2} = enc_type({'tk_struct', "", "", 
				      [{"repository ID", {'tk_string', 0}},
				       {"name", {'tk_string', 0}},
				       {"ValueModifier", 'tk_short'},
				       {"TypeCode", 'tk_TypeCode'},
				       {"element list",
					{'tk_sequence', 
					 {'tk_struct', "","",
					  [{"member name", {'tk_string', 0}},
					   {"member type", 'tk_TypeCode'},
					   {"Visibility", 'tk_short'}]},
					 0}}]},
				     Version,
				     {"", RepId, Name, ValueModifier, TC,
				      lists:map(fun({N,T,V}) -> {"",N,T,V} end, ElementList)},
				     Message2, 1),
    encode_complex_tc_paramters(lists:reverse(ComplexParams), Len2, Message1, Len1);
enc_type_code({'tk_value_box', RepId, Name, TC}, Version, Message, Len) ->
    {Message1, Len1} = enc_type('tk_ulong', Version, 30, Message, Len),
    {Message2, _} = enc_byte_order(Version, []),
    {ComplexParams, Len2} = enc_type({'tk_struct', "", "", 
				      [{"repository ID", {'tk_string', 0}},
				       {"name", {'tk_string', 0}},
				       {"TypeCode", 'tk_TypeCode'}]},
				     Version,
				     {"", RepId, Name, TC},
				     Message2, 1),
    encode_complex_tc_paramters(lists:reverse(ComplexParams), Len2, Message1, Len1);
enc_type_code({'tk_native', RepId, Name}, Version, Message, Len) ->
    {Message1, Len1} = enc_type('tk_ulong', Version, 31, Message, Len),
    {Message2, _} = enc_byte_order(Version, []),
    {ComplexParams, Len2} = enc_type({'tk_struct', "", "", 
				      [{"repository ID", {'tk_string', 0}},
				       {"name", {'tk_string', 0}}]},
				     Version,
				     {"", RepId, Name},
				     Message2, 1),
    encode_complex_tc_paramters(lists:reverse(ComplexParams), Len2, Message1, Len1);
enc_type_code({'tk_abstract_interface', RepId, Name}, Version, Message, Len) ->
    {Message1, Len1} = enc_type('tk_ulong', Version, 32, Message, Len),
    {Message2, _} = enc_byte_order(Version, []),
    {ComplexParams, Len2} = enc_type({'tk_struct', "", "", 
				      [{"RepositoryId", {'tk_string', 0}},
				       {"name", {'tk_string', 0}}]},
				     Version,
				     {"", RepId, Name},
				     Message2, 1),
    encode_complex_tc_paramters(lists:reverse(ComplexParams), Len2, Message1, Len1);
enc_type_code({'tk_local_interface', RepId, Name}, Version, Message, Len) ->
    {Message1, Len1} = enc_type('tk_ulong', Version, 33, Message, Len),
    {Message2, _} = enc_byte_order(Version, []),
    {ComplexParams, Len2} = enc_type({'tk_struct', "", "", 
				      [{"RepositoryId", {'tk_string', 0}},
				       {"name", {'tk_string', 0}}]},
				     Version,
				     {"", RepId, Name},
				     Message2, 1),
    encode_complex_tc_paramters(lists:reverse(ComplexParams), Len2, Message1, Len1);
enc_type_code({'none', Indirection}, Version, Message, Len) ->  %% placeholder
     enc_type({'tk_struct', "", "", [{"TCKind", 'tk_ulong'},
				    {"indirection", 'tk_long'}]},
	      Version,
	      {"", 16#ffffffff, Indirection},
	      Message, Len);
enc_type_code(Type, _, _, _) ->
    orber:dbg("[~p] cdr_encode:enc_type_code(~p); No match.", 
	      [?LINE, Type], ?DEBUG_LEVEL),
    corba:raise(#'MARSHAL'{minor=(?ORBER_VMCID bor 7), completion_status=?COMPLETED_MAYBE}).

check_enum({'tk_enum', _, _, _}) ->
    true;
check_enum(_) ->
    false.

encode_complex_tc_paramters(Value, ValueLength, Message, Len) ->
    {Message1, _Len1} = enc_align(Message, Len, 4),
    Message2 = cdrlib:enc_unsigned_long(ValueLength, Message1),
    {[Value |Message2], Len+ValueLength+4}.

%%-----------------------------------------------------------------
%% Func: enc_align/1
%%-----------------------------------------------------------------
enc_align(R, Len, Alignment) ->
    Rem = Len rem Alignment,
    if Rem == 0 ->
	    {R, Len};
       true ->
	    Diff = Alignment - Rem,
	    {add_bytes(R, Diff), Len + Diff}
    end.

add_bytes(R, 0) ->
    R;
add_bytes(R, 1) ->
    [<<16#01:8>> | R];
add_bytes(R, 2) ->
    [<<16#02:8, 16#02:8>> | R];
add_bytes(R, 3) ->
    [<<16#03:8, 16#03:8, 16#03:8>> | R];
add_bytes(R, 4) ->
    [<<16#04:8, 16#04:8, 16#04:8, 16#04:8>> | R];
add_bytes(R, 5) ->
    [<<16#05:8, 16#05:8, 16#05:8, 16#05:8, 16#05:8>> | R];
add_bytes(R, 6) ->
    [<<16#06:8, 16#06:8, 16#06:8, 16#06:8, 16#06:8, 16#06:8>> | R];
add_bytes(R, 7) ->
    [<<16#07:8, 16#07:8, 16#07:8, 16#07:8, 16#07:8, 16#07:8, 16#07:8>> | R];
add_bytes(R,N) ->
    add_bytes([<<16#08:8>> | R], N - 1).

