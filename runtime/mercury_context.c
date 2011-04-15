/*
** vim: ts=4 sw=4 expandtab
*/
/*
INIT mercury_sys_init_scheduler_wrapper
ENDINIT
*/
/*
** Copyright (C) 1995-2007, 2009-2011 The University of Melbourne.
** This file may only be copied under the terms of the GNU Library General
** Public License - see the file COPYING.LIB in the Mercury distribution.
*/

/* mercury_context.c - handles multithreading stuff. */

#include "mercury_imp.h"

#include <stdio.h>
#ifdef MR_THREAD_SAFE
  #include "mercury_thread.h"
  #include "mercury_stm.h"
  #ifndef MR_HIGHLEVEL_CODE
    #include <semaphore.h>
  #endif
#endif
#ifdef MR_CAN_DO_PENDING_IO
  #include <sys/types.h>	/* for fd_set */
  #include <sys/time.h>		/* for struct timeval */
  #ifdef MR_HAVE_UNISTD_H
	#include <unistd.h>	/* for select() on OS X */
  #endif
#endif
#ifdef MR_PROFILE_PARALLEL_EXECUTION_SUPPORT
  #include <math.h> /* for sqrt and pow */
#endif

#ifdef MR_HAVE_SCHED_H
#include <sched.h>
#endif

#ifdef MR_MINGW
  #include <sys/time.h>     /* for gettimeofday() */
#endif

#ifdef MR_WIN32
  #include <sys/timeb.h>    /* for _ftime() */
#endif

#include "mercury_memory_handlers.h"
#include "mercury_context.h"
#include "mercury_engine.h"             /* for `MR_memdebug' */
#include "mercury_threadscope.h"        /* for data types and posting events */
#include "mercury_reg_workarounds.h"    /* for `MR_fd*' stuff */

#ifdef MR_PROFILE_PARALLEL_EXECUTION_SUPPORT
#define MR_PROFILE_PARALLEL_EXECUTION_FILENAME "parallel_execution_profile.txt"
#endif

/*---------------------------------------------------------------------------*/

static void
MR_init_context_maybe_generator(MR_Context *c, const char *id,
    MR_GeneratorPtr gen);

/*---------------------------------------------------------------------------*/

#ifdef  MR_LL_PARALLEL_CONJ
static void
MR_milliseconds_from_now(struct timespec *timeout, unsigned int msecs);
#endif

#ifdef MR_THREAD_SAFE

/*
** These states are bitfields so they can be combined when passed to
** try_wake_engine.  The definitions of the starts are:
**
** working      the engine has work to do and is working on it.
**
** sleeping     The engine has no work to do and is sleeping on it's sleep
**              semaphore.
**
** idle         The engine has recently finished it's work and is looking for
**              more work before it goes to sleep.  This state is useful when
**              there are no sleeping engines but there are idle engines,
**              signalling an idle engine will prevent it from sleeping and
**              allow it to re-check the work queues.
**
** woken        The engine was either sleeping or idle and has been signaled
**              and possibly been given work to do.  DO NOT signal these
**              engines again doing so may leak work.
*/
#define ENGINE_STATE_WORKING    0x0001
#define ENGINE_STATE_SLEEPING   0x0002
#define ENGINE_STATE_IDLE       0x0004
#define ENGINE_STATE_WOKEN      0x0008
#define ENGINE_STATE_ALL        0xFFFF

struct engine_sleep_sync_i {
    sem_t                               es_sleep_semaphore;
    sem_t                               es_wake_semaphore;
    volatile unsigned                   es_state;
    volatile unsigned                   es_action;
    union MR_engine_wake_action_data    es_action_data;
};

#define CACHE_LINE_SIZE 64
#define PAD_CACHE_LINE(s) \
    ((CACHE_LINE_SIZE) > (s) ? (CACHE_LINE_SIZE) - (s) : 0)

typedef struct {
    struct engine_sleep_sync_i d;
    /*
    ** Padding ensures that engine sleep synchronisation data for different
    ** engines doesn't share cache lines.
    */
    char padding[PAD_CACHE_LINE(sizeof(struct engine_sleep_sync_i))];
} engine_sleep_sync;

static
engine_sleep_sync *engine_sleep_sync_data;
#endif /* MR_THREAD_SAFE */


/*
** The run queue is protected with MR_runqueue_lock and signalled with
** MR_runqueue_cond.
*/
MR_Context              *MR_runqueue_head;
MR_Context              *MR_runqueue_tail;
#ifdef  MR_THREAD_SAFE
  MercuryLock           MR_runqueue_lock;
#endif

MR_PendingContext       *MR_pending_contexts;
#ifdef  MR_THREAD_SAFE
  MercuryLock           MR_pending_contexts_lock;
#endif

#ifdef MR_PROFILE_PARALLEL_EXECUTION_SUPPORT
MR_bool                 MR_profile_parallel_execution = MR_FALSE;

  #ifndef MR_HIGHLEVEL_CODE
static MR_Stats         MR_profile_parallel_executed_global_sparks =
        { 0, 0, 0, 0 };
static MR_Stats         MR_profile_parallel_executed_contexts = { 0, 0, 0, 0 };
static MR_Stats         MR_profile_parallel_executed_nothing = { 0, 0, 0, 0 };
/* This cannot be static as it is used in macros by other modules. */
MR_Stats                MR_profile_parallel_executed_local_sparks =
        { 0, 0, 0, 0 };
static MR_Integer       MR_profile_parallel_contexts_created_for_sparks = 0;

/*
** We don't access these atomically. They are protected by the free context
** list lock.
*/
static MR_Integer       MR_profile_parallel_small_context_reused = 0;
static MR_Integer       MR_profile_parallel_regular_context_reused = 0;
static MR_Integer       MR_profile_parallel_small_context_kept = 0;
static MR_Integer       MR_profile_parallel_regular_context_kept = 0;
  #endif /* ! MR_HIGHLEVEL_CODE */
#endif /* MR_PROFILE_PARALLEL_EXECUTION_SUPPORT */

/*
** Local variables for thread pinning.
*/
#ifdef MR_LL_PARALLEL_CONJ
static MercuryLock      MR_next_cpu_lock;
MR_bool                 MR_thread_pinning = MR_FALSE;
static MR_Unsigned      MR_next_cpu = 0;
/* This is initialised the first the MR_pin_primordial_thread() is called */
MR_Unsigned             MR_primordial_thread_cpu;
#endif

#if defined(MR_LL_PARALLEL_CONJ) && \
    defined(MR_PROFILE_PARALLEL_EXECUTION_SUPPORT)
/*
** This is used to give each context its own unique ID. It is accessed with
** atomic operations.
*/
static MR_ContextId     MR_next_context_id = 0;

/*
** Allocate a context ID.
*/
static MR_ContextId
allocate_context_id(void);
#endif

/*
** free_context_list and free_small_context_list are a global linked lists
** of unused context structures, with regular and small stacks respectively.
** If the MR_MemoryZone pointers are not NULL, then they point to allocated
** MR_MemoryZones.
*/
static MR_Context       *free_context_list = NULL;
#ifndef MR_STACK_SEGMENTS
static MR_Context       *free_small_context_list = NULL;
#endif
#ifdef  MR_THREAD_SAFE
  static MercuryLock    free_context_list_lock;
#endif

#ifdef  MR_LL_PARALLEL_CONJ
MR_Integer volatile         MR_num_idle_engines = 0;
MR_Unsigned volatile        MR_num_exited_engines = 0;
static MR_Integer volatile  MR_num_outstanding_contexts = 0;
static sem_t                shutdown_semaphore;

static MercuryLock MR_par_cond_stats_lock;
/*
** The spark deques are kept in engine id order.
**
** This array will contain MR_num_threads pointers to deques.
*/
MR_SparkDeque           **MR_spark_deques = NULL;
#endif

/*---------------------------------------------------------------------------*/

#ifdef MR_LL_PARALLEL_CONJ
/*
** Try to wake up a sleeping message and tell it to do action.  The engine is
** only woken if the engine is in one of the states in the bitfield states.  If
** the engine is woekn the result of this function is MR_TRUE, otherwise it's
** MR_FALSE.
*/
static MR_bool
try_wake_engine(MR_EngineId engine_id, int action,
    union MR_engine_wake_action_data *action_data, unsigned states);
#endif

/*
** Write out the profiling data that we collect during execution.
*/
static void
MR_write_out_profiling_parallel_execution(void);

#if defined(MR_LL_PARALLEL_CONJ) && defined(MR_HAVE_SCHED_SETAFFINITY)
static void
MR_do_pin_thread(int cpu);
#endif

/*---------------------------------------------------------------------------*/

