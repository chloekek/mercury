%-----------------------------------------------------------------------------%
% Copyright (C) 1999-2000 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%

% File: ml_code_util.m
% Main author: fjh

% This module is part of the MLDS code generator.
% It defines the ml_gen_info type and its access routines.

%-----------------------------------------------------------------------------%

:- module ml_code_util.
:- interface.

:- import_module prog_data.
:- import_module hlds_module, hlds_pred.
:- import_module rtti.
:- import_module mlds.
:- import_module llds. % XXX for `code_model'.

:- import_module bool, int, list, map, std_util.

%-----------------------------------------------------------------------------%
%
% Various utility routines used for MLDS code generation.
%

	% Generate an MLDS assignment statement.
:- func ml_gen_assign(mlds__lval, mlds__rval, prog_context) = mlds__statement.

	% Generate a block statement, i.e. `{ <Decls>; <Statements>; }'.
	% But if the block consists only of a single statement with no
	% declarations, then just return that statement.
	%
:- func ml_gen_block(mlds__defns, mlds__statements, prog_context) =
		mlds__statement.

	% ml_join_decls:
	% 	Join two statement lists and their corresponding
	% 	declaration lists in sequence.
	% 
	% 	If the statements have no declarations in common,
	% 	then their corresponding declaration lists will be
	% 	concatenated together into a single list of declarations.
	% 	But if they have any declarations in common, then we
	% 	put each statement list and its declarations into
	% 	a block, so that the declarations remain local to
	% 	each statement list.
	% 
:- pred ml_join_decls(mlds__defns, mlds__statements,
		mlds__defns, mlds__statements, prog_context,
		mlds__defns, mlds__statements).
:- mode ml_join_decls(in, in, in, in, in, out, out) is det.

	% ml_combine_conj:
	%	Given closures to generate code for two conjuncts,
	%	generate code for their conjunction.

:- type gen_pred == pred(mlds__defns, mlds__statements,
		ml_gen_info, ml_gen_info).
:- inst gen_pred = (pred(out, out, in, out) is det).

:- pred ml_combine_conj(code_model, prog_context, gen_pred, gen_pred,
		mlds__defns, mlds__statements, ml_gen_info, ml_gen_info).
:- mode ml_combine_conj(in, in, in(gen_pred), in(gen_pred),
		out, out, in, out) is det.

	% Given a function label and the statement which will comprise
	% the function body for that function, generate an mlds__defn
	% which defines that function.
	%
:- pred ml_gen_nondet_label_func(ml_label_func, prog_context,
		mlds__statement, mlds__defn, ml_gen_info, ml_gen_info).
:- mode ml_gen_nondet_label_func(in, in, in, out, in, out) is det.

	% Given a function label, the function parameters, and the statement
	% which will comprise the function body for that function,
	% generate an mlds__defn which defines that function.
	%
:- pred ml_gen_label_func(ml_label_func, mlds__func_params, prog_context,
		mlds__statement, mlds__defn, ml_gen_info, ml_gen_info).
:- mode ml_gen_label_func(in, in, in, in, out, in, out) is det.

	% Call error/1 with a "Sorry, not implemented" message.
	%
:- pred sorry(string::in) is erroneous.

%-----------------------------------------------------------------------------%
%
% Routines for generating types.
%

	% A convenient abbreviation.
	%
:- type prog_type == prog_data__type.

	% Convert a Mercury type to an MLDS type.
	%
:- pred ml_gen_type(prog_type, mlds__type, ml_gen_info, ml_gen_info).
:- mode ml_gen_type(in, out, in, out) is det.

%-----------------------------------------------------------------------------%
%
% Routines for generating function declarations (i.e. mlds__func_params).
%

	% Generate the function prototype for a given procedure.
	%
:- func ml_gen_proc_params(module_info, pred_id, proc_id) = mlds__func_params.

:- func ml_gen_proc_params_from_rtti(module_info, rtti_proc_label) =
	mlds__func_params.

	% Generate the function prototype for a procedure with the
	% given argument types, modes, and code model.
	%
:- func ml_gen_params(module_info, list(string), list(prog_type),
		list(mode), code_model) = mlds__func_params.

%-----------------------------------------------------------------------------%
%
% Routines for generating labels and entity names.
%

	% Generate the mlds__entity_name for the entry point function
	% corresponding to a given procedure.
	%
:- func ml_gen_proc_label(module_info, pred_id, proc_id) = mlds__entity_name.

	% Generate an mlds__entity_name for a continuation function
	% with the given sequence number.  The pred_id and proc_id
	% specify the procedure that this continuation function
	% is part of.
	%
:- func ml_gen_nondet_label(module_info, pred_id, proc_id, ml_label_func)
		= mlds__entity_name.

	% Allocate a new function label and return an rval containing
	% the function's address.
	%
:- pred ml_gen_new_func_label(ml_label_func, mlds__rval,
		ml_gen_info, ml_gen_info).
:- mode ml_gen_new_func_label(out, out, in, out) is det.

	% Generate the mlds__pred_label and module name
	% for a given procedure.
	%
:- pred ml_gen_pred_label(module_info, pred_id, proc_id,
		mlds__pred_label, mlds_module_name).
:- mode ml_gen_pred_label(in, in, in, out, out) is det.

:- pred ml_gen_pred_label_from_rtti(rtti_proc_label,
		mlds__pred_label, mlds_module_name).
:- mode ml_gen_pred_label_from_rtti(in, out, out) is det.

%-----------------------------------------------------------------------------%
%
% Routines for dealing with variables
%

	% Generate a list of the mlds__lvals corresponding to a
	% given list of prog_vars.
	%
:- pred ml_gen_var_list(list(prog_var), list(mlds__lval),
		ml_gen_info, ml_gen_info).
:- mode ml_gen_var_list(in, out, in, out) is det.

	% Generate the mlds__lval corresponding to a given prog_var.
	%
:- pred ml_gen_var(prog_var, mlds__lval, ml_gen_info, ml_gen_info).
:- mode ml_gen_var(in, out, in, out) is det.

	% Generate the mlds__lval corresponding to a given prog_var,
	% with a given type.
	%
:- pred ml_gen_var_with_type(prog_var, prog_type, mlds__lval,
		ml_gen_info, ml_gen_info).
:- mode ml_gen_var_with_type(in, in, out, in, out) is det.

	% Lookup the types of a list of variables.
	%
:- pred ml_variable_types(list(prog_var), list(prog_type),
		ml_gen_info, ml_gen_info).
:- mode ml_variable_types(in, out, in, out) is det.

	% Lookup the type of a variable.
	%
:- pred ml_variable_type(prog_var, prog_type, ml_gen_info, ml_gen_info).
:- mode ml_variable_type(in, out, in, out) is det.

	% Generate the MLDS variable names for a list of variables.
	%
:- func ml_gen_var_names(prog_varset, list(prog_var)) = list(mlds__var_name).

	% Generate the MLDS variable name for a variable.
	%
:- func ml_gen_var_name(prog_varset, prog_var) = mlds__var_name.

	% Qualify the name of the specified variable
	% with the current module name.
	%
