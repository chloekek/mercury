%-----------------------------------------------------------------------------%
% Copyright (C) 1994-2000 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%

% File: quantification.m.
% Main authors: fjh, conway.

	% Make implicit quantification explicit, and rename apart
	% variables with the same name that appear in distinct scopes.
	% For the rules on implicit quantification, see the
	% Mercury language reference manual.
	%
	% This pass also expands out bi-implications (that has to be
	% done after quantification, and preferably as soon as possible,
	% so we do it here).
	%
	% Rather than making implicit quantification explicit by
	% inserting additional existential quantifiers in the form of
	% `some/2' goals, we instead record existential quantification
	% in the goal_info for each goal.  In fact we could (should?)
	% even delete any explicit existential quantifiers that were
	% present in the source code, since the information they convey
	% will be stored in the goal_info, although currently we don't
	% do that.
	% 
	% The important piece of information that later stages of the
	% compilation process want to know is "Does this goal bind any
	% of its non-local variables?".  So, rather than storing a list
	% of the variables which _are_ existentially quantified in the
	% goal_info, we store the set of variables which are _not_
	% quantified.

%-----------------------------------------------------------------------------%

:- module quantification.

:- interface.

:- import_module hlds_goal, hlds_pred, prog_data.
:- import_module map, list, set.

	%
	% When the compiler performs structure reuse, using
	% the ordinary non-locals during code generation
	% causes variables taken from the reused cell in
	% a reconstruction to be extracted and possibly stored
	% on the stack unnecessarily.
	%
	% For the example below, the variables `B' ... `H' are
	% extracted from the term and stored on the stack across
	% the call.
	% 
	% To avoid this, the compiler computes a set of `code-gen non-locals'
	% which are the same as the ordinary non-locals, except that the
	% variables taken from the reused cell are considered to be local
	% to the goal. No renaming is performed when computing
	% the code-gen non-locals to avoid stuffing up the ordinary
	% non-locals.
	%
	% Mode information is always computed using the ordinary non-locals.
	%
	% :- pred update(X::in, foo::di, foo::uo) is det.
	% update(A0, Foo0, Foo) :-
	% 	Foo0 = foo(_, B, C, D, E, F, G, H),
	%	some_call(A0, A),
	% 	Foo0 = foo(A, B, C, D, E, F, G, H).
	%
:- type nonlocals_to_recompute
	--->	ordinary_nonlocals
	;	code_gen_nonlocals.

:- pred implicitly_quantify_clause_body(nonlocals_to_recompute, list(prog_var),
		hlds_goal, prog_varset, map(prog_var, type),
		hlds_goal, prog_varset, map(prog_var, type),
		list(quant_warning)).
:- mode implicitly_quantify_clause_body(in, in, in, in, in, out, out, out, out)
	is det.

	
	% As above, with `ordinary_nonlocals' passed as the first argument.
:- pred implicitly_quantify_clause_body(list(prog_var),
		hlds_goal, prog_varset, map(prog_var, type),
		hlds_goal, prog_varset, map(prog_var, type),
		list(quant_warning)).
:- mode implicitly_quantify_clause_body(in, in, in, in, out, out, out, out)
	is det.

:- pred implicitly_quantify_goal(nonlocals_to_recompute, hlds_goal, prog_varset,
		map(prog_var, type), set(prog_var), hlds_goal, prog_varset,
		map(prog_var, type), list(quant_warning)).
:- mode implicitly_quantify_goal(in, in, in, in, in,
		out, out, out, out) is det.

	% As above, with `ordinary_nonlocals' passed as the first argument.
:- pred implicitly_quantify_goal(hlds_goal, prog_varset, map(prog_var, type),
		set(prog_var), hlds_goal, prog_varset,
		map(prog_var, type), list(quant_warning)).
:- mode implicitly_quantify_goal(in, in, in, in, out, out, out, out) is det.

:- pred requantify_proc(nonlocals_to_recompute, proc_info, proc_info) is det.
:- mode requantify_proc(in, in, out) is det.

	% As above, with `ordinary_nonlocals' passed as the first argument.
:- pred requantify_proc(proc_info, proc_info) is det.
:- mode requantify_proc(in, out) is det.

	% We return a list of warnings back to make_hlds.m.
	% Currently the only thing we warn about is variables with
	% overlapping scopes.

:- type quant_warning
	--->	warn_overlap(list(prog_var), prog_context).

	% quantification__goal_vars(Goal, Vars):
	%	Vars is the set of variables that are free (unquantified)
	%	in Goal.
:- pred quantification__goal_vars(nonlocals_to_recompute,
		hlds_goal, set(prog_var)).
:- mode quantification__goal_vars(in, in, out) is det.

	% As above, with `ordinary_nonlocals' passed as the first argument.
:- pred quantification__goal_vars(hlds_goal, set(prog_var)).
:- mode quantification__goal_vars(in, out) is det.

%-----------------------------------------------------------------------------%

:- implementation.

:- import_module instmap, goal_util.

:- import_module term, varset.
:- import_module std_util, bool, require.

	% The `outside vars', `lambda outside vars', and `quant vars'
	% fields are inputs; the `nonlocals' field is output; and
	% the `seen so far', the varset, the types, and the warnings fields
	% are threaded (i.e. both input and output).
	% We use the convention that the input fields are callee save,
	% and the outputs are caller save.
	% The nonlocals_to_recompute field is constant.
:- type quant_info
	--->	quant_info(
			nonlocals_to_recompute :: nonlocals_to_recompute,
			outside :: set(prog_var),
			quant_vars :: set(prog_var),
			lambda_outside :: set(prog_var),
			nonlocals :: set(prog_var),
			seen :: set(prog_var),
			varset :: prog_varset,
			vartypes :: vartypes,
			warnings :: list(quant_warning)
		).

	% `OutsideVars' are the variables that have occurred free outside
	% this goal, not counting occurrences in parallel goals
	% and not counting occurrences in lambda goals,
	% or which have been explicitly existentially quantified 
	% over a scope which includes the current goal in a negated context.
	% `QuantVars' are the variables not in `OutsideVars' 
	% that have been explicitly existentially quantified over a scope
	% which includes the current goal in a positive (non-negated) context.
	% `OutsideLambdaVars' are the variables that have occurred free in
	% a lambda expression outside this goal, not counting occurrences in
	% parallel goals (and if this goal is itself inside a lambda
	% expression, not counting occurrences outside that lambda
	% expression).
	%
	% For example, for
	%
	%	test :- some [X] (p(X) ; not q(X) ; r(X), s(X)).
	%
	% when processing `r(X), s(X)', OutsideVars will be [] and
	% QuantifiedVars will be [X]; when processing `r(X)',
	% OutsideVars will be [X] and QuantifiedVars will be [],
	% since now [X] has occured in a goal (`s(X)') outside of `r(X)'.
	% When processing `not q(X)', OutsideVars will be [] and
	% QuantifiedVars will be [X]; when processing `q(X)',
	% OutsideVars will be [X] and QuantifiedVars will be [],
	% since the quantification can't be pushed inside the negation.

%-----------------------------------------------------------------------------%

implicitly_quantify_clause_body(HeadVars, Goal0, Varset0, VarTypes0,
		Goal, Varset, VarTypes, Warnings) :-
	implicitly_quantify_clause_body(ordinary_nonlocals,
		HeadVars, Goal0, Varset0, VarTypes0,
		Goal, Varset, VarTypes, Warnings).