void
MR_init_context_stuff(void)
{
#ifdef MR_LL_PARALLEL_CONJ
    unsigned i;
#endif

#ifdef  MR_THREAD_SAFE

    pthread_mutex_init(&MR_runqueue_lock, MR_MUTEX_ATTR);
    pthread_mutex_init(&free_context_list_lock, MR_MUTEX_ATTR);
    pthread_mutex_init(&MR_pending_contexts_lock, MR_MUTEX_ATTR);
  #ifdef MR_LL_PARALLEL_CONJ
    #ifdef MR_HAVE_SCHED_SETAFFINITY
    pthread_mutex_init(&MR_next_cpu_lock, MR_MUTEX_ATTR);
    #endif
    #ifdef MR_DEBUG_RUNTIME_GRANULARITY_CONTROL
    pthread_mutex_init(&MR_par_cond_stats_lock, MR_MUTEX_ATTR);
    #endif
    sem_init(&shutdown_semaphore, 0, 0);
  #endif
    pthread_mutex_init(&MR_STM_lock, MR_MUTEX_ATTR);

  #ifdef MR_HIGHLEVEL_CODE
    MR_KEY_CREATE(&MR_backjump_handler_key, NULL);
    MR_KEY_CREATE(&MR_backjump_next_choice_id_key, (void *)0);
  #endif

    /*
    ** If MR_num_threads is unset, configure it to match number of processors
    ** on the system. If we do this, then we prepare to set processor
    ** affinities later on.
    */
    if (MR_num_threads == 0) {
  #if defined(MR_HAVE_SYSCONF) && defined(_SC_NPROCESSORS_ONLN)
        long result;

        result = sysconf(_SC_NPROCESSORS_ONLN);
        if (result < 1) {
            /* We couldn't determine the number of processors. */
            MR_num_threads = 1;
        } else {
            MR_num_threads = result;
            /*
            ** On systems that don't support sched_setaffinity we don't try to
            ** automatically enable thread pinning. This prevents a runtime
            ** warning that could unnecessarily confuse the user.
            **/
    #if defined(MR_LL_PARALLEL_CONJ) && defined(MR_HAVE_SCHED_SETAFFINITY)
            /*
            ** Comment this back in to enable thread pinning by default if we
            ** autodetected the correct number of CPUs.
            */
            /* MR_thread_pinning = MR_TRUE; */
    #endif
        }
    #else /* ! defined(MR_HAVE_SYSCONF) && defined(_SC_NPROCESSORS_ONLN) */
        MR_num_threads = 1;
  #endif /* ! defined(MR_HAVE_SYSCONF) && defined(_SC_NPROCESSORS_ONLN) */
    }
  #ifdef MR_LL_PARALLEL_CONJ
    MR_granularity_wsdeque_length =
        MR_granularity_wsdeque_length_factor * MR_num_threads;

    MR_spark_deques = MR_GC_NEW_ARRAY(MR_SparkDeque*, MR_num_threads);
    engine_sleep_sync_data = MR_GC_NEW_ARRAY(engine_sleep_sync, MR_num_threads);
    for (i = 0; i < MR_num_threads; i++) {
        MR_spark_deques[i] = NULL;

        sem_init(&(engine_sleep_sync_data[i].d.es_sleep_semaphore), 0, 0);
        sem_init(&(engine_sleep_sync_data[i].d.es_wake_semaphore), 0, 1);
        /*
        ** All engines are initially working (because telling them to wake up
        ** before they're started would be useless.
        */
        engine_sleep_sync_data[i].d.es_state = ENGINE_STATE_WORKING;
        engine_sleep_sync_data[i].d.es_action = MR_ENGINE_ACTION_NONE;
    }
  #endif
#endif /* MR_THREAD_SAFE */
}

/*
** Pin the primordial thread first to the CPU it is currently using (where
** support is available).
*/
#if defined(MR_THREAD_SAFE) && defined(MR_LL_PARALLEL_CONJ)
unsigned
MR_pin_primordial_thread(void)
{
    unsigned    cpu;
    int         temp;

    /*
    ** We don't need locking to pin the primordial thread as it is called
    ** before any other threads exist.
    */
    /*
    ** We go through the motions of thread pinning even when thread pinning is
    ** not supported as the allocation of CPUs to threads may be used later.
    */
  #ifdef MR_HAVE_SCHED_GETCPU
    temp = sched_getcpu();
    if (temp == -1) {
        MR_primordial_thread_cpu = 0;
    #ifdef MR_HAVE_SCHED_SET_AFFINITY
        if (MR_thread_pinning) {
            perror("Warning: unable to determine the current CPU for "
                "the primordial thread: ");
        }
    #endif
    } else {
        MR_primordial_thread_cpu = temp;
    }
  #else
    MR_primordial_thread_cpu = 0;
  #endif
  #ifdef MR_HAVE_SCHED_SET_AFFINITY
    if (MR_thread_pinning) {
        MR_do_pin_thread(MR_primordial_thread_cpu);
    }
  #endif
    return MR_primordial_thread_cpu;
}
#endif /* defined(MR_THREAD_SAFE) && defined(MR_LL_PARALLEL_CONJ) */

#if defined(MR_THREAD_SAFE) && defined(MR_LL_PARALLEL_CONJ)
unsigned
MR_pin_thread(void)
{
    unsigned cpu;

    /*
    ** We go through the motions of thread pinning even when thread pinning is
    ** not supported as the allocation of CPUs to threads may be used later.
    */
    MR_LOCK(&MR_next_cpu_lock, "MR_pin_thread");
    if (MR_next_cpu == MR_primordial_thread_cpu) {
        /*
        ** Skip the CPU that the primordial thread was pinned on.
        */
        MR_next_cpu++;
    }
    cpu = MR_next_cpu++;
    MR_UNLOCK(&MR_next_cpu_lock, "MR_pin_thread");

#ifdef MR_HAVE_SCHED_SETAFFINITY
    if (MR_thread_pinning) {
        MR_do_pin_thread(cpu);
    }
#endif

    return cpu;
}
#endif /* defined(MR_THREAD_SAFE) && defined(MR_LL_PARALLEL_CONJ) */

#if defined(MR_LL_PARALLEL_CONJ) && defined(MR_HAVE_SCHED_SETAFFINITY)
static void
MR_do_pin_thread(int cpu)
{
    cpu_set_t   cpus;

    if (cpu < CPU_SETSIZE) {
        CPU_ZERO(&cpus);
        CPU_SET(cpu, &cpus);
        if (sched_setaffinity(0, sizeof(cpu_set_t), &cpus) == -1) {
            perror("Warning: Couldn't set CPU affinity: ");
            /*
            ** If this failed once, it will probably fail again, so we
            ** disable it.
            */
            MR_thread_pinning = MR_FALSE;
        }
    } else {
        perror("Warning: Couldn't set CPU affinity due to a static "
            "system limit: ");
        MR_thread_pinning = MR_FALSE;
    }
}
#endif

void
MR_finalize_context_stuff(void)
{
#ifdef MR_THREAD_SAFE
    pthread_mutex_destroy(&MR_runqueue_lock);
    pthread_mutex_destroy(&free_context_list_lock);
  #ifdef MR_LL_PARALLEL_CONJ
    sem_destroy(&shutdown_semaphore);
  #endif
#endif

#ifdef MR_PROFILE_PARALLEL_EXECUTION_SUPPORT
    if (MR_profile_parallel_execution) {
        MR_write_out_profiling_parallel_execution();
    }
#endif
}

#ifdef MR_PROFILE_PARALLEL_EXECUTION_SUPPORT
static int
fprint_stats(FILE *stream, const char *message, MR_Stats *stats);

/*
** Write out the profiling data for parallel execution.
**
** This writes out a flat text file which may be parsed by a machine or easily
** read by a human. There is no advantage in using a binary format since we
** do this once at the end of execution and it's a small amount of data.
** Therefore a text file is used since it has the advantage of being human
** readable.
*/

static void
MR_write_out_profiling_parallel_execution(void)
{
    FILE    *file;
    int     result;

    file = fopen(MR_PROFILE_PARALLEL_EXECUTION_FILENAME, "w");
    if (NULL == file) goto Error;

    result = fprintf(file, "Mercury parallel execution profiling data\n\n");
    if (result < 0) goto Error;

    if (MR_cpu_cycles_per_sec) {
        result = fprintf(file, "CPU cycles per second: %ld\n",
            MR_cpu_cycles_per_sec);
        if (result < 0) goto Error;
    }

    result = fprint_stats(file, "MR_do_runnext(): global sparks executed",
        &MR_profile_parallel_executed_global_sparks);
    if (result < 0) goto Error;

    result = fprint_stats(file, "MR_do_runnext(): global contexts resumed",
        &MR_profile_parallel_executed_contexts);
    if (result < 0) goto Error;

    result = fprint_stats(file, "MR_do_runnext(): executed nothing",
        &MR_profile_parallel_executed_nothing);
    if (result < 0) goto Error;

    result = fprint_stats(file, "Local sparks executed",
        &MR_profile_parallel_executed_local_sparks);
    if (result < 0) goto Error;

    result = fprintf(file, "Contexts created for global spark execution: %d\n",
        MR_profile_parallel_contexts_created_for_sparks);
    if (result < 0) goto Error;

    result = fprintf(file, "Number of times a small context was reused: %d\n",
        MR_profile_parallel_small_context_reused);
    if (result < 0) goto Error;

    result = fprintf(file,
        "Number of times a regular context was reused: %d\n",
        MR_profile_parallel_regular_context_reused);
    if (result < 0) goto Error;

    result = fprintf(file,
        "Number of times a small context was kept for later use: %d\n",
        MR_profile_parallel_small_context_kept);
    if (result < 0) goto Error;

    result = fprintf(file,
        "Number of times a regular context was kept for later use: %d\n",
        MR_profile_parallel_regular_context_kept);
    if (result < 0) goto Error;

    if (fclose(file) != 0) goto Error;

    return;

Error:
    perror(MR_PROFILE_PARALLEL_EXECUTION_FILENAME);
    abort();
}

