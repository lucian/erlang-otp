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

-module(beam_validator).

-export([file/1,files/1]).

%% Interface for compiler.
-export([module/2,format_error/1]).

-import(lists, [reverse/1,foldl/3,foreach/2]).

-define(MAXREG, 1024).

%-define(DEBUG, 1).
-ifdef(DEBUG).
-define(DBG_FORMAT(F, D), (io:format((F), (D)))).
-else.
-define(DBG_FORMAT(F, D), ok).
-endif.

%%%
%%% API functions.
%%%

files([F|Fs]) ->
    ?DBG_FORMAT("# Verifying: ~p~n", [F]),
    case file(F) of
	ok -> ok;
	{error,Es} -> 
	    io:format("~p:~n~s~n", [F,format_error(Es)])
    end,
    files(Fs);
files([]) -> ok.

file(Name) when is_list(Name) ->
    case case filename:extension(Name) of
	     ".S" -> s_file(Name);
	     ".beam" -> beam_file(Name)
	 end of
	[] -> ok;
	Es -> {error,Es}
    end.

%% To be called by the compiler.
module({Mod,Exp,Attr,Fs,Lc}=Code, _Opts)
  when is_atom(Mod), is_list(Exp), is_list(Attr), is_integer(Lc) ->
    case validate(Mod, Fs) of
	[] -> {ok,Code};
	Es0 ->
	    Es = [{?MODULE,E} || E <- Es0],
	    {error,[{atom_to_list(Mod),Es}]}
    end.

format_error([]) -> [];
format_error([{{M,F,A},{I,Off,Desc}}|Es]) ->
    [io_lib:format("  ~p:~p/~p+~p:~n    ~p - ~p~n", 
		   [M,F,A,Off,I,Desc])|format_error(Es)];
format_error([Error|Es]) ->
    [format_error(Error)|format_error(Es)];
format_error({{_M,F,A},{I,Off,Desc}}) ->
    io_lib:format(
      "function ~p/~p+~p:~n"
      "  Internal consistency check failed - please report this bug.~n"
      "  Instruction: ~p~n"
      "  Error:       ~p:~n", [F,A,Off,I,Desc]);
format_error({Module,Error}) ->
    [Module:format_error(Error)];
format_error(Error) ->
    io_lib:format("~p~n", [Error]).

%%%
%%% Local functions follow.
%%% 

s_file(Name) ->
    {ok,Is} = file:consult(Name),
    {value,{module,Module}} = lists:keysearch(module, 1, Is),
    Fs = find_functions(Is),
    validate(Module, Fs).

find_functions(Fs) ->
    find_functions_1(Fs, none, [], []).

find_functions_1([{function,Name,Arity,Entry}|Is], Func, FuncAcc, Acc0) ->
    Acc = add_func(Func, FuncAcc, Acc0),
    find_functions_1(Is, {Name,Arity,Entry}, [], Acc);
find_functions_1([I|Is], Func, FuncAcc, Acc) ->
    find_functions_1(Is, Func, [I|FuncAcc], Acc);
find_functions_1([], Func, FuncAcc, Acc) ->
    reverse(add_func(Func, FuncAcc, Acc)).

add_func(none, _, Acc) -> Acc;
add_func({Name,Arity,Entry}, Is, Acc) ->
    [{function,Name,Arity,Entry,reverse(Is)}|Acc].

beam_file(Name) ->
    try beam_disasm:file(Name) of
	{error,beam_lib,Reason} -> [{beam_lib,Reason}];
	{beam_file,L} ->
	    {value,{module,Module}} = lists:keysearch(module, 1, L),
	    {value,{code,Code}} = lists:keysearch(code, 1, L),
	    validate(Module, Code)
    catch _:_ -> [disassembly_failed]
    end.

%%%
%%% The validator follows.
%%%
%%% The purpose of the validator is find errors in the generated code
%%% that may cause the emulator to crash or behave strangely.
%%% We don't care about type errors in the user's code that will
%%% cause a proper exception at run-time.
%%%

%%% Things currently not checked. XXX
%%%
%%% - Heap allocation for floating point numbers.
%%% - Heap allocation for binaries.
%%% - That put_tuple is followed by the correct number of
%%%   put instructions.
%%%

%% validate([Function]) -> [] | [Error]
%%  A list of functions with their code. The code is in the same
%%  format as used in the compiler and in .S files.
validate(_Module, []) -> [];
validate(Module, [{function,Name,Ar,Entry,Code}|Fs]) ->
    try validate_1(Code, Name, Ar, Entry) of
	_ -> validate(Module, Fs)
    catch
	Error ->
	    [Error|validate(Module, Fs)];
	  error:Error ->
	    [validate_error(Error, Module, Name, Ar)|validate(Module, Fs)]
    end.

-ifdef(DEBUG).
validate_error(Error, Module, Name, Ar) ->
    exit(validate_error_1(Error, Module, Name, Ar)).
-else.
validate_error(Error, Module, Name, Ar) ->
    validate_error_1(Error, Module, Name, Ar).
-endif.
validate_error_1(Error, Module, Name, Ar) ->
    {{Module,Name,Ar},
     {internal_error,'_',{Error,erlang:get_stacktrace()}}}.

-record(st,				%Emulation state
	{x=init_regs(0, term),		%x register info.
	 y=init_regs(0, initialized),	%y register info.
	 f=init_fregs(),                %
	 numy=none,			%Number of y registers.
	 h=0,				%Available heap size.
	 fls=undefined,			%Floating point state.
	 ct=[],				%List of hot catch/try labels
	 bsm=undefined			%Bit syntax matching state.
	}).

-record(vst,				%Validator state
	{current=none,			%Current state
	 branched=gb_trees:empty()	%States at jumps
	}).

-ifdef(DEBUG).
print_st(#st{x=Xs,y=Ys,numy=NumY,h=H,ct=Ct}) ->
    io:format("  #st{x=~p~n"
	      "      y=~p~n"
	      "      numy=~p,h=~p,ct=~w~n",
	      [gb_trees:to_list(Xs),gb_trees:to_list(Ys),NumY,H,Ct]).
-endif.

validate_1(Is, Name, Arity, Entry) ->
    validate_2(labels(Is), Name, Arity, Entry).

validate_2({Ls1,[{func_info,{atom,Mod},{atom,Name},Arity}=_F|Is]},
	   Name, Arity, Entry) ->
    lists:foreach(fun (_L) -> ?DBG_FORMAT("  ~p.~n", [{label,_L}]) end, Ls1),
    ?DBG_FORMAT("  ~p.~n", [_F]),
    validate_3(labels(Is), Name, Arity, Entry, Mod, Ls1);
validate_2({Ls1,Is}, Name, Arity, _Entry) ->
    error({{'_',Name,Arity},{first(Is),length(Ls1),illegal_instruction}}).

validate_3({Ls2,Is}, Name, Arity, Entry, Mod, Ls1) ->
    lists:foreach(fun (_L) -> ?DBG_FORMAT("  ~p.~n", [{label,_L}]) end, Ls2),
    Offset = 1 + length(Ls1) + 1 + length(Ls2),
    EntryOK = (Entry == undefined) orelse lists:member(Entry, Ls2),
    if  EntryOK ->
	    St = init_state(Arity),
	    Vst = #vst{current=St,
		       branched=gb_trees_from_list([{L,St} || L <- Ls1])},
	    valfun(Is, {Mod,Name,Arity}, Offset, Vst);
	true ->
	    error({{Mod,Name,Arity},{first(Is),Offset,no_entry_label}})
    end.