:- pred ml_qualify_var(mlds__var_name, mlds__lval,
		ml_gen_info, ml_gen_info).
:- mode ml_qualify_var(in, out, in, out) is det.

	% Generate a declaration for an MLDS variable, given its HLDS type.
	%
:- func ml_gen_var_decl(var_name, prog_type, mlds__context, module_info) =
	mlds__defn.

	% Generate a declaration for an MLDS variable, given its MLDS type.
	%
:- func ml_gen_mlds_var_decl(mlds__data_name, mlds__type, mlds__context) =
	mlds__defn.

	% Generate a declaration for an MLDS variable, given its MLDS type
	% and initializer.
	%
:- func ml_gen_mlds_var_decl(mlds__data_name, mlds__type, mlds__initializer,
	mlds__context) = mlds__defn.

%-----------------------------------------------------------------------------%
%
% Routines for handling success and failure
%

	% Generate code to succeed in the given code_model.
	%
:- pred ml_gen_success(code_model, prog_context, mlds__statements,
			ml_gen_info, ml_gen_info).
:- mode ml_gen_success(in, in, out, in, out) is det.

	% Generate code to fail in the given code_model.
	%
:- pred ml_gen_failure(code_model, prog_context, mlds__statements,
			ml_gen_info, ml_gen_info).
:- mode ml_gen_failure(in, in, out, in, out) is det.

	% Generate the declaration for the built-in `succeeded' flag.
	% (`succeeded' is a boolean variable used to record
	% the success or failure of model_semi procedures.)
	%
:- func ml_gen_succeeded_var_decl(mlds__context) = mlds__defn.

	% Return the lval for the `succeeded' flag.
	% (`succeeded' is a boolean variable used to record
	% the success or failure of model_semi procedures.)
	%
:- pred ml_success_lval(mlds__lval, ml_gen_info, ml_gen_info).
:- mode ml_success_lval(out, in, out) is det.

	% Return an rval which will test the value of the `succeeded' flag.
	% (`succeeded' is a boolean variable used to record
	% the success or failure of model_semi procedures.)
	%