#define MR_FPRINT_STATS_FORMAT_STRING_FULL \
    ("%s: count %" MR_INTEGER_LENGTH_MODIFIER "u (%" \
    MR_INTEGER_LENGTH_MODIFIER "ur, %" MR_INTEGER_LENGTH_MODIFIER \
    "unr), average %.0f, standard deviation %.0f\n")
#define MR_FPRINT_STATS_FORMAT_STRING_SINGLE \
    ("%s: count %" MR_INTEGER_LENGTH_MODIFIER "u (%" \
    MR_INTEGER_LENGTH_MODIFIER "ur, %" MR_INTEGER_LENGTH_MODIFIER \
    "unr), sample %ul\n")
#define MR_FPRINT_STATS_FORMAT_STRING_NONE \
    ("%s: count %" MR_INTEGER_LENGTH_MODIFIER "u (%" \
    MR_INTEGER_LENGTH_MODIFIER "ur, %" MR_INTEGER_LENGTH_MODIFIER "unr)\n")

static int
fprint_stats(FILE *stream, const char *message, MR_Stats *stats)
{
    MR_Unsigned     count;
    double          average;
    double          sum_squared_over_n;
    double          standard_deviation;

    count = (unsigned)(stats->MR_stat_count_recorded +
        stats->MR_stat_count_not_recorded);

    if (stats->MR_stat_count_recorded > 1) {
        average = (double)stats->MR_stat_sum /
            (double)stats->MR_stat_count_recorded;
        sum_squared_over_n = pow((double)stats->MR_stat_sum,2.0)/
            (double)stats->MR_stat_count_recorded;
        standard_deviation =
            sqrt(((double)stats->MR_stat_sum_squares - sum_squared_over_n) /
            (double)(stats->MR_stat_count_recorded - 1));

        return fprintf(stream, MR_FPRINT_STATS_FORMAT_STRING_FULL, message,
            count, stats->MR_stat_count_recorded,
            stats->MR_stat_count_not_recorded, average, standard_deviation);
    } else if (stats->MR_stat_count_recorded == 1) {
        return fprintf(stream, MR_FPRINT_STATS_FORMAT_STRING_SINGLE,
            message, count, stats->MR_stat_count_recorded,
            stats->MR_stat_count_not_recorded, stats->MR_stat_sum);
    } else {
        return fprintf(stream, MR_FPRINT_STATS_FORMAT_STRING_NONE,
            message, count, stats->MR_stat_count_recorded,
            stats->MR_stat_count_not_recorded);
    }
};

#endif /* MR_PROFILE_PARALLEL_EXECUTION_SUPPORT */

static void
MR_init_context_maybe_generator(MR_Context *c, const char *id,
    MR_GeneratorPtr gen)
{
    const char  *detstack_name;
    const char  *nondetstack_name;
    size_t      detstack_size;
    size_t      nondetstack_size;

    c->MR_ctxt_id = id;
    c->MR_ctxt_next = NULL;
    c->MR_ctxt_resume = NULL;
#ifdef  MR_THREAD_SAFE
    c->MR_ctxt_resume_owner_engine = 0;
    c->MR_ctxt_resume_engine_required = MR_FALSE;
    c->MR_ctxt_resume_c_depth = 0;
    c->MR_ctxt_saved_owners = NULL;
#endif

#ifndef MR_HIGHLEVEL_CODE
    c->MR_ctxt_succip = MR_ENTRY(MR_do_not_reached);

    switch (c->MR_ctxt_size) {
        case MR_CONTEXT_SIZE_REGULAR:
            detstack_name  = "detstack";
            nondetstack_name = "nondetstack";
            detstack_size  = MR_detstack_size;
            nondetstack_size = MR_nondetstack_size;
            break;
#ifndef MR_STACK_SEGMENTS
        case MR_CONTEXT_SIZE_SMALL:
            detstack_name  = "small_detstack";
            nondetstack_name = "small_nondetstack";
            detstack_size  = MR_small_detstack_size;
            nondetstack_size = MR_small_nondetstack_size;
            break;
#endif
    }

#ifdef MR_DEBUG_CONTEXT_CREATION_SPEED
    MR_debug_log_message("Allocating det stack");
#endif
    if (c->MR_ctxt_detstack_zone == NULL) {
        if (gen != NULL) {
            c->MR_ctxt_detstack_zone = MR_create_or_reuse_zone("gen_detstack",
                    MR_gen_detstack_size, MR_next_offset(),
                    MR_gen_detstack_zone_size, MR_default_handler);
        } else {
            c->MR_ctxt_detstack_zone = MR_create_or_reuse_zone(detstack_name,
                    detstack_size, MR_next_offset(),
                    MR_detstack_zone_size, MR_default_handler);
        }

        if (c->MR_ctxt_prev_detstack_zones != NULL) {
            /*
            ** We may be able to reuse a previously allocated stack, but
            ** a context should be reused only when its stacks are empty.
            */
            MR_fatal_error("MR_init_context_maybe_generator: prev det stack");
        }
    }
#ifdef MR_DEBUG_CONTEXT_CREATION_SPEED
    MR_debug_log_message("done");
#endif
    c->MR_ctxt_prev_detstack_zones = NULL;
    c->MR_ctxt_sp = c->MR_ctxt_detstack_zone->MR_zone_min;

#ifdef MR_DEBUG_CONTEXT_CREATION_SPEED
    MR_debug_log_message("Allocating nondet stack");
#endif
    if (c->MR_ctxt_nondetstack_zone == NULL) {
        if (gen != NULL) {
            c->MR_ctxt_nondetstack_zone = MR_create_or_reuse_zone("gen_nondetstack",
                    MR_gen_nondetstack_size, MR_next_offset(),
                    MR_gen_nondetstack_zone_size, MR_default_handler);
        } else {
            c->MR_ctxt_nondetstack_zone = MR_create_or_reuse_zone(nondetstack_name,
                    nondetstack_size, MR_next_offset(),
                    MR_nondetstack_zone_size, MR_default_handler);
        }

        if (c->MR_ctxt_prev_nondetstack_zones != NULL) {
            /*
            ** We may be able to reuse a previously allocated stack, but
            ** a context should be reused only when its stacks are empty.
            */
            MR_fatal_error(
                "MR_init_context_maybe_generator: prev nondet stack");
        }
    }
#ifdef MR_DEBUG_CONTEXT_CREATION_SPEED
    MR_debug_log_message("done");
#endif
    c->MR_ctxt_prev_nondetstack_zones = NULL;
    /*
    ** Note that maxfr and curfr point to the last word in the frame,
    ** not to the first word, so we need to add the size of the frame,
    ** minus one word, to the base address to get the maxfr/curfr pointer
    ** for the first frame on the nondet stack.
    */
    c->MR_ctxt_maxfr = c->MR_ctxt_nondetstack_zone->MR_zone_min +
        MR_NONDET_FIXED_SIZE - 1;
    c->MR_ctxt_curfr = c->MR_ctxt_maxfr;
    MR_redoip_slot_word(c->MR_ctxt_curfr) = (MR_Word)
        MR_ENTRY(MR_do_not_reached);
    MR_redofr_slot_word(c->MR_ctxt_curfr) = (MR_Word) NULL;
    MR_prevfr_slot_word(c->MR_ctxt_curfr) = (MR_Word) NULL;
    MR_succip_slot_word(c->MR_ctxt_curfr) = (MR_Word)
        MR_ENTRY(MR_do_not_reached);
    MR_succfr_slot_word(c->MR_ctxt_curfr) = (MR_Word) NULL;

  #ifdef MR_USE_MINIMAL_MODEL_STACK_COPY
    if (gen != NULL) {
        MR_fatal_error("MR_init_context_maybe_generator: "
            "generator and stack_copy");
    }

    if (c->MR_ctxt_genstack_zone == NULL) {
        c->MR_ctxt_genstack_zone = MR_create_or_reuse_zone("genstack",
            MR_genstack_size, MR_next_offset(),
            MR_genstack_zone_size, MR_default_handler);
    }
    c->MR_ctxt_gen_next = 0;

    if (c->MR_ctxt_cutstack_zone == NULL) {
        c->MR_ctxt_cutstack_zone = MR_create_or_reuse_zone("cutstack",
            MR_cutstack_size, MR_next_offset(),
            MR_cutstack_zone_size, MR_default_handler);
    }
    c->MR_ctxt_cut_next = 0;

    if (c->MR_ctxt_pnegstack_zone == NULL) {
        c->MR_ctxt_pnegstack_zone = MR_create_or_reuse_zone("pnegstack",
            MR_pnegstack_size, MR_next_offset(),
            MR_pnegstack_zone_size, MR_default_handler);
    }
    c->MR_ctxt_pneg_next = 0;
  #endif /* MR_USE_MINIMAL_MODEL_STACK_COPY */

  #ifdef MR_USE_MINIMAL_MODEL_OWN_STACKS
    c->MR_ctxt_owner_generator = gen;
  #endif /* MR_USE_MINIMAL_MODEL_OWN_STACKS */

  #ifdef MR_LL_PARALLEL_CONJ
    c->MR_ctxt_parent_sp = NULL;
  #endif /* MR_LL_PARALLEL_CONJ */

#endif /* !MR_HIGHLEVEL_CODE */

#ifdef MR_USE_TRAIL
    if (gen != NULL) {
        MR_fatal_error("MR_init_context_maybe_generator: generator and trail");
    }

    if (c->MR_ctxt_trail_zone == NULL) {
        c->MR_ctxt_trail_zone = MR_create_or_reuse_zone("trail",
            MR_trail_size, MR_next_offset(),
            MR_trail_zone_size, MR_default_handler);
    }
    c->MR_ctxt_trail_ptr =
        (MR_TrailEntry *) c->MR_ctxt_trail_zone->MR_zone_min;
    c->MR_ctxt_ticket_counter = 1;
    c->MR_ctxt_ticket_high_water = 1;
#endif

#ifndef MR_HIGHLEVEL_CODE
    c->MR_ctxt_backjump_handler = NULL;
    c->MR_ctxt_backjump_next_choice_id = 0;
#endif

#ifndef MR_CONSERVATIVE_GC
    if (gen != NULL) {
        MR_fatal_error("MR_init_context: generator and no conservative gc");
    }

    c->MR_ctxt_hp = NULL;
    c->MR_ctxt_min_hp_rec = NULL;
#endif

#ifdef  MR_EXEC_TRACE_INFO_IN_CONTEXT
    c->MR_ctxt_call_seqno = 0;
    c->MR_ctxt_call_depth = 0;
    c->MR_ctxt_event_number = 0;
#endif

    /* The caller is responsible for initialising this field. */
    c->MR_ctxt_thread_local_mutables = NULL;
}