implicitly_quantify_clause_body(RecomputeNonLocals, HeadVars, Goal0,
		Varset0, VarTypes0, Goal, Varset, VarTypes, Warnings) :-
	set__list_to_set(HeadVars, OutsideVars),
	implicitly_quantify_goal(RecomputeNonLocals, Goal0, Varset0, VarTypes0,
			OutsideVars, Goal, Varset, VarTypes, Warnings).

requantify_proc(ProcInfo0, ProcInfo) :-
	requantify_proc(ordinary_nonlocals, ProcInfo0, ProcInfo).

requantify_proc(RecomputeNonLocals, ProcInfo0, ProcInfo) :-
	proc_info_varset(ProcInfo0, Varset0),
	proc_info_vartypes(ProcInfo0, VarTypes0),
	proc_info_headvars(ProcInfo0, HeadVars),
	proc_info_goal(ProcInfo0, Goal0),
	implicitly_quantify_clause_body(RecomputeNonLocals, HeadVars,
		Goal0, Varset0, VarTypes0, Goal, Varset, VarTypes, _),
	proc_info_set_varset(ProcInfo0, Varset, ProcInfo1),
	proc_info_set_vartypes(ProcInfo1, VarTypes, ProcInfo2),
	proc_info_set_goal(ProcInfo2, Goal, ProcInfo).

implicitly_quantify_goal(Goal0, Varset0, VarTypes0, OutsideVars,
		Goal, Varset, VarTypes, Warnings) :-
	implicitly_quantify_goal(ordinary_nonlocals, Goal0, Varset0, VarTypes0,
		OutsideVars, Goal, Varset, VarTypes, Warnings).

implicitly_quantify_goal(RecomputeNonLocals, Goal0, Varset0, VarTypes0,
		OutsideVars, Goal, Varset, VarTypes, Warnings) :-
	implicitly_quantify_goal_2(ordinary_nonlocals,
		Goal0, Varset0, VarTypes0, OutsideVars,
		Goal1, Varset1, VarTypes1, Warnings),
	(
		RecomputeNonLocals = code_gen_nonlocals,

		% If the goal does not contain a reconstruction,
		% the code-gen nonlocals and the ordinary non-locals
		% are the same.
		goal_contains_reconstruction(Goal1)
	->
		implicitly_quantify_goal_2(code_gen_nonlocals,
			Goal1, Varset1, VarTypes1, OutsideVars,
			Goal, Varset, VarTypes, _)
	;
		Goal = Goal1,
		Varset = Varset1,
		VarTypes = VarTypes1
	).

:- pred implicitly_quantify_goal_2(nonlocals_to_recompute, hlds_goal,
		prog_varset, vartypes, set(prog_var), hlds_goal,
		prog_varset, vartypes, list(quant_warning)).
:- mode implicitly_quantify_goal_2(in, in, in, in, in,
		out, out, out, out) is det.
		
implicitly_quantify_goal_2(RecomputeNonLocals,
		Goal0, Varset0, VarTypes0, OutsideVars,
		Goal, Varset, VarTypes, Warnings) :-
	quantification__init(RecomputeNonLocals, OutsideVars,
		Varset0, VarTypes0, QuantInfo0),
	implicitly_quantify_goal(Goal0, Goal, QuantInfo0, QuantInfo),
	quantification__get_varset(Varset, QuantInfo, _),
	quantification__get_vartypes(VarTypes, QuantInfo, _),
	quantification__get_warnings(Warnings0, QuantInfo, _),
	list__reverse(Warnings0, Warnings).

:- pred implicitly_quantify_goal(hlds_goal, hlds_goal,
					quant_info, quant_info).
:- mode implicitly_quantify_goal(in, out, in, out) is det.

implicitly_quantify_goal(Goal0 - GoalInfo0, Goal - GoalInfo) -->
	quantification__get_seen(SeenVars),
	{ goal_info_get_context(GoalInfo0, Context) },
	implicitly_quantify_goal_2(Goal0, Context, Goal1),
	quantification__get_nonlocals(NonLocalVars),
	quantification__get_nonlocals_to_recompute(NonLocalsToRecompute),
	(
		% If there are any variables that are local to the goal
		% which we have come across before, then we rename them
		% apart.
		{ quantification__goal_vars(NonLocalsToRecompute,
			Goal0 - GoalInfo0, GoalVars0) },
		{ set__difference(GoalVars0, NonLocalVars, LocalVars) },
		{ set__intersect(SeenVars, LocalVars, RenameVars) },
		{ \+ set__empty(RenameVars) }
	->
		quantification__rename_apart(RenameVars, _, Goal1 - GoalInfo0,
				Goal - GoalInfo1)
	;
		{ Goal = Goal1 },
		{ GoalInfo1 = GoalInfo0 }
	),
	quantification__set_goal_nonlocals(GoalInfo1, NonLocalVars, GoalInfo2),
	%
	% If the non-locals set has shrunk (e.g. because some optimization
	% optimizes away the other occurrences of a variable, causing it
	% to become local when previously it was non-local),
	% then we may need to likewise shrink the instmap delta.
	%
	{ goal_info_get_instmap_delta(GoalInfo2, InstMapDelta0) },
	{ instmap_delta_restrict(InstMapDelta0, NonLocalVars, InstMapDelta) },
	{ goal_info_set_instmap_delta(GoalInfo2, InstMapDelta, GoalInfo) }.

:- pred implicitly_quantify_goal_2(hlds_goal_expr, prog_context,
				hlds_goal_expr, quant_info, quant_info).