first([X|_]) -> X;
first([]) -> [].

labels(Is) ->
    labels_1(Is, []).

labels_1([{label,L}|Is], R) ->
    labels_1(Is, [L|R]);
labels_1(Is, R) ->
    {lists:reverse(R),Is}.

init_state(Arity) ->
    Xs = init_regs(Arity, term),
    Ys = init_regs(0, initialized),
    #st{x=Xs,y=Ys,numy=none,h=0,ct=[]}.

init_regs(0, _) ->
    gb_trees:empty();
init_regs(N, Type) ->
    gb_trees_from_list([{R,Type} || R <- lists:seq(0, N-1)]).

valfun([], _MFA, _Offset, Vst) -> Vst;
valfun([I|Is], MFA, Offset, Vst) ->
    ?DBG_FORMAT("    ~p.\n", [I]),
    valfun(Is, MFA, Offset+1,
	   try valfun_1(I, Vst)
	   catch Error ->
		   error({MFA,{I,Offset,Error}})
	   end).

%% Instructions that are allowed in dead code or when failing,
%% that is while the state is undecided in some way.
valfun_1({label,Lbl}, #vst{current=St0,branched=B}=Vst) ->
    St = merge_states(Lbl, St0, B),
    Vst#vst{current=St,branched=gb_trees:enter(Lbl, St, B)};
valfun_1(_I, #vst{current=none}=Vst) ->
    %% Ignore instructions after erlang:error/1,2, which
    %% the original R10B compiler thought would return.
    ?DBG_FORMAT("Ignoring ~p\n", [_I]),
    Vst;
valfun_1({badmatch,Src}, Vst) ->
    assert_term(Src, Vst),
    kill_state(Vst);
valfun_1({case_end,Src}, Vst) ->
    assert_term(Src, Vst),
    kill_state(Vst);
valfun_1(if_end, Vst) ->
    kill_state(Vst);
valfun_1({try_case_end,Src}, Vst) ->
    assert_term(Src, Vst),
    kill_state(Vst);
%% Instructions that can not cause exceptions
valfun_1({move,Src,Dst}, Vst) ->
    Type = get_term_type(Src, Vst),
    set_type_reg(Type, Dst, Vst);
valfun_1({fmove,Src,{fr,_}=Dst}, Vst) ->
    assert_type(float, Src, Vst),
    set_freg(Dst, Vst);
valfun_1({fmove,{fr,_}=Src,Dst}, Vst) ->
    assert_freg_set(Src, Vst),
    assert_fls(checked, Vst),
    set_type_reg({float,[]}, Dst, Vst);
valfun_1({kill,{y,_}=Reg}, Vst) ->
    set_type_y(initialized, Reg, Vst);
valfun_1({init,{y,_}=Reg}, Vst) ->
    set_type_y(initialized, Reg, Vst);
valfun_1({test_heap,Heap,Live}, Vst) ->
    test_heap(Heap, Live, Vst);
valfun_1({bif,_Op,nofail,Src,Dst}, Vst) ->
    validate_src(Src, Vst),
    set_type_reg(term, Dst, Vst);
%% Put instructions.
valfun_1({put_list,A,B,Dst}, Vst0) ->
    assert_term(A, Vst0),
    assert_term(B, Vst0),
    Vst = eat_heap(2, Vst0),
    set_type_reg(cons, Dst, Vst);
valfun_1({put_tuple,Sz,Dst}, Vst0) when is_integer(Sz) ->
    Vst = eat_heap(1, Vst0),
    set_type_reg({tuple,Sz}, Dst, Vst);
valfun_1({put,Src}, Vst) ->
    assert_term(Src, Vst),
    eat_heap(1, Vst);
valfun_1({put_string,Sz,_,Dst}, Vst0) when is_integer(Sz) ->
    Vst = eat_heap(2*Sz, Vst0),
    set_type_reg(cons, Dst, Vst);
%% Misc.
valfun_1({'%live',Live}, Vst) ->
    verify_live(Live, Vst),
    Vst;
%% Exception generating calls
valfun_1({call_ext,Live,Func}=I, Vst) ->
    case return_type(Func, Vst) of
	exception ->
	    verify_live(Live, Vst),
	    kill_state(Vst);
	_ ->
	    valfun_2(I, Vst)
    end;
valfun_1(_I, #vst{current=#st{ct=undecided}}) ->
    error(unknown_catch_try_state);
%%
%% Allocate and deallocate, et.al
valfun_1({allocate,Stk,Live}, Vst) ->
    allocate(false, Stk, 0, Live, Vst);
valfun_1({allocate_heap,Stk,Heap,Live}, Vst) ->
    allocate(false, Stk, Heap, Live, Vst);
valfun_1({allocate_zero,Stk,Live}, Vst) ->
    allocate(true, Stk, 0, Live, Vst);
valfun_1({allocate_heap_zero,Stk,Heap,Live}, Vst) ->
    allocate(true, Stk, Heap, Live, Vst);
valfun_1({deallocate,StkSize}, #vst{current=#st{numy=StkSize}}=Vst) ->
    verify_no_ct(Vst),
    deallocate(Vst);
valfun_1({deallocate,_}, #vst{current=#st{numy=NumY}}) ->
    error({allocated,NumY});
%% Catch & try.
valfun_1({'catch',Dst,{f,Fail}}, Vst0) when Fail /= none ->
    Vst = #vst{current=#st{ct=Fails}=St} = 
	set_type_y({catchtag,Fail}, Dst, Vst0),
    Vst#vst{current=St#st{ct=[Fail|Fails]}};
valfun_1({'try',Dst,{f,Fail}}, Vst0) ->
    Vst = #vst{current=#st{ct=Fails}=St} = 
	set_type_y({trytag,Fail}, Dst, Vst0),
    Vst#vst{current=St#st{ct=[Fail|Fails]}};
valfun_1(I, Vst) ->
    valfun_2(I, Vst).

%% Update branched state if necessary and try next set of instructions.
valfun_2(I, #vst{current=#st{ct=[]}}=Vst) ->
    valfun_3(I, Vst);
valfun_2(I, #vst{current=#st{ct=[Fail|_]}}=Vst) -> 
    %% Update branched state
    valfun_3(I, branch_state(Fail, Vst)).

%% Handle the remaining floating point instructions here.
%% Floating point.
valfun_3({arithfbif,Op,F,Src,Dst}, Vst) ->
    valfun_3({bif,Op,F,Src,Dst}, Vst);
valfun_3({fconv,Src,{fr,_}=Dst}, Vst) ->
    assert_term(Src, Vst),
    set_freg(Dst, Vst);
valfun_3({bif,fadd,_,[_,_]=Src,Dst}, Vst) ->
    float_op(Src, Dst, Vst);
valfun_3({bif,fdiv,_,[_,_]=Src,Dst}, Vst) ->
    float_op(Src, Dst, Vst);
valfun_3({bif,fmul,_,[_,_]=Src,Dst}, Vst) ->
    float_op(Src, Dst, Vst);
valfun_3({bif,fnegate,_,[_]=Src,Dst}, Vst) ->
    float_op(Src, Dst, Vst);
valfun_3({bif,fsub,_,[_,_]=Src,Dst}, Vst) ->
    float_op(Src, Dst, Vst);
valfun_3(fclearerror, Vst) ->
    case get_fls(Vst) of
	undefined -> ok;
	checked -> ok;
	Fls -> error({bad_floating_point_state,Fls})
    end,
    set_fls(cleared, Vst);
valfun_3({fcheckerror,_}, Vst) ->
    assert_fls(cleared, Vst),
    set_fls(checked, Vst);
valfun_3(I, Vst) ->
    %% The instruction is not a float instruction.
    case get_fls(Vst) of
	undefined ->
	    valfun_4(I, Vst);
	checked ->
	    valfun_4(I, Vst);
	Fls ->
	    error({unsafe_instruction,{float_error_state,Fls}})
    end.

%% Instructions that can cause exceptions.
valfun_4({apply,Live}, Vst) ->
    call(Live+2, Vst);
valfun_4({apply_last,Live,_}, Vst) ->
    tail_call(Live+2, Vst);
valfun_4({call_fun,Live}, Vst) ->
    call(Live, Vst);
valfun_4({call,Live,_}, Vst) ->
    call(Live, Vst);
valfun_4({call_ext,Live,Func}, Vst) ->
    %% Exception BIFs has alread been taken care of above.
    call(Func, Live, Vst);
valfun_4({call_only,Live,_}, Vst) ->
    tail_call(Live, Vst);
valfun_4({call_ext_only,Live,_}, Vst) ->
    tail_call(Live, Vst);
valfun_4({call_last,Live,_,StkSize}, #vst{current=#st{numy=StkSize}}=Vst) ->
    tail_call(Live, Vst);
valfun_4({call_last,_,_,_}, #vst{current=#st{numy=NumY}}) ->
    error({allocated,NumY});
valfun_4({call_ext_last,Live,_,StkSize}, 
	 #vst{current=#st{numy=StkSize}}=Vst) ->
    tail_call(Live, Vst);
valfun_4({call_ext_last,_,_,_}, #vst{current=#st{numy=NumY}}) ->
    error({allocated,NumY});
valfun_4({make_fun,_,_,Live}, Vst) ->
    call(Live, Vst);
valfun_4({make_fun2,_,_,_,Live}, Vst) ->
    call(Live, Vst);
%% Other BIFs
valfun_4({bif,element,{f,Fail},[Pos,Tuple],Dst}, Vst0) ->
    TupleType0 = get_term_type(Tuple, Vst0),
    PosType = get_term_type(Pos, Vst0),
    Vst1 = branch_state(Fail, Vst0),
    TupleType = upgrade_type({tuple,[get_tuple_size(PosType)]}, TupleType0),
    Vst = set_type(TupleType, Tuple, Vst1),
    set_type_reg(term, Dst, Vst);
valfun_4({arithbif,Op,F,Src,Dst}, Vst) ->
    valfun_4({bif,Op,F,Src,Dst}, Vst);
valfun_4({bif,Op,{f,Fail},Src,Dst}, Vst0) ->
    validate_src(Src, Vst0),
    Vst = branch_state(Fail, Vst0),
    Type = bif_type(Op, Src, Vst),
    set_type_reg(Type, Dst, Vst);
valfun_4(return, #vst{current=#st{numy=none}}=Vst) ->
    kill_state(Vst);
valfun_4(return, #vst{current=#st{numy=NumY}}) ->
    error({stack_frame,NumY});
valfun_4({jump,{f,_}}, #vst{current=none}=Vst) ->
    %% Must be an unreachable jump which was not optimized away.
    %% Do nothing.
    Vst;
valfun_4({jump,{f,Lbl}}, Vst) ->
    kill_state(branch_state(Lbl, Vst));
valfun_4({loop_rec,{f,Fail},Dst}, Vst0) ->
    Vst = branch_state(Fail, Vst0),
    set_type_reg(term, Dst, Vst);
valfun_4(remove_message, Vst) ->
    Vst;
valfun_4({wait,_}, Vst) ->
    kill_state(Vst);
valfun_4({wait_timeout,_,Src}, Vst) ->
    assert_term(Src, Vst);
valfun_4({loop_rec_end,_}, Vst) ->
    kill_state(Vst);
valfun_4(timeout, #vst{current=St}=Vst) ->
    Vst#vst{current=St#st{x=init_regs(0, term)}};
valfun_4(send, Vst) ->
    call(2, Vst);
%% Catch & try.
valfun_4({catch_end,Reg}, #vst{current=#st{ct=[Fail|Fails]}=St0}=Vst0) ->
    case get_special_y_type(Reg, Vst0) of
	{catchtag,Fail} ->
	    Vst = #vst{current=St} = 
		set_type_y(initialized_ct, Reg, 
			   Vst0#vst{current=St0#st{ct=Fails}}),
	    Xs = gb_trees_from_list([{0,term}]),
	    Vst#vst{current=St#st{x=Xs}};
	Type ->
	    error({bad_type,Type})
    end;
valfun_4({try_end,Reg}, #vst{current=#st{ct=[Fail|Fails]}=St}=Vst) ->
    case get_special_y_type(Reg, Vst) of
	{trytag,Fail} ->
	    set_type_reg(initialized_ct, Reg, 
			 Vst#vst{current=St#st{ct=Fails}});
	Type ->
	    error({bad_type,Type})
    end;
valfun_4({try_case,Reg}, #vst{current=#st{ct=[Fail|Fails]}=St0}=Vst0) ->
    case get_special_y_type(Reg, Vst0) of
	{trytag,Fail} ->
	    Vst = #vst{current=St} = 
		set_type_y(initialized_ct, Reg, 
			   Vst0#vst{current=St0#st{ct=Fails}}),
	    Xs = gb_trees_from_list([{0,{atom,[]}},{1,term},{2,term}]),
	    Vst#vst{current=St#st{x=Xs}};
	Type ->
	    error({bad_type,Type})
    end;
valfun_4({set_tuple_element,Src,Tuple,I}, Vst) ->
    assert_term(Src, Vst),
    assert_type({tuple_element,I+1}, Tuple, Vst);
%% Match instructions.
valfun_4({select_val,Src,{f,Fail},{list,Choices}}, Vst) ->
    assert_term(Src, Vst),
    Lbls = [L || {f,L} <- Choices]++[Fail],
    kill_state(foldl(fun(L, S) -> branch_state(L, S) end, Vst, Lbls));
valfun_4({select_tuple_arity,Tuple,{f,Fail},{list,Choices}}, Vst) ->
    assert_type(tuple, Tuple, Vst),
    kill_state(branch_arities(Choices, Tuple, branch_state(Fail, Vst)));
valfun_4({get_list,Src,D1,D2}, Vst0) ->
    assert_type(cons, Src, Vst0),
    Vst = set_type_reg(term, D1, Vst0),
    set_type_reg(term, D2, Vst);
valfun_4({get_tuple_element,Src,I,Dst}, Vst) ->
    assert_type({tuple_element,I+1}, Src, Vst),
    set_type_reg(term, Dst, Vst);

%% Bit syntax instructions.
valfun_4({bs_start_match,{f,Fail},Src}, Vst) ->
    valfun_4({test,bs_start_match,{f,Fail},[Src]}, Vst);
valfun_4({test,bs_start_match,{f,Fail},[Src]}, Vst) ->
    assert_term(Src, Vst),
    bs_start_match(branch_state(Fail, Vst));
valfun_4({bs_save,SavePoint}, Vst) ->
    bs_assert_state(Vst),
    bs_save(SavePoint, Vst);
valfun_4({bs_restore,SavePoint}, Vst) ->
    bs_assert_state(Vst),
    bs_assert_savepoint(SavePoint, Vst),
    Vst;
valfun_4({test,bs_skip_bits,{f,Fail},[Src,_,_]}, Vst) ->
    bs_assert_state(Vst),
    assert_term(Src, Vst),
    branch_state(Fail, Vst);
valfun_4({test,bs_test_tail,{f,Fail},_}, Vst) ->
    bs_assert_state(Vst),
    branch_state(Fail, Vst);
valfun_4({test,_,{f,Fail},[_,_,_,Dst]}, Vst0) ->
    bs_assert_state(Vst0),
    Vst = branch_state(Fail, Vst0),
    set_type_reg({integer,[]}, Dst, Vst);
%% Other test instructions.
valfun_4({test,is_float,{f,Lbl},[Float]}, Vst) ->
    assert_term(Float, Vst),
    set_type({float,[]}, Float, branch_state(Lbl, Vst));
valfun_4({test,is_tuple,{f,Lbl},[Tuple]}, Vst) ->
    assert_term(Tuple, Vst),
    set_type({tuple,[0]}, Tuple, branch_state(Lbl, Vst));
valfun_4({test,is_nonempty_list,{f,Lbl},[Cons]}, Vst) ->
    assert_term(Cons, Vst),
    set_type(cons, Cons, branch_state(Lbl, Vst));
valfun_4({test,test_arity,{f,Lbl},[Tuple,Sz]}, Vst) when is_integer(Sz) ->
    assert_type(tuple, Tuple, Vst),
    set_type_reg({tuple,Sz}, Tuple, branch_state(Lbl, Vst));
valfun_4({test,_Op,{f,Lbl},Src}, Vst) ->
    validate_src(Src, Vst),
    branch_state(Lbl, Vst);
valfun_4({bs_add,{f,Fail},[A,B,_],Dst}, Vst) ->
    assert_term(A, Vst),
    assert_term(B, Vst),
    set_type_reg({integer,[]}, Dst, branch_state(Fail, Vst));
valfun_4({bs_bits_to_bytes,{f,Fail},Src,Dst}, Vst) ->
    assert_term(Src, Vst),
    set_type_reg({integer,[]}, Dst, branch_state(Fail, Vst));
valfun_4({bs_init2,{f,Fail},_,Heap,Live,_,Dst}, Vst0) ->
    verify_live(Live, Vst0),
    Vst1 = heap_alloc(Heap, Vst0),
    Vst2 = branch_state(Fail, Vst1),
    Vst = prune_x_regs(Live, Vst2),
    set_type_reg(binary, Dst, Vst);
valfun_4({bs_put_string,Sz,_}, Vst) when is_integer(Sz) ->
    Vst;
valfun_4({bs_put_binary,{f,Fail},_,_,_,Src}, Vst0) ->
    assert_term(Src, Vst0),
    branch_state(Fail, Vst0);
valfun_4({bs_put_float,{f,Fail},_,_,_,Src}, Vst0) ->
    assert_term(Src, Vst0),
    branch_state(Fail, Vst0);
valfun_4({bs_put_integer,{f,Fail},_,_,_,Src}, Vst0) ->
    assert_term(Src, Vst0),
    branch_state(Fail, Vst0);
%% Old bit syntax construction (before R10B).
valfun_4({bs_init,_,_}, Vst) -> Vst;
valfun_4({bs_need_buf,_}, Vst) -> Vst;
valfun_4({bs_final,{f,Fail},Dst}, Vst0) ->
    Vst = branch_state(Fail, Vst0),
    set_type_reg(binary, Dst, Vst);
valfun_4(_, _) ->
    error(unknown_instruction).

kill_state(Vst) ->
    Vst#vst{current=none}.

%% A "plain" call.
%%  The stackframe must be initialized.
%%  The instruction will return to the instruction following the call.
call(Live, #vst{current=St}=Vst) ->
    verify_live(Live, Vst),
    verify_y_init(Vst),
    Xs = gb_trees_from_list([{0,term}]),
    Vst#vst{current=St#st{x=Xs,f=init_fregs(),bsm=undefined}}.

%% A "plain" call.
%%  The stackframe must be initialized.
%%  The instruction will return to the instruction following the call.
call(Name, Live, #vst{current=St}=Vst) ->
    verify_live(Live, Vst),
    verify_y_init(Vst),
    case return_type(Name, Vst) of
	Type when Type =/= exception ->
	    %% Type is never 'exception' because it has been handled earlier.
	    Xs = gb_trees_from_list([{0,Type}]),
	    Vst#vst{current=St#st{x=Xs,f=init_fregs(),bsm=undefined}}
    end.

%% Tail call.
%%  The stackframe must have a known size and be initialized.
%%  Does not return to the instruction following the call.
tail_call(Live, Vst) ->
    verify_live(Live, Vst),
    verify_y_init(Vst),
    verify_no_ct(Vst),
    kill_state(Vst).

allocate(Zero, Stk, Heap, Live, #vst{current=#st{numy=none}=St}=Vst0) ->
    verify_live(Live, Vst0),
    Vst = prune_x_regs(Live, Vst0),
    Ys = init_regs(Stk, case Zero of 
			    true -> initialized;
			    false -> uninitialized
			end),
    Vst#vst{current=St#st{y=Ys,numy=Stk,h=heap_alloc_1(Heap),bsm=undefined}};
allocate(_, _, _, _, #vst{current=#st{numy=Numy}}) ->
    error({existing_stack_frame,{size,Numy}}).

deallocate(#vst{current=St}=Vst) ->
    Vst#vst{current=St#st{y=init_regs(0, initialized),numy=none,bsm=undefined}}.

test_heap(Heap, Live, Vst0) ->
    verify_live(Live, Vst0),
    Vst = prune_x_regs(Live, Vst0),
    heap_alloc(Heap, Vst).

heap_alloc(Heap, #vst{current=St}=Vst) ->
    Vst#vst{current=St#st{h=heap_alloc_1(Heap),bsm=undefined}}.
    
heap_alloc_1({alloc,Alloc}) ->
    {value,{_,Heap}} = lists:keysearch(words, 1, Alloc),
    Heap;
heap_alloc_1(Heap) when is_integer(Heap) -> Heap.

prune_x_regs(Live, #vst{current=#st{x=Xs0}=St0}=Vst) when is_integer(Live) ->
    Xs1 = gb_trees:to_list(Xs0),
    Xs = [P || {R,_}=P <- Xs1, R < Live],
    St = St0#st{x=gb_trees:from_orddict(Xs)},
    Vst#vst{current=St}.

%%%
%%% Floating point checking.
%%%
%%% Possible values for the fls field (=floating point error state).
%%%
%%% undefined 	- Undefined (initial state). No float operations allowed.
%%%
%%% cleared	- fcheckerror/0 has been executed. Float operations
%%%		  are allowed (such as fadd).
%%%
%%% checked	- fcheckerror/1 has been executed. It is allowed to
%%%                move values out of floating point registers.
%%%
%%% The following instructions may be executed in any state:
%%%
%%%   fconv Src {fr,_}             
%%%   fmove Src {fr,_}		%% Move INTO floating point register.
%%%

float_op(Src, Dst, Vst0) ->
    foreach (fun(S) -> assert_freg_set(S, Vst0) end, Src),
    assert_fls(cleared, Vst0),
    Vst = set_fls(cleared, Vst0),
    set_freg(Dst, Vst).

assert_fls(Fls, Vst) ->
    case get_fls(Vst) of
	Fls -> Vst;
	OtherFls -> error({bad_floating_point_state,OtherFls})
    end.

set_fls(Fls, #vst{current=#st{}=St}=Vst) when is_atom(Fls) ->
    Vst#vst{current=St#st{fls=Fls}}.

get_fls(#vst{current=#st{fls=Fls}}) when is_atom(Fls) -> Fls.

init_fregs() -> 0.

set_freg({fr,Fr}, #vst{current=#st{f=Fregs0}=St}=Vst)
  when is_integer(Fr), 0 =< Fr, Fr < ?MAXREG ->
    Bit = 1 bsl Fr,
    if
	Fregs0 band Bit =:= 0 ->
	    Fregs = Fregs0 bor Bit,
	    Vst#vst{current=St#st{f=Fregs}};
	true -> Vst
    end;
set_freg(Fr, _) -> error({bad_target,Fr}).

assert_freg_set({fr,Fr}=Freg, #vst{current=#st{f=Fregs}}) when is_integer(Fr) ->
    if
	0 =< Fr, Fr < ?MAXREG, Fregs band (1 bsl Fr) =/= 0 -> ok;
	true -> error({uninitialized_reg,Freg})
    end;
assert_freg_set(Fr, _) -> error({bad_source,Fr}).

%%%
%%% Binary matching.
%%%
%%% Possible values for the bsm field (=bit syntax matching state).
%%%
%%% undefined 	- Undefined (initial state). No matching instructions allowed.
%%%		 
%%% (gb set)	- The gb set contains the defined save points.
%%%
%%% The bsm field is reset to 'undefined' by instructions that may cause a
%%% a garbage collection (might move the binary) and/or context switch
%%% (may invalidate the save points).

bs_start_match(#vst{current=#st{bsm=undefined}=St}=Vst) ->
    Vst#vst{current=St#st{bsm=gb_sets:empty()}};
bs_start_match(Vst) ->
    %% Must retain save points here - it is possible to restore back
    %% to a previous binary.
    Vst.

bs_save(Reg, #vst{current=#st{bsm=Saved}=St}=Vst) ->
    Vst#vst{current=St#st{bsm=gb_sets:add(Reg, Saved)}}.

bs_assert_savepoint(Reg, #vst{current=#st{bsm=Saved}}) ->
    case gb_sets:is_member(Reg, Saved) of
	false -> error({no_save_point,Reg});
	true -> ok
    end.

bs_assert_state(#vst{current=#st{bsm=undefined}}) ->
    error(no_bs_match_state);
bs_assert_state(_) -> ok.

%%%
%%% Keeping track of types.
%%%

set_type(Type, {x,_}=Reg, Vst) -> set_type_reg(Type, Reg, Vst);
set_type(Type, {y,_}=Reg, Vst) -> set_type_y(Type, Reg, Vst);
set_type(_, _, #vst{}=Vst) -> Vst.

set_type_reg(Type, {x,X}, #vst{current=#st{x=Xs}=St}=Vst) 
  when 0 =< X, X < ?MAXREG ->
    Vst#vst{current=St#st{x=gb_trees:enter(X, Type, Xs)}};
set_type_reg(Type, Reg, Vst) ->
    set_type_y(Type, Reg, Vst).

set_type_y(Type, {y,Y}=Reg, #vst{current=#st{y=Ys0,numy=NumY}=St}=Vst) 
  when is_integer(Y), 0 =< Y, Y < ?MAXREG ->
    case {Y,NumY} of
	{_,none} ->
	    error({no_stack_frame,Reg});
	{_,_} when Y > NumY ->
	    error({y_reg_out_of_range,Reg,NumY});
	{_,_} ->
	    Ys = if  Type == initialized_ct ->
			 gb_trees:enter(Y, initialized, Ys0);
		     true ->
			 case gb_trees:lookup(Y, Ys0) of
			     none -> 
				 gb_trees:insert(Y, Type, Ys0);
			     {value,uinitialized} ->
				 gb_trees:insert(Y, Type, Ys0);
			     {value,{catchtag,_}=Tag} ->
				 error(Tag);
			     {value,{trytag,_}=Tag} ->
				 error(Tag);
			     {value,_} ->
				 gb_trees:update(Y, Type, Ys0)
			 end
		 end,
	    Vst#vst{current=St#st{y=Ys}}
    end;
set_type_y(Type, Reg, #vst{}) -> error({invalid_store,Reg,Type}).

assert_term(Src, Vst) ->
    get_term_type(Src, Vst),
    Vst.

%% The possible types.
%%
%% First non-term types:
%%
%% initialized		Only for Y registers. Means that the Y register
%%			has been initialized with some valid term so that
%%			it is safe to pass to the garbage collector.
%%			NOT safe to use in any other way (will not crash the
%%			emulator, but clearly points to a bug in the compiler).
%%
%% {catchtag,Lbl}	A special term used within a catch. Must only be used
%%			by the catch instructions; NOT safe to use in other
%%			instructions.
%%
%% {trytag,Lbl}		A special term used within a try block. Must only be
%%			used by the catch instructions; NOT safe to use in other
%%			instructions.
%%
%% exception		Can only be used as a type returned by return_type/2
%%			(which gives the type of the value returned by a BIF).
%%			Thus 'exception' is never stored as type descriptor
%%			for a register.
%%
%% Normal terms:
%%
%% term			Any valid Erlang (but not of the special types above).
%%
%% bool			The atom 'true' or the atom 'false'.
%%
%% cons         	Cons cell: [_|_]
%%
%% nil			Empty list: []
%%
%% {tuple,[Sz]}		Tuple. An element has been accessed using
%%              	element/2 or setelement/3 so that it is known that
%%              	the type is a tuple of size at least Sz.
%%
%% {tuple,Sz}		Tuple. A test_arity instruction has been seen
%%           		so that it is known that the size is exactly Sz.
%%
%% {atom,[]}		Atom.
%% {atom,Atom}
%%
%% {integer,[]}		Integer.
%% {integer,Integer}
%%
%% {float,[]}		Float.
%% {float,Float}
%%
%% number		Integer or Float of unknown value
%%

assert_type(WantedType, Term, Vst) ->
    assert_type(WantedType, get_term_type(Term, Vst)),
    Vst.

assert_type(Correct, Correct) -> ok;
assert_type(float, {float,_}) -> ok;
assert_type(tuple, {tuple,_}) -> ok;
assert_type({tuple_element,I}, {tuple,[Sz]})
  when 1 =< I, I =< Sz ->
    ok;
assert_type({tuple_element,I}, {tuple,Sz})
  when is_integer(Sz), 1 =< I, I =< Sz ->
    ok;
assert_type(Needed, Actual) ->
    error({bad_type,{needed,Needed},{actual,Actual}}).

%% upgrade_type/2 is used when linear code finds out more and
%% more information about a type, so the type gets "narrower"
%% or perhaps inconsistent. In the case of inconsistency
%% we mostly widen the type to 'term' to make subsequent
%% code fail if it assumes anything about the type.

upgrade_type(Same, Same) -> Same;
upgrade_type(term, OldT) -> OldT;
upgrade_type(NewT, term) -> NewT;
upgrade_type({Type,New}=NewT, {Type,Old}=OldT)
  when Type == atom; Type == integer; Type == float ->
    if New =:= Old -> OldT;
       New =:= [] -> OldT;
       Old =:= [] -> NewT;
       true -> term
    end;
upgrade_type({Type,_}=NewT, number) 
  when Type == integer; Type == float ->
    NewT;
upgrade_type(number, {Type,_}=OldT) 
  when Type == integer; Type == float ->
    OldT;
upgrade_type(bool, {atom,A}) ->
    upgrade_bool(A);
upgrade_type({atom,A}, bool) ->
    upgrade_bool(A);
upgrade_type({tuple,[Sz]}, {tuple,[OldSz]})
  when is_integer(Sz) ->
    {tuple,[max(Sz, OldSz)]};
upgrade_type({tuple,Sz}=T, {tuple,[_]}) 
  when is_integer(Sz) ->
    %% This also takes care of the user error when a tuple element
    %% is accesed outside the known exact tuple size; there is 
    %% no more type information, just a runtime error which is not
    %% our problem.
    T;
upgrade_type({tuple,[Sz]}, {tuple,_}=T) 
  when is_integer(Sz) ->
    %% Same as the previous clause but mirrored.
    T;
upgrade_type(_A, _B) ->
    %%io:format("upgrade_type: ~p ~p\n", [_A,_B]),
    term.

upgrade_bool([]) -> bool;
upgrade_bool(true) -> {atom,true};
upgrade_bool(false) -> {atom,false};
upgrade_bool(_) -> term.

get_tuple_size({integer,[]}) -> 0;
get_tuple_size({integer,Sz}) -> Sz;
get_tuple_size(_) -> 0.

validate_src(Ss, Vst) when is_list(Ss) ->
    foreach(fun(S) -> get_term_type(S, Vst) end, Ss).

%% get_term_type(Src, ValidatorState) -> Type
%%  Get the type of the source Src. The returned type Type will be
%%  a standard Erlang type (no catch/try tags).

get_term_type(Src, Vst) ->
    case get_term_type_1(Src, Vst) of
	initialized -> error({unassigned,Src});
	{catchtag,_} -> error({catchtag,Src});
	{trytag,_} -> error({trytag,Src});
	Type -> Type
    end.

%% get_special_y_type(Src, ValidatorState) -> Type
%%  Return the type for the Y register without doing any validity checks.

get_special_y_type({y,_}=Reg, Vst) -> get_term_type_1(Reg, Vst);
get_special_y_type(Src, _) -> error({source_not_y_reg,Src}).

get_term_type_1(nil=T, _) -> T;
get_term_type_1({atom,A}=T, _) when is_atom(A) -> T;
get_term_type_1({float,F}=T, _) when is_float(F) -> T;
get_term_type_1({integer,I}=T, _) when is_integer(I) -> T;
get_term_type_1({x,X}=Reg, #vst{current=#st{x=Xs}}) when is_integer(X) ->
    case gb_trees:lookup(X, Xs) of
	{value,Type} -> Type;
	none -> error({uninitialized_reg,Reg})
    end;
get_term_type_1({y,Y}=Reg, #vst{current=#st{y=Ys}}) when is_integer(Y) ->
    case gb_trees:lookup(Y, Ys) of
 	none -> error({uninitialized_reg,Reg});
	{value,uninitialized} -> error({uninitialized_reg,Reg});
	{value,Type} -> Type
    end;
get_term_type_1(Src, _) -> error({bad_source,Src}).


branch_arities([], _, #vst{}=Vst) -> Vst;
branch_arities([Sz,{f,L}|T], Tuple, #vst{current=St}=Vst0) 
  when is_integer(Sz) ->
    Vst1 = set_type_reg({tuple,Sz}, Tuple, Vst0),
    Vst = branch_state(L, Vst1),
    branch_arities(T, Tuple, Vst#vst{current=St}).

branch_state(0, #vst{}=Vst) -> Vst;
branch_state(L, #vst{current=St,branched=B}=Vst) ->
    Vst#vst{
      branched=case gb_trees:is_defined(L, B) of
		   false ->
		       gb_trees:insert(L, St, B);
		   true ->
		       MergedSt = merge_states(L, St, B),
		       gb_trees:update(L, MergedSt, B)
	       end}.

%% merge_states/3 is used when there are more than one way to arrive
%% at this point, and the type states for the different paths has
%% to be merged. The type states are downgraded to the least common
%% subset for the subsequent code.

merge_states(L, St, Branched) when L =/= 0 ->
    case gb_trees:lookup(L, Branched) of
	none -> St;
	{value,OtherSt} when St == none -> OtherSt;
	{value,OtherSt} -> merge_states_1(St, OtherSt)
    end.

merge_states_1(#st{x=Xs0,y=Ys0,numy=NumY0,h=H0,ct=Ct0,bsm=Bsm0}=St,
	       #st{x=Xs1,y=Ys1,numy=NumY1,h=H1,ct=Ct1,bsm=Bsm1}) ->
    NumY = merge_stk(NumY0, NumY1),
    Xs = merge_regs(Xs0, Xs1),
    Ys = merge_y_regs(Ys0, Ys1),
    Ct = merge_stk(Ct0, Ct1),
    Bsm = merge_bsm(Bsm0, Bsm1),
    St#st{x=Xs,y=Ys,numy=NumY,h=min(H0, H1),ct=Ct,bsm=Bsm}.

merge_stk(S, S) -> S;
merge_stk(_, _) -> undecided.

merge_regs(Rs0, Rs1) ->
    Rs = merge_regs_1(gb_trees:to_list(Rs0), gb_trees:to_list(Rs1)),
    gb_trees_from_list(Rs).

merge_regs_1([Same|Rs1], [Same|Rs2]) ->
    [Same|merge_regs_1(Rs1, Rs2)];
merge_regs_1([{R1,_}|Rs1], [{R2,_}|_]=Rs2) when R1 < R2 ->
    merge_regs_1(Rs1, Rs2);
merge_regs_1([{R1,_}|_]=Rs1, [{R2,_}|Rs2]) when R1 > R2 ->
    merge_regs_1(Rs1, Rs2);
merge_regs_1([{R,Type1}|Rs1], [{R,Type2}|Rs2]) ->
    [{R,merge_types(Type1, Type2)}|merge_regs_1(Rs1, Rs2)];
merge_regs_1([], []) -> [];
merge_regs_1([], [_|_]) -> [];
merge_regs_1([_|_], []) -> [].

merge_y_regs(Rs0, Rs1) ->
    Rs = merge_y_regs_1(gb_trees:to_list(Rs0), gb_trees:to_list(Rs1)),
    gb_trees_from_list(Rs).

merge_y_regs_1([Same|Rs1], [Same|Rs2]) ->
    [Same|merge_y_regs_1(Rs1, Rs2)];
merge_y_regs_1([{R1,_}|Rs1], [{R2,_}|_]=Rs2) when R1 < R2 ->
    [{R1,uninitialized}|merge_y_regs_1(Rs1, Rs2)];
merge_y_regs_1([{R1,_}|_]=Rs1, [{R2,_}|Rs2]) when R1 > R2 ->
    [{R2,uninitialized}|merge_y_regs_1(Rs1, Rs2)];
merge_y_regs_1([{R,Type1}|Rs1], [{R,Type2}|Rs2]) ->
    [{R,merge_types(Type1, Type2)}|merge_y_regs_1(Rs1, Rs2)];
merge_y_regs_1([], []) -> [];
merge_y_regs_1([], [_|_]=Rs) -> Rs;
merge_y_regs_1([_|_]=Rs, []) -> Rs.

%% merge_types(Type1, Type2) -> Type
%%  Return the most specific type possible.
%%  Note: Type1 must NOT be the same as Type2.
merge_types(uninitialized=I, _) -> I;
merge_types(_, uninitialized=I) -> I;
merge_types(initialized=I, _) -> I;
merge_types(_, initialized=I) -> I;
merge_types({tuple,A}, {tuple,B}) ->
    {tuple,[min(tuple_sz(A), tuple_sz(B))]};
merge_types({Type,A}, {Type,B}) 
  when Type == atom; Type == integer; Type == float ->
    if A =:= B -> {Type,A};
       true -> {Type,[]}
    end;
merge_types({Type,_}, number) 
  when Type == integer; Type == float ->
    number;
merge_types(number, {Type,_}) 
  when Type == integer; Type == float ->
    number;
merge_types(bool, {atom,A}) ->
    merge_bool(A);
merge_types({atom,A}, bool) ->
    merge_bool(A);
merge_types(T1, T2) when T1 =/= T2 ->
    %% Too different. All we know is that the type is a 'term'.
    term.

merge_bsm(undefined, _) -> undefined;
merge_bsm(_, undefined) -> undefined;
merge_bsm(Bsm0, Bsm1) -> gb_sets:intersection(Bsm0, Bsm1).

tuple_sz([Sz]) -> Sz;
tuple_sz(Sz) -> Sz.

merge_bool([]) -> {atom,[]};
merge_bool(true) -> bool;
merge_bool(false) -> bool;
merge_bool(_) -> {atom,[]}.
    
verify_y_init(#vst{current=#st{y=Ys}}) ->
    verify_y_init_1(gb_trees:to_list(Ys)).

verify_y_init_1([]) -> ok;
verify_y_init_1([{Y,uninitialized}|_]) ->
    error({uninitialized_reg,{y,Y}});
verify_y_init_1([{_,_}|Ys]) ->
    verify_y_init_1(Ys).

verify_live(0, #vst{}) -> ok;
verify_live(N, #vst{current=#st{x=Xs}}) ->
    verify_live_1(N, Xs).

verify_live_1(0, _) -> ok;
verify_live_1(N, Xs) ->
    X = N-1,
    case gb_trees:is_defined(X, Xs) of
	false -> error({{x,X},not_live});
	true -> verify_live_1(X, Xs)
    end.

verify_no_ct(#vst{current=#st{numy=none}}) -> ok;
verify_no_ct(#vst{current=#st{numy=undecided}}) ->
    error(unknown_size_of_stackframe);
verify_no_ct(#vst{current=#st{y=Ys}}) ->
    case lists:filter(fun ({_,{catchtag,_}}) -> true;
			  ({_,{trytag,_}}) -> true;
			  ({_,_}) -> false
		      end, gb_trees:to_list(Ys)) of
	[] -> ok;
	CT -> error({unfinished_catch_try,CT})
    end.

eat_heap(N, #vst{current=#st{h=Heap0}=St}=Vst) ->
    case Heap0-N of
	Neg when Neg < 0 ->
	    error({heap_overflow,{left,Heap0},{wanted,N}});
	Heap ->
	    Vst#vst{current=St#st{h=Heap}}
    end.

bif_type('-', Src, Vst) ->
    arith_type(Src, Vst);
bif_type('+', Src, Vst) ->
    arith_type(Src, Vst);
bif_type('*', Src, Vst) ->
    arith_type(Src, Vst);
bif_type(abs, [Num], Vst) ->
    case get_term_type(Num, Vst) of
	{float,_}=T -> T;
	{integer,_}=T -> T;
	_ -> number
    end;
bif_type(float, _, _) -> {float,[]};
bif_type('/', _, _) -> {float,[]};
%% Integer operations.
bif_type('div', [_,_], _) -> {integer,[]};
bif_type('rem', [_,_], _) -> {integer,[]};
bif_type(length, [_], _) -> {integer,[]};
bif_type(size, [_], _) -> {integer,[]};
bif_type(trunc, [_], _) -> {integer,[]};
bif_type(round, [_], _) -> {integer,[]};
bif_type('band', [_,_], _) -> {integer,[]};
bif_type('bor', [_,_], _) -> {integer,[]};
bif_type('bxor', [_,_], _) -> {integer,[]};
bif_type('bnot', [_], _) -> {integer,[]};
bif_type('bsl', [_,_], _) -> {integer,[]};
bif_type('bsr', [_,_], _) -> {integer,[]};
%% Booleans.
bif_type('==', [_,_], _) -> bool;
bif_type('/=', [_,_], _) -> bool;
bif_type('=<', [_,_], _) -> bool;
bif_type('<', [_,_], _) -> bool;
bif_type('>=', [_,_], _) -> bool;
bif_type('>', [_,_], _) -> bool;
bif_type('=:=', [_,_], _) -> bool;
bif_type('=/=', [_,_], _) -> bool;
bif_type('not', [_], _) -> bool;
bif_type('and', [_,_], _) -> bool;
bif_type('or', [_,_], _) -> bool;
bif_type('xor', [_,_], _) -> bool;
bif_type(is_atom, [_], _) -> bool;
bif_type(is_boolean, [_], _) -> bool;
bif_type(is_binary, [_], _) -> bool;
bif_type(is_constant, [_], _) -> bool;
bif_type(is_float, [_], _) -> bool;
bif_type(is_function, [_], _) -> bool;
bif_type(is_integer, [_], _) -> bool;
bif_type(is_list, [_], _) -> bool;
bif_type(is_number, [_], _) -> bool;
bif_type(is_pid, [_], _) -> bool;
bif_type(is_port, [_], _) -> bool;
bif_type(is_reference, [_], _) -> bool;
bif_type(is_tuple, [_], _) -> bool;
%% Misc.
bif_type(node, [], _) -> {atom,[]};
bif_type(node, [_], _) -> {atom,[]};
bif_type(hd, [_], _) -> term;
bif_type(tl, [_], _) -> term;
bif_type(get, [_], _) -> term;
bif_type(raise, [_,_], _) -> exception;
bif_type(_, _, _) -> term.

arith_type([A,B], Vst) ->
    case {get_term_type(A, Vst),get_term_type(B, Vst)} of
	{{float,_},_} -> {float,[]};
	{_,{float,_}} -> {float,[]};
	{_,_} -> number
    end;
arith_type(_, _) -> number.

return_type({extfunc,M,F,A}, Vst) ->
    return_type_1(M, F, A, Vst).

return_type_1(erlang, setelement, 3, Vst) ->
    Tuple = {x,1},
    TupleType =
	case get_term_type(Tuple, Vst) of
	    {tuple,_}=TT -> TT;
	    _ -> {tuple,[0]}
	end,
    case get_term_type({x,0}, Vst) of
	{integer,[]} -> TupleType;
	{integer,I} -> upgrade_type({tuple,[I]}, TupleType);
	_ -> TupleType
    end;
return_type_1(erlang, F, A, _) ->
    return_type_erl(F, A);
return_type_1(math, F, A, _) ->
    return_type_math(F, A);
return_type_1(_, _, _, _) -> term.

return_type_erl(exit, 1) -> exception;
return_type_erl(throw, 1) -> exception;
return_type_erl(fault, 1) -> exception;
return_type_erl(fault, 2) -> exception;
return_type_erl(error, 1) -> exception;
return_type_erl(error, 2) -> exception;
return_type_erl(_, _) -> term.

return_type_math(cos, 1) -> {float,[]};
return_type_math(cosh, 1) -> {float,[]};
return_type_math(sin, 1) -> {float,[]};
return_type_math(sinh, 1) -> {float,[]};
return_type_math(tan, 1) -> {float,[]};
return_type_math(tanh, 1) -> {float,[]};
return_type_math(acos, 1) -> {float,[]};
return_type_math(acosh, 1) -> {float,[]};
return_type_math(asin, 1) -> {float,[]};
return_type_math(asinh, 1) -> {float,[]};
return_type_math(atan, 1) -> {float,[]};
return_type_math(atanh, 1) -> {float,[]};
return_type_math(erf, 1) -> {float,[]};
return_type_math(erfc, 1) -> {float,[]};
return_type_math(exp, 1) -> {float,[]};
return_type_math(log, 1) -> {float,[]};
return_type_math(log10, 1) -> {float,[]};
return_type_math(sqrt, 1) -> {float,[]};
return_type_math(atan2, 2) -> {float,[]};
return_type_math(pow, 2) -> {float,[]};
return_type_math(pi, 0) -> {float,[]};
return_type_math(_, _) -> term.

min(A, B) when is_integer(A), is_integer(B), A < B -> A;
min(A, B) when is_integer(A), is_integer(B) -> B.

max(A, B) when is_integer(A), is_integer(B), A > B -> A;
max(A, B) when is_integer(A), is_integer(B) -> B.

gb_trees_from_list(L) -> gb_trees:from_orddict(orddict:from_list(L)).

-ifdef(DEBUG).
error(Error) -> exit(Error).
-else.
error(Error) -> throw(Error).
-endif.