MR_Context *
MR_create_context(const char *id, MR_ContextSize ctxt_size, MR_Generator *gen)
{
    MR_Context  *c = NULL;

#ifdef MR_LL_PARALLEL_CONJ
    MR_atomic_inc_int(&MR_num_outstanding_contexts);
#endif

    MR_LOCK(&free_context_list_lock, "create_context");

    /*
    ** Regular contexts have stacks at least as big as small contexts,
    ** so we can return a regular context in place of a small context
    ** if one is already available.
    */
#ifndef MR_STACK_SEGMENTS
    if (ctxt_size == MR_CONTEXT_SIZE_SMALL && free_small_context_list) {
        c = free_small_context_list;
        free_small_context_list = c->MR_ctxt_next;
#ifdef MR_PROFILE_PARALLEL_EXECUTION_SUPPORT
        if (MR_profile_parallel_execution) {
            MR_profile_parallel_small_context_reused++;
        }
#endif
    }
#endif
    if (c == NULL && free_context_list != NULL) {
        c = free_context_list;
        free_context_list = c->MR_ctxt_next;
#ifdef MR_PROFILE_PARALLEL_EXECUTION_SUPPORT
        if (MR_profile_parallel_execution) {
            MR_profile_parallel_regular_context_reused++;
        }
#endif
    }
    MR_UNLOCK(&free_context_list_lock, "create_context i");

#ifdef MR_DEBUG_STACK_SEGMENTS
    MR_debug_log_message("Re-used an old context: %p", c);
#endif

    if (c == NULL) {
        c = MR_GC_NEW(MR_Context);
#ifdef MR_DEBUG_STACK_SEGMENTS
        if (c) {
            MR_debug_log_message("Creating new context: %p", c);
        }
#endif
        c->MR_ctxt_size = ctxt_size;
#ifndef MR_HIGHLEVEL_CODE
        c->MR_ctxt_detstack_zone = NULL;
        c->MR_ctxt_nondetstack_zone = NULL;
#endif
#ifdef MR_USE_TRAIL
        c->MR_ctxt_trail_zone = NULL;
#endif
    }
#ifdef MR_THREADSCOPE
    c->MR_ctxt_num_id = allocate_context_id();
#endif

#ifdef MR_DEBUG_CONTEXT_CREATION_SPEED
    MR_debug_log_message("Calling MR_init_context_maybe_generator");
#endif
    MR_init_context_maybe_generator(c, id, gen);
    return c;
}

/*
** TODO: We should gc the cached contexts, or otherwise not cache to many.
*/
void
MR_destroy_context(MR_Context *c)
{
    MR_assert(c);

#ifdef MR_DEBUG_STACK_SEGMENTS
    MR_debug_log_message("Caching old context: %p", c);
#endif

#ifdef MR_THREAD_SAFE
    MR_assert(c->MR_ctxt_saved_owners == NULL);
#endif

    /*
    ** Save the context first, even though we're not saving a computation
    ** that's in progress we are saving some bookkeeping information.
    */
    /*
    ** TODO: When retrieving a context from the cached contexts, try to
    ** retrieve one with a matching engine ID, or give each engine a local
    ** cache of spare contexts.
    */
#ifdef MR_LL_PARALLEL_CONJ
    c->MR_ctxt_resume_owner_engine = MR_ENGINE(MR_eng_id);
#endif
    MR_save_context(c);

    /* XXX not sure if this is an overall win yet */
#if 0 && defined(MR_CONSERVATIVE_GC) && !defined(MR_HIGHLEVEL_CODE)
    /* Clear stacks to prevent retention of data. */
    MR_clear_zone_for_GC(c->MR_ctxt_detstack_zone,
        c->MR_ctxt_detstack_zone->MR_zone_min);
    MR_clear_zone_for_GC(c->MR_ctxt_nondetstack_zone,
        c->MR_ctxt_nondetstack_zone->MR_zone_min);
#endif /* defined(MR_CONSERVATIVE_GC) && !defined(MR_HIGHLEVEL_CODE) */

#ifdef MR_LL_PARALLEL_CONJ
    MR_atomic_dec_int(&MR_num_outstanding_contexts);
#endif

    MR_LOCK(&free_context_list_lock, "destroy_context");
    switch (c->MR_ctxt_size) {
        case MR_CONTEXT_SIZE_REGULAR:
            c->MR_ctxt_next = free_context_list;
            free_context_list = c;
#ifdef MR_PROFILE_PARALLEL_EXECUTION_SUPPORT
            if (MR_profile_parallel_execution) {
                MR_profile_parallel_regular_context_kept++;
            }
#endif
            break;
#ifndef MR_STACK_SEGMENTS
        case MR_CONTEXT_SIZE_SMALL:
            c->MR_ctxt_next = free_small_context_list;
            free_small_context_list = c;
#ifdef MR_PROFILE_PARALLEL_EXECUTION_SUPPORT
            if (MR_profile_parallel_execution) {
                MR_profile_parallel_small_context_kept++;
            }
#endif
            break;
#endif
    }
    MR_UNLOCK(&free_context_list_lock, "destroy_context");
}

#ifdef MR_PROFILE_PARALLEL_EXECUTION_SUPPORT
static MR_ContextId
allocate_context_id(void) {
    return MR_atomic_add_and_fetch_int(&MR_next_context_id, 1);
}
#endif

#ifdef MR_LL_PARALLEL_CONJ