:- mode implicitly_quantify_goal_2(in, in, out, in, out) is det.

	% After this pass, explicit quantifiers are redundant,
	% since all variables which were explicitly quantified
	% have been renamed apart.  So we don't keep them.
	% We need to keep the structure, though, so that mode
	% analysis doesn't try to reorder through quantifiers.
	% (Actually it would make sense to allow mode analysis
	% to do that, but the reference manual says it doesn't,
	% so we don't.)  Thus we replace `some(Vars, Goal0)' with
	% an empty quantifier `some([], Goal)'.

implicitly_quantify_goal_2(some(Vars0, CanRemove, Goal0), Context,
		some([], CanRemove, Goal)) -->
	quantification__get_outside(OutsideVars),
	quantification__get_lambda_outside(LambdaOutsideVars),
	quantification__get_quant_vars(QuantVars),
		% Rename apart all the quantified
		% variables that occur outside this goal.
	{ set__list_to_set(Vars0, QVars) },
	{ set__intersect(OutsideVars, QVars, RenameVars1) },
	{ set__intersect(LambdaOutsideVars, QVars, RenameVars2) },
	{ set__union(RenameVars1, RenameVars2, RenameVars) },
	(
		{ set__empty(RenameVars) }
	->
		{ Goal1 = Goal0 },
		{ Vars = Vars0 }
	;
		quantification__warn_overlapping_scope(RenameVars, Context),
		quantification__rename_apart(RenameVars, RenameMap,
			Goal0, Goal1),
		{ goal_util__rename_var_list(Vars0, no, RenameMap, Vars) }
	),
	quantification__update_seen_vars(QVars),
	{ set__insert_list(QuantVars, Vars, QuantVars1) },
	quantification__set_quant_vars(QuantVars1),
	implicitly_quantify_goal(Goal1, Goal),
	quantification__get_nonlocals(NonLocals0),
	{ set__delete_list(NonLocals0, Vars, NonLocals) },
	quantification__set_quant_vars(QuantVars),
	quantification__set_nonlocals(NonLocals).

implicitly_quantify_goal_2(conj(List0), _, conj(List)) -->
	implicitly_quantify_conj(List0, List).

implicitly_quantify_goal_2(par_conj(List0, SM), _, par_conj(List, SM)) -->
	implicitly_quantify_conj(List0, List).

implicitly_quantify_goal_2(disj(Goals0, SM), _, disj(Goals, SM)) -->
	implicitly_quantify_disj(Goals0, Goals).

implicitly_quantify_goal_2(switch(Var, Det, Cases0, SM), _,
					switch(Var, Det, Cases, SM)) -->
	implicitly_quantify_cases(Cases0, Cases),
		% The switch variable is guaranteed to be non-local to the
		% switch, since it has to be bound elsewhere, so we put it
		% in the nonlocals here.
	quantification__get_nonlocals(NonLocals0),
	{ set__insert(NonLocals0, Var, NonLocals) },
	quantification__set_nonlocals(NonLocals).

implicitly_quantify_goal_2(not(Goal0), _, not(Goal)) -->
		% quantified variables cannot be pushed inside a negation,
		% so we insert the quantified vars into the outside vars set,
		% and initialize the new quantified vars set to be empty
		% (the lambda outside vars remain unchanged)
	quantification__get_quant_vars(QuantVars),
	quantification__get_outside(OutsideVars),
	{ set__union(OutsideVars, QuantVars, OutsideVars1) },
	{ set__init(QuantVars1) },
	quantification__set_quant_vars(QuantVars1),
	quantification__set_outside(OutsideVars1),
	implicitly_quantify_goal(Goal0, Goal),
	quantification__set_outside(OutsideVars),
	quantification__set_quant_vars(QuantVars).

implicitly_quantify_goal_2(if_then_else(Vars0, Cond0, Then0, Else0, SM),
			Context, if_then_else(Vars, Cond, Then, Else, SM)) -->
	quantification__get_quant_vars(QuantVars),
	quantification__get_outside(OutsideVars),
	quantification__get_lambda_outside(LambdaOutsideVars),
	{ set__list_to_set(Vars0, QVars) },
		% Rename apart those variables that
		% are quantified to the cond and then
		% of the i-t-e that occur outside the
		% i-t-e.
	{ set__intersect(OutsideVars, QVars, RenameVars1) },
	{ set__intersect(LambdaOutsideVars, QVars, RenameVars2) },
	{ set__union(RenameVars1, RenameVars2, RenameVars) },
	(
		{ set__empty(RenameVars) }
	->
		{ Cond1 = Cond0 },
		{ Then1 = Then0 },
		{ Vars = Vars0 }
	;
		quantification__warn_overlapping_scope(RenameVars, Context),
		quantification__rename_apart(RenameVars, RenameMap,
						Cond0, Cond1),
		{ goal_util__rename_vars_in_goal(Then0, RenameMap, Then1) },
		{ goal_util__rename_var_list(Vars0, no, RenameMap, Vars) }
	),
	{ set__insert_list(QuantVars, Vars, QuantVars1) },
	quantification__get_nonlocals_to_recompute(NonLocalsToRecompute),
	{ quantification__goal_vars(NonLocalsToRecompute,
		Then1, VarsThen, LambdaVarsThen) },
	{ set__union(OutsideVars, VarsThen, OutsideVars1) },
	{ set__union(LambdaOutsideVars, LambdaVarsThen, LambdaOutsideVars1) },
	quantification__set_quant_vars(QuantVars1),
	quantification__set_outside(OutsideVars1),
	quantification__set_lambda_outside(LambdaOutsideVars1),
	quantification__update_seen_vars(QVars),
	implicitly_quantify_goal(Cond1, Cond),
	quantification__get_nonlocals(NonLocalsCond),
	{ set__union(OutsideVars, NonLocalsCond, OutsideVars2) },
	quantification__set_outside(OutsideVars2),
	quantification__set_lambda_outside(LambdaOutsideVars),
	implicitly_quantify_goal(Then1, Then),
	quantification__get_nonlocals(NonLocalsThen),
	quantification__set_outside(OutsideVars),
	quantification__set_quant_vars(QuantVars),
	implicitly_quantify_goal(Else0, Else),
	quantification__get_nonlocals(NonLocalsElse),
	{ set__union(NonLocalsCond, NonLocalsThen, NonLocalsIfThen) },
	{ set__union(NonLocalsIfThen, NonLocalsElse, NonLocalsIfThenElse) },
	{ set__intersect(NonLocalsIfThenElse, OutsideVars, NonLocalsO) },
	{ set__intersect(NonLocalsIfThenElse, LambdaOutsideVars, NonLocalsL) },
	{ set__union(NonLocalsO, NonLocalsL, NonLocals) },
	quantification__set_nonlocals(NonLocals).

implicitly_quantify_goal_2(call(A, B, HeadVars, D, E, F), _,
		call(A, B, HeadVars, D, E, F)) -->
	implicitly_quantify_atomic_goal(HeadVars).

implicitly_quantify_goal_2(generic_call(GenericCall, ArgVars1, C, D), _,
		generic_call(GenericCall, ArgVars1, C, D)) -->
	{ goal_util__generic_call_vars(GenericCall, ArgVars0) },
	{ list__append(ArgVars0, ArgVars1, ArgVars) },
	implicitly_quantify_atomic_goal(ArgVars).

implicitly_quantify_goal_2(
		unify(Var, UnifyRHS0, Mode, Unification0, UnifyContext),
		Context,
		unify(Var, UnifyRHS, Mode, Unification, UnifyContext)) -->
	quantification__get_outside(OutsideVars),
	quantification__get_lambda_outside(LambdaOutsideVars),
	{ quantification__get_unify_typeinfos(Unification0, TypeInfoVars) },

	{ Unification0 = construct(_, _, _, _, CellToReuse0, _, _) ->
		CellToReuse = CellToReuse0
	;
		CellToReuse = no
	},

	implicitly_quantify_unify_rhs(UnifyRHS0, CellToReuse,
		Unification0, Context, UnifyRHS, Unification),
	quantification__get_nonlocals(VarsUnifyRHS),
	{ set__insert(VarsUnifyRHS, Var, GoalVars0) },
	{ set__insert_list(GoalVars0, TypeInfoVars, GoalVars1) },

	{ CellToReuse = yes(cell_to_reuse(ReuseVar, _, _)) ->
		set__insert(GoalVars1, ReuseVar, GoalVars)
	;
		GoalVars = GoalVars1
	},

	quantification__update_seen_vars(GoalVars),
	{ set__intersect(GoalVars, OutsideVars, NonLocalVars1) },
	{ set__intersect(GoalVars, LambdaOutsideVars, NonLocalVars2) },
	{ set__union(NonLocalVars1, NonLocalVars2, NonLocalVars) },
	quantification__set_nonlocals(NonLocalVars).

implicitly_quantify_goal_2(pragma_c_code(A,B,C,Vars,E,F,G), _,
		pragma_c_code(A,B,C,Vars,E,F,G)) --> 
	implicitly_quantify_atomic_goal(Vars).

implicitly_quantify_goal_2(bi_implication(LHS0, RHS0), Context, Goal) -->

		% get the initial values of various settings
	quantification__get_quant_vars(QuantVars0),
	quantification__get_outside(OutsideVars0),
	quantification__get_lambda_outside(LambdaOutsideVars0),

		% quantified variables cannot be pushed inside a negation,
		% so we insert the quantified vars into the outside vars set,
		% and initialize the new quantified vars set to be empty
		% (the lambda outside vars remain unchanged)
	{ set__union(OutsideVars0, QuantVars0, OutsideVars1) },
	{ set__init(QuantVars1) },
	{ LambdaOutsideVars1 = LambdaOutsideVars0 },
	quantification__set_quant_vars(QuantVars1),

		% prepare for quantifying the LHS:
		% add variables from the RHS to the outside vars
		% and the outside lambda vars sets.
	quantification__get_nonlocals_to_recompute(NonLocalsToRecompute),
	{ quantification__goal_vars(NonLocalsToRecompute,
			RHS0, RHS_Vars, RHS_LambdaVars) },
	{ set__union(OutsideVars1, RHS_Vars, LHS_OutsideVars) },
	{ set__union(LambdaOutsideVars1, RHS_LambdaVars,
			LHS_LambdaOutsideVars) },

		% quantify the LHS
	quantification__set_outside(LHS_OutsideVars),
	quantification__set_lambda_outside(LHS_LambdaOutsideVars),
	implicitly_quantify_goal(LHS0, LHS),
	quantification__get_nonlocals(LHS_NonLocalVars),

		% prepare for quantifying the RHS:
		% add nonlocals from the LHS to the outside vars.
		% (We use the nonlocals rather than the more symmetric
		% approach of calling quantification__goal_vars on the
		% LHS goal because it is more efficient.)
	{ set__union(OutsideVars1, LHS_NonLocalVars, RHS_OutsideVars) },
	{ RHS_LambdaOutsideVars = LambdaOutsideVars1 },

		% quantify the RHS
	quantification__set_outside(RHS_OutsideVars),
	quantification__set_lambda_outside(RHS_LambdaOutsideVars),
	implicitly_quantify_goal(RHS0, RHS),
	quantification__get_nonlocals(RHS_NonLocalVars),

		% compute the nonlocals for this goal
	{ set__union(LHS_NonLocalVars, RHS_NonLocalVars, AllNonLocalVars) },
	{ set__intersect(AllNonLocalVars, OutsideVars0, NonLocalVarsO) },
	{ set__intersect(AllNonLocalVars, LambdaOutsideVars0, NonLocalVarsL) },
	{ set__union(NonLocalVarsO, NonLocalVarsL, NonLocalVars) },
	quantification__set_nonlocals(NonLocalVars),

		% restore the original values of various settings
	quantification__set_outside(OutsideVars0),
	quantification__set_lambda_outside(LambdaOutsideVars0),
	quantification__set_quant_vars(QuantVars0),

		%
		% We've figured out the quantification.
		% Now expand the bi-implication according to the usual
		% rules:
		%	LHS <=> RHS
		% ===>
		%	(LHS => RHS), (RHS => LHS)
		% ===>
		%	(not (LHS, not RHS)), (not (RHS, not LHS))
		%
	{ goal_info_init(GoalInfo0) },
	{ goal_info_set_context(GoalInfo0, Context, GoalInfo1) },
	quantification__set_goal_nonlocals(GoalInfo1,
		LHS_NonLocalVars, LHS_GI),
	quantification__set_goal_nonlocals(GoalInfo1,
		RHS_NonLocalVars, RHS_GI),
	quantification__set_goal_nonlocals(GoalInfo1, NonLocalVars, GI),
	{ NotLHS = not(LHS) - LHS_GI },
	{ NotRHS = not(RHS) - RHS_GI },
	{ ForwardsImplication = not(conj([LHS, NotRHS]) - GI) - GI },

		%
		% Rename apart the local variables of the goals
		% we've just duplicated.
		%
	{ ReverseImplication0 = not(conj([RHS, NotLHS]) - GI) - GI },
	{ quantification__goal_vars(NonLocalsToRecompute,
		ReverseImplication0, GoalVars) },
	{ set__difference(GoalVars, NonLocalVars, RenameVars) },
	quantification__rename_apart(RenameVars, _,
		ReverseImplication0, ReverseImplication),

	{ Goal = conj([ForwardsImplication, ReverseImplication]) }.

:- pred implicitly_quantify_atomic_goal(list(prog_var), quant_info, quant_info).
:- mode implicitly_quantify_atomic_goal(in, in, out) is det.

implicitly_quantify_atomic_goal(HeadVars) -->
	{ set__list_to_set(HeadVars, GoalVars) },
	quantification__update_seen_vars(GoalVars),
	quantification__get_outside(OutsideVars),
	quantification__get_lambda_outside(LambdaOutsideVars),
	{ set__intersect(GoalVars, OutsideVars, NonLocals1) },
	{ set__intersect(GoalVars, LambdaOutsideVars, NonLocals2) },
	{ set__union(NonLocals1, NonLocals2, NonLocals) },
	quantification__set_nonlocals(NonLocals).

:- pred implicitly_quantify_unify_rhs(unify_rhs, maybe(cell_to_reuse),
		unification, prog_context, unify_rhs, unification,
		quant_info, quant_info).
:- mode implicitly_quantify_unify_rhs(in, in, in, in,
		out, out, in, out) is det.

implicitly_quantify_unify_rhs(var(X), _, Unification, _,
		var(X), Unification) -->
	{ set__singleton_set(Vars, X) },
	quantification__set_nonlocals(Vars).
implicitly_quantify_unify_rhs(functor(Functor, ArgVars), Reuse, Unification, _,
				functor(Functor, ArgVars), Unification) -->
	quantification__get_nonlocals_to_recompute(NonLocalsToRecompute),
	{
		NonLocalsToRecompute = code_gen_nonlocals,
		Reuse = yes(cell_to_reuse(_, _, SetArgs))
	->
		% The fields taken from the reused cell aren't
		% counted as code-gen nonlocals.
		quantification__get_updated_fields(SetArgs, ArgVars, Vars0),
		set__list_to_set(Vars0, Vars)
	;	
		set__list_to_set(ArgVars, Vars)
	},
	quantification__set_nonlocals(Vars).
implicitly_quantify_unify_rhs(
		lambda_goal(PredOrFunc, EvalMethod, FixModes, LambdaNonLocals0,
			LambdaVars0, Modes, Det, Goal0),
		_, Unification0,
		Context,
		lambda_goal(PredOrFunc, EvalMethod, FixModes, LambdaNonLocals,
			LambdaVars, Modes, Det, Goal),
		Unification
		) -->
	%
	% Note: make_hlds.m has already done most of the hard work
	% for lambda expressions.  At this point, LambdaVars0
	% should in fact be guaranteed to be fresh distinct
	% variables.  However, the code below does not assume this.
	%
	quantification__get_outside(OutsideVars0),
	{ set__list_to_set(LambdaVars0, QVars) },
		% Figure out which variables have overlapping scopes
		% because they occur outside the goal and are also
		% lambda-quantified vars.
	{ set__intersect(OutsideVars0, QVars, RenameVars0) },
	(
		{ set__empty(RenameVars0) }
	->
		[]
	;
		quantification__warn_overlapping_scope(RenameVars0, Context)
	),
		% We need to rename apart any of the lambda vars that
		% we have already seen, since they are new instances.
	quantification__get_seen(Seen0),
	{ set__intersect(Seen0, QVars, RenameVars1) },

	{ set__union(RenameVars0, RenameVars1, RenameVars) },
	quantification__rename_apart(RenameVars, RenameMap, Goal0, Goal1),
	{ goal_util__rename_var_list(LambdaVars0, no, RenameMap, LambdaVars) },

		% Quantified variables cannot be pushed inside a lambda goal,
		% so we insert the quantified vars into the outside vars set,
		% and initialize the new quantified vars set to be empty.
	quantification__get_quant_vars(QuantVars0),
	{ set__union(OutsideVars0, QuantVars0, OutsideVars1) },
	{ set__init(QuantVars) },
	quantification__set_quant_vars(QuantVars),
		% Add the lambda vars as outside vars, since they are
		% outside of the lambda goal
	{ set__insert_list(OutsideVars1, LambdaVars, OutsideVars) },
	quantification__set_outside(OutsideVars),
		% Set the LambdaOutsideVars set to empty, because
		% variables that occur outside this lambda expression
		% only in other lambda expressions should not be
		% considered non-local.
	quantification__get_lambda_outside(LambdaOutsideVars0),
	{ set__init(LambdaOutsideVars) },
	quantification__set_lambda_outside(LambdaOutsideVars),
	implicitly_quantify_goal(Goal1, Goal),

	quantification__get_nonlocals(NonLocals0),
		% lambda-quantified variables are local
	{ set__delete_list(NonLocals0, LambdaVars, NonLocals) },
	quantification__set_quant_vars(QuantVars0),
	quantification__set_outside(OutsideVars0),
	quantification__set_lambda_outside(LambdaOutsideVars0),
	quantification__set_nonlocals(NonLocals),

	%
	% Work out the list of non-local curried arguments to the lambda
	% expression. This set must only ever decrease, since the first
	% approximation that make_hlds uses includes all variables in the 
	% lambda expression except the quantified variables.
	%
	{ Goal = _ - LambdaGoalInfo },
	{ goal_info_get_nonlocals(LambdaGoalInfo, LambdaGoalNonLocals) },
	{ IsNonLocal = lambda([V::in] is semidet, (
			set__member(V, LambdaGoalNonLocals)
		)) },
	{ list__filter(IsNonLocal, LambdaNonLocals0, LambdaNonLocals) },

	%
	% For a unification that constructs a lambda expression,
	% the argument variables of the construction are the non-local
	% variables of the lambda expression.  So if we recompute the
	% non-locals, we need to recompute the argument variables of
	% the construction, and hence we also need to recompute their modes.
	% The non-locals set must only ever decrease, not increase,
	% so we can just use the old modes.
	%
	{
		Unification0 = construct(ConstructVar, ConsId, Args0,
			ArgModes0, Reuse, Uniq, AditiInfo)
	->
		map__from_corresponding_lists(Args0, ArgModes0, ArgModesMap),
		set__to_sorted_list(NonLocals, Args),
		map__apply_to_list(Args, ArgModesMap, ArgModes),
		Unification = construct(ConstructVar, ConsId, Args,
			ArgModes, Reuse, Uniq, AditiInfo)
	;
		% after mode analysis, unifications with lambda variables
		% should always be construction unifications, but
		% quantification gets invoked before mode analysis,
		% so we need to allow this case...
		Unification = Unification0
	}.

:- pred implicitly_quantify_conj(list(hlds_goal), list(hlds_goal), 
					quant_info, quant_info).
:- mode implicitly_quantify_conj(in, out, in, out) is det.

implicitly_quantify_conj(Goals0, Goals) -->
	quantification__get_nonlocals_to_recompute(NonLocalsToRecompute),
	{ get_vars(NonLocalsToRecompute, Goals0, FollowingVarsList) },
	implicitly_quantify_conj_2(Goals0, FollowingVarsList, Goals).

:- pred implicitly_quantify_conj_2(list(hlds_goal), list(pair(set(prog_var))),
			list(hlds_goal), quant_info, quant_info).
:- mode implicitly_quantify_conj_2(in, in, out, in, out) is det.

implicitly_quantify_conj_2([], _, []) -->
	{ set__init(NonLocalVars) },
	quantification__set_nonlocals(NonLocalVars).
implicitly_quantify_conj_2([_|_], [], _, _, _) :-
	error("implicitly_quantify_conj_2: length mismatch").
implicitly_quantify_conj_2([Goal0 | Goals0],
		[FollowingVars - LambdaFollowingVars | FollowingVarsList],
			[Goal | Goals]) -->
	quantification__get_outside(OutsideVars),
	quantification__get_lambda_outside(LambdaOutsideVars),
	{ set__union(OutsideVars, FollowingVars, OutsideVars1) },
	{ set__union(LambdaOutsideVars, LambdaFollowingVars,
			LambdaOutsideVars1) },
	quantification__set_outside(OutsideVars1),
	quantification__set_lambda_outside(LambdaOutsideVars1),
	implicitly_quantify_goal(Goal0, Goal),
	quantification__get_nonlocals(NonLocalVars1),
	{ set__union(OutsideVars, NonLocalVars1, OutsideVars2) },
	quantification__set_outside(OutsideVars2),
	quantification__set_lambda_outside(LambdaOutsideVars),
	implicitly_quantify_conj_2(Goals0, FollowingVarsList,
				Goals),
	quantification__get_nonlocals(NonLocalVars2),
	{ set__union(NonLocalVars1, NonLocalVars2, NonLocalVarsConj) },
	{ set__intersect(NonLocalVarsConj, OutsideVars, NonLocalVarsO) },
	{ set__intersect(NonLocalVarsConj, LambdaOutsideVars, NonLocalVarsL) },
	{ set__union(NonLocalVarsO, NonLocalVarsL, NonLocalVars) },
	quantification__set_outside(OutsideVars),
	quantification__set_nonlocals(NonLocalVars).

:- pred implicitly_quantify_disj(list(hlds_goal), list(hlds_goal), 
					quant_info, quant_info).
:- mode implicitly_quantify_disj(in, out, in, out) is det.

implicitly_quantify_disj([], []) -->
	{ set__init(NonLocalVars) },
	quantification__set_nonlocals(NonLocalVars).
implicitly_quantify_disj([Goal0 | Goals0], [Goal | Goals]) -->
	implicitly_quantify_goal(Goal0, Goal),
	quantification__get_nonlocals(NonLocalVars0),
	implicitly_quantify_disj(Goals0, Goals),
	quantification__get_nonlocals(NonLocalVars1),
	{ set__union(NonLocalVars0, NonLocalVars1, NonLocalVars) },
	quantification__set_nonlocals(NonLocalVars).

:- pred implicitly_quantify_cases(list(case), list(case),
					quant_info, quant_info).
:- mode implicitly_quantify_cases(in, out, in, out) is det.

implicitly_quantify_cases([], []) -->
	{ set__init(NonLocalVars) },
	quantification__set_nonlocals(NonLocalVars).
implicitly_quantify_cases([case(Cons, Goal0) | Cases0],
				[case(Cons, Goal) | Cases]) -->
	implicitly_quantify_goal(Goal0, Goal),
	quantification__get_nonlocals(NonLocalVars0),
	implicitly_quantify_cases(Cases0, Cases),
	quantification__get_nonlocals(NonLocalVars1),
	{ set__union(NonLocalVars0, NonLocalVars1, NonLocalVars) },
	quantification__set_nonlocals(NonLocalVars).

%-----------------------------------------------------------------------------%

	% insert the given set of variables into the set of `seen' variables.

:- pred quantification__update_seen_vars(set(prog_var), quant_info, quant_info).
:- mode quantification__update_seen_vars(in, in, out) is det.

quantification__update_seen_vars(NewVars) -->
	quantification__get_seen(SeenVars0),
	{ set__union(SeenVars0, NewVars, SeenVars) },
	quantification__set_seen(SeenVars).

%-----------------------------------------------------------------------------%

	% Given a list of goals, produce a corresponding list of
	% following variables, where the following variables
	% for each goal are those variables which occur free in any of the
	% following goals in the list.  The following variables
	% are divided into a pair of sets: the first set
	% contains following variables that occur not in lambda goals,
	% and the second contains following variables that
	% occur in lambda goals.

:- pred get_vars(nonlocals_to_recompute, list(hlds_goal),
		list(pair(set(prog_var)))).
:- mode get_vars(in, in, out) is det.

get_vars(_, [], []).
get_vars(NonLocalsToRecompute, [_Goal | Goals],
		[Set - LambdaSet | SetPairs]) :-
	get_vars_2(NonLocalsToRecompute, Goals, Set, LambdaSet, SetPairs).

:- pred get_vars_2(nonlocals_to_recompute, list(hlds_goal),
		set(prog_var), set(prog_var), list(pair(set(prog_var)))).
:- mode get_vars_2(in, in, out, out, out) is det.

get_vars_2(_, [], Set, LambdaSet, []) :-
	set__init(Set),
	set__init(LambdaSet).
get_vars_2(NonLocalsToRecompute, [Goal | Goals],
		Set, LambdaSet, SetPairList) :-
	get_vars_2(NonLocalsToRecompute, Goals,
		Set0, LambdaSet0, SetPairList0),
	quantification__goal_vars(NonLocalsToRecompute,
		Goal, Set1, LambdaSet1),
	set__union(Set0, Set1, Set),
	set__union(LambdaSet0, LambdaSet1, LambdaSet),
	SetPairList = [Set0 - LambdaSet0 | SetPairList0].

:- pred goal_list_vars_2(nonlocals_to_recompute, list(hlds_goal),
		set(prog_var), set(prog_var), set(prog_var), set(prog_var)).
:- mode goal_list_vars_2(in, in, in, in, out, out) is det.

goal_list_vars_2(_, [], Set, LambdaSet, Set, LambdaSet).
goal_list_vars_2(NonLocalsToRecompute, [Goal - _GoalInfo| Goals],
		Set0, LambdaSet0, Set, LambdaSet) :-
	quantification__goal_vars_2(NonLocalsToRecompute,
		Goal, Set0, LambdaSet0, Set1, LambdaSet1),
	goal_list_vars_2(NonLocalsToRecompute, Goals,
		Set1, LambdaSet1, Set, LambdaSet).

:- pred case_list_vars_2(nonlocals_to_recompute, list(case),
		set(prog_var), set(prog_var), set(prog_var), set(prog_var)).
:- mode case_list_vars_2(in, in, in, in, out, out) is det.

case_list_vars_2(_, [], Set, LambdaSet, Set, LambdaSet).
case_list_vars_2(NonLocalsToRecompute,
		[case(_Cons, Goal - _GoalInfo)| Cases], Set0,
		LambdaSet0, Set, LambdaSet) :-
	quantification__goal_vars_2(NonLocalsToRecompute,
		Goal, Set0, LambdaSet0, Set1, LambdaSet1),
	case_list_vars_2(NonLocalsToRecompute, Cases,
		Set1, LambdaSet1, Set, LambdaSet).

	% quantification__goal_vars(NonLocalsToRecompute, Goal, Vars):
	%	Vars is the set of variables that occur free (unquantified)
	%	in Goal, excluding unset fields of reconstructions if
	%	NonLocalsToRecompute is `code_gen_nonlocals'.
quantification__goal_vars(NonLocalsToRecompute, Goal, BothSet) :-
	quantification__goal_vars(NonLocalsToRecompute,
		Goal, NonLambdaSet, LambdaSet),
	set__union(NonLambdaSet, LambdaSet, BothSet).

quantification__goal_vars(Goal, BothSet) :-
	quantification__goal_vars(ordinary_nonlocals, Goal, BothSet).

	% quantification__goal_vars(Goal, NonLambdaSet, LambdaSet):
	%	Set is the set of variables that occur free (unquantified)
	%	in Goal, not counting occurrences in lambda expressions.
	%	LambdaSet is the set of variables that occur free (unquantified)
	%	in lambda expressions in Goal.
:- pred quantification__goal_vars(nonlocals_to_recompute,
		hlds_goal, set(prog_var), set(prog_var)).
:- mode quantification__goal_vars(in, in, out, out) is det.

quantification__goal_vars(NonLocalsToRecompute,
		Goal - _GoalInfo, Set, LambdaSet) :-
	set__init(Set0),
	set__init(LambdaSet0),
	quantification__goal_vars_2(NonLocalsToRecompute,
		Goal, Set0, LambdaSet0, Set, LambdaSet).

:- pred quantification__goal_vars_2(nonlocals_to_recompute, hlds_goal_expr,
		set(prog_var), set(prog_var), set(prog_var), set(prog_var)).
:- mode quantification__goal_vars_2(in, in, in, in, out, out) is det.

quantification__goal_vars_2(NonLocalsToRecompute,
		unify(A, B, _, Unification, _), Set0, LambdaSet0,
		Set, LambdaSet) :-
	set__insert(Set0, A, Set1),
	( Unification = construct(_, _, _, _, Reuse0, _, _) ->
		Reuse = Reuse0
	;
		Reuse = no
	),
	(
		Reuse = yes(cell_to_reuse(ReuseVar, _, _))
	->
		set__insert(Set1, ReuseVar, Set2)
	;
		Unification = complicated_unify(_, _, TypeInfoVars)
	->
		set__insert_list(Set1, TypeInfoVars, Set2)
	;
		Set2 = Set1
	),
	quantification__unify_rhs_vars(NonLocalsToRecompute, B, Reuse,
		Set2, LambdaSet0, Set, LambdaSet).

quantification__goal_vars_2(_, generic_call(GenericCall, ArgVars1, _, _),
		Set0, LambdaSet, Set, LambdaSet) :-
	goal_util__generic_call_vars(GenericCall, ArgVars0),
	set__insert_list(Set0, ArgVars0, Set1),
	set__insert_list(Set1, ArgVars1, Set).

quantification__goal_vars_2(_, call(_, _, ArgVars, _, _, _), Set0, LambdaSet,
		Set, LambdaSet) :-
	set__insert_list(Set0, ArgVars, Set).

quantification__goal_vars_2(NonLocalsToRecompute, conj(Goals),
		Set0, LambdaSet0, Set, LambdaSet) :-
	goal_list_vars_2(NonLocalsToRecompute, Goals,
		Set0, LambdaSet0, Set, LambdaSet).

quantification__goal_vars_2(NonLocalsToRecompute, par_conj(Goals, _SM),
		Set0, LambdaSet0, Set, LambdaSet) :-
	goal_list_vars_2(NonLocalsToRecompute, Goals,
		Set0, LambdaSet0, Set, LambdaSet).

quantification__goal_vars_2(NonLocalsToRecompute, disj(Goals, _),
		Set0, LambdaSet0, Set, LambdaSet) :-
	goal_list_vars_2(NonLocalsToRecompute, Goals, Set0, LambdaSet0,
		Set, LambdaSet).

quantification__goal_vars_2(NonLocalsToRecompute, switch(Var, _Det, Cases, _),
		Set0, LambdaSet0, Set, LambdaSet) :-
	set__insert(Set0, Var, Set1),
	case_list_vars_2(NonLocalsToRecompute, Cases,
		Set1, LambdaSet0, Set, LambdaSet).

quantification__goal_vars_2(NonLocalsToRecompute, some(Vars, _, Goal),
		Set0, LambdaSet0, Set, LambdaSet) :-
	quantification__goal_vars(NonLocalsToRecompute,
		Goal, Set1, LambdaSet1),
	set__delete_list(Set1, Vars, Set2),
	set__delete_list(LambdaSet1, Vars, LambdaSet2),
	set__union(Set0, Set2, Set),
	set__union(LambdaSet0, LambdaSet2, LambdaSet).

quantification__goal_vars_2(NonLocalsToRecompute, not(Goal - _GoalInfo),
		Set0, LambdaSet0, Set, LambdaSet) :-
	quantification__goal_vars_2(NonLocalsToRecompute, Goal,
		Set0, LambdaSet0, Set, LambdaSet).

quantification__goal_vars_2(NonLocalsToRecompute,
		if_then_else(Vars, A, B, C, _),
		Set0, LambdaSet0, Set, LambdaSet) :-
	% This code does the following:
	%     Set = Set0 + ( (vars(A) + vars(B)) \ Vars ) + vars(C)
	% where `+' is set union and `\' is relative complement.
	quantification__goal_vars(NonLocalsToRecompute, A, Set1, LambdaSet1),
	quantification__goal_vars(NonLocalsToRecompute, B, Set2, LambdaSet2),
	set__union(Set1, Set2, Set3),
	set__union(LambdaSet1, LambdaSet2, LambdaSet3),
	set__delete_list(Set3, Vars, Set4),
	set__delete_list(LambdaSet3, Vars, LambdaSet4),
	set__union(Set0, Set4, Set5),
	set__union(LambdaSet0, LambdaSet4, LambdaSet5),
	quantification__goal_vars(NonLocalsToRecompute, C, Set6, LambdaSet6),
	set__union(Set5, Set6, Set),
	set__union(LambdaSet5, LambdaSet6, LambdaSet).

quantification__goal_vars_2(_, pragma_c_code(_, _, _, ArgVars, _, _, _),
		Set0, LambdaSet, Set, LambdaSet) :-
	set__insert_list(Set0, ArgVars, Set).

quantification__goal_vars_2(NonLocalsToRecompute, bi_implication(LHS, RHS),
		Set0, LambdaSet0, Set, LambdaSet) :-
	goal_list_vars_2(NonLocalsToRecompute, [LHS, RHS],
		Set0, LambdaSet0, Set, LambdaSet).

:- pred quantification__unify_rhs_vars(nonlocals_to_recompute, unify_rhs,
		maybe(cell_to_reuse), set(prog_var), set(prog_var),
		set(prog_var), set(prog_var)).
:- mode quantification__unify_rhs_vars(in, in, in, in, in, out, out) is det.

quantification__unify_rhs_vars(_, var(X), _,
		Set0, LambdaSet, Set, LambdaSet) :-
	set__insert(Set0, X, Set).
quantification__unify_rhs_vars(NonLocalsToRecompute,
		functor(_Functor, ArgVars), Reuse,
		Set0, LambdaSet, Set, LambdaSet) :-
	(
		NonLocalsToRecompute = code_gen_nonlocals,
		Reuse = yes(cell_to_reuse(_, _, SetArgs))
	->
		% Ignore the fields taken from the reused cell.
		quantification__get_updated_fields(SetArgs, ArgVars,
			ArgsToSet),
		set__insert_list(Set0, ArgsToSet, Set)
	;
		set__insert_list(Set0, ArgVars, Set)
	).
quantification__unify_rhs_vars(NonLocalsToRecompute,
		lambda_goal(_POrF, _E, _F, _N, LambdaVars, _M, _D, Goal), 
		_, Set, LambdaSet0, Set, LambdaSet) :-
	% Note that the NonLocals list is not counted, since all the 
	% variables in that list must occur in the goal.
	quantification__goal_vars(NonLocalsToRecompute, Goal, GoalVars),
	set__delete_list(GoalVars, LambdaVars, GoalVars1),
	set__union(LambdaSet0, GoalVars1, LambdaSet).

:- pred quantification__insert_set_fields(list(bool), list(prog_var),
		set(prog_var), set(prog_var)).
:- mode quantification__insert_set_fields(in, in, in, out) is det.

quantification__insert_set_fields(SetArgs, Args, Set0, Set) :-
	quantification__get_updated_fields(SetArgs, Args,  ArgsToSet),
	set__insert_list(Set0, ArgsToSet, Set).

:- pred quantification__get_updated_fields(list(bool),
		list(prog_var), list(prog_var)).
:- mode quantification__get_updated_fields(in, in, out) is det.

quantification__get_updated_fields(SetArgs, Args, ArgsToSet) :-
	quantification__get_updated_fields(SetArgs, Args, [], ArgsToSet).

:- pred quantification__get_updated_fields(list(bool),
		list(prog_var), list(prog_var), list(prog_var)).
:- mode quantification__get_updated_fields(in, in, in, out) is det.

quantification__get_updated_fields([], [], Fields, Fields).
quantification__get_updated_fields([], [_|_], _, _) :-
	error("quantification__get_updated_fields").
quantification__get_updated_fields([_|_], [], _, _) :-
	error("quantification__get_updated_fields").
quantification__get_updated_fields([SetArg | SetArgs], [Arg | Args],
		ArgsToSet0, ArgsToSet) :-
	(
		SetArg = yes,
		ArgsToSet1 = [Arg | ArgsToSet0]
	;
		SetArg = no,
		ArgsToSet1 = ArgsToSet0
	),
	quantification__get_updated_fields(SetArgs, Args,
		ArgsToSet1, ArgsToSet).

:- pred quantification__get_unify_typeinfos(unification, list(prog_var)).
:- mode quantification__get_unify_typeinfos(in, out) is det.

quantification__get_unify_typeinfos(Unification, TypeInfoVars) :-
	( Unification = complicated_unify(_, _, TypeInfoVars0) ->
		TypeInfoVars = TypeInfoVars0
	;
		TypeInfoVars = []
	).

%-----------------------------------------------------------------------------%

:- pred quantification__warn_overlapping_scope(set(prog_var), prog_context,
					quant_info, quant_info).
:- mode quantification__warn_overlapping_scope(in, in, in, out) is det.

quantification__warn_overlapping_scope(OverlapVars, Context) -->
	{ set__to_sorted_list(OverlapVars, Vars) },
	quantification__get_warnings(Warnings0),
	{ Warnings = [warn_overlap(Vars, Context) | Warnings0] },
	quantification__set_warnings(Warnings).

%-----------------------------------------------------------------------------%

% quantification__rename_apart(RenameSet, RenameMap, Goal0, Goal):
%	For each variable V in RenameSet, create a fresh variable V',
%	and insert the mapping V->V' into RenameMap.
%	Apply RenameMap to Goal0 giving Goal.

:- pred quantification__rename_apart(set(prog_var), map(prog_var, prog_var),
				hlds_goal, hlds_goal, quant_info, quant_info).
:- mode quantification__rename_apart(in, out, in, out, in, out) is det.

quantification__rename_apart(RenameSet, RenameMap, Goal0, Goal) -->
	quantification__get_nonlocals_to_recompute(NonLocalsToRecompute),
	( 
		%
		% Don't rename apart variables when recomputing the
		% code-gen nonlocals -- that would stuff up the
		% ordinary non-locals and the mode information.
		% The ordinary non-locals are always recomputed
		% before the code-gen nonlocals -- any necessary
		% renaming will have been done while recomputing
		% the ordinary non-locals.
		%
		{ set__empty(RenameSet)
		; NonLocalsToRecompute = code_gen_nonlocals
		}
	->
		{ map__init(RenameMap) },
		{ Goal = Goal0 }
	;
		{ set__to_sorted_list(RenameSet, RenameList) },
		quantification__get_varset(Varset0),
		quantification__get_vartypes(VarTypes0),
		{ map__init(RenameMap0) },
		{ goal_util__create_variables(RenameList,
			Varset0, VarTypes0, RenameMap0, VarTypes0, Varset0,
				% ^ Accumulator		^ Reference ^Var names
			Varset, VarTypes, RenameMap) },
		{ goal_util__rename_vars_in_goal(Goal0, RenameMap, Goal) },
		quantification__set_varset(Varset),
		quantification__set_vartypes(VarTypes)
/****
		We don't need to add the newly created vars to the seen vars
		because we won't find them anywhere else in the enclosing goal.
		This is a performance improvement because it keeps the size of
		the seen var set down.
		quantification__get_seen(SeenVars0),
		{ map__values(RenameMap, NewVarsList) },
		{ set__insert_list(SeenVars0, NewVarsList, SeenVars) },
		quantification__set_seen(SeenVars).
****/
	).

%-----------------------------------------------------------------------------%

:- pred quantification__set_goal_nonlocals(hlds_goal_info,
		set(prog_var), hlds_goal_info, quant_info, quant_info).
:- mode quantification__set_goal_nonlocals(in, in, out, in, out) is det.

quantification__set_goal_nonlocals(GoalInfo0, NonLocals, GoalInfo) -->
	quantification__get_nonlocals_to_recompute(NonLocalsToRecompute),
	{
		NonLocalsToRecompute = ordinary_nonlocals,
		goal_info_set_nonlocals(GoalInfo0, NonLocals, GoalInfo)
	;
		NonLocalsToRecompute = code_gen_nonlocals,
		goal_info_set_code_gen_nonlocals(GoalInfo0,
			NonLocals, GoalInfo)
	}.

%-----------------------------------------------------------------------------%

%-----------------------------------------------------------------------------%

:- pred quantification__init(nonlocals_to_recompute, set(prog_var),
		prog_varset, map(prog_var, type), quant_info).
:- mode quantification__init(in, in, in, in, out) is det.

quantification__init(RecomputeNonLocals, OutsideVars,
		Varset, VarTypes, QuantInfo) :-
	set__init(QuantVars),
	set__init(NonLocals),
	set__init(LambdaOutsideVars),
	Seen = OutsideVars,
	OverlapWarnings = [],
	QuantInfo = quant_info(RecomputeNonLocals, OutsideVars, QuantVars,
		LambdaOutsideVars, NonLocals, Seen, Varset, VarTypes,
		OverlapWarnings).

:- pred quantification__get_nonlocals_to_recompute(nonlocals_to_recompute,
		quant_info, quant_info).
:- mode quantification__get_nonlocals_to_recompute(out, in, out) is det.

quantification__get_nonlocals_to_recompute(Q ^ nonlocals_to_recompute, Q, Q).

:- pred quantification__get_outside(set(prog_var), quant_info, quant_info).
:- mode quantification__get_outside(out, in, out) is det.

quantification__get_outside(Q ^ outside, Q, Q).

:- pred quantification__set_outside(set(prog_var), quant_info, quant_info).
:- mode quantification__set_outside(in, in, out) is det.

quantification__set_outside(Outside, Q0, Q0 ^ outside := Outside).

:- pred quantification__get_quant_vars(set(prog_var), quant_info, quant_info).
:- mode quantification__get_quant_vars(out, in, out) is det.

quantification__get_quant_vars(Q ^ quant_vars, Q, Q).

:- pred quantification__set_quant_vars(set(prog_var), quant_info, quant_info).
:- mode quantification__set_quant_vars(in, in, out) is det.

quantification__set_quant_vars(QuantVars, Q0, Q0 ^ quant_vars := QuantVars).

:- pred quantification__get_lambda_outside(set(prog_var),
		quant_info, quant_info).
:- mode quantification__get_lambda_outside(out, in, out) is det.

quantification__get_lambda_outside(Q ^ lambda_outside, Q, Q).

:- pred quantification__set_lambda_outside(set(prog_var),
		quant_info, quant_info).
:- mode quantification__set_lambda_outside(in, in, out) is det.

quantification__set_lambda_outside(LambdaOutsideVars, Q0,
		Q0 ^ lambda_outside := LambdaOutsideVars).

:- pred quantification__get_nonlocals(set(prog_var), quant_info, quant_info).
:- mode quantification__get_nonlocals(out, in, out) is det.

quantification__get_nonlocals(Q ^ nonlocals, Q, Q).

:- pred quantification__set_nonlocals(set(prog_var), quant_info, quant_info).
:- mode quantification__set_nonlocals(in, in, out) is det.

quantification__set_nonlocals(NonLocals, Q0, Q0 ^ nonlocals := NonLocals).

:- pred quantification__get_seen(set(prog_var), quant_info, quant_info).
:- mode quantification__get_seen(out, in, out) is det.

quantification__get_seen(Q ^ seen, Q, Q).

:- pred quantification__set_seen(set(prog_var), quant_info, quant_info).
:- mode quantification__set_seen(in, in, out) is det.

quantification__set_seen(Seen, Q0, Q0 ^ seen := Seen).

:- pred quantification__get_varset(prog_varset, quant_info, quant_info).
:- mode quantification__get_varset(out, in, out) is det.

quantification__get_varset(Q ^ varset, Q, Q).

:- pred quantification__set_varset(prog_varset, quant_info, quant_info).
:- mode quantification__set_varset(in, in, out) is det.

quantification__set_varset(Varset, Q0, Q0 ^ varset := Varset).

:- pred quantification__get_vartypes(map(prog_var, type),
		quant_info, quant_info).
:- mode quantification__get_vartypes(out, in, out) is det.

quantification__get_vartypes(Q ^ vartypes, Q, Q).

:- pred quantification__set_vartypes(map(prog_var, type),
		quant_info, quant_info).
:- mode quantification__set_vartypes(in, in, out) is det.

quantification__set_vartypes(VarTypes, Q0, Q0 ^ vartypes := VarTypes).

:- pred quantification__get_warnings(list(quant_warning),
					quant_info, quant_info).
:- mode quantification__get_warnings(out, in, out) is det.

quantification__get_warnings(Q ^ warnings, Q, Q).

:- pred quantification__set_warnings(list(quant_warning),
					quant_info, quant_info).
:- mode quantification__set_warnings(in, in, out) is det.

quantification__set_warnings(Warnings, Q0, Q0 ^ warnings := Warnings).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%
