%-----------------------------------------------------------------------------%
% Copyright (C) 2002, 2004-2005 The University of Melbourne.
% This file may only be copied under the terms of the GNU Library General
% Public License - see the file COPYING.LIB in the Mercury distribution.
%-----------------------------------------------------------------------------%
%
% File: io_action.m
% Author: zs.
%
% This module defines the representation of I/O actions used by the
% declarative debugger.

%-----------------------------------------------------------------------------%

:- module mdb.io_action.

:- interface.

:- import_module mdb.browser_term.
:- import_module mdbcomp.prim_data.

:- import_module list, map, std_util, io.

:- type io_action
	--->	io_action(
			io_action_proc_name	:: string,
			io_action_pf		:: pred_or_func,
			io_action_args		:: list(univ)
		).

:- type maybe_tabled_io_action
	--->	tabled(io_action)
	;	untabled(io_seq_num).

:- type io_seq_num	== int.
:- type io_action_map	== map(io_seq_num, io_action).

:- pred make_io_action_map(int::in, int::in, io_action_map::out,
	io__state::di, io__state::uo) is det.

:- func io_action_to_browser_term(io_action) = browser_term.

:- implementation.

:- import_module bool.
:- import_module int.
:- import_module require.
:- import_module svmap.

io_action_to_browser_term(IoAction) = Term :-
	IoAction = io_action(ProcName, PredFunc, Args),
	(
		PredFunc = predicate,
		IsFunc = no
	;
		PredFunc = function,
		IsFunc = yes
	),
	Term = synthetic_term_to_browser_term(ProcName, Args, IsFunc).

make_io_action_map(Start, End, IoActionMap) -->
	make_io_action_map_2(Start, End, map__init, IoActionMap).

:- pred make_io_action_map_2(int::in, int::in,
	io_action_map::in, io_action_map::out, io__state::di, io__state::uo)
	is det.

make_io_action_map_2(Cur, End, !IoActionMap, !IO) :-
	( Cur = End ->
		true
	;
		pickup_io_action(Cur, MaybeIoAction, !IO),
		(
			MaybeIoAction = yes(IoAction),
			svmap.det_insert(Cur, IoAction, !IoActionMap)
		;
			MaybeIoAction = no
		),
		make_io_action_map_2(Cur + 1, End, !IoActionMap, !IO)
	).

:- pred pickup_io_action(int::in, maybe(io_action)::out,
	io__state::di, io__state::uo) is det.

:- pragma foreign_proc("C",
	pickup_io_action(SeqNum::in, MaybeIOAction::out, S0::di, S::uo),
	[thread_safe, promise_pure, tabled_for_io],
"{
	const char	*problem;
	const char	*proc_name;
	MR_bool		is_func;
	MR_Word		args;
	MR_bool		io_action_tabled;
	MR_String	ProcName;

	MR_save_transient_hp();
	io_action_tabled = MR_trace_get_action(SeqNum, &proc_name, 
		&is_func, &args);
	MR_restore_transient_hp();

	/* cast away const */
	ProcName = (MR_String) (MR_Integer) proc_name;
	if (io_action_tabled) {
		MaybeIOAction = MR_IO_ACTION_make_yes_io_action(
			ProcName, is_func, args);
	} else {
		MaybeIOAction = MR_IO_ACTION_make_no_io_action();
	}

	S = S0;
}").

:- func make_no_io_action = maybe(io_action).
:- pragma export(make_no_io_action = out, "MR_IO_ACTION_make_no_io_action").

make_no_io_action = no.

:- func make_yes_io_action(string, bool, list(univ)) = maybe(io_action).
:- pragma export(make_yes_io_action(in, in, in) = out, 
	"MR_IO_ACTION_make_yes_io_action").
	
make_yes_io_action(ProcName, yes, Args) = 
	yes(io_action(ProcName, function, Args)).
make_yes_io_action(ProcName, no, Args) = 
	yes(io_action(ProcName, predicate, Args)).

pickup_io_action(_, _, _, _) :-
	private_builtin__sorry("pickup_io_action").