/* Search for a ready context which we can handle. */
static MR_Context *
MR_find_ready_context(void)
{
    MR_Context  *cur;
    MR_Context  *prev;
    MR_Context  *preferred_context;
    MR_Context  *preferred_context_prev;
    MR_EngineId engine_id = MR_ENGINE(MR_eng_id);
    MR_Unsigned depth = MR_ENGINE(MR_eng_c_depth);

    /* XXX check pending io */

    /*
    ** Give preference to contexts as follows:
    **
    **  A context that must be run on this engine.
    **  A context that prefers to be run on this engine.
    **  Any runnable context that may be ran on this engine.
    **
    ** TODO: There are other scheduling decisions we should test, such as
    ** running older versus younger contexts, or more recently stopped/runnable
    ** contexts.
    */
    cur = MR_runqueue_head;
    prev = NULL;
    preferred_context = NULL;
    preferred_context_prev = NULL;
    while (cur != NULL) {
#ifdef MR_DEBUG_THREADS
        if (MR_debug_threads) {
            fprintf(stderr, "%ld Eng: %d, c_depth: %d, Considering context %p\n",
                MR_SELF_THREAD_ID, engine_id, depth, cur);
        }
#endif
        if (cur->MR_ctxt_resume_engine_required == MR_TRUE) {
#ifdef MR_DEBUG_THREADS
            if (MR_debug_threads) {
                fprintf(stderr, "%ld Context requires engine %d and c_depth %d\n",
                    MR_SELF_THREAD_ID, cur->MR_ctxt_resume_owner_engine,
                    cur->MR_ctxt_resume_c_depth);
            }
#endif
            if ((cur->MR_ctxt_resume_owner_engine == engine_id) &&
                (cur->MR_ctxt_resume_c_depth == depth))
            {
                preferred_context = cur;
                preferred_context_prev = prev;
                cur->MR_ctxt_resume_engine_required = MR_FALSE;
                /*
                ** This is the best thread to resume.
                */
                break;
            }
        } else {
#ifdef MR_DEBUG_THREADS
            if (MR_debug_threads) {
                fprintf(stderr, "%ld Context prefers engine %d\n",
                    MR_SELF_THREAD_ID, cur->MR_ctxt_resume_owner_engine);
            }
#endif
            if (cur->MR_ctxt_resume_owner_engine == engine_id) {
                /*
                ** This context prefers to be ran on this engine.
                */
                preferred_context = cur;
                preferred_context_prev = prev;
            } else if (preferred_context == NULL) {
                /*
                ** There is no preferred context yet, and this context is okay.
                */
                preferred_context = cur;
                preferred_context_prev = prev;
            }
        }

        prev = cur;
        cur = cur->MR_ctxt_next;
    }

    if (preferred_context != NULL) {
        if (preferred_context_prev != NULL) {
            preferred_context_prev->MR_ctxt_next =
                preferred_context->MR_ctxt_next;
        } else {
            MR_runqueue_head = preferred_context->MR_ctxt_next;
        }
        if (MR_runqueue_tail == preferred_context) {
            MR_runqueue_tail = preferred_context_prev;
        }
#ifdef MR_DEBUG_THREADS
        if (MR_debug_threads) {
            fprintf(stderr, "%ld Will run context %p\n",
                MR_SELF_THREAD_ID, preferred_context);
        }
#endif
    } else {
#ifdef MR_DEBUG_THREADS
        if (MR_debug_threads) {
            fprintf(stderr, "%ld No suitable context to run\n",
                MR_SELF_THREAD_ID);
        }
#endif
    }

    return preferred_context;
}

static MR_bool
MR_attempt_steal_spark(MR_Spark *spark)
{
    int             i;
    int             offset;
    MR_SparkDeque   *victim;
    int             result = MR_FALSE;

    offset = MR_ENGINE(MR_eng_victim_counter);

    for (i = 0; i < MR_num_threads; i++) {
        victim = MR_spark_deques[(i + offset) % MR_num_threads];
        if (victim != NULL) {
            result = (MR_wsdeque_steal_top(victim, spark)) == 1;
            if (result) {
                /* Steal successful. */
                break;
            }
        }
    }

    MR_ENGINE(MR_eng_victim_counter) = (i % MR_num_threads);
    return result;
}

static void
MR_milliseconds_from_now(struct timespec *timeout, unsigned int msecs)
{
#if defined(MR_HAVE_GETTIMEOFDAY)

    const long          NANOSEC_PER_SEC = 1000000000L;
    struct timeval      now;
    MR_int_least64_t    nanosecs;

    gettimeofday(&now, NULL);
    timeout->tv_sec = now.tv_sec;
    nanosecs = ((MR_int_least64_t) (now.tv_usec + (msecs * 1000))) * 1000L;
    if (nanosecs >= NANOSEC_PER_SEC) {
        timeout->tv_sec++;
        nanosecs %= NANOSEC_PER_SEC;
    }
    timeout->tv_nsec = (long) nanosecs;

#elif defined(MR_WIN32)

    const long          NANOSEC_PER_SEC = 1000000000L;
    const long          NANOSEC_PER_MILLISEC = 1000000L;
    struct _timeb       now;
    MR_int_least64_t    nanosecs;

    _ftime(&now);
    timeout->tv_sec = now.time;
    nanosecs = ((MR_int_least64_t) (msecs + now.millitm)) *
        NANOSEC_PER_MILLISEC;
    if (nanosecs >= NANOSEC_PER_SEC) {
        timeout->tv_sec++;
        nanosecs %= NANOSEC_PER_SEC;
    }
    timeout->tv_nsec = (long) nanosecs;

#else

    #error Missing definition of MR_milliseconds_from_now.

#endif
}

#endif  /* MR_LL_PARALLEL_CONJ */

void
MR_flounder(void)
{
    MR_fatal_error("computation floundered");
}

void
MR_sched_yield(void)
{
#if defined(MR_HAVE_SCHED_YIELD)
    sched_yield();
#elif defined(MR_CAN_DO_PENDING_IO)
    struct timeval timeout = {0, 1};
    select(0, NULL, NULL, NULL, &timeout);
#endif
}

/*
** Check to see if any contexts that blocked on IO have become
** runnable. Return the number of contexts that are still blocked.
** The parameter specifies whether or not the call to select should
** block or not.
*/

static int
MR_check_pending_contexts(MR_bool block)
{
#ifdef  MR_CAN_DO_PENDING_IO
    int                 err;
    int                 max_id;
    int                 n_ids;
    fd_set              rd_set0;
    fd_set              wr_set0;
    fd_set              ex_set0;
    fd_set              rd_set;
    fd_set              wr_set;
    fd_set              ex_set;
    struct timeval      timeout;
    MR_PendingContext   *pctxt;

    if (MR_pending_contexts == NULL) {
        return 0;
    }

    MR_fd_zero(&rd_set0);
    MR_fd_zero(&wr_set0);
    MR_fd_zero(&ex_set0);
    max_id = -1;
    for (pctxt = MR_pending_contexts ; pctxt ; pctxt = pctxt -> next) {
        if (pctxt->waiting_mode & MR_PENDING_READ) {
            if (max_id > pctxt->fd) {
                max_id = pctxt->fd;
            }
            FD_SET(pctxt->fd, &rd_set0);
        }
        if (pctxt->waiting_mode & MR_PENDING_WRITE) {
            if (max_id > pctxt->fd) {
                max_id = pctxt->fd;
            }
            FD_SET(pctxt->fd, &wr_set0);
        }
        if (pctxt->waiting_mode & MR_PENDING_EXEC) {
            if (max_id > pctxt->fd) {
                max_id = pctxt->fd;
            }
            FD_SET(pctxt->fd, &ex_set0);
        }
    }
    max_id++;

    if (max_id == 0) {
        MR_fatal_error("no fd's set!");
    }

    if (block) {
        do {
            rd_set = rd_set0;
            wr_set = wr_set0;
            ex_set = ex_set0;
            err = select(max_id, &rd_set, &wr_set, &ex_set, NULL);
        } while (err == -1 && MR_is_eintr(errno));
    } else {
        do {
            rd_set = rd_set0;
            wr_set = wr_set0;
            ex_set = ex_set0;
            timeout.tv_sec = 0;
            timeout.tv_usec = 0;
            err = select(max_id, &rd_set, &wr_set, &ex_set, &timeout);
        } while (err == -1 && MR_is_eintr(errno));
    }

    if (err < 0) {
        MR_fatal_error("select failed!");
    }

    n_ids = 0;
    for (pctxt = MR_pending_contexts; pctxt; pctxt = pctxt -> next) {
        n_ids++;
        if (    ((pctxt->waiting_mode & MR_PENDING_READ)
                && FD_ISSET(pctxt->fd, &rd_set))
            ||  ((pctxt->waiting_mode & MR_PENDING_WRITE)
                && FD_ISSET(pctxt->fd, &wr_set))
            ||  ((pctxt->waiting_mode & MR_PENDING_EXEC)
                && FD_ISSET(pctxt->fd, &ex_set))
            )
        {
            MR_schedule_context(pctxt->context);
        }
    }

    return n_ids;

#else   /* !MR_CAN_DO_PENDING_IO */

    MR_fatal_error("select() unavailable!");

#endif
}

