%-----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%-----------------------------------------------------------------------------%
% Copyright (C) 2006-2011 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%
%
% File: mdprof_feedback.m.
% Author: tannier, pbone.
%
% This module contains the code for writing to a file the CSSs whose CSD's
% mean/median call sequence counts (own and desc) exceed the given threshold.
%
% The generated file will then be used by the compiler for
% implicit parallelism.
%
%-----------------------------------------------------------------------------%

:- module mdprof_feedback.
:- interface.

:- import_module io.

%-----------------------------------------------------------------------------%

:- pred main(io::di, io::uo) is det.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- import_module conf.
:- import_module mdbcomp.
:- import_module mdbcomp.feedback.
:- import_module mdbcomp.feedback.automatic_parallelism.
:- import_module mdprof_fb.
:- import_module mdprof_fb.automatic_parallelism.
:- import_module mdprof_fb.automatic_parallelism.autopar_search_callgraph.
:- import_module message.
:- import_module profile.
:- import_module startup.

:- import_module bool.
:- import_module char.
:- import_module cord.
:- import_module float.
:- import_module getopt.
:- import_module int.
:- import_module library.
:- import_module list.
:- import_module map.
:- import_module maybe.
:- import_module parsing_utils.
:- import_module require.
:- import_module string.
:- import_module svmap.

%-----------------------------------------------------------------------------%
%
% This section contains the main predicate as well as code to read the deep
% profiling data and display usage and version messages to the user.
%

main(!IO) :-
    io.progname_base("mdprof_feedback", ProgName, !IO),
    io.command_line_arguments(Args0, !IO),
    io.stderr_stream(Stderr, !IO),
    getopt.process_options(option_ops_multi(short, long, defaults),
        Args0, Args, MaybeOptions),
    (
        MaybeOptions = ok(Options),
        lookup_bool_option(Options, help, Help),
        lookup_bool_option(Options, version, Version),
        lookup_bool_option(Options, debug_read_profile, DebugReadProfile),
        lookup_bool_option(Options, report, Report),
        (
            Version = yes
        ->
            write_version_message(ProgName, !IO)
        ;
            Help = yes
        ->
            write_help_message(ProgName, !IO)
        ;
            Args = [OutputFileName]
        ->
            feedback.read_feedback_file(OutputFileName, FeedbackReadResult,
                !IO),
            (
                FeedbackReadResult = ok(Feedback),
                ProfileProgName = get_feedback_program_name(Feedback),
                print_feedback_report(ProfileProgName, Feedback, !IO)
            ;
                FeedbackReadResult = error(FeedbackReadError),
                feedback.read_error_message_string(OutputFileName,
                    FeedbackReadError, Message),
                io.write_string(Stderr, Message, !IO),
                io.set_exit_status(1, !IO)
            )
        ;
            Args = [InputFileName, OutputFileName],
            check_options(Options, RequestedFeedbackInfo),
            check_verbosity_option(Options, VerbosityLevel)
        ->
            read_deep_file(InputFileName, DebugReadProfile, MaybeDeep, !IO),
            (
                MaybeDeep = ok(Deep),
                ProfileProgName = Deep ^ profile_stats ^ prs_program_name,
                feedback.read_or_create(OutputFileName, ProfileProgName,
                    FeedbackReadResult, !IO),
                (
                    FeedbackReadResult = ok(Feedback0),
                    process_deep_to_feedback(RequestedFeedbackInfo,
                        Deep, Messages, Feedback0, Feedback),
                    (
                        Report = yes,
                        print_feedback_report(ProfileProgName, Feedback, !IO)
                    ;
                        Report = no
                    ),
                    write_feedback_file(OutputFileName, ProfileProgName,
                        Feedback, WriteResult, !IO),
                    (
                        WriteResult = ok
                    ;
                        ( WriteResult = open_error(Error)
                        ; WriteResult = write_error(Error)
                        ),
                        io.error_message(Error, ErrorMessage),
                        io.format(Stderr, "%s: %s\n",
                            [s(OutputFileName), s(ErrorMessage)], !IO),
                        io.set_exit_status(1, !IO)
                    ),
                    set_verbosity_level(VerbosityLevel, !IO),
                    write_out_messages(Stderr, Messages, !IO)
                ;
                    FeedbackReadResult = error(FeedbackReadError),
                    feedback.read_error_message_string(OutputFileName,
                        FeedbackReadError, Message),
                    io.write_string(Stderr, Message, !IO),
                    io.set_exit_status(1, !IO)
                )
            ;
                MaybeDeep = error(Error),
                io.set_exit_status(1, !IO),
                io.format(Stderr, "%s: error reading %s: %s\n",
                    [s(ProgName), s(InputFileName), s(Error)], !IO)
            )
        ;
            io.set_exit_status(1, !IO),
            write_help_message(ProgName, !IO)
        )
    ;
        MaybeOptions = error(Msg),
        io.set_exit_status(1, !IO),
        io.format(Stderr, "%s: error parsing options: %s\n",
            [s(ProgName), s(Msg)], !IO),
        write_help_message(ProgName, !IO)
    ).

