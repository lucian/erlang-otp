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
%%----------------------------------------------------------------------
%% File    : orber_ifr_repository.erl
%% Purpose : Code for Repository
%% Created : 14 May 1997
%%----------------------------------------------------------------------

-module(orber_ifr_repository).

-export(['_get_def_kind'/1,
	 destroy/1,
	 lookup/2,
	 contents/3,
	 lookup_name/5,
	 describe_contents/4,
	 create_module/4,
	 create_constant/6,
	 create_struct/5,
	 create_union/6,
	 create_enum/5,
	 create_alias/5,
	 create_interface/5,
	 create_exception/5,
	 lookup_id/2,
	 get_primitive/2,
	 create_string/2,
	 create_wstring/2,
	 create_fixed/3,
	 create_sequence/3,
	 create_array/3,
	 create_idltype/2,			%not in CORBA 2.0
	 create_primitivedef/1			%not in CORBA 2.0
	]).

-import(orber_ifr_utils,[set_object/1,
		   get_field/2,
		   makeref/1,
		   unique/0
		  ]).

-include("orber_ifr.hrl").
-include("ifr_objects.hrl").
-include_lib("orber/include/corba.hrl").

%%%======================================================================
%%% Repository (Container (IRObject))

%%%----------------------------------------------------------------------
%%%  Interfaces inherited from IRObject

'_get_def_kind'({ObjType, ObjID}) ?tcheck(ir_Repository, ObjType) ->
    orber_ifr_irobject:'_get_def_kind'({ObjType, ObjID}).

destroy({ObjType,ObjID}) ?tcheck(ir_Repository, ObjType) ->
    ?ifr_exception("Destroying a repository is an error", {ObjType,ObjID}).

%%%----------------------------------------------------------------------
%%%  Interfaces inherited from Container

lookup({ObjType,ObjID}, Search_name) ?tcheck(ir_Repository, ObjType) ->
    orber_ifr_container:lookup({ObjType, ObjID}, Search_name).

contents({ObjType,ObjID}, Limit_type, Exclude_inherited)
	?tcheck(ir_Repository, ObjType) ->
    orber_ifr_container:contents({ObjType,ObjID},Limit_type,Exclude_inherited).

lookup_name({ObjType,ObjID}, Search_name, Levels_to_search, Limit_type,
	    Exclude_inherited) ?tcheck(ir_Repository, ObjType) ->
    orber_ifr_container:lookup_name({ObjType, ObjID}, Search_name,
				    Levels_to_search, Limit_type,
				    Exclude_inherited).

describe_contents({ObjType,ObjID}, Limit_type, Exclude_inherited,
		  Max_returned_objs) ?tcheck(ir_Repository, ObjType) ->
    orber_ifr_container:describe_contents({ObjType, ObjID}, Limit_type,
					  Exclude_inherited,Max_returned_objs).

create_module({ObjType,ObjID}, Id, Name, Version)
	     ?tcheck(ir_Repository, ObjType) ->
    orber_ifr_container:create_module({ObjType,ObjID}, Id, Name, Version).

create_constant({ObjType,ObjID}, Id, Name, Version, Type, Value)
	       ?tcheck(ir_Repository, ObjType) ->
    orber_ifr_container:create_constant({ObjType,ObjID}, Id, Name, Version,
					Type, Value).

create_struct({ObjType,ObjID}, Id, Name, Version, Members)
	     ?tcheck(ir_Repository, ObjType) ->
    orber_ifr_container:create_struct({ObjType,ObjID}, Id, Name, Version,
				      Members).

create_union({ObjType,ObjID}, Id, Name, Version, Discriminator_type, Members)
	    ?tcheck(ir_Repository, ObjType) ->
    orber_ifr_container:create_union({ObjType,ObjID}, Id, Name, Version,
				     Discriminator_type, Members).

create_enum({ObjType,ObjID}, Id, Name, Version, Members)
	   ?tcheck(ir_Repository, ObjType) ->
    orber_ifr_container:create_enum({ObjType,ObjID},Id,Name,Version,Members).

create_alias({ObjType,ObjID}, Id, Name, Version, Original_type)
	    ?tcheck(ir_Repository, ObjType) ->
    orber_ifr_container:create_alias({ObjType,ObjID}, Id, Name, Version,
				     Original_type).

create_interface({ObjType,ObjID}, Id, Name, Version, Base_interfaces)
		?tcheck(ir_Repository, ObjType) ->
    orber_ifr_container:create_interface({ObjType,ObjID}, Id, Name, Version,
					 Base_interfaces).

create_exception({ObjType, ObjID}, Id, Name, Version, Members)
		?tcheck(ir_Repository, ObjType) ->
    orber_ifr_container:create_exception({ObjType, ObjID}, Id, Name, Version,
					 Members).

%%%----------------------------------------------------------------------
%%% Non-inherited interfaces