void
MR_schedule_context(MR_Context *ctxt)
{
#ifdef MR_THREAD_SAFE
    MR_EngineId engine_id;
    union MR_engine_wake_action_data wake_action_data;
    wake_action_data.MR_ewa_context = ctxt;

#ifdef MR_PROFILE_PARALLEL_EXECUTION_SUPPORT
    MR_threadscope_post_context_runnable(ctxt);
#endif

    /*
    ** Try to give this context straight to the engine that would execute it.
    */
    engine_id = ctxt->MR_ctxt_resume_owner_engine;
#ifdef MR_DEBUG_THREADS
    if (MR_debug_threads) {
        fprintf(stderr, "%ld Scheduling context %p desired engine: %d\n",
            MR_SELF_THREAD_ID, ctxt, engine_id);
    }
#endif
    if (ctxt->MR_ctxt_resume_engine_required == MR_TRUE) {
        /*
        ** Only engine_id may execute this context, attempt to wake it.
        */
#ifdef MR_DEBUG_THREADS
        if (MR_debug_threads) {
            fprintf(stderr, "%ld Context _must_ run on this engine\n",
                MR_SELF_THREAD_ID);
        }
#endif
        if (try_wake_engine(engine_id, MR_ENGINE_ACTION_CONTEXT,
            &wake_action_data, ENGINE_STATE_IDLE | ENGINE_STATE_SLEEPING))
        {
            /*
            ** We've successfully given the context to the correct engine.
            */
            return;
        }
    } else {
        /*
        ** If there is some idle engine try to wake it up, starting with the
        ** preferred engine.
        */
        if (MR_num_idle_engines > 0) {
            if (MR_try_wake_an_engine(engine_id, MR_ENGINE_ACTION_CONTEXT,
                &wake_action_data, NULL))
            {
                /*
                ** THe context has been given to a engine.
                */
                return;
            }
        }
    }
#endif

    MR_LOCK(&MR_runqueue_lock, "schedule_context");
    ctxt->MR_ctxt_next = NULL;
    if (MR_runqueue_tail) {
        MR_runqueue_tail->MR_ctxt_next = ctxt;
        MR_runqueue_tail = ctxt;
    } else {
        MR_runqueue_head = ctxt;
        MR_runqueue_tail = ctxt;
    }
    MR_UNLOCK(&MR_runqueue_lock, "schedule_context");
}

#ifdef MR_LL_PARALLEL_CONJ
/*
** Try to wake an engine, starting at the preferred engine
*/
MR_bool
MR_try_wake_an_engine(MR_EngineId preferred_engine, int action,
    union MR_engine_wake_action_data *action_data, MR_EngineId *target_eng)
{
    MR_EngineId current_engine;
    int i = 0;
    int state;
    MR_bool result;

    /*
    ** Right now this algorithm is naive, it searches from the preferred engine
    ** around the loop until it finds an engine.
    */
    for (i = 0; i < MR_num_threads; i++) {
        current_engine = (i + preferred_engine) % MR_num_threads;
        if (current_engine == MR_ENGINE(MR_eng_id)) {
            /*
            ** Don't post superfluous events to ourself
            */
            continue;
        }
        state = engine_sleep_sync_data[current_engine].d.es_state;
        if (state == ENGINE_STATE_SLEEPING) {
            result = try_wake_engine(current_engine, action, action_data,
                    ENGINE_STATE_SLEEPING);
            if (result) {
                if (target_eng) {
                    *target_eng = current_engine;
                }
                return MR_TRUE;
            }
        }
    }

    return MR_FALSE;
}

static MR_bool
try_wake_engine(MR_EngineId engine_id, int action,
    union MR_engine_wake_action_data *action_data, unsigned states)
{
    MR_bool success = MR_FALSE;
    engine_sleep_sync *esync = &(engine_sleep_sync_data[engine_id]);

    /*
    ** This engine is probably in the state our caller checked that it was in.
    ** Wait on the semaphore then re-check the state to be sure.
    */
    MR_SEM_WAIT(&(esync->d.es_wake_semaphore), "try_wake_engine, wake_sem");
    MR_CPU_LFENCE;
    if (esync->d.es_state & states) {
        /*
        ** We now KNOW that the engine is in one of the correct states.
        **
        ** We tell the engine what to do, and tell others that we've woken
        ** it before actually waking it.
        */
        esync->d.es_action = action;
        if (action_data) {
            esync->d.es_action_data = *action_data;
        }
        esync->d.es_state = ENGINE_STATE_WOKEN;
        MR_CPU_SFENCE;
        MR_SEM_POST(&(esync->d.es_sleep_semaphore), "try_wake_engine sleep_sem");
        success = MR_TRUE;
    }
    MR_SEM_POST(&(esync->d.es_wake_semaphore), "try_wake_engine wake_sem");

    return success;
}

void
MR_shutdown_all_engines(void)
{
    int i;

    for (i = 0; i < MR_num_threads; i++) {
        if (i == MR_ENGINE(MR_eng_id)) {
            continue;
        }
        try_wake_engine(i, MR_ENGINE_ACTION_SHUTDOWN, NULL,
            ENGINE_STATE_ALL);
    }

    for (i = 0; i < (MR_num_threads - 1); i++) {
        MR_SEM_WAIT(&shutdown_semaphore, "MR_shutdown_all_engines");
    }
}

#endif /* MR_LL_PARALLEL_CONJ */

#ifndef MR_HIGHLEVEL_CODE

/****************************************************************************
**
** Parallel runtime idle loop.
**
** This also contains code to run the next runnable context for non-parallel
** low level C grades.
**
*/

/*
** The run queue used to include timing code, it's been removed and may be
** added in the future.
*/

/*
** If the call returns a non-null code pointer then jump to that address,
** otherwise fall-through
*/
#define MR_MAYBE_TRAMPOLINE_AND_ACTION(call, action)                        \
    do {                                                                    \
        MR_Code *tramp;                                                     \
        tramp = (call);                                                     \
        if (tramp) {                                                        \
            action;                                                         \
            MR_GOTO(tramp);                                                 \
        }                                                                   \
    } while (0)
#define MR_MAYBE_TRAMPOLINE(call) \
    MR_MAYBE_TRAMPOLINE_AND_ACTION((call), )

MR_define_extern_entry(MR_do_idle);

#ifdef MR_THREAD_SAFE
MR_define_extern_entry(MR_do_idle_clean_context);
MR_define_extern_entry(MR_do_idle_dirty_context);
MR_define_extern_entry(MR_do_sleep);

static MR_Code*
do_get_context(void);

static MR_Code*
do_local_spark(MR_Code *join_label);

static MR_Code*
do_work_steal(MR_Code *join_label);

static void
save_dirty_context(MR_Code *join_label);

/*
** Prepare the engine to execute a spark.  If join_label is not null then this
** engine has a context that may not be compatible with the spark.  If it isn't
** then the context must be saved with join_label as the resume point.
*/
static void
prepare_engine_for_spark(volatile MR_Spark *spark, MR_Code *join_label);

/*
** Prepare the engine to execute a context.  This loads the context into the
** engine after discarding any existing context.  All the caller need do is
** jump to the resume/start point.
*/
static void
prepare_engine_for_context(MR_Context *context);

/*
** Advertise that the engine is looking for work after being in the working state.
** (Do not use this call when waking from sleep).
*/
static void
advertise_engine_state_idle(void);

/*
** Advertise that the engine will begin working.
*/
static void
advertise_engine_state_working(void);
#endif

MR_BEGIN_MODULE(scheduler_module_idle)
    MR_init_entry_an(MR_do_idle);
MR_BEGIN_CODE
MR_define_entry(MR_do_idle);
  #ifdef MR_THREAD_SAFE
{
    /*
    ** Try to get a context.
    **
    ** Always look for local work first, even though we'd need to allocate a
    ** context to execute it.  This is probably less efficient (TODO) but it's
    ** safer. It makes it easier for the state of the machine to change before
    ** it goes to sleep.
    */
    MR_MAYBE_TRAMPOLINE(do_local_spark(NULL));

    advertise_engine_state_idle();

    MR_MAYBE_TRAMPOLINE_AND_ACTION(do_get_context(),
        advertise_engine_state_working());
    MR_MAYBE_TRAMPOLINE_AND_ACTION(do_work_steal(NULL),
        advertise_engine_state_working());
    MR_GOTO(MR_ENTRY(MR_do_sleep));
}
  #else /* !MR_THREAD_SAFE */
{
    /*
    ** When an engine becomes idle in a non parallel grade it simply picks up
    ** another context.
    */
    if (MR_runqueue_head == NULL && MR_pending_contexts == NULL) {
        MR_fatal_error("empty runqueue!");
    }

    while (MR_runqueue_head == NULL) {
        MR_check_pending_contexts(MR_TRUE); /* block */
    }

    MR_ENGINE(MR_eng_this_context) = MR_runqueue_head;
    MR_runqueue_head = MR_runqueue_head->MR_ctxt_next;
    if (MR_runqueue_head == NULL) {
        MR_runqueue_tail = NULL;
    }

    MR_load_context(MR_ENGINE(MR_eng_this_context));
    MR_GOTO(MR_ENGINE(MR_eng_this_context)->MR_ctxt_resume);
}
  #endif /* !MR_THREAD_SAFE */