:- pred print_feedback_report(string::in, feedback_info::in, io::di, io::uo)
    is det.

print_feedback_report(ProgName, Feedback, !IO) :-
    get_all_feedback_data(Feedback, AllFeedback),
    map(create_feedback_report, AllFeedback, Reports),
    ReportStr = string.append_list(Reports),
    io.format("Feedback report for %s:\n\n%s", [s(ProgName), s(ReportStr)],
        !IO).

:- pred create_feedback_report(feedback_data::in, string::out) is det.

create_feedback_report(feedback_data_calls_above_threshold_sorted(_, _, _),
        Report) :-
   Report = "  feedback_data_calls_above_threshold_sorted is deprecated\n".
create_feedback_report(feedback_data_candidate_parallel_conjunctions(
        Parameters, Conjs), Report) :-
    NumConjs = length(Conjs),
    Parameters = candidate_par_conjunctions_params(DesiredParallelism,
        IntermoduleVarUse, SparkingCost, SparkingDelay, BarrierCost,
        SignalCost, WaitCost, ContextWakeupDelay, CliqueThreshold,
        CallSiteThreshold, ParalleliseDepConjs, BestParAlgorithm),
    best_par_algorithm_string(BestParAlgorithm, BestParAlgorithmStr),
    ReportHeader = singleton(format(
        "  Candidate Parallel Conjunctions:\n" ++
        "    Desired parallelism: %f\n" ++
        "    Intermodule var use: %s\n" ++
        "    Sparking cost: %d\n" ++
        "    Sparking delay: %d\n" ++
        "    Barrier cost: %d\n" ++
        "    Future signal cost: %d\n" ++
        "    Future wait cost: %d\n" ++
        "    Context wakeup delay: %d\n" ++
        "    Clique threshold: %d\n" ++
        "    Call site threshold: %d\n" ++
        "    Parallelise dependant conjunctions: %s\n" ++
        "    BestParallelisationAlgorithm: %s\n" ++
        "    Number of Parallel Conjunctions: %d\n" ++
        "    Parallel Conjunctions:\n\n",
        [f(DesiredParallelism),
         s(string(IntermoduleVarUse)),
         i(SparkingCost),
         i(SparkingDelay),
         i(BarrierCost),
         i(SignalCost),
         i(WaitCost),
         i(ContextWakeupDelay),
         i(CliqueThreshold),
         i(CallSiteThreshold),
         s(ParalleliseDepConjsStr),
         s(BestParAlgorithmStr),
         i(NumConjs)])),
    (
        ParalleliseDepConjs = parallelise_dep_conjs_overlap,
        ParalleliseDepConjsStr = "yes, use overlap calculation"
    ;
        ParalleliseDepConjs = parallelise_dep_conjs_num_vars,
        ParalleliseDepConjsStr =
            "yes, the more shared variables then the less overlap there is"
    ;
        ParalleliseDepConjs = parallelise_dep_conjs_naive,
        ParalleliseDepConjsStr = "yes, pretend they're independant"
    ;
        ParalleliseDepConjs = do_not_parallelise_dep_conjs,
        ParalleliseDepConjsStr = "no"
    ),
    map(create_candidate_parallel_conj_proc_report, Conjs, ReportConjs),
    Report = append_list(list(ReportHeader ++ cord_list_to_cord(ReportConjs))).