:- pred ml_gen_test_success(mlds__rval, ml_gen_info, ml_gen_info).
:- mode ml_gen_test_success(out, in, out) is det.
	
	% Generate code to set the `succeeded' flag to the
	% specified truth value.
	%
:- pred ml_gen_set_success(mlds__rval, prog_context, mlds__statement,
				ml_gen_info, ml_gen_info).
:- mode ml_gen_set_success(in, in, out, in, out) is det.

	% Generate the declaration for the specified `cond'
	% variable.
	% (`cond' variables are boolean variables used to record
	% the success or failure of model_non conditions of
	% if-then-elses.)
	%
:- func ml_gen_cond_var_decl(cond_seq, mlds__context) = mlds__defn.

	% Return the lval for the specified `cond' flag.
	% (`cond' variables are boolean variables used to record
	% the success or failure of model_non conditions of
	% if-then-elses.)
	%
:- pred ml_cond_var_lval(cond_seq, mlds__lval, ml_gen_info, ml_gen_info).
:- mode ml_cond_var_lval(in, out, in, out) is det.

	% Return an rval which will test the value of the specified
	% `cond' variable.
	% (`cond' variables are boolean variables used to record
	% the success or failure of model_non conditions of
	% if-then-elses.)
	%
:- pred ml_gen_test_cond_var(cond_seq, mlds__rval, ml_gen_info, ml_gen_info).
:- mode ml_gen_test_cond_var(in, out, in, out) is det.
	
	% Generate code to set the specified `cond' variable to the
	% specified truth value.
	%
:- pred ml_gen_set_cond_var(cond_seq, mlds__rval, prog_context,
		mlds__statement, ml_gen_info, ml_gen_info).
:- mode ml_gen_set_cond_var(in, in, in, out, in, out) is det.

	% Return rvals for the success continuation that was
	% passed as the current function's argument(s).
	% The success continuation consists of two parts, the
	% `cont' argument, and the `cont_env' argument.
	% The `cont' argument is a continuation function that
	% will be called when a model_non goal succeeds.
	% The `cont_env' argument is a pointer to the environment (set
	% of local variables in the containing procedure) for the continuation
	% function.  (If we're using gcc nested function, the `cont_env'
	% is not used.)
	%
:- pred ml_initial_cont(success_cont, ml_gen_info, ml_gen_info).
:- mode ml_initial_cont(out, in, out) is det.

	% Generate code to call the current success continuation.
	% This is used for generating success when in a model_non context.
	%
:- pred ml_gen_call_current_success_cont(prog_context, mlds__statement,
			ml_gen_info, ml_gen_info).
:- mode ml_gen_call_current_success_cont(in, out, in, out) is det.

%-----------------------------------------------------------------------------%
%
% Routines for dealing with the environment pointer
% used for nested functions.
%

	% Return an rval for a pointer to the current environment
	% (the set of local variables in the containing procedure).
	% Note that we generate this as a dangling reference.
	% The ml_elim_nested pass will insert the declaration
	% of the env_ptr variable.
:- pred ml_get_env_ptr(mlds__rval, ml_gen_info, ml_gen_info).
:- mode ml_get_env_ptr(out, in, out) is det.

	% Return an rval for a pointer to the current environment
	% (the set of local variables in the containing procedure).
:- pred ml_declare_env_ptr_arg(pair(mlds__entity_name, mlds__type),
		ml_gen_info, ml_gen_info).
:- mode ml_declare_env_ptr_arg(out, in, out) is det.

%-----------------------------------------------------------------------------%
%
% Magic numbers relating to the representation of
% typeclass_infos, base_typeclass_infos, and closures.
%
	% This function returns the offset to add to the argument
	% number of a closure arg to get its field number.
:- func ml_closure_arg_offset = int.

	% This function returns the offset to add to the argument
	% number of a typeclass_info arg to get its field number.
:- func ml_typeclass_info_arg_offset = int.

	% This function returns the offset to add to the method number
	% for a type class method to get its field number within the
	% base_typeclass_info.
:- func ml_base_typeclass_info_method_offset = int.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%
%
% The `ml_gen_info' ADT.
%

	%
	% The `ml_gen_info' type holds information used during
	% MLDS code generation for a given procedure.
	%
:- type ml_gen_info.

	% initialize the ml_gen_info, so that it is
	% ready for generating code for the given procedure
:- func ml_gen_info_init(module_info, pred_id, proc_id) = ml_gen_info.

	% accessor predicates; these just get the specified
	% information from the ml_gen_info

:- pred ml_gen_info_get_module_info(ml_gen_info, module_info).
:- mode ml_gen_info_get_module_info(in, out) is det.

:- pred ml_gen_info_get_module_name(ml_gen_info, mercury_module_name).
:- mode ml_gen_info_get_module_name(in, out) is det.

:- pred ml_gen_info_get_pred_id(ml_gen_info, pred_id).
:- mode ml_gen_info_get_pred_id(in, out) is det.

:- pred ml_gen_info_get_proc_id(ml_gen_info, proc_id).
:- mode ml_gen_info_get_proc_id(in, out) is det.

:- pred ml_gen_info_get_varset(ml_gen_info, prog_varset).
:- mode ml_gen_info_get_varset(in, out) is det.

:- pred ml_gen_info_get_var_types(ml_gen_info, map(prog_var, prog_type)).
:- mode ml_gen_info_get_var_types(in, out) is det.

:- pred ml_gen_info_get_output_vars(ml_gen_info, list(prog_var)).
:- mode ml_gen_info_get_output_vars(in, out) is det.

:- pred ml_gen_info_use_gcc_nested_functions(bool, ml_gen_info, ml_gen_info).
:- mode ml_gen_info_use_gcc_nested_functions(out, in, out) is det.

	% A number corresponding to an MLDS nested function which serves as a
	% label (i.e. a continuation function).
:- type ml_label_func == mlds__func_sequence_num.

	% Generate a new function label number.
	% This is used to give unique names to the nested functions
	% used when generating code for nondet procedures.
:- pred ml_gen_info_new_func_label(ml_label_func, ml_gen_info, ml_gen_info).
:- mode ml_gen_info_new_func_label(out, in, out) is det.

	% Increase the function label counter by some
	% amount which is presumed to be sufficient
	% to ensure that if we start again with a fresh
	% ml_gen_info and then call this function,
	% we won't encounter any already-used function labels.
	% (This is used when generating wrapper functions
	% for type class methods.)
:- pred ml_gen_info_bump_func_label(ml_gen_info, ml_gen_info).
:- mode ml_gen_info_bump_func_label(in, out) is det.

	% Generate a new commit label number.
	% This is used to give unique names to the labels
	% used when generating code for commits.
:- type commit_sequence_num == int.
:- pred ml_gen_info_new_commit_label(commit_sequence_num,
		ml_gen_info, ml_gen_info).
:- mode ml_gen_info_new_commit_label(out, in, out) is det.

	% Generate a new `cond' variable number.
	% This is used to give unique names to the local
	% variables used to hold the results of 
	% nondet conditions of if-then-elses.
:- type cond_seq == int.
:- pred ml_gen_info_new_cond_var(cond_seq,
		ml_gen_info, ml_gen_info).
:- mode ml_gen_info_new_cond_var(out, in, out) is det.

	% Generate a new `conv' variable number.
	% This is used to give unique names to the local
	% variables generated by ml_gen_box_or_unbox_lval,
	% which are used to handle boxing/unboxing
	% argument conversions.
:- type conv_seq == int.
:- pred ml_gen_info_new_conv_var(conv_seq,
		ml_gen_info, ml_gen_info).
:- mode ml_gen_info_new_conv_var(out, in, out) is det.

	%
	% A success continuation specifies the (rval for the variable
	% holding the address of the) function that a nondet procedure
	% should call if it succeeds, and possibly also the
	% (rval for the variable holding) the environment pointer
	% for that function.
	%
:- type success_cont 
	--->	success_cont(
			mlds__rval,	% function pointer
			mlds__rval	% environment pointer
				% note that if we're using nested
				% functions then the environment
				% pointer will not be used
		).

	%
	% The ml_gen_info contains a stack of success continuations.
	% The following routines provide access to that stack.
	%

:- pred ml_gen_info_push_success_cont(success_cont,
			ml_gen_info, ml_gen_info).
:- mode ml_gen_info_push_success_cont(in, in, out) is det.

:- pred ml_gen_info_pop_success_cont(ml_gen_info, ml_gen_info).
:- mode ml_gen_info_pop_success_cont(in, out) is det.

:- pred ml_gen_info_current_success_cont(success_cont,
			ml_gen_info, ml_gen_info).
:- mode ml_gen_info_current_success_cont(out, in, out) is det.

	%
	% We keep a partial mapping from vars to lvals.
	% This is used in special cases to override the normal
	% lval for a variable.  ml_gen_var will check this
	% map first, and if the variable is not in this map,
	% then it will go ahead and generate an lval for it
	% as usual.
	%

	% Set the lval for a variable.
:- pred ml_gen_info_set_var_lval(prog_var, mlds__lval,
			ml_gen_info, ml_gen_info).
:- mode ml_gen_info_set_var_lval(in, in, in, out) is det.

	% Get the partial mapping from variables to lvals.
:- pred ml_gen_info_get_var_lvals(ml_gen_info, map(prog_var, mlds__lval)).
:- mode ml_gen_info_get_var_lvals(in, out) is det.

	%
	% The ml_gen_info contains a list of extra definitions
	% of functions or global constants which should be inserted
	% before the definition of the function for the current procedure.
	% This is used for the definitions of the wrapper functions needed
	% for closures.  When generating code for a procedure that creates
	% a closure, we insert the definition of the wrapper function used
	% for that closure into this list.
	%

	% Insert an extra definition at the start of the list of extra
	% definitions.
:- pred ml_gen_info_add_extra_defn(mlds__defn,
			ml_gen_info, ml_gen_info).
:- mode ml_gen_info_add_extra_defn(in, in, out) is det.

	% Get the list of extra definitions.
:- pred ml_gen_info_get_extra_defns(ml_gen_info, mlds__defns).
:- mode ml_gen_info_get_extra_defns(in, out) is det.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- import_module prog_util, type_util, mode_util, special_pred.
:- import_module code_util. % XXX for `code_util__compiler_generated'.
:- import_module globals, options.

:- import_module stack, string, require, term, varset.

%-----------------------------------------------------------------------------%
%
% Code for various utility routines
%

	% Generate an MLDS assignment statement.
ml_gen_assign(Lval, Rval, Context) = MLDS_Statement :-
	Assign = assign(Lval, Rval),
	MLDS_Stmt = atomic(Assign),
	MLDS_Statement = mlds__statement(MLDS_Stmt,
		mlds__make_context(Context)).

	% Generate a block statement, i.e. `{ <Decls>; <Statements>; }'.
	% But if the block consists only of a single statement with no
	% declarations, then just return that statement.
	%
ml_gen_block(VarDecls, Statements, Context) =
	(if VarDecls = [], Statements = [SingleStatement] then
		SingleStatement
	else
		mlds__statement(block(VarDecls, Statements),
			mlds__make_context(Context))
	).

	% ml_join_decls:
	% 	Join two statement lists and their corresponding
	% 	declaration lists in sequence.
	% 
	% 	If the statements have no declarations in common,
	% 	then their corresponding declaration lists will be
	% 	concatenated together into a single list of declarations.
	% 	But if they have any declarations in common, then we
	% 	put each statement list and its declarations into
	% 	a block, so that the declarations remain local to
	% 	each statement list.
	% 
ml_join_decls(FirstDecls, FirstStatements, RestDecls, RestStatements, Context,
		MLDS_Decls, MLDS_Statements) :-
	(
		list__member(mlds__defn(Name, _, _, _), FirstDecls),
		list__member(mlds__defn(Name, _, _, _), RestDecls)
	->
		First = ml_gen_block(FirstDecls, FirstStatements, Context),
		Rest = ml_gen_block(RestDecls, RestStatements, Context),
		MLDS_Decls = [],
		MLDS_Statements = [First, Rest]
	;
		MLDS_Decls = list__append(FirstDecls, RestDecls),
		MLDS_Statements = list__append(FirstStatements, RestStatements)
	).

	% ml_combine_conj:
	%	Given closures to generate code for two conjuncts,
	%	generate code for their conjunction.
	%
ml_combine_conj(FirstCodeModel, Context, DoGenFirst, DoGenRest,
		MLDS_Decls, MLDS_Statements) -->
	(
		%	model_det goal:
		%		<First, Rest>
		% 	===>
		%		<do First>
		%		<Rest>
		%	
		{ FirstCodeModel = model_det },
		DoGenFirst(FirstDecls, FirstStatements),
		DoGenRest(RestDecls, RestStatements),
		{ ml_join_decls(FirstDecls, FirstStatements,
			RestDecls, RestStatements, Context,
			MLDS_Decls, MLDS_Statements) }
	;
		%	model_semi goal:
		%		<Goal, Goals>
		% 	===>
		%	{
		%		bool succeeded;
		%
		%		<succeeded = Goal>;
		%		if (succeeded) {
		%			<Goals>;
		%		}
		%	}
		{ FirstCodeModel = model_semi },
		DoGenFirst(FirstDecls, FirstStatements),
		ml_gen_test_success(Succeeded),
		DoGenRest(RestDecls, RestStatements),
		{ IfBody = ml_gen_block(RestDecls, RestStatements, Context) },
		{ IfStmt = if_then_else(Succeeded, IfBody, no) },
		{ IfStatement = mlds__statement(IfStmt,
			mlds__make_context(Context)) },
		{ MLDS_Decls = FirstDecls },
		{ MLDS_Statements = list__append(FirstStatements,
			[IfStatement]) }
	;
		%	model_non goal:
		%		<First, Rest>
		% 	===>
		%	{
		%		succ_func() {
		%			<Rest && SUCCEED()>;
		%		}
		%
		%		<First && succ_func()>;
		%	}
		%
		% XXX this leads to deep nesting for long conjunctions;
		%     we should avoid that.

		{ FirstCodeModel = model_non },

		% generate the `succ_func'
		ml_gen_new_func_label(RestFuncLabel, RestFuncLabelRval),
		/* push nesting level */
		DoGenRest(RestDecls, RestStatements),
		{ RestStatement = ml_gen_block(RestDecls, RestStatements,
			Context) },
		/* pop nesting level */
		ml_gen_nondet_label_func(RestFuncLabel, Context, RestStatement,
			RestFunc),

		ml_get_env_ptr(EnvPtrRval),
		{ SuccessCont = success_cont(RestFuncLabelRval,
			EnvPtrRval) },
		ml_gen_info_push_success_cont(SuccessCont),
		DoGenFirst(FirstDecls, FirstStatements),
		ml_gen_info_pop_success_cont,

		% it might be better to put the decls in the other order:
		/* { MLDS_Decls = list__append(FirstDecls, [RestFunc]) }, */
		{ MLDS_Decls = [RestFunc | FirstDecls] },
		{ MLDS_Statements = FirstStatements }
	).

	% Given a function label and the statement which will comprise
	% the function body for that function, generate an mlds__defn
	% which defines that function.
	%
ml_gen_nondet_label_func(FuncLabel, Context, Statement, Func) -->
	ml_gen_info_use_gcc_nested_functions(UseNested),
	( { UseNested = yes } ->
		{ FuncParams = mlds__func_params([], []) }
	;
		ml_declare_env_ptr_arg(EnvPtrArg),
		{ FuncParams = mlds__func_params([EnvPtrArg], []) }
	),
	ml_gen_label_func(FuncLabel, FuncParams, Context, Statement, Func).

	% Given a function label, the function parameters, and the statement
	% which will comprise the function body for that function,
	% generate an mlds__defn which defines that function.
	%
ml_gen_label_func(FuncLabel, FuncParams, Context, Statement, Func) -->
	%
	% compute the function name
	%
	=(Info),
	{ ml_gen_info_get_module_info(Info, ModuleInfo) },
	{ ml_gen_info_get_pred_id(Info, PredId) },
	{ ml_gen_info_get_proc_id(Info, ProcId) },
	{ FuncName = ml_gen_nondet_label(ModuleInfo, PredId, ProcId,
		FuncLabel) },

	%
	% compute the function definition
	%
	{ DeclFlags = ml_gen_label_func_decl_flags },
	{ MaybePredProcId = no },
	{ FuncDefn = function(MaybePredProcId, FuncParams, yes(Statement)) },
	{ Func = mlds__defn(FuncName, mlds__make_context(Context), DeclFlags,
			FuncDefn) }.

	% Return the declaration flags appropriate for a label func
	% (a label func is a function used as a continuation
	% when generating nondet code).
	%
:- func ml_gen_label_func_decl_flags = mlds__decl_flags.
ml_gen_label_func_decl_flags = MLDS_DeclFlags :-
	Access = private,
	PerInstance = per_instance,
	Virtuality = non_virtual,
	Finality = overridable,
	Constness = modifiable,
	Abstractness = concrete,
	MLDS_DeclFlags = init_decl_flags(Access, PerInstance,
		Virtuality, Finality, Constness, Abstractness).

	% Call error/1 with a "Sorry, not implemented" message.
	%
sorry(What) :-
	string__format("ml_code_gen.m: Sorry, not implemented: %s",
		[s(What)], ErrorMessage),
	error(ErrorMessage).

%-----------------------------------------------------------------------------%
%
% Code for generating types.
%

ml_gen_type(Type, MLDS_Type) -->
	=(Info),
	{ ml_gen_info_get_module_info(Info, ModuleInfo) },
	{ MLDS_Type = mercury_type_to_mlds_type(ModuleInfo, Type) }.

%-----------------------------------------------------------------------------%
%
% Code for generating function declarations (i.e. mlds__func_params).
%

	% Generate the function prototype for a given procedure.
	%
ml_gen_proc_params(ModuleInfo, PredId, ProcId) = FuncParams :-
	module_info_pred_proc_info(ModuleInfo, PredId, ProcId,
		PredInfo, ProcInfo),
	proc_info_varset(ProcInfo, VarSet),
	proc_info_headvars(ProcInfo, HeadVars),
	pred_info_arg_types(PredInfo, HeadTypes),
	proc_info_argmodes(ProcInfo, HeadModes),
	proc_info_interface_code_model(ProcInfo, CodeModel),
	HeadVarNames = ml_gen_var_names(VarSet, HeadVars),
	FuncParams = ml_gen_params(ModuleInfo, HeadVarNames, HeadTypes,
		HeadModes, CodeModel).

	% As above, but from the rtti_proc_id rather than
	% from the module_info, pred_id, and proc_id.
	%
ml_gen_proc_params_from_rtti(ModuleInfo, RttiProcId) = FuncParams :-
	VarSet = RttiProcId^proc_varset,
	HeadVars = RttiProcId^proc_headvars,
	ArgTypes = RttiProcId^arg_types,
	ArgModes = RttiProcId^proc_arg_modes,
	CodeModel = RttiProcId^proc_interface_code_model,
	HeadVarNames = ml_gen_var_names(VarSet, HeadVars),
	FuncParams = ml_gen_params_base(ModuleInfo, HeadVarNames,
		ArgTypes, ArgModes, CodeModel).
	
	% Generate the function prototype for a procedure with the
	% given argument types, modes, and code model.
	%
ml_gen_params(ModuleInfo, HeadVarNames, HeadTypes, HeadModes, CodeModel) =
		FuncParams :-
	modes_to_arg_modes(ModuleInfo, HeadModes, HeadTypes, ArgModes),
	FuncParams = ml_gen_params_base(ModuleInfo, HeadVarNames,
		HeadTypes, ArgModes, CodeModel).

:- func ml_gen_params_base(module_info, list(string), list(prog_type),
		list(arg_mode), code_model) = mlds__func_params.

ml_gen_params_base(ModuleInfo, HeadVarNames, HeadTypes, HeadModes,
		CodeModel) = FuncParams :-
	( CodeModel = model_semi ->
		RetTypes = [mlds__native_bool_type]
	;
		RetTypes = []
	),
	ml_gen_arg_decls(ModuleInfo, HeadVarNames, HeadTypes, HeadModes,
		FuncArgs0),
	( CodeModel = model_non ->
		ContType = mlds__cont_type,
		ContName = data(var("cont")),
		ContArg = ContName - ContType,
		ContEnvType = mlds__generic_env_ptr_type,
		ContEnvName = data(var("cont_env_ptr")),
		ContEnvArg = ContEnvName - ContEnvType,
		module_info_globals(ModuleInfo, Globals),
		globals__lookup_bool_option(Globals, gcc_nested_functions,
			NestedFunctions),
		(
			NestedFunctions = yes
		->
			FuncArgs = list__append(FuncArgs0, [ContArg])
		;
			FuncArgs = list__append(FuncArgs0,
				[ContArg, ContEnvArg])
		)
	;
		FuncArgs = FuncArgs0
	),
	FuncParams = mlds__func_params(FuncArgs, RetTypes).

	% Given the argument variable names, and corresponding lists of their
	% types and modes, generate the MLDS argument list declaration.
	%
:- pred ml_gen_arg_decls(module_info, list(mlds__var_name), list(prog_type),
		list(arg_mode), mlds__arguments).
:- mode ml_gen_arg_decls(in, in, in, in, out) is det.

ml_gen_arg_decls(ModuleInfo, HeadVars, HeadTypes, HeadModes, FuncArgs) :-
	(
		HeadVars = [], HeadTypes = [], HeadModes = []
	->
		FuncArgs = []
	;	
		HeadVars = [Var | Vars],
		HeadTypes = [Type | Types],
		HeadModes = [Mode | Modes]
	->
		ml_gen_arg_decls(ModuleInfo, Vars, Types, Modes, FuncArgs0),
		% exclude types such as io__state, etc.
		( type_util__is_dummy_argument_type(Type) ->
			FuncArgs = FuncArgs0
		;
			ml_gen_arg_decl(ModuleInfo, Var, Type, Mode, FuncArg),
			FuncArgs = [FuncArg | FuncArgs0]
		)
	;
		error("ml_gen_arg_decls: length mismatch")
	).

	% Given an argument variable, and its type and mode,
	% generate an MLDS argument declaration for it.
	%
:- pred ml_gen_arg_decl(module_info, var_name, prog_type, arg_mode,
			pair(mlds__entity_name, mlds__type)).
:- mode ml_gen_arg_decl(in, in, in, in, out) is det.

ml_gen_arg_decl(ModuleInfo, Var, Type, ArgMode, FuncArg) :-
	MLDS_Type = mercury_type_to_mlds_type(ModuleInfo, Type),
	( ArgMode \= top_in ->
		MLDS_ArgType = mlds__ptr_type(MLDS_Type)
	;
		MLDS_ArgType = MLDS_Type
	),
	Name = data(var(Var)),
	FuncArg = Name - MLDS_ArgType.

%-----------------------------------------------------------------------------%
%
% Code for generating mlds__entity_names.
%

	% Generate the mlds__entity_name for the entry point function
	% corresponding to a given procedure.
	%
ml_gen_proc_label(ModuleInfo, PredId, ProcId) = 
	ml_gen_func_label(ModuleInfo, PredId, ProcId, no).

	% Generate an mlds__entity_name for a continuation function
	% with the given sequence number.  The pred_id and proc_id
	% specify the procedure that this continuation function
	% is part of.
	%
ml_gen_nondet_label(ModuleInfo, PredId, ProcId, SeqNum) =
	ml_gen_func_label(ModuleInfo, PredId, ProcId, yes(SeqNum)).

:- func ml_gen_func_label(module_info, pred_id, proc_id,
		maybe(ml_label_func)) = mlds__entity_name.
ml_gen_func_label(ModuleInfo, PredId, ProcId, MaybeSeqNum) = MLDS_Name :-
	ml_gen_pred_label(ModuleInfo, PredId, ProcId, MLDS_PredLabel, _),
	MLDS_Name = function(MLDS_PredLabel, ProcId, MaybeSeqNum, PredId).

	% Allocate a new function label and return an rval containing
	% the function's address.
	%
ml_gen_new_func_label(FuncLabel, FuncLabelRval) -->
	ml_gen_info_new_func_label(FuncLabel),
	=(Info),
	{ ml_gen_info_get_module_info(Info, ModuleInfo) },
	{ ml_gen_info_get_pred_id(Info, PredId) },
	{ ml_gen_info_get_proc_id(Info, ProcId) },
	{ ml_gen_pred_label(ModuleInfo, PredId, ProcId,
		PredLabel, PredModule) },
	{ ml_gen_info_use_gcc_nested_functions(UseNestedFuncs, Info, _) },
	{ UseNestedFuncs = yes ->
		ArgTypes = []
	;
		ArgTypes = [mlds__generic_env_ptr_type]
	},
	{ Signature = mlds__func_signature(ArgTypes, []) },

	{ ProcLabel = qual(PredModule, PredLabel - ProcId) },
	{ FuncLabelRval = const(code_addr_const(internal(ProcLabel,
		FuncLabel, Signature))) }.

	% Generate the mlds__pred_label and module name
	% for a given procedure.
	%
ml_gen_pred_label(ModuleInfo, PredId, ProcId, MLDS_PredLabel, MLDS_Module) :-
	RttiProcLabel = rtti__make_proc_label(ModuleInfo, PredId, ProcId),
	ml_gen_pred_label_from_rtti(RttiProcLabel,
		MLDS_PredLabel, MLDS_Module).

ml_gen_pred_label_from_rtti(RttiProcLabel, MLDS_PredLabel, MLDS_Module) :-
	RttiProcLabel = rtti_proc_label(PredOrFunc, ThisModule, PredModule,	
		PredName, PredArity, ArgTypes, _PredId, ProcId,
		_VarSet, _HeadVars, _ArgModes, _CodeModel,
		IsImported, _IsPseudoImported, _IsExported,
		IsSpecialPredInstance),
	(
		IsSpecialPredInstance = yes
	->
		(
			special_pred_get_type(PredName, ArgTypes, Type),
			type_to_type_id(Type, TypeId, _),
			% All type_ids here should be module qualified,
			% since builtin types are handled separately in
			% polymorphism.m.
			TypeId = qualified(TypeModule, TypeName) - TypeArity
		->
			(
				ThisModule \= TypeModule,
				PredName = "__Unify__",
				\+ hlds_pred__in_in_unification_proc_id(ProcId)
			->
				% This is a locally-defined instance
				% of a unification procedure for a type
				% defined in some other module
				DefiningModule = ThisModule,
				MaybeDeclaringModule = yes(TypeModule)
			;
				% the module declaring the type is the same as
				% the module defining this special pred
				DefiningModule = TypeModule,
				MaybeDeclaringModule = no
			),
			MLDS_PredLabel = special_pred(PredName,
				MaybeDeclaringModule, TypeName, TypeArity)
		;
			string__append_list(["ml_gen_pred_label:\n",
				"cannot make label for special pred `",
				PredName, "'"], ErrorMessage),
			error(ErrorMessage)
		)
	;
		(
			% Work out which module supplies the code for
			% the predicate.
			ThisModule \= PredModule,
			IsImported = no
		->
			% This predicate is a specialized version of 
			% a pred from a `.opt' file.
			DefiningModule = ThisModule,
			MaybeDeclaringModule = yes(PredModule)
		;	
			% The predicate was declared in the same module
			% that it is defined in
			DefiningModule = PredModule,
			MaybeDeclaringModule = no
		),
		MLDS_PredLabel = pred(PredOrFunc, MaybeDeclaringModule,
				PredName, PredArity)
	),
	MLDS_Module = mercury_module_name_to_mlds(DefiningModule).

%-----------------------------------------------------------------------------%
%
% Code for dealing with variables
%

	% Generate a list of the mlds__lvals corresponding to a
	% given list of prog_vars.
	%
ml_gen_var_list([], []) --> [].
ml_gen_var_list([Var | Vars], [Lval | Lvals]) -->
	ml_gen_var(Var, Lval),
	ml_gen_var_list(Vars, Lvals).

	% Generate the mlds__lval corresponding to a given prog_var.
	%
ml_gen_var(Var, Lval) -->
	%
	% First check the var_lvals override mapping;
	% if an lval has been set for this variable, use it
	%
	=(Info),
	{ ml_gen_info_get_var_lvals(Info, VarLvals) },
	( { map__search(VarLvals, Var, VarLval) } ->
		{ Lval = VarLval }
	;
		%
		% Otherwise just look up the variable's type
		% and generate an lval for it using the ordinary
		% algorithm.
		%
		ml_variable_type(Var, Type),
		ml_gen_var_with_type(Var, Type, Lval)
	).

	% Generate the mlds__lval corresponding to a given prog_var,
	% with a given type.
	%
ml_gen_var_with_type(Var, Type, Lval) -->
	( { type_util__is_dummy_argument_type(Type) } ->
		%
		% The variable won't have been declared, so
		% we need to generate a dummy lval for this variable.
		%
		{ mercury_private_builtin_module(PrivateBuiltin) },
		{ MLDS_Module = mercury_module_name_to_mlds(PrivateBuiltin) },
		{ Lval = var(qual(MLDS_Module, "dummy_var")) }
	;
		=(MLDSGenInfo),
		{ ml_gen_info_get_varset(MLDSGenInfo, VarSet) },
		{ VarName = ml_gen_var_name(VarSet, Var) },
		ml_qualify_var(VarName, VarLval),
		%
		% output variables are passed by reference...
		%
		{ ml_gen_info_get_output_vars(MLDSGenInfo, OutputVars) },
		( { list__member(Var, OutputVars) } ->
			ml_gen_type(Type, MLDS_Type),
			{ Lval = mem_ref(lval(VarLval), MLDS_Type) }
		;
			{ Lval = VarLval }
		)
	).

	% Lookup the types of a list of variables.
	%
ml_variable_types([], []) --> [].
ml_variable_types([Var | Vars], [Type | Types]) -->
	ml_variable_type(Var, Type),
	ml_variable_types(Vars, Types).

	% Lookup the type of a variable.
	%
ml_variable_type(Var, Type) -->
	=(MLDSGenInfo),
	{ ml_gen_info_get_var_types(MLDSGenInfo, VarTypes) },
	{ map__lookup(VarTypes, Var, Type) }.

	% Generate the MLDS variable names for a list of HLDS variables.
	%
ml_gen_var_names(VarSet, Vars) = list__map(ml_gen_var_name(VarSet), Vars).

	% Generate the MLDS variable name for an HLDS variable.
	%
ml_gen_var_name(VarSet, Var) = UniqueVarName :-
	varset__lookup_name(VarSet, Var, VarName),
	term__var_to_int(Var, VarNumber),
	string__format("%s_%d", [s(VarName), i(VarNumber)], UniqueVarName).

ml_qualify_var(VarName, QualifiedVarLval) -->
	=(MLDSGenInfo),
	{ ml_gen_info_get_module_name(MLDSGenInfo, ModuleName) },
	{ MLDS_Module = mercury_module_name_to_mlds(ModuleName) },
	{ QualifiedVarLval = var(qual(MLDS_Module, VarName)) }.

	% Generate a declaration for an MLDS variable, given its HLDS type.
	%
ml_gen_var_decl(VarName, Type, Context, ModuleInfo) =
	ml_gen_mlds_var_decl(var(VarName),
		mercury_type_to_mlds_type(ModuleInfo, Type), Context).

	% Generate a declaration for an MLDS variable, given its MLDS type.
	%
ml_gen_mlds_var_decl(DataName, MLDS_Type, Context) = 
	ml_gen_mlds_var_decl(DataName, MLDS_Type, no_initializer, Context).
	

	% Generate a declaration for an MLDS variable, given its MLDS type
	% and initializer.
	%
ml_gen_mlds_var_decl(DataName, MLDS_Type, Initializer, Context) = MLDS_Defn :-
	Name = data(DataName),
	Defn = data(MLDS_Type, Initializer),
	DeclFlags = ml_gen_var_decl_flags,
	MLDS_Defn = mlds__defn(Name, Context, DeclFlags, Defn).

	% Return the declaration flags appropriate for a local variable.
:- func ml_gen_var_decl_flags = mlds__decl_flags.
ml_gen_var_decl_flags = MLDS_DeclFlags :-
	Access = public,
	PerInstance = per_instance,
	Virtuality = non_virtual,
	Finality = overridable,
	Constness = modifiable,
	Abstractness = concrete,
	MLDS_DeclFlags = init_decl_flags(Access, PerInstance,
		Virtuality, Finality, Constness, Abstractness).

%-----------------------------------------------------------------------------%
%
% Code for handling success and failure
%

	% Generate code to succeed in the given code_model.
	%
ml_gen_success(model_det, _, MLDS_Statements) -->
	%
	% det succeed:
	%	<do true>
	% ===>
	%	/* just fall through */
	%
	{ MLDS_Statements = [] }.
ml_gen_success(model_semi, Context, [SetSuccessTrue]) -->
	%
	% semidet succeed:
	%	<do true>
	% ===>
	%	succeeded = TRUE;
	%
	ml_gen_set_success(const(true), Context, SetSuccessTrue).
ml_gen_success(model_non, Context, [CallCont]) -->
	%
	% nondet succeed:
	%	<true && SUCCEED()>
	% ===>
	%	SUCCEED()
	%
	ml_gen_call_current_success_cont(Context, CallCont).

	% Generate code to fail in the given code_model.
	%
ml_gen_failure(model_det, _, _) -->
	% this should never happen
	{ error("ml_code_gen: `fail' has determinism `det'") }.
ml_gen_failure(model_semi, Context, [SetSuccessFalse]) -->
	%
	% semidet fail:
	%	<do fail>
	% ===>
	%	succeeded = FALSE;
	%
	ml_gen_set_success(const(false), Context, SetSuccessFalse).
ml_gen_failure(model_non, _, MLDS_Statements) -->
	%
	% nondet fail:
	%	<fail && SUCCEED()>
	% ===>
	%	/* just fall through */
	%
	{ MLDS_Statements = [] }.

%-----------------------------------------------------------------------------%

	% Generate the declaration for the built-in `succeeded' variable.
	%
ml_gen_succeeded_var_decl(Context) =
	ml_gen_mlds_var_decl(var("succeeded"), mlds__native_bool_type, Context).

	% Return the lval for the `succeeded' flag.
	% (`succeeded' is a boolean variable used to record
	% the success or failure of model_semi procedures.)
	%
ml_success_lval(SucceededLval) -->
	ml_qualify_var("succeeded", SucceededLval).

	% Return an rval which will test the value of the `succeeded' flag.
	% (`succeeded' is a boolean variable used to record
	% the success or failure of model_semi procedures.)
	%
ml_gen_test_success(SucceededRval) -->
	ml_success_lval(SucceededLval),
	{ SucceededRval = lval(SucceededLval) }.
	
	% Generate code to set the `succeeded' flag to the
	% specified truth value.
	%
ml_gen_set_success(Value, Context, MLDS_Statement) -->
	ml_success_lval(Succeeded),
	{ MLDS_Statement = ml_gen_assign(Succeeded, Value, Context) }.

%-----------------------------------------------------------------------------%

	% Generate the name for the specified `cond_<N>' variable.
	%
:- func ml_gen_cond_var_name(cond_seq) = string.
ml_gen_cond_var_name(CondVar) =
	string__append("cond_", string__int_to_string(CondVar)).

ml_gen_cond_var_decl(CondVar, Context) =
	ml_gen_mlds_var_decl(var(ml_gen_cond_var_name(CondVar)),
		mlds__native_bool_type, Context).

ml_cond_var_lval(CondVar, CondVarLval) -->
	ml_qualify_var(ml_gen_cond_var_name(CondVar), CondVarLval).

ml_gen_test_cond_var(CondVar, CondVarRval) -->
	ml_cond_var_lval(CondVar, CondVarLval),
	{ CondVarRval = lval(CondVarLval) }.
	
ml_gen_set_cond_var(CondVar, Value, Context, MLDS_Statement) -->
	ml_cond_var_lval(CondVar, CondVarLval),
	{ MLDS_Statement = ml_gen_assign(CondVarLval, Value, Context) }.

%-----------------------------------------------------------------------------%

	% Return rvals for the success continuation that was
	% passed as the current function's argument(s).
	% The success continuation consists of two parts, the
	% `cont' argument, and the `cont_env' argument.
	% The `cont' argument is a continuation function that
	% will be called when a model_non goal succeeds.
	% The `cont_env' argument is a pointer to the environment (set
	% of local variables in the containing procedure) for the continuation
	% function.  (If we're using gcc nested function, the `cont_env'
	% is not used.)
	%
ml_initial_cont(Cont) -->
	ml_qualify_var("cont", ContLval),
	ml_qualify_var("cont_env_ptr", ContEnvLval),
	{ Cont = success_cont(lval(ContLval), lval(ContEnvLval)) }.

	% Generate code to call the current success continuation.
	% This is used for generating success when in a model_non context.
	%
ml_gen_call_current_success_cont(Context, MLDS_Statement) -->
	ml_gen_info_current_success_cont(SuccCont),
	{ SuccCont = success_cont(FuncRval, EnvPtrRval) },
	ml_gen_info_use_gcc_nested_functions(UseNestedFuncs),
	( { UseNestedFuncs = yes } ->
		{ ArgTypes = [] }
	;
		{ ArgTypes = [mlds__generic_env_ptr_type] }
	),
	{ RetTypes = [] },
	{ Signature = mlds__func_signature(ArgTypes, RetTypes) },
	{ ObjectRval = no },
	( { UseNestedFuncs = yes } ->
		{ ArgRvals = [] }
	;
		{ ArgRvals = [EnvPtrRval] }
	),
	{ RetLvals = [] },
	{ CallOrTailcall = call },
	{ MLDS_Stmt = call(Signature, FuncRval, ObjectRval, ArgRvals, RetLvals,
			CallOrTailcall) },
	{ MLDS_Statement = mlds__statement(MLDS_Stmt,
			mlds__make_context(Context)) }.

%-----------------------------------------------------------------------------%
%
% Routines for dealing with the environment pointer
% used for nested functions.
%

	% Return an rval for a pointer to the current environment
	% (the set of local variables in the containing procedure).
	% Note that we generate this as a dangling reference.
	% The ml_elim_nested pass will insert the declaration
	% of the env_ptr variable.
ml_get_env_ptr(lval(EnvPtrLval)) -->
	ml_qualify_var("env_ptr", EnvPtrLval).

	% Return an rval for a pointer to the current environment
	% (the set of local variables in the containing procedure).
ml_declare_env_ptr_arg(Name - mlds__generic_env_ptr_type) -->
	{ Name = data(var("env_ptr_arg")) }.

%-----------------------------------------------------------------------------%
%
% The definition of the `ml_gen_info' ADT.
%

%
% The `ml_gen_info' type holds information used during MLDS code generation
% for a given procedure.
%
% Only the `func_label', `commit_label', `cond_var', `success_cont_stack',
% and `extra_defns' fields are mutable; the others are set when the 
% `ml_gen_info' is created and then never modified.
% 

:- type ml_gen_info
	--->	ml_gen_info(
			%
			% these fields remain constant for each procedure
			%

			module_info :: module_info,
			pred_id :: pred_id,
			proc_id :: proc_id,
			varset :: prog_varset,
			var_types :: map(prog_var, prog_type),
			output_vars :: list(prog_var),	% output arguments

			%
			% these fields get updated as we traverse
			% each procedure
			%

			func_label :: mlds__func_sequence_num,
			commit_label :: commit_sequence_num,
			cond_var :: cond_seq,
			conv_var :: conv_seq,
			success_cont_stack :: stack(success_cont),
				% a partial mapping from vars to lvals,
				% used to override the normal lval
				% that we use for a variable
			var_lvals :: map(prog_var, mlds__lval),
				% definitions of functions or global
				% constants which should be inserted
				% before the definition of the function
				% for the current procedure
			extra_defns :: mlds__defns
		).

ml_gen_info_init(ModuleInfo, PredId, ProcId) = MLDSGenInfo :-
	module_info_pred_proc_info(ModuleInfo, PredId, ProcId,
			PredInfo, ProcInfo),
	proc_info_headvars(ProcInfo, HeadVars),
	proc_info_varset(ProcInfo, VarSet),
	proc_info_vartypes(ProcInfo, VarTypes),
	proc_info_argmodes(ProcInfo, HeadModes),
	pred_info_arg_types(PredInfo, ArgTypes),
	map__from_corresponding_lists(HeadVars, ArgTypes, HeadVarTypes),
	OutputVars = select_output_vars(ModuleInfo, HeadVars, HeadModes,
		HeadVarTypes, VarTypes),

	FuncLabelCounter = 0,
	CommitLabelCounter = 0,
	CondVarCounter = 0,
	ConvVarCounter = 0,
	stack__init(SuccContStack),
	map__init(VarLvals),
	ExtraDefns = [],

	MLDSGenInfo = ml_gen_info(
			ModuleInfo,
			PredId,
			ProcId,
			VarSet,
			VarTypes,
			OutputVars,
			FuncLabelCounter,
			CommitLabelCounter,
			CondVarCounter,
			ConvVarCounter,
			SuccContStack,
			VarLvals,
			ExtraDefns
		).

ml_gen_info_get_module_info(Info, Info^module_info).

ml_gen_info_get_module_name(MLDSGenInfo, ModuleName) :-
	ml_gen_info_get_module_info(MLDSGenInfo, ModuleInfo),
	module_info_name(ModuleInfo, ModuleName).

ml_gen_info_get_pred_id(Info, Info^pred_id).
ml_gen_info_get_proc_id(Info, Info^proc_id).
ml_gen_info_get_varset(Info, Info^varset).
ml_gen_info_get_var_types(Info, Info^var_types).
ml_gen_info_get_output_vars(Info, Info^output_vars).

ml_gen_info_use_gcc_nested_functions(UseNestedFuncs) -->
	=(Info),
	{ ml_gen_info_get_module_info(Info, ModuleInfo) },
	{ module_info_globals(ModuleInfo, Globals) },
	{ globals__lookup_bool_option(Globals, gcc_nested_functions,
		UseNestedFuncs) }.

ml_gen_info_new_func_label(Label, Info, Info^func_label := Label) :-
	Label = Info^func_label + 1.

ml_gen_info_bump_func_label(Info,
	Info^func_label := Info^func_label + 10000).

ml_gen_info_new_commit_label(CommitLabel, Info,
		Info^commit_label := CommitLabel) :-
	CommitLabel = Info^commit_label + 1.

ml_gen_info_new_cond_var(CondVar, Info, Info^cond_var := CondVar) :-
	CondVar = Info^cond_var + 1.

ml_gen_info_new_conv_var(ConvVar, Info, Info^conv_var := ConvVar) :-
	ConvVar = Info^conv_var + 1.

ml_gen_info_push_success_cont(SuccCont, Info,
	Info^success_cont_stack :=
		stack__push(Info^success_cont_stack, SuccCont)).

ml_gen_info_pop_success_cont(Info0, Info) :-
	Stack0 = Info0^success_cont_stack,
	stack__pop_det(Stack0, _SuccCont, Stack),
	Info = (Info0^success_cont_stack := Stack).

ml_gen_info_current_success_cont(SuccCont, Info, Info) :-
	stack__top_det(Info^success_cont_stack, SuccCont).

ml_gen_info_get_var_lvals(Info, Info^var_lvals).

ml_gen_info_set_var_lval(Var, Lval, Info,
		Info^var_lvals := map__set(Info^var_lvals, Var, Lval)).

ml_gen_info_add_extra_defn(ExtraDefn, Info,
	Info^extra_defns := [ExtraDefn | Info^extra_defns]).

ml_gen_info_get_extra_defns(Info, Info^extra_defns).

%-----------------------------------------------------------------------------%

	% Given a list of variables and their corresponding modes,
	% return a list containing only those variables which have
	% an output mode.
	%
:- func select_output_vars(module_info, list(prog_var), list(mode),
		vartypes, vartypes) = list(prog_var).

select_output_vars(ModuleInfo, HeadVars, HeadModes, HeadVarTypes, VarTypes)
		= OutputVars :-
	( HeadVars = [], HeadModes = [] ->
		OutputVars = []
	; HeadVars = [Var|Vars], HeadModes = [Mode|Modes] ->
		map__lookup(VarTypes, Var, VarType),
		map__lookup(HeadVarTypes, Var, HeadType),
		(
			\+ mode_to_arg_mode(ModuleInfo, Mode, VarType, top_in),
			%
			% if this argument is an existentially typed output
			% that we need to box, then don't include it in the
			% output_vars; ml_gen_box_existential_outputs
			% will handle these outputs separately.
			%
			\+ (
				HeadType = term__variable(_),
				VarType = term__functor(_, _, _)
			)
		->
			OutputVars1 = select_output_vars(ModuleInfo,
					Vars, Modes, HeadVarTypes, VarTypes),
			OutputVars = [Var | OutputVars1]
		;
			OutputVars = select_output_vars(ModuleInfo,
					Vars, Modes, HeadVarTypes, VarTypes)
		)
	;
		error("select_output_vars: length mismatch")
	).

%-----------------------------------------------------------------------------%

	% This function returns the offset to add to the argument
	% number of a closure arg to get its field number.
	%	field 0 is the closure layout
	%	field 1 is the closure address
	%	field 2 is the number of arguments
	%	field 3 is the 1st argument field
	%	field 4 is the 2nd argument field,
	%	etc.
	% Hence the offset to add to the argument number
	% to get the field number is 2.
ml_closure_arg_offset = 2.

	% This function returns the offset to add to the argument
	% number of a typeclass_info arg to get its field number.
	% The Nth extra argument to pass to the method is
	% in field N of the typeclass_info, so the offset is zero.
ml_typeclass_info_arg_offset = 0.

	% This function returns the offset to add to the method number
	% for a type class method to get its field number within the
	% base_typeclass_info. 
	%	field 0 is num_extra
	%	field 1 is num_constraints
	%	field 2 is num_superclasses
	%	field 3 is class_arity
	%	field 4 is num_methods
	%	field 5 is the 1st method
	%	field 6 is the 2nd method
	%	etc.
	%	(See the base_typeclass_info type in rtti.m or the
	%	description in notes/type_class_transformation.html for
	%	more information about the layout of base_typeclass_infos.)
	% Hence the offset is 4.
ml_base_typeclass_info_method_offset = 4.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%