MR_END_MODULE

#ifdef MR_THREAD_SAFE
MR_BEGIN_MODULE(scheduler_module_idle_clean_context)
    MR_init_entry_an(MR_do_idle_clean_context);
MR_BEGIN_CODE
MR_define_entry(MR_do_idle_clean_context);
{
    MR_MAYBE_TRAMPOLINE(do_local_spark(NULL));

    advertise_engine_state_idle();

    MR_MAYBE_TRAMPOLINE_AND_ACTION(do_work_steal(NULL),
        advertise_engine_state_working());
    MR_MAYBE_TRAMPOLINE_AND_ACTION(do_get_context(),
        advertise_engine_state_working());
    MR_GOTO(MR_ENTRY(MR_do_sleep));
}
MR_END_MODULE
#endif /* MR_THREAD_SAFE */

#ifdef MR_THREAD_SAFE
MR_BEGIN_MODULE(scheduler_module_idle_dirty_context)
    MR_init_entry_an(MR_do_idle_dirty_context);
MR_BEGIN_CODE
MR_define_entry(MR_do_idle_dirty_context);
{
    MR_Code *join_label = (MR_Code*)MR_r1;

    MR_MAYBE_TRAMPOLINE(do_local_spark(join_label));

    advertise_engine_state_idle();

    MR_MAYBE_TRAMPOLINE_AND_ACTION(do_work_steal(join_label),
        advertise_engine_state_working());

    /*
    ** Save the dirty context, we can't take it to sleep and it won't be used
    ** if do_get_context() succeeds.
    */
    save_dirty_context(join_label);
    MR_ENGINE(MR_eng_this_context) = NULL;

    MR_MAYBE_TRAMPOLINE_AND_ACTION(do_get_context(),
        advertise_engine_state_working());
    MR_GOTO(MR_ENTRY(MR_do_sleep));
}
MR_END_MODULE

/*
** Put the engine to sleep since there's no work to do.
**
** This call does not return.
**
** REQUIREMENT: Only call this with either no context or a clean context.
** REQUIREMENT: This must be called from the same C and Mercury stack depths as
**              the call into the idle loop.
*/
MR_BEGIN_MODULE(scheduler_module_idle_sleep)
    MR_init_entry_an(MR_do_sleep);
MR_BEGIN_CODE
MR_define_entry(MR_do_sleep);
{
    MR_EngineId engine_id = MR_ENGINE(MR_eng_id);
    unsigned action;
    int result;

    while (1) {
        engine_sleep_sync_data[engine_id].d.es_state = ENGINE_STATE_SLEEPING;
        MR_CPU_SFENCE;
        result = MR_SEM_WAIT(
            &(engine_sleep_sync_data[engine_id].d.es_sleep_semaphore),
            "MR_do_sleep sleep_sem");

        if (0 == result) {
            MR_CPU_LFENCE;
            action = engine_sleep_sync_data[engine_id].d.es_action;
#ifdef MR_DEBUG_THREADS
            if (MR_debug_threads) {
                fprintf(stderr, "%ld Engine %d is awake and will do action %d\n",
                    MR_SELF_THREAD_ID, engine_id, action);
            }
#endif

            switch(action) {
                case MR_ENGINE_ACTION_SHUTDOWN:
                    /*
                    ** The primordial thread has the responsibility of cleaning
                    ** up the Mercury runtime. It cannot exit by this route.
                    */
                    assert(engine_id != 0);
                    MR_atomic_dec_int(&MR_num_idle_engines);
                    MR_destroy_thread(MR_cur_engine());
                    MR_SEM_POST(&shutdown_semaphore, "MR_do_sleep shutdown_sem");
                    pthread_exit(0);
                    break;

                case MR_ENGINE_ACTION_WORKSTEAL:
                    MR_ENGINE(MR_eng_victim_counter) =
                        engine_sleep_sync_data[engine_id].d.es_action_data.
                        MR_ewa_worksteal_engine;
                    MR_MAYBE_TRAMPOLINE(do_work_steal(NULL));
                    MR_MAYBE_TRAMPOLINE(do_get_context());
                    break;

                case MR_ENGINE_ACTION_CONTEXT:
                    {
                        MR_Context *context;
                        MR_Code *resume_point;

                        context = engine_sleep_sync_data[engine_id].d.
                            es_action_data.MR_ewa_context;
                        prepare_engine_for_context(context);

                        #ifdef MR_DEBUG_STACK_SEGMENTS
                        MR_debug_log_message("resuming old context: %p",
                            context);
                        #endif

                        resume_point = (MR_Code*)(context->MR_ctxt_resume);
                        context->MR_ctxt_resume = NULL;

                        MR_GOTO(resume_point);
                    }
                    break;

                case MR_ENGINE_ACTION_NONE:
                default:
                    MR_MAYBE_TRAMPOLINE(do_get_context());
                    MR_MAYBE_TRAMPOLINE(do_work_steal(NULL));
                    break;
            }
        } else {
            /*
            ** sem_wait reported an error
            */
            switch (errno) {
                case EINTR:
                    /*
                    ** An interrupt woke the engine, go back to sleep.
                    */
                    break;
                default:
                    perror("sem_post");
                    abort();
            }
        }
    }
}
MR_END_MODULE
#endif

#ifdef MR_THREAD_SAFE

static MR_Code*
do_get_context(void)
{
    MR_Context *ready_context;
    MR_Code *resume_point;

    /*
    ** Look for a runnable context and execute it.  If there was no runnable
    ** context, then proceed to MR_do_runnext_local.
    */

    #ifdef MR_THREADSCOPE
    MR_threadscope_post_looking_for_global_context();
    #endif

    MR_LOCK(&MR_runqueue_lock, "do_get_context (i)");
    ready_context = MR_find_ready_context();
    MR_UNLOCK(&MR_runqueue_lock, "do_get_context (ii)");

    if (ready_context != NULL) {
        prepare_engine_for_context(ready_context);

        #ifdef MR_DEBUG_STACK_SEGMENTS
        MR_debug_log_message("resuming old context: %p", ready_context);
        #endif

        resume_point = (MR_Code*)(ready_context->MR_ctxt_resume);
        ready_context->MR_ctxt_resume = NULL;

        return resume_point;
    }

    return NULL;
}

static void
prepare_engine_for_context(MR_Context *context) {
    /*
    ** Discard whatever unused context we may have and switch to the new one.
    */
    if (MR_ENGINE(MR_eng_this_context) != NULL) {
    #ifdef MR_DEBUG_STACK_SEGMENTS
        MR_debug_log_message("destroying old context %p",
            MR_ENGINE(MR_eng_this_context));
    #endif
        MR_destroy_context(MR_ENGINE(MR_eng_this_context));
    }
    MR_ENGINE(MR_eng_this_context) = context;
    MR_load_context(context);
}

static void
prepare_engine_for_spark(volatile MR_Spark *spark, MR_Code *join_label)
{
    MR_Context *this_context = MR_ENGINE(MR_eng_this_context);

    /*
    ** We need to save this context if it is dirty and incompatible with
    ** this spark.
    */
    if ((this_context != NULL) &&
        (join_label != NULL) &&
        (spark->MR_spark_sync_term->MR_st_orig_context != this_context))
    {
#ifdef MR_DEBUG_CONTEXT_CREATION_SPEED
        MR_debug_log_message("Saving old dirty context %p", this_context);
#endif
        save_dirty_context(join_label);
#ifdef MR_DEBUG_CONTEXT_CREATION_SPEED
        MR_debug_log_message("done.");
#endif
        this_context = NULL;
    }
    if (this_context == NULL) {
        /*
        ** Get a new context
        */
#ifdef MR_DEBUG_CONTEXT_CREATION_SPEED
        MR_debug_log_message("Need a new context.");
#endif
        MR_ENGINE(MR_eng_this_context) = MR_create_context("from spark",
            MR_CONTEXT_SIZE_FOR_SPARK, NULL);
#ifdef MR_THREADSCOPE
        MR_threadscope_post_create_context_for_spark(
            MR_ENGINE(MR_eng_this_context));
#endif
/*
#ifdef MR_PROFILE_PARALLEL_EXECUTION_SUPPORT
        if (MR_profile_parallel_execution) {
            MR_atomic_inc_int(
                &MR_profile_parallel_contexts_created_for_sparks);
        }
#endif
*/
        MR_load_context(MR_ENGINE(MR_eng_this_context));
#ifdef MR_DEBUG_STACK_SEGMENTS
        MR_debug_log_message("created new context for spark: %p",
            MR_ENGINE(MR_eng_this_context));
#endif
    }

    /*
    ** At this point we have a context, either a dirty context that's compatbile or a clean one.
    */
    MR_parent_sp = spark->MR_spark_sync_term->MR_st_parent_sp;
    MR_SET_THREAD_LOCAL_MUTABLES(spark->MR_spark_thread_local_mutables);

    MR_assert(MR_parent_sp);
    MR_assert(MR_parent_sp != MR_sp);
    MR_assert(spark.MR_spark_sync_term->MR_st_count > 0);
}