:- func help_message = string.

help_message =
"Usage: %s [<options>] <input> <output>
       %s <output>
       %s --help
       %s --version

    The first form of this command generates feedback information from
    profiling data.  The second form prints a report of the feedback data and
    does not modify it.  The third and forth forms print this help message and
    version information respectively.

    <input> must name a deep profiling data file.
    <output> is the name of the file to be generated by this program.

    You may specify the following general options:

    -h --help       Generate this help message.
    -V --version    Report the program's version number.
    -v --verbosity  <0-4>
                    Generate messages.  The higher the argument the more
                    verbose the program becomes.  2 is recommended and the
                    default.
    --debug-read-profile
                    Generate debugging messages when reading the deep profile
                    and creating the deep structure.
    -r --report     Display a report about the feedback information in the file
                    after any processing has been done.

    The following options select sets of feedback information useful
    for particular compiler optimizations:

    --implicit-parallelism
                Generate information that the compiler can use for automatic
                parallelization.
    --desired-parallelism <value>
                The amount of desired parallelism for implicit parallelism,
                value must be a floating point number above 1.0.
                Note: This option is currently ignored.
    --implicit-parallelism-intermodule-var-use
                Assume that the compiler will be able to push signals and waits
                for futures across module boundaries.
    --implicit-parallelism-sparking-cost <value>
                The cost of creating a spark, measured in the deep profiler's
                call sequence counts.
    --implicit-parallelism-sparking-delay <value>
                The time taken from the time a spark is created until the spark
                is executed by another processor, assuming that there is a free
                processor.
    --implicit-parallelism-barrier-cost <value>
                The cost of executing the barrier code at the end of each
                parallel conjunct.
    --implicit-parallelism-future-signal-cost <value>
                The cost of the signal() call for the producer of a shared
                variable, measured in the profiler's call sequence counts.
    --implicit-parallelism-future-wait-cost <value>
                The cost of the wait() call for the consumer of a shared
                variable, measured in the profiler's call sequence counts.
    --implicit-parallelism-context-wakeup-delay <value>
                The time taken for a context to resume execution after being
                placed on the run queue.  This is used to estimate the impact
                of blocking of a context's execution, it is measured in the
                profiler's call sequence counts.
    --implicit-parallelism-clique-cost-threshold <value>
                The cost threshold for cliques to be considered for implicit
                parallelism, measured on the profiler's call sequence counts.
    --implicit-parallelism-call-site-cost-threshold <value>
                The cost of a call site to be considered for parallelism
                against another call site.
    --implicit-parallelism-dependant-conjunctions
                Advise the compiler to parallelise dependant conjunctions.
                This will become the default once the implementation is
                complete.
    --implicit-parallelism-dependant-conjunctions-algorithm <alg>
                Choose the algorithm that is used to estimate the speedup for
                dependant calculations.  The algorithms are:
                    overlap: Compute the 'overlap' between dependant
                      conjunctions.
                    num_vars: Use the number of shared variables as a proxy for
                      the amount of overlap available.
                    naive: Ignore dependencies.
                The default is overlap.
    --implicit-parallelism-best-parallelisation-algorithm <algorithm>
                Select which algorithm to use to find the best way to
                parallelise a conjunction.  The algorithms are:
                    greedy: A greedy algorithm with a linear time complexity.
                    complete: A complete algorithm with a branch and bound
                      search. This can be slow for problems larger than 50
                      conjuncts, since it has an exponential complexity.
                    complete-size(N): As above exept that it takes a single
                      parameter, N.  A conjunction has more than N conjuncts
                      then the greedy algorithm will be used.
                    complete-branches(N): The same as the complete algorithm,
                      except that it allows at most N branches to be created
                      during the search.  Once N branches have been created a
                      greedy search is used on each open branch.
                The default is complete-branches(1000).

    The following options select specific types of feedback information
    and parameterise them:

    --calls-above-threshold-sorted
                A list of calls whose typical cost (in call sequence counts) is
                above a given threshold. This option uses the
                --desired-parallelism option to specify the threshold,
                --calls-above-threshold-sorted-measure specifies what 'typical'
                means.  This option is deprecated.
    --calls-above-threshold-sorted-measure mean|median
                mean: Use mean(call site dynamic cost) as the typical cost.
                median: Use median(call site dynamic cost) as the typical cost.
                The default is 'mean'.

    --candidate-parallel-conjunctions
                Produce a list of candidate parallel conjunctions for implicit
                parallelism.  This option uses the implicit parallelism
                settings above.