lookup_id({ObjType,ObjID}, Search_id) ?tcheck(ir_Repository, ObjType) ->
    Contents = orber_ifr_container:contents({ObjType, ObjID}, dk_All, false),
    case lists:filter(fun(X) -> orber_ifr_contained:'_get_id'(X) == Search_id
		 end, Contents) of
	[] ->
	    [];
	[ObjRef] ->
	    ObjRef;
	[H|T] ->
	    %% This case is just a safety-guard; orber_ifr_container:contents
	    %% sometimes return duplicates due to inheritance.
	    case lists:any(fun(X) -> X =/= H end, T) of
		false ->
		    H;
		true ->
		    corba:raise(#'INTERNAL'{completion_status=?COMPLETED_NO})
	    end
    end.

get_primitive({ObjType,ObjID}, Kind) ?tcheck(ir_Repository, ObjType) ->
    Primitivedefs = get_field({ObjType,ObjID}, primitivedefs),
    lists:filter(fun(X) -> orber_ifr_primitivedef:'_get_kind'(X) == Kind end,
		 Primitivedefs).

%%% It is probably incorrect to add the anonymous typedefs (string,
%%% sequence and array) to the field primitivdefs in the Repository.
%%% It is probably also not correct to add them to the contents field.
%%% Perhaps it is necessary to add another field in the ir_Repository
%%% record for anonymous typedefs? Then again, perhaps it is not
%%% necessary to keep the anonymous typedefs anywhere? According to
%%% the specification it is the callers responsibility to destroy the
%%% anonymous typedef if it is not successfully used.

%%add_to_repository({ObjType,ObjID},Object) ?tcheck(ir_Repository, ObjType) ->
%%    F = fun() ->
%%		[Repository_obj] = mnesia:read({ObjType,ObjID}),
%%		ObjectRef = makeref(Object),
%%		New_repository_obj =
%%		    orber_ifr_utils:construct(Repository_obj,contents,
%%			      [ObjectRef | orber_ifr_utils:select(Repository_obj,
%%						  primitivedefs)]),
%%		mnesia:write(New_repository_obj),
%%		mnesia:write(Object)
%%	end,
%%    orber_ifr_utils:ifr_transaction_write(F).

create_string({ObjType,ObjID}, Bound) ?tcheck(ir_Repository, ObjType) ->
    New_string = #ir_StringDef{ir_Internal_ID = unique(),
			       def_kind = dk_String,
			       type = {tk_string, Bound},
			       bound = Bound},
%%    add_to_repository({ObjType,ObjID},New_string),
    makeref(New_string).

create_wstring({ObjType,ObjID}, Bound) ?tcheck(ir_Repository, ObjType) ->
    NewWstring = #ir_WstringDef{ir_Internal_ID = unique(),
			       def_kind = dk_Wstring,
			       type = {tk_wstring, Bound},
			       bound = Bound},
%%    add_to_repository({ObjType,ObjID},New_string),
    makeref(NewWstring).

create_fixed({ObjType,ObjID}, Digits, Scale) ?tcheck(ir_Repository, ObjType) ->
    NewFixed = #ir_FixedDef{ir_Internal_ID = unique(),
			    def_kind = dk_Fixed,
			    type = {tk_fixed, Digits, Scale},
			    digits = Digits,
			    scale = Scale},
%%    add_to_repository({ObjType,ObjID},NewFixed),
    makeref(NewFixed).

create_sequence({ObjType,ObjID}, Bound, Element_type)
			    ?tcheck(ir_Repository, ObjType) ->
    Element_typecode = get_field(Element_type, type),
    New_sequence = #ir_SequenceDef{ir_Internal_ID = unique(),
				   def_kind = dk_Sequence,
				   type = {tk_sequence,Element_typecode,Bound},
				   bound = Bound,
				   element_type = Element_typecode,
				   element_type_def = Element_type},
%%    add_to_repository({ObjType,ObjID},New_sequence),
    makeref(New_sequence).

create_array({ObjType,ObjID}, Length, Element_type)
			 ?tcheck(ir_Repository, ObjType) ->
    Element_typecode = get_field(Element_type, type),
    New_array = #ir_ArrayDef{ir_Internal_ID = unique(),
			     def_kind = dk_Array,
			     type = {tk_array, Element_typecode, Length},
			     length = Length,
			     element_type = Element_typecode,
			     element_type_def = Element_type},
%%    add_to_repository({ObjType,ObjID},New_array),
    makeref(New_array).

%%%----------------------------------------------------------------------
%%% Extra interfaces (not in the IDL-spec for the IFR).

create_idltype({ObjType,ObjID}, Typecode) ?tcheck(ir_Repository, ObjType) ->
    New_idltype = #ir_IDLType{ir_Internal_ID = unique(),
			      def_kind = dk_none,
			      type=Typecode},
    set_object(New_idltype),
    makeref(New_idltype).

create_primitivedef(Pkind) ->
    Typecode = case Pkind of
		   pk_void ->
		       tk_void;
		   pk_short ->
		       tk_short;
		   pk_long ->
		       tk_long;
		   pk_longlong ->
		       tk_longlong;
		   pk_ushort ->
		       tk_ushort;
		   pk_ulong ->
		       tk_ulong;
		   pk_ulonglong ->
		       tk_ulonglong;
		   pk_float ->
		       tk_float;
		   pk_double ->
		       tk_double;
		   pk_boolean ->
		       tk_boolean;
		   pk_char ->
		       tk_char;
		   pk_wchar ->
		       tk_wchar;
		   pk_fixed ->
		       tk_fixed;
		   pk_octet ->
		       tk_octet;
		   pk_any ->
		       tk_any;
		   pk_TypeCode ->
		       tk_TypeCode;
		   pk_Principal ->
		       tk_Principal;
		   pk_string ->
		       orber_ifr_orb:create_string_tc(0);
		   pk_wstring ->
		       orber_ifr_orb:create_wstring_tc(0);
		   pk_objref ->
		       %%*** what should the Id and Name be here?
		       orber_ifr_orb:create_interface_tc("", "");
		   _ ->
		       ?ifr_exception("Illegal primitivekind ",Pkind)
	       end,
    New_primitivedef = #ir_PrimitiveDef{ir_Internal_ID = unique(),
					def_kind = dk_Primitive,
					type = Typecode,
					kind = Pkind},
    set_object(New_primitivedef),
    makeref(New_primitivedef).