static MR_Code*
do_local_spark(MR_Code *join_label)
{
    volatile MR_Spark *spark;

    spark = MR_wsdeque_pop_bottom(&MR_ENGINE(MR_eng_spark_deque));
    if (NULL == spark) {
        return NULL;
    }

#ifdef MR_THREADSCOPE
    MR_threadscope_post_run_spark(spark->MR_spark_id);
#endif
    prepare_engine_for_spark(spark, join_label);
    return spark->MR_spark_resume;
}

static MR_Code*
do_work_steal(MR_Code *join_label)
{
    MR_Spark spark;

    #ifdef MR_THREADSCOPE
    MR_threadscope_post_work_stealing();
    #endif

    /*
    ** A context may be created to execute a spark, so only attempt to
    ** steal sparks if doing so would not exceed the limit of outstanding
    ** contexts.
    */
    if (!((MR_ENGINE(MR_eng_this_context) == NULL) &&
         (MR_max_outstanding_contexts <= MR_num_outstanding_contexts))) {
        /* Attempt to steal a spark */
        if (MR_attempt_steal_spark(&spark)) {
#ifdef MR_THREADSCOPE
            MR_threadscope_post_steal_spark(spark.MR_spark_id);
#endif
            prepare_engine_for_spark(&spark, join_label);
            return spark.MR_spark_resume;
        }
    }

    return NULL;
}

static void
save_dirty_context(MR_Code *join_label) {
    MR_Context *this_context = MR_ENGINE(MR_eng_this_context);

#ifdef MR_THREADSCOPE
    MR_threadscope_post_stop_context(MR_TS_STOP_REASON_BLOCKED);
#endif
    this_context->MR_ctxt_resume_owner_engine = MR_ENGINE(MR_eng_id);
    MR_save_context(this_context);
    /*
    ** Make sure the context gets saved before we set the join
    ** label, use a memory barrier.
    */
    MR_CPU_SFENCE;
    this_context->MR_ctxt_resume = join_label;
    MR_ENGINE(MR_eng_this_context) = NULL;
}

static void
advertise_engine_state_idle(void)
{
    engine_sleep_sync_data[MR_ENGINE(MR_eng_id)].d.es_state = ENGINE_STATE_IDLE;
    MR_CPU_SFENCE;
    MR_atomic_inc_int(&MR_num_idle_engines);
}

static void
advertise_engine_state_working(void)
{
    MR_atomic_dec_int(&MR_num_idle_engines);
    MR_CPU_SFENCE;
    engine_sleep_sync_data[MR_ENGINE(MR_eng_id)].d.es_state = ENGINE_STATE_WORKING;
}
#endif /* MR_THREAD_SAFE */

#endif /* !MR_HIGHLEVEL_CODE */

#ifdef MR_LL_PARALLEL_CONJ
MR_Code*
MR_do_join_and_continue(MR_SyncTerm *jnc_st, MR_Code *join_label)
{
    MR_bool     jnc_last;
    MR_Context  *this_context = MR_ENGINE(MR_eng_this_context);

  #ifdef MR_THREADSCOPE
    MR_threadscope_post_stop_par_conjunct((MR_Word*)jnc_st);
  #endif

    /*
    ** Atomically decrement and fetch the number of conjuncts yet to complete.
    ** If we're the last conjunct to complete (the parallel conjunction is
    ** finished) then jnc_last will be true.
    */
    /*
    ** XXX: We should take the current TSC time here and use it to post the
    ** various 'context stopped' threadscope events. This profile will be more
    ** accurate.
    */

    jnc_last = MR_atomic_dec_and_is_zero_uint(&(jnc_st->MR_st_count));

    if (this_context == jnc_st->MR_st_orig_context) {
        /*
        ** This context originated this parallel conjunction.
        */
        if (jnc_last) {
            /*
            ** All the conjuncts have finished so jump to the join label.
            */
            return join_label;
        } else {
            /*
            ** This context is dirty, it is needed to complete the parallel
            ** conjunction
            */
            MR_r1 = (MR_Word)join_label;
            return MR_ENTRY(MR_do_idle_dirty_context);
        }
    } else {
        /*
        ** This context is now clean, it can be used to execute _any_ spark.
        */
        if (jnc_last) {
#ifdef MR_THREADSCOPE
            MR_threadscope_post_stop_context(MR_TS_STOP_REASON_FINISHED);
#endif
            /*
            ** This context didn't originate this parallel conjunction and
            ** we're the last branch to finish. The originating context should
            ** be suspended waiting for us to finish, we should run it using
            ** the current engine.
            **
            ** We could be racing with the original context, in which case we
            ** have to make sure that it is ready to be scheduled before we
            ** schedule it. It will set its resume point to join_label to
            ** indicate that it is ready.
            */
            while (jnc_st->MR_st_orig_context->MR_ctxt_resume != join_label) {
                /* XXX: Need to configure using sched_yeild or spin waiting */
                MR_ATOMIC_PAUSE;
            }
#ifdef MR_THREADSCOPE
            MR_threadscope_post_context_runnable(jnc_st->MR_st_orig_context);
#endif
            prepare_engine_for_context(jnc_st->MR_st_orig_context);
            return join_label;
        }
        return MR_ENTRY(MR_do_idle_clean_context);
    }
}
#endif

#ifdef MR_LL_PARALLEL_CONJ

/*
 * Debugging functions for runtime granularity control.
 */

#ifdef MR_DEBUG_RUNTIME_GRANULARITY_CONTROL

#define MR_PAR_COND_STATS_FILENAME "par_cond_stats.log"
static FILE * volatile MR_par_cond_stats_file = NULL;
static volatile MR_Unsigned MR_par_cond_stats_last;
static volatile MR_Unsigned MR_par_cond_stats_last_count;

void MR_record_conditional_parallelism_decision(MR_Unsigned decision)
{
    MR_LOCK(&MR_par_cond_stats_lock,
        "record_conditional_parallelism_decision");

    if (MR_par_cond_stats_file == NULL) {
        MR_par_cond_stats_file = fopen(MR_PAR_COND_STATS_FILENAME, "w");
        MR_par_cond_stats_last = decision;
        MR_par_cond_stats_last_count = 1;
    } else {
        if (decision == MR_par_cond_stats_last) {
            MR_par_cond_stats_last_count++;
        } else {
            fprintf(MR_par_cond_stats_file, "%d %d\n", MR_par_cond_stats_last,
                MR_par_cond_stats_last_count);
            MR_par_cond_stats_last = decision;
            MR_par_cond_stats_last_count = 1;
        }
    }

    MR_UNLOCK(&MR_par_cond_stats_lock,
        "record_conditional_parallelism_decision");
}

void MR_write_out_conditional_parallelism_log(void)
{
    MR_LOCK(&MR_par_cond_stats_lock,
        "write_out_conditional_parallelism_log");

    if (MR_par_cond_stats_file != NULL) {
        fprintf(MR_par_cond_stats_file, "%d %d\n",
            MR_par_cond_stats_last, MR_par_cond_stats_last_count);
        fclose(MR_par_cond_stats_file);
        MR_par_cond_stats_file = NULL;
    }

    MR_UNLOCK(&MR_par_cond_stats_lock,
        "write_out_conditional_parallelism_log");
}

#endif /* MR_DEBUG_RUNTIME_GRANULARITY_CONTROL */
#endif /* MR_LL_PARALLEL_CONJ */

/* forward decls to suppress gcc warnings */
void mercury_sys_init_scheduler_wrapper_init(void);
void mercury_sys_init_scheduler_wrapper_init_type_tables(void);
#ifdef  MR_DEEP_PROFILING
void mercury_sys_init_scheduler_wrapper_write_out_proc_statics(FILE *fp);
#endif

void mercury_sys_init_scheduler_wrapper_init(void)
{
#ifndef MR_HIGHLEVEL_CODE
    scheduler_module_idle();
#ifdef MR_THREAD_SAFE
    scheduler_module_idle_clean_context();
    scheduler_module_idle_dirty_context();
    scheduler_module_idle_sleep();
#endif
#endif
}

void mercury_sys_init_scheduler_wrapper_init_type_tables(void)
{
    /* no types to register */
}

#ifdef  MR_DEEP_PROFILING
void mercury_sys_init_scheduler_wrapper_write_out_proc_statics(FILE *fp)
{
    /* no proc_statics to write out */
}
#endif