".

:- pred write_help_message(string::in, io::di, io::uo) is det.

write_help_message(ProgName, !IO) :-
    Message = help_message,
    io.format(Message, duplicate(4, s(ProgName)), !IO).

:- pred write_version_message(string::in, io::di, io::uo) is det.

write_version_message(ProgName, !IO) :-
    library.version(Version),
    io.write_string(ProgName, !IO),
    io.write_string(": Mercury deep profiler", !IO),
    io.nl(!IO),
    io.write_string(Version, !IO),
    io.nl(!IO).

    % Read a deep profiling data file.
    %
:- pred read_deep_file(string::in, bool::in, maybe_error(deep)::out,
    io::di, io::uo) is det.

read_deep_file(Input, Debug, MaybeDeep, !IO) :-
    server_name_port(Machine, !IO),
    script_name(ScriptName, !IO),
    (
        Debug = yes,
        io.stdout_stream(Stdout, !IO),
        MaybeOutput = yes(Stdout)
    ;
        Debug = no,
        MaybeOutput = no
    ),
    read_and_startup_default_deep_options(Machine, ScriptName, Input, no,
        MaybeOutput, [], MaybeDeep, !IO).

%----------------------------------------------------------------------------%
%
% This section describes and processes command line options. Individual
% feedback information can be requested by the user, as well as options named
% after optimizations that may imply one or more feedback inforemation types,
% which that optimization uses.
%

    % Command line options.
    %
:- type option
    --->    help
    ;       version
    ;       verbosity
    ;       debug_read_profile
    ;       report

            % The calls above threshold sorted feedback information, this is
            % used for the old implicit parallelism implementation.
    ;       calls_above_threshold_sorted
    ;       calls_above_threshold_sorted_measure

            % A list of candidate parallel conjunctions is produced for the new
            % implicit parallelism implementation.
    ;       candidate_parallel_conjunctions

            % Provide suitable feedback information for implicit parallelism
    ;       implicit_parallelism
    ;       desired_parallelism
    ;       implicit_parallelism_intermodule_var_use
    ;       implicit_parallelism_sparking_cost
    ;       implicit_parallelism_sparking_delay
    ;       implicit_parallelism_barrier_cost
    ;       implicit_parallelism_future_signal_cost
    ;       implicit_parallelism_future_wait_cost
    ;       implicit_parallelism_context_wakeup_delay
    ;       implicit_parallelism_clique_cost_threshold
    ;       implicit_parallelism_call_site_cost_threshold
    ;       implicit_parallelism_dependant_conjunctions
    ;       implicit_parallelism_dependant_conjunctions_algorithm
    ;       implicit_parallelism_best_parallelisation_algorithm.

% TODO: Introduce an option to disable parallelisation of dependant
% conjunctions, or switch to the simple calculations for independent
% conjunctions.

:- pred short(char::in, option::out) is semidet.

short('h',  help).
short('v',  verbosity).
short('V',  version).
short('r',  report).

:- pred long(string::in, option::out) is semidet.

long("help",
    help).
long("verbosity",
    verbosity).
long("version",
    version).
long("debug-read-profile",
    debug_read_profile).
long("report",
    report).
long("calls-above-threshold-sorted",
    calls_above_threshold_sorted).
long("calls-above-threshold-sorted-measure",
    calls_above_threshold_sorted_measure).
long("candidate-parallel-conjunctions",
    candidate_parallel_conjunctions).
long("implicit-parallelism",
    implicit_parallelism).
long("desired-parallelism",
    desired_parallelism).
long("implicit-parallelism-intermodule-var-use",
    implicit_parallelism_intermodule_var_use).
long("implicit-parallelism-sparking-cost",
    implicit_parallelism_sparking_cost).
long("implicit-parallelism-sparking-delay",
    implicit_parallelism_sparking_delay).
long("implicit-parallelism-future-signal-cost",
    implicit_parallelism_future_signal_cost).
long("implicit-parallelism-barrier-cost",
    implicit_parallelism_barrier_cost).
long("implicit-parallelism-future-wait-cost",
    implicit_parallelism_future_wait_cost).
long("implicit-parallelism-context-wakeup-delay",
    implicit_parallelism_context_wakeup_delay).
long("implicit-parallelism-clique-cost-threshold",
    implicit_parallelism_clique_cost_threshold).
long("implicit-parallelism-call-site-cost-threshold",
    implicit_parallelism_call_site_cost_threshold).
long("implicit-parallelism-dependant-conjunctions",
    implicit_parallelism_dependant_conjunctions).
long("implicit-parallelism-dependant-conjunctions-algorithm",
    implicit_parallelism_dependant_conjunctions_algorithm).
long("implicit-parallelism-best-parallelisation-algorithm",
    implicit_parallelism_best_parallelisation_algorithm).

:- pred defaults(option::out, option_data::out) is multi.

defaults(help,                  bool(no)).
defaults(verbosity,             int(2)).
defaults(version,               bool(no)).
defaults(debug_read_profile,    bool(no)).
defaults(report,                bool(no)).

defaults(calls_above_threshold_sorted,                      bool(no)).
defaults(calls_above_threshold_sorted_measure,              string("mean")).

defaults(candidate_parallel_conjunctions,                   bool(no)).

defaults(implicit_parallelism,                              bool(no)).
defaults(desired_parallelism,                               string("4.0")).
% XXX: These values have been chosen arbitrarily, appropriately values should
% be tested for.
defaults(implicit_parallelism_intermodule_var_use,          bool(no)).
defaults(implicit_parallelism_sparking_cost,                int(100)).
defaults(implicit_parallelism_sparking_delay,               int(1000)).
defaults(implicit_parallelism_barrier_cost,                 int(100)).
defaults(implicit_parallelism_future_signal_cost,           int(100)).
defaults(implicit_parallelism_future_wait_cost,             int(250)).
defaults(implicit_parallelism_context_wakeup_delay,         int(1000)).
defaults(implicit_parallelism_clique_cost_threshold,        int(100000)).
defaults(implicit_parallelism_call_site_cost_threshold,     int(50000)).
defaults(implicit_parallelism_dependant_conjunctions,       bool(no)).
defaults(implicit_parallelism_dependant_conjunctions_algorithm,
    string("overlap")).
defaults(implicit_parallelism_best_parallelisation_algorithm,
    string("complete-branches(1000)")).

:- pred construct_measure(string::in, stat_measure::out) is semidet.

construct_measure("mean",       stat_mean).
construct_measure("median",     stat_median).

    % This type defines the set of feedback_types that are to be calculated and
    % put into the feedback info file. They should correspond with the values
    % of feedback_type.
    %
:- type requested_feedback_info
    --->    requested_feedback_info(
                maybe_candidate_parallel_conjunctions
                    :: maybe(candidate_par_conjunctions_params)
            ).

:- pred check_verbosity_option(option_table(option)::in, int::out) is semidet.

check_verbosity_option(Options, VerbosityLevel) :-
    lookup_int_option(Options, verbosity, VerbosityLevel),
    VerbosityLevel >= 0,
    VerbosityLevel =< 4.

    % Check all the command line options and return a well-typed representation
    % of the user's request. Some command line options imply other options,
    % those implications are also handled here.
    %
:- pred check_options(option_table(option)::in, requested_feedback_info::out)
    is det.

check_options(Options0, RequestedFeedbackInfo) :-
    % Handle options that imply other options here.
    some [!Options]
    (
        !:Options = Options0,
        lookup_bool_option(!.Options, implicit_parallelism,
            ImplicitParallelism),
        (
            ImplicitParallelism = yes,
            set_option(calls_above_threshold_sorted, bool(yes), !Options),
            set_option(candidate_parallel_conjunctions, bool(yes), !Options)
        ;
            ImplicitParallelism = no
        ),
        Options = !.Options
    ),

    % For each feedback type, determine if it is requested and fill in the
    % field in the RequestedFeedbackInfo structure.
    lookup_bool_option(Options, candidate_parallel_conjunctions,
        CandidateParallelConjunctions),
    (
        CandidateParallelConjunctions = yes,
        lookup_string_option(Options, desired_parallelism,
            DesiredParallelismStr),
        (
            string.to_float(DesiredParallelismStr, DesiredParallelismPrime),
            DesiredParallelismPrime > 1.0
        ->
            DesiredParallelism = DesiredParallelismPrime
        ;
            error("Invalid value for desired_parallelism: " ++
                DesiredParallelismStr)
        ),
        lookup_bool_option(Options, implicit_parallelism_intermodule_var_use,
            IntermoduleVarUse),
        lookup_int_option(Options, implicit_parallelism_sparking_cost,
            SparkingCost),
        lookup_int_option(Options, implicit_parallelism_sparking_delay,
            SparkingDelay),
        lookup_int_option(Options, implicit_parallelism_barrier_cost,
            BarrierCost),
        lookup_int_option(Options, implicit_parallelism_future_signal_cost,
            FutureSignalCost),
        lookup_int_option(Options, implicit_parallelism_future_wait_cost,
            FutureWaitCost),
        lookup_int_option(Options, implicit_parallelism_context_wakeup_delay,
            ContextWakeupDelay),
        lookup_int_option(Options, implicit_parallelism_clique_cost_threshold,
            CPCCliqueThreshold),
        lookup_int_option(Options,
            implicit_parallelism_call_site_cost_threshold,
            CPCCallSiteThreshold),
        lookup_bool_option(Options,
            implicit_parallelism_dependant_conjunctions,
            ParalleliseDepConjsBool),
        lookup_string_option(Options,
            implicit_parallelism_dependant_conjunctions_algorithm,
            ParalleliseDepConjsString),
        (
            parse_parallelise_dep_conjs_string(ParalleliseDepConjsBool,
                ParalleliseDepConjsString, ParalleliseDepConjsPrime)
        ->
            ParalleliseDepConjs = ParalleliseDepConjsPrime
        ;
            error(format(
                "Couldn't parse '%s' into a parallelise dependant conjs "
                    ++ "option",
                [s(ParalleliseDepConjsString)]))
        ),
        lookup_string_option(Options,
            implicit_parallelism_best_parallelisation_algorithm,
            BestParAlgorithmStr),
        parse_best_par_algorithm(BestParAlgorithmStr,
            MaybeBestParAlgorithm),
        (
            MaybeBestParAlgorithm = ok(BestParAlgorithm)
        ;
            MaybeBestParAlgorithm = error(MaybeMessage, _Line, _Col),
            (
                MaybeMessage = yes(Message),
                Error = format(
                    "Couldn't parse %s as a best parallelsation algorithm:" ++
                        " %s\n",
                    [s(BestParAlgorithmStr), s(Message)])
            ;
                MaybeMessage = no,
                Error = format(
                    "Couldn't parse %s as a best parallelsation algorithm\n",
                    [s(BestParAlgorithmStr)])
            ),
            error(Error)
        ),
        CandidateParallelConjunctionsOpts =
            candidate_par_conjunctions_params(DesiredParallelism,
                IntermoduleVarUse,
                SparkingCost,
                SparkingDelay,
                BarrierCost,
                FutureSignalCost,
                FutureWaitCost,
                ContextWakeupDelay,
                CPCCliqueThreshold,
                CPCCallSiteThreshold,
                ParalleliseDepConjs,
                BestParAlgorithm),
        MaybeCandidateParallelConjunctionsOpts =
            yes(CandidateParallelConjunctionsOpts)
    ;
        CandidateParallelConjunctions = no,
        MaybeCandidateParallelConjunctionsOpts = no
    ),
    RequestedFeedbackInfo =
        requested_feedback_info(MaybeCandidateParallelConjunctionsOpts).

:- pred parse_best_par_algorithm(string::in,
    parse_result(best_par_algorithm)::out) is det.

parse_best_par_algorithm(String, Result) :-
    promise_equivalent_solutions [Result] (
        parse(String, best_par_algorithm_parser, Result)
    ).

:- pred best_par_algorithm_parser(src::in, best_par_algorithm::out,
    ps::in, ps::out) is semidet.

best_par_algorithm_parser(Src, Algorithm, !PS) :-
    whitespace(Src, _, !PS),
    (
        keyword(idchars, "greedy", Src, _, !PS)
    ->
        Algorithm = bpa_greedy
    ;
        keyword(idchars, "complete-branches", Src, _, !PS),
        brackets("(", ")", int_literal, Src, N, !PS),
        N >= 0
    ->
        Algorithm = bpa_complete_branches(N)
    ;
        keyword(idchars, "complete-size", Src, _, !PS),
        brackets("(", ")", int_literal, Src, N, !PS),
        N >= 0
    ->
        Algorithm = bpa_complete_size(N)
    ;
        keyword(idchars, "complete", Src, _, !PS),
        Algorithm = bpa_complete
    ),
    eof(Src, _, !PS).

:- func idchars = string.

idchars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_".

:- pred best_par_algorithm_string(best_par_algorithm::in, string::out) is det.

best_par_algorithm_string(bpa_greedy, "greedy").
best_par_algorithm_string(bpa_complete_branches(N),
    format("complete-branches(%d)", [i(N)])).
best_par_algorithm_string(bpa_complete_size(N),
    format("complete-size(%d)", [i(N)])).
best_par_algorithm_string(bpa_complete, "complete").

:- pred parse_parallelise_dep_conjs_string(bool::in, string::in,
    parallelise_dep_conjs::out) is semidet.

parse_parallelise_dep_conjs_string(no, _, do_not_parallelise_dep_conjs).
parse_parallelise_dep_conjs_string(yes, "overlap",
    parallelise_dep_conjs_overlap).
parse_parallelise_dep_conjs_string(yes, "num_vars",
    parallelise_dep_conjs_num_vars).
parse_parallelise_dep_conjs_string(yes, "naive",
    parallelise_dep_conjs_naive).

    % Adjust command line options when one option implies other options.
    %
:- pred option_implies(option::in, option::in, bool::in,
    option_table(option)::in, option_table(option)::out) is det.

option_implies(Option, ImpliedOption, ImpliedValue, !Options) :-
    ( lookup_bool_option(!.Options, Option, yes) ->
        set_option(ImpliedOption, bool(ImpliedValue), !Options)
    ;
        true
    ).

    % Set the value of an option in the option table.
    %
:- pred set_option(option::in, option_data::in,
    option_table(option)::in, option_table(option)::out) is det.

set_option(Option, Value, !Options) :-
    svmap.set(Option, Value, !Options).

%----------------------------------------------------------------------------%

    % process_deep_to_feedback(RequestedFeedbackInfo, Deep, Messages,
    %   !Feedback)
    %
    % Process a deep profiling structure and update the feedback information
    % according to the RequestedFeedbackInfo parameter.
    %
:- pred process_deep_to_feedback(requested_feedback_info::in, deep::in,
    cord(message)::out, feedback_info::in, feedback_info::out) is det.

process_deep_to_feedback(RequestedFeedbackInfo, Deep, Messages, !Feedback) :-
    MaybeCandidateParallelConjunctionsOpts =
        RequestedFeedbackInfo ^ maybe_candidate_parallel_conjunctions,
    (
        MaybeCandidateParallelConjunctionsOpts =
            yes(CandidateParallelConjunctionsOpts),
        candidate_parallel_conjunctions(CandidateParallelConjunctionsOpts,
            Deep, Messages, !Feedback)
    ;
        MaybeCandidateParallelConjunctionsOpts = no,
        Messages = cord.empty
    ).

%-----------------------------------------------------------------------------%
:- end_module mdprof_feedback.
%-----------------------------------------------------------------------------%
