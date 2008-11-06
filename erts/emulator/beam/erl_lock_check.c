/* ``The contents of this file are subject to the Erlang Public License,
 * Version 1.1, (the "License"); you may not use this file except in
 * compliance with the License. You should have received a copy of the
 * Erlang Public License along with this software. If not, it can be
 * retrieved via the world wide web at http://www.erlang.org/.
 * 
 * Software distributed under the License is distributed on an "AS IS"
 * basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
 * the License for the specific language governing rights and limitations
 * under the License.
 * 
 * The Initial Developer of the Original Code is Ericsson Utvecklings AB.
 * Portions created by Ericsson are Copyright 1999, Ericsson Utvecklings
 * AB. All Rights Reserved.''
 * 
 *     $Id$
 */

/*
 * Description: A lock checker that checks that each thread acquires
 *              locks according to a predefined global lock order. The
 *              global lock order is used to prevent deadlocks. If the
 *              lock order is violated, an error message is printed
 *              and the emulator aborts. The lock checker is only
 *              intended to be enabled when debugging.
 *
 * Author: Rickard Green
 */

#ifdef HAVE_CONFIG_H
#  include "config.h"
#endif

/* Needed for VxWorks va_arg */
#include "sys.h"

#ifdef ERTS_ENABLE_LOCK_CHECK

#include "erl_lock_check.h"
#include "erl_term.h"
#include "erl_threads.h"

typedef struct {
    char *name;
    char *internal_order;
} erts_lc_lock_order_t;

/*
 * Global lock order for locks in the emulator.
 *
 * Locks early (low indexes) in the 'erts_lock_order' array should be
 * locked before locks late (high indexes) in the array. Each lock has
 * a name which is set on initialization. If multiple locks with the
 * same name are used, either an immediate Erlang term (e.g. internal
 * pid) or the address of the lock is used for internal lock order.
 * The immediate Erlang term used for internal lock order is also set
 * on initialization. Locks with small immediate Erlang terms should
 * be locked before locks with large immediate Erlang terms, and
 * locks with small addresses should be locked before locks with
 * large addresses. The immediate terms and adresses (boxed pointers)
 * are compared as unsigned integers not as Erlang terms.
 *
 * Once a spinlock or rw(spin)lock has been locked, the thread is not
 * allowed to lock mutexes, rwmutexes or process locks until all
 * spinlocks and rwlocks have been unlocked. This restriction is not
 * reflected by the lock order below, but the lock checker will still
 * check for violations of this restriction.
 */
static erts_lc_lock_order_t erts_lock_order[] = {
    /*
     *	"Lock name"				"Internal lock order
     *  					 description (NULL
     *						 if only one lock use
     *						 the lock name)"
     */
#ifdef ERTS_SMP
    {	"driver_lock",				"driver_name"		},
    {	"port_lock",				"port_id"		},
#endif
    {	"port_data_lock",			"address"		},
#ifdef ERTS_SMP
    {	"bif_timers",				NULL			},
    {	"reg_tab",				NULL			},
    {	"proc_main",				"pid"			},
    {	"nodes_monitors",			NULL			},
    {   "driver_list",                          NULL                    },
    {	"proc_link",				"pid"			},
    {	"proc_msgq",				"pid"			},
    {	"dist_entry",				"address"		},
    {	"proc_status",				"pid"			},
    {	"proc_tab",				NULL			},
    {	"db_tab",				"address"		},
    {	"meta_pid_to_tab",			NULL 			},
    {	"meta_pid_to_fixed_tab",		NULL 			},
    {	"meta_name_tab",	         	"address"		},
    {	"meta_main_tab_slot",			"address"		},
    {	"meta_main_tab_main",			NULL 			},
    {	"node_table",				NULL			},
    {	"dist_table",				NULL			},
    {	"sys_tracers",				NULL			},
    {	"trace_pattern",			NULL			},
    {	"module_tab",				NULL			},
    {	"export_tab",				NULL			},
    {	"fun_tab",				NULL			},
    {	"environ",				NULL			},
#endif
    {	"asyncq",				"address"		},
#ifndef ERTS_SMP
    {	"async_ready",				NULL			},
#endif
    {	"efile_drv",				"address"		},
#if defined(ENABLE_CHILD_WAITER_THREAD) || defined(ERTS_SMP)
    {	"child_status",				NULL			},
#endif
    {	"drv_ev_state_grow",			NULL,   		}, 
    {	"drv_ev_state",				"address"		},
    {	"safe_hash",				"address"		},
    {   "pollset_rm_list",                      NULL                    },
    {   "removed_fd_pre_alloc_lock",            NULL                    },
    {   "state_prealloc",                       NULL                    },
    {	"schdlq",				NULL			},
    {	"multi_scheduling_block",		NULL			},
    {	"pollset",				"address"		},
#ifdef __WIN32__
    {	"pollwaiter",				"address"		},
    {   "break_waiter_lock",                    NULL                    },
#endif /* __WIN32__ */
    {	"alcu_init_atoms",			NULL			},
    {	"mseg_init_atoms",			NULL			},
    {	"drv_tsd",				NULL			},
#ifdef ERTS_SMP
    {	"sys_msg_q", 				NULL			},
    {	"atom_tab",				NULL			},
    {	"make_ref",				NULL			},
    {	"message_pre_alloc_lock",		"address"		},
    {	"ptimer_pre_alloc_lock",		"address",		},
    {	"btm_pre_alloc_lock",			NULL,			},
#endif
    {	"mtrace_op",				NULL			},
    {	"instr_x",				NULL			},
    {	"instr",				NULL			},
    {	"fix_alloc",				"index"			},
    {	"alcu_allocator",			"index"			},
    {	"mseg",					NULL			},
#ifdef ERTS_SMP
    {	"port_task_pre_alloc_lock",		"address"		},
    {	"port_taskq_pre_alloc_lock",		"address"		},
    {	"port_tasks_lock",			NULL			},
    {	"port_tab_lock",			NULL			},
    {	"xports_list_pre_alloc_lock",		"address"		},
    {	"inet_buffer_stack_lock",		NULL			},
    {	"gc_info",				NULL			},
    {	"io_wake",				NULL			},
    {	"timer_wheel",				NULL			},
    {	"system_block",				NULL			},
    {	"timeofday",				NULL			},
    {	"breakpoints",				NULL			},
    {	"pollsets_lock",			NULL			},
    {	"async_id",				NULL			},
    {	"pix_lock",				"address"		},
#endif
    {	"alloc_thr_ix_lock",			NULL			},
#ifdef ERTS_SMP
    {	"proc_lck_wtr_alloc",			NULL 			},
#ifdef __WIN32__
    {	"sys_driver_data_lock",			NULL 			}, 
#endif
#endif
#ifdef __WIN32__
#ifdef DEBUG
    {   "save_ops_lock",                        NULL                    },
#endif
#endif
    {	"mtrace_buf",				NULL			}
};

#define ERTS_LOCK_ORDER_SIZE \
  (sizeof(erts_lock_order)/sizeof(erts_lc_lock_order_t))

#define LOCK_IS_TYPE_ORDER_VIOLATION(LCK_FLG, LCKD_FLG)			\
  (((LCKD_FLG) & (ERTS_LC_FLG_LT_SPINLOCK|ERTS_LC_FLG_LT_RWSPINLOCK))	\
   && ((LCK_FLG)							\
       & ERTS_LC_FLG_LT_ALL						\
       & ~(ERTS_LC_FLG_LT_SPINLOCK|ERTS_LC_FLG_LT_RWSPINLOCK)))

static char *
lock_type(Uint16 flags)
{
    switch (flags & ERTS_LC_FLG_LT_ALL) {
    case ERTS_LC_FLG_LT_SPINLOCK:	return "[spinlock]";
    case ERTS_LC_FLG_LT_RWSPINLOCK:	return "[rw(spin)lock]";
    case ERTS_LC_FLG_LT_MUTEX:		return "[mutex]";
    case ERTS_LC_FLG_LT_RWMUTEX:	return "[rwmutex]";
    case ERTS_LC_FLG_LT_PROCLOCK:	return "[proclock]";
    default:				return "";
    }
}

static char *
rw_op_str(Uint16 flags)
{
    switch (flags & ERTS_LC_FLG_LO_READ_WRITE) {
    case ERTS_LC_FLG_LO_READ_WRITE:
	return " (rw)";
    case ERTS_LC_FLG_LO_READ:
	return " (r)";
    case ERTS_LC_FLG_LO_WRITE:
	erts_fprintf(stderr, "\nInternal error\n");
	abort();
    default:
	break;
    }
    return "";
}

typedef struct erts_lc_locked_lock_t_ erts_lc_locked_lock_t;
struct erts_lc_locked_lock_t_ {
    erts_lc_locked_lock_t *next;
    erts_lc_locked_lock_t *prev;
    Eterm extra;
    Sint16 id;
    Uint16 flags;
};

typedef struct {
    erts_lc_locked_lock_t *first;
    erts_lc_locked_lock_t *last;
} erts_lc_locked_lock_list_t;

typedef struct erts_lc_locked_locks_t_ erts_lc_locked_locks_t;
struct erts_lc_locked_locks_t_ {
    char *thread_name;
    erts_tid_t tid;
    erts_lc_locked_locks_t *next;
    erts_lc_locked_locks_t *prev;
    erts_lc_locked_lock_list_t locked;
    erts_lc_locked_lock_list_t required;
};

typedef union erts_lc_free_block_t_ erts_lc_free_block_t;
union erts_lc_free_block_t_ {
    erts_lc_free_block_t *next;
    erts_lc_locked_lock_t lock;
};

static ethr_tsd_key locks_key;

static erts_lc_locked_locks_t *erts_locked_locks;

static erts_lc_free_block_t *free_blocks;

#ifdef ERTS_LC_STATIC_ALLOC
#define ERTS_LC_FB_CHUNK_SIZE 10000
#else
#define ERTS_LC_FB_CHUNK_SIZE 10
#endif

#ifdef ETHR_HAVE_NATIVE_LOCKS
static ethr_spinlock_t free_blocks_lock;
#define ERTS_LC_LOCK	ethr_spin_lock
#define ERTS_LC_UNLOCK	ethr_spin_unlock
#else
static ethr_mutex free_blocks_lock;
#define ERTS_LC_LOCK	ethr_mutex_lock
#define ERTS_LC_UNLOCK	ethr_mutex_unlock
#endif

static ERTS_INLINE void
lc_lock(void)
{
    if (ERTS_LC_LOCK(&free_blocks_lock) != 0)
	abort();
}

static ERTS_INLINE void
lc_unlock(void)
{
    if (ERTS_LC_UNLOCK(&free_blocks_lock) != 0)
	abort();
}

static ERTS_INLINE void lc_free(void *p)
{
    erts_lc_free_block_t *fb = (erts_lc_free_block_t *) p;
#ifdef DEBUG
    memset((void *) p, 0xdf, sizeof(erts_lc_free_block_t));
#endif
    lc_lock();
    fb->next = free_blocks;
    free_blocks = fb;
    lc_unlock();   
}

#ifdef ERTS_LC_STATIC_ALLOC

static void *lc_core_alloc(void)
{
    lc_unlock();
    erts_fprintf(stderr, "Lock checker out of memory!\n");
    abort();
}

#else

static void *lc_core_alloc(void)
{
    int i;
    erts_lc_free_block_t *fbs;
    lc_unlock();
    fbs = (erts_lc_free_block_t *) malloc(sizeof(erts_lc_free_block_t)
					  * ERTS_LC_FB_CHUNK_SIZE);
    if (!fbs) {
	erts_fprintf(stderr, "Lock checker failed to allocate memory!\n");
	abort();
    }
    for (i = 1; i < ERTS_LC_FB_CHUNK_SIZE - 1; i++) {
#ifdef DEBUG
	memset((void *) &fbs[i], 0xdf, sizeof(erts_lc_free_block_t));
#endif
	fbs[i].next = &fbs[i+1];
    }
#ifdef DEBUG
    memset((void *) &fbs[ERTS_LC_FB_CHUNK_SIZE-1],
	   0xdf, sizeof(erts_lc_free_block_t));
#endif
    lc_lock();
    fbs[ERTS_LC_FB_CHUNK_SIZE-1].next = free_blocks;
    free_blocks = &fbs[1];
    return (void *) &fbs[0];
}

#endif

static ERTS_INLINE void *lc_alloc(void)
{
    void *res;
    lc_lock();
    if (!free_blocks)
	res = lc_core_alloc();
    else {
	res = (void *) free_blocks;
	free_blocks = free_blocks->next;
    }
    lc_unlock();
    return res;
}


static erts_lc_locked_locks_t *
create_locked_locks(char *thread_name)
{
    erts_lc_locked_locks_t *l_lcks = malloc(sizeof(erts_lc_locked_locks_t));
    if (!l_lcks)
	abort();

    l_lcks->thread_name = strdup(thread_name ? thread_name : "unknown");
    if (!l_lcks->thread_name)
	abort();

    l_lcks->tid = erts_thr_self();
    l_lcks->required.first = NULL;
    l_lcks->required.last = NULL;
    l_lcks->locked.first = NULL;
    l_lcks->locked.last = NULL;
    l_lcks->prev = NULL;
    lc_lock();
    l_lcks->next = erts_locked_locks;
    if (erts_locked_locks)
	erts_locked_locks->prev = l_lcks;
    erts_locked_locks = l_lcks;
    lc_unlock();
    erts_tsd_set(locks_key, (void *) l_lcks);
    return l_lcks;
}

static void
destroy_locked_locks(erts_lc_locked_locks_t *l_lcks)
{
    ASSERT(l_lcks->thread_name);
    free((void *) l_lcks->thread_name);
    ASSERT(l_lcks->required.first == NULL);
    ASSERT(l_lcks->required.last == NULL);
    ASSERT(l_lcks->locked.first == NULL);
    ASSERT(l_lcks->locked.last == NULL);

    lc_lock();
    if (l_lcks->prev)
	l_lcks->prev->next = l_lcks->next;
    else {
	ASSERT(erts_locked_locks == l_lcks);
	erts_locked_locks = l_lcks->next;
    }

    if (l_lcks->next)
	l_lcks->next->prev = l_lcks->prev;
    lc_unlock();

    free((void *) l_lcks);

}

static ERTS_INLINE erts_lc_locked_locks_t *
get_my_locked_locks(void)
{
    return erts_tsd_get(locks_key);
}

static ERTS_INLINE erts_lc_locked_locks_t *
make_my_locked_locks(void)
{
    erts_lc_locked_locks_t *l_lcks = get_my_locked_locks();
    if (l_lcks)
	return l_lcks;
    else
	return create_locked_locks(NULL);
}

static ERTS_INLINE erts_lc_locked_lock_t *
new_locked_lock(erts_lc_lock_t *lck, Uint16 op_flags)
{
    erts_lc_locked_lock_t *l_lck = (erts_lc_locked_lock_t *) lc_alloc();
    l_lck->next = NULL;
    l_lck->prev = NULL;
    l_lck->id = lck->id;
    l_lck->extra = lck->extra;
    l_lck->flags = lck->flags | op_flags;
    return l_lck;
}

static void
print_lock2(char *prefix, Sint16 id, Eterm extra, Uint16 flags, char *suffix)
{
    char *lname = (0 <= id && id < ERTS_LOCK_ORDER_SIZE
		   ? erts_lock_order[id].name
		   : "unknown");
    if (is_boxed(extra))
	erts_fprintf(stderr,
		     "%s'%s:%p%s'%s%s",
		     prefix,
		     lname,
		     boxed_val(extra),
		     lock_type(flags),
		     rw_op_str(flags),
		     suffix);
    else
	erts_fprintf(stderr,
		     "%s'%s:%T%s'%s%s",
		     prefix,
		     lname,
		     extra,
		     lock_type(flags),
		     rw_op_str(flags),
		     suffix);
}

static void
print_lock(char *prefix, erts_lc_lock_t *lck, char *suffix)
{
    print_lock2(prefix, lck->id, lck->extra, lck->flags, suffix);
}

static void
print_curr_locks(erts_lc_locked_locks_t *l_lcks)
{
    erts_lc_locked_lock_t *l_lck;
    if (!l_lcks || !l_lcks->locked.first)
	erts_fprintf(stderr,
		     "Currently no locks are locked by the %s thread.\n",
		     l_lcks->thread_name);
    else {
	erts_fprintf(stderr,
		     "Currently these locks are locked by the %s thread:\n",
		     l_lcks->thread_name);
	for (l_lck = l_lcks->locked.first; l_lck; l_lck = l_lck->next)
	    print_lock2("  ", l_lck->id, l_lck->extra, l_lck->flags, "\n");
    }
}

static void
print_lock_order(void)
{
    int i;
    erts_fprintf(stderr, "Lock order:\n");
    for (i = 1; i < ERTS_LOCK_ORDER_SIZE; i++) {
	if (erts_lock_order[i].internal_order)
	    erts_fprintf(stderr,
			 "  %s:%s\n",
			 erts_lock_order[i].name,
			 erts_lock_order[i].internal_order);
	else
	    erts_fprintf(stderr, "  %s\n", erts_lock_order[i].name);
    }
}

static void
uninitialized_lock(void)
{
    erts_fprintf(stderr, "Performing operations on uninitialized lock!\n");
    print_curr_locks(get_my_locked_locks());
    abort();
}

static void
lock_twice(char *prefix, erts_lc_locked_locks_t *l_lcks, erts_lc_lock_t *lck,
	   Uint16 op_flags)
{
    erts_fprintf(stderr, "%s%s", prefix, rw_op_str(op_flags));
    print_lock(" ", lck, " lock which is already locked by thread!\n");
    print_curr_locks(l_lcks);
    abort();
}

static void
unlock_op_mismatch(erts_lc_locked_locks_t *l_lcks, erts_lc_lock_t *lck,
		   Uint16 op_flags)
{
    erts_fprintf(stderr, "Unlocking%s ", rw_op_str(op_flags));
    print_lock("", lck, " lock which mismatch previous lock operation!\n");
    print_curr_locks(l_lcks);
    abort();
}

static void
unlock_of_not_locked(erts_lc_locked_locks_t *l_lcks, erts_lc_lock_t *lck)
{
    print_lock("Unlocking ", lck, " lock which is not locked by thread!\n");
    print_curr_locks(l_lcks);
    abort();
}

static void
lock_order_violation(erts_lc_locked_locks_t *l_lcks, erts_lc_lock_t *lck)
{
    print_lock("Lock order violation occured when locking ", lck, "!\n");
    print_curr_locks(l_lcks);
    print_lock_order();
    abort();
}

static void
type_order_violation(char *op, erts_lc_locked_locks_t *l_lcks,
		     erts_lc_lock_t *lck)
{
    erts_fprintf(stderr, "Lock type order violation occured when ");
    print_lock(op, lck, "!\n");
    ASSERT(l_lcks);
    print_curr_locks(l_lcks);
    abort();
}

static void
lock_mismatch(erts_lc_locked_locks_t *l_lcks, int exact,
	      int failed_have, erts_lc_lock_t *have, int have_len,
	      int failed_have_not, erts_lc_lock_t *have_not, int have_not_len)
{
    int i;
    erts_fprintf(stderr, "Lock mismatch found!\n");
    if (failed_have >= 0) {
	ASSERT(have && have_len > failed_have);
	print_lock2("At least the ",
		   have[failed_have].id, have[failed_have].extra, 0,
		   " lock is not locked when it should have been\n");
    }
    else if (failed_have_not >= 0) {
	ASSERT(have_not && have_not_len > failed_have_not);
	print_lock2("At least the ",
		    have_not[failed_have_not].id,
		    have_not[failed_have_not].extra,
		    0,
		    " lock is locked when it should not have been\n");
    }
    if (exact) {
	if (!have || have_len <= 0)
	    erts_fprintf(stderr,
			 "Thread should not have any locks locked at all\n");
	else {
	    erts_fprintf(stderr,
			 "Thread should have these and only these locks "
			 "locked:\n");
	    for (i = 0; i < have_len; i++)
		print_lock2("  ", have[i].id, have[i].extra, 0, "\n");
	}
    }
    else {
	if (have && have_len > 0) {
	    erts_fprintf(stderr,
			 "Thread should at least have these locks locked:\n");
	    for (i = 0; i < have_len; i++)
		print_lock2("  ", have[i].id, have[i].extra, 0, "\n");
	}
	if (have_not && have_not_len > 0) {
	    erts_fprintf(stderr,
			 "Thread should at least not have these locks "
			 "locked:\n");
	    for (i = 0; i < have_not_len; i++)
		print_lock2("  ", have_not[i].id, have_not[i].extra, 0, "\n");
	}
    }
    print_curr_locks(l_lcks);
    abort();
}

static void
unlock_of_required_lock(erts_lc_locked_locks_t *l_lcks, erts_lc_lock_t *lck)
{
    print_lock("Unlocking required ", lck, " lock!\n");
    print_curr_locks(l_lcks);
    abort();
}

static void
unrequire_of_not_required_lock(erts_lc_locked_locks_t *l_lcks, erts_lc_lock_t *lck)
{
    print_lock("Unrequire on ", lck, " lock not required!\n");
    print_curr_locks(l_lcks);
    abort();
}

static void
require_twice(erts_lc_locked_locks_t *l_lcks, erts_lc_lock_t *lck)
{
    print_lock("Require on ", lck, " lock already required!\n");
    print_curr_locks(l_lcks);
    abort();
}

static void
required_not_locked(erts_lc_locked_locks_t *l_lcks, erts_lc_lock_t *lck)
{
    print_lock("Required ", lck, " lock not locked!\n");
    print_curr_locks(l_lcks);
    abort();
}


static void
thread_exit_handler(void)
{
    erts_lc_locked_locks_t *l_lcks = get_my_locked_locks();
    if (l_lcks) {
	if (l_lcks->locked.first) {
	    erts_fprintf(stderr,
			 "Thread exiting while having locked locks!\n");
	    print_curr_locks(l_lcks);
	    abort();
	}
	destroy_locked_locks(l_lcks);
	/* erts_tsd_set(locks_key, NULL); */
    }
}

void
erts_lc_set_thread_name(char *thread_name)
{
    erts_lc_locked_locks_t *l_lcks = get_my_locked_locks();
    if (!l_lcks)
	(void) create_locked_locks(thread_name);
    else {
	ASSERT(l_lcks->thread_name);
	free((void *) l_lcks->thread_name);
	l_lcks->thread_name = strdup(thread_name ? thread_name : "unknown");
	if (!l_lcks->thread_name)
	    abort();
    }
}

int
erts_lc_assert_failed(char *file, int line, char *assertion)
{
    erts_fprintf(stderr, "%s:%d: Lock check assertion \"%s\" failed!\n",
		 file, line, assertion);
    print_curr_locks(get_my_locked_locks());
    abort();
    return 0;
}

void erts_lc_fail(char *fmt, ...)
{
    va_list args;
    erts_fprintf(stderr, "Lock check failed: ");
    va_start(args, fmt);
    erts_vfprintf(stderr, fmt, args);
    va_end(args);
    erts_fprintf(stderr, "\n");
    print_curr_locks(get_my_locked_locks());
    abort();
}


Sint16
erts_lc_get_lock_order_id(char *name)
{
    int i;

    if (!name || name[0] == '\0')
	erts_fprintf(stderr, "Missing lock name\n");
    else {
	for (i = 0; i < ERTS_LOCK_ORDER_SIZE; i++)
	    if (strcmp(erts_lock_order[i].name, name) == 0)
		return i;
	erts_fprintf(stderr,
		     "Lock name '%s' missing in lock order "
		     "(update erl_lock_check.c)\n",
		     name);
    }
    abort();
    return (Sint16) -1;
}


static int
find_lock(erts_lc_locked_lock_t **l_lcks, erts_lc_lock_t *lck)
{
    erts_lc_locked_lock_t *l_lck = *l_lcks;

    if (l_lck) {
	if (l_lck->id == lck->id && l_lck->extra == lck->extra) {
	    if ((l_lck->flags & lck->flags) == lck->flags)
		return 1;
	    return 0;
	}
	else if (l_lck->id < lck->id
		 || (l_lck->id == lck->id
		     && l_lck->extra < lck->extra)) {
	    for (l_lck = l_lck->next; l_lck; l_lck = l_lck->next) {
		if (l_lck->id > lck->id
		    || (l_lck->id == lck->id
			&& l_lck->extra >= lck->extra)) {
		    *l_lcks = l_lck;
		    if (l_lck->id == lck->id
			&& l_lck->extra == lck->extra
			&& ((l_lck->flags & lck->flags) == lck->flags))
			    return 1;
		    return 0;
		}
	    }
	}
	else {
	    for (l_lck = l_lck->prev; l_lck; l_lck = l_lck->prev) {
		if (l_lck->id < lck->id
		    || (l_lck->id == lck->id
			&& l_lck->extra <= lck->extra)) {
		    *l_lcks = l_lck;
		    if (l_lck->id == lck->id
			&& l_lck->extra == lck->extra
			&& ((l_lck->flags & lck->flags) == lck->flags))
			return 1;
		    return 0;
		}
	    }
	}
    }
    return 0;
}

static int
find_id(erts_lc_locked_lock_t **l_lcks, Sint16 id)
{
    erts_lc_locked_lock_t *l_lck = *l_lcks;

    if (l_lck) {
	if (l_lck->id == id)
	    return 1;
	else if (l_lck->id < id) {
	    for (l_lck = l_lck->next; l_lck; l_lck = l_lck->next) {
		if (l_lck->id >= id) {
		    *l_lcks = l_lck;
		    if (l_lck->id == id)
			return 1;
		    return 0;
		}
	    }
	}
	else {
	    for (l_lck = l_lck->prev; l_lck; l_lck = l_lck->prev) {
		if (l_lck->id <= id) {
		    *l_lcks = l_lck;
		    if (l_lck->id == id)
			return 1;
		    return 0;
		}
	    }
	}
    }
    return 0;
}

void
erts_lc_have_locks(int *resv, erts_lc_lock_t *locks, int len)
{
    erts_lc_locked_locks_t *l_lcks = get_my_locked_locks();
    int i;

    if (!l_lcks) {
	for (i = 0; i < len; i++)
	    resv[i] = 0;
    }
    else {
	erts_lc_locked_lock_t *l_lck = l_lcks->locked.first;
	for (i = 0; i < len; i++)
	    resv[i] = find_lock(&l_lck, &locks[i]);
    }
}

void
erts_lc_have_lock_ids(int *resv, int *ids, int len)
{
    erts_lc_locked_locks_t *l_lcks = get_my_locked_locks();
    int i;

    if (!l_lcks) {
	for (i = 0; i < len; i++)
	    resv[i] = 0;
    }
    else {
	erts_lc_locked_lock_t *l_lck = l_lcks->locked.first;
	for (i = 0; i < len; i++)
	    resv[i] = find_id(&l_lck, ids[i]);
    }
}

void
erts_lc_check(erts_lc_lock_t *have, int have_len,
	      erts_lc_lock_t *have_not, int have_not_len)
{
    int i;
    erts_lc_locked_locks_t *l_lcks = get_my_locked_locks();
    erts_lc_locked_lock_t *l_lck;
    
    if (have && have_len > 0) {
	if (!l_lcks)
	    lock_mismatch(NULL, 0,
			  -1, have, have_len,
			  -1, have_not, have_not_len);
	l_lck = l_lcks->locked.first;
	for (i = 0; i < have_len; i++) {
	    if (!find_lock(&l_lck, &have[i]))
		lock_mismatch(l_lcks, 0,
			      i, have, have_len,
			      -1, have_not, have_not_len);
	}
    }
    if (have_not && have_not_len > 0 && l_lcks) {
	l_lck = l_lcks->locked.first;
	for (i = 0; i < have_not_len; i++) {
	    if (find_lock(&l_lck, &have_not[i]))
		lock_mismatch(l_lcks, 0,
			      -1, have, have_len,
			      i, have_not, have_not_len);
	}
    }
}

void
erts_lc_check_exact(erts_lc_lock_t *have, int have_len)
{
    erts_lc_locked_locks_t *l_lcks = get_my_locked_locks();
    if (!l_lcks) {
	if (have && have_len > 0)
	    lock_mismatch(NULL, 1,
			  -1, have, have_len,
			  -1, NULL, 0);
    }
    else {
	int i;
	erts_lc_locked_lock_t *l_lck = l_lcks->locked.first;
	for (i = 0; i < have_len; i++) {
	    if (!find_lock(&l_lck, &have[i]))
		lock_mismatch(l_lcks, 1,
			      i, have, have_len,
			      -1, NULL, 0);
	}
	for (i = 0, l_lck = l_lcks->locked.first; l_lck; l_lck = l_lck->next)
	    i++;
	if (i != have_len)
	    lock_mismatch(l_lcks, 1,
			  -1, have, have_len,
			  -1, NULL, 0);
    }
}

int
erts_lc_trylock_force_busy_flg(erts_lc_lock_t *lck, Uint16 op_flags)
{
#ifdef ERTS_LC_DO_NOT_FORCE_BUSY_TRYLOCK_ON_LOCK_ORDER_VIOLATION
    return 0;
#else
    /*
     * Force busy trylock if locking doesn't follow lock order.
     * This in order to make sure that caller can handle
     * the situation without causing a lock order violation.
     */
    erts_lc_locked_locks_t *l_lcks;

    if (lck->inited != ERTS_LC_INITITALIZED)
	uninitialized_lock();

    if (lck->id < 0)
	return 0;

    l_lcks = get_my_locked_locks();

    if (!l_lcks || !l_lcks->locked.first) {
	ASSERT(!l_lcks || !l_lcks->locked.last);
	return 0;
    }
    else {
	erts_lc_locked_lock_t *tl_lck;

	ASSERT(l_lcks->locked.last);

#if 0 /* Ok when trylocking I guess... */
	if (LOCK_IS_TYPE_ORDER_VIOLATION(lck->flags, l_lcks->locked.last->flags))
	    type_order_violation("trylocking ", l_lcks, lck);
#endif

	if (l_lcks->locked.last->id < lck->id
	    || (l_lcks->locked.last->id == lck->id
		&& l_lcks->locked.last->extra < lck->extra))
	    return 0;

	/*
	 * Lock order violation
	 */


	/* Check that we are not trying to lock this lock twice */
	for (tl_lck = l_lcks->locked.last; tl_lck; tl_lck = tl_lck->prev) {
	    if (tl_lck->id < lck->id
		|| (tl_lck->id == lck->id && tl_lck->extra <= lck->extra)) {
		if (tl_lck->id == lck->id && tl_lck->extra == lck->extra)
		    lock_twice("Trylocking", l_lcks, lck, op_flags);
		break;
	    }
	}

#ifndef ERTS_LC_ALLWAYS_FORCE_BUSY_TRYLOCK_ON_LOCK_ORDER_VIOLATION
	/* We only force busy if a lock order violation would occur
	   and when on an even millisecond. */
	{
	    erts_thr_timeval_t time;
	    erts_thr_time_now(&time);

	    if ((time.tv_nsec / 1000000) & 1)
		return 0;
	}
#endif

	return 1;
    }
#endif
}

void erts_lc_trylock_flg(int locked, erts_lc_lock_t *lck, Uint16 op_flags)
{
    erts_lc_locked_locks_t *l_lcks;
    erts_lc_locked_lock_t *l_lck;

    if (lck->inited != ERTS_LC_INITITALIZED)
	uninitialized_lock();

    if (lck->id < 0)
	return;

    l_lcks = make_my_locked_locks();
    l_lck = locked ? new_locked_lock(lck, op_flags) : NULL;

    if (!l_lcks->locked.last) {
	ASSERT(!l_lcks->locked.first);
	if (locked)
	    l_lcks->locked.first = l_lcks->locked.last = l_lck;
    }
    else {
	erts_lc_locked_lock_t *tl_lck;
#if 0 /* Ok when trylocking I guess... */
	if (LOCK_IS_TYPE_ORDER_VIOLATION(lck->flags, l_lcks->locked.last->flags))
	    type_order_violation("trylocking ", l_lcks, lck);
#endif

	for (tl_lck = l_lcks->locked.last; tl_lck; tl_lck = tl_lck->prev) {
	    if (tl_lck->id < lck->id
		|| (tl_lck->id == lck->id && tl_lck->extra <= lck->extra)) {
		if (tl_lck->id == lck->id && tl_lck->extra == lck->extra)
		    lock_twice("Trylocking", l_lcks, lck, op_flags);
		if (locked) {
		    l_lck->next = tl_lck->next;
		    l_lck->prev = tl_lck;
		    if (tl_lck->next)
			tl_lck->next->prev = l_lck;
		    else
			l_lcks->locked.last = l_lck;
		    tl_lck->next = l_lck;
		}
		return;
	    }
	}

	if (locked) {
	    l_lck->next = l_lcks->locked.first;
	    l_lcks->locked.first->prev = l_lck;
	    l_lcks->locked.first = l_lck;
	}
    }

}

void erts_lc_require_lock_flg(erts_lc_lock_t *lck, Uint16 op_flags)
{
    erts_lc_locked_locks_t *l_lcks = make_my_locked_locks();
    erts_lc_locked_lock_t *l_lck = l_lcks->locked.first;
    if (!find_lock(&l_lck, lck))
	required_not_locked(l_lcks, lck);
    l_lck = new_locked_lock(lck, op_flags);
    if (!l_lcks->required.last) {
	ASSERT(!l_lcks->required.first);
	l_lck->next = l_lck->prev = NULL;
	l_lcks->required.first = l_lcks->required.last = l_lck;
    }
    else {
	erts_lc_locked_lock_t *l_lck2;
	ASSERT(l_lcks->required.first);
	for (l_lck2 = l_lcks->required.last;
	     l_lck2;
	     l_lck2 = l_lck2->prev) {
	    if (l_lck2->id < lck->id
		|| (l_lck2->id == lck->id && l_lck2->extra < lck->extra))
		break;
	    else if (l_lck2->id == lck->id && l_lck2->extra == lck->extra)
		require_twice(l_lcks, lck);
	}
	if (!l_lck2) {
	    l_lck->next = l_lcks->required.first;
	    l_lck->prev = NULL;
	    l_lcks->required.first->prev = l_lck;
	    l_lcks->required.first = l_lck;
	}
	else {
	    l_lck->next = l_lck2->next;
	    if (l_lck->next) {
		ASSERT(l_lcks->required.last != l_lck2);
		l_lck->next->prev = l_lck;
	    }
	    else {
		ASSERT(l_lcks->required.last == l_lck2);
		l_lcks->required.last = l_lck;
	    }
	    l_lck->prev = l_lck2;
	    l_lck2->next = l_lck;		
	}
    }
}

void erts_lc_unrequire_lock_flg(erts_lc_lock_t *lck, Uint16 op_flags)
{
    erts_lc_locked_locks_t *l_lcks = make_my_locked_locks();
    erts_lc_locked_lock_t *l_lck = l_lcks->locked.first;
    if (!find_lock(&l_lck, lck))
	required_not_locked(l_lcks, lck);
    l_lck = l_lcks->required.first;
    if (!find_lock(&l_lck, lck))
	unrequire_of_not_required_lock(l_lcks, lck);
    if (l_lck->prev) {
	ASSERT(l_lcks->required.first != l_lck);
	l_lck->prev->next = l_lck->next;
    }
    else {
	ASSERT(l_lcks->required.first == l_lck);
	l_lcks->required.first = l_lck->next;
    }
    if (l_lck->next) {
	ASSERT(l_lcks->required.last != l_lck);
	l_lck->next->prev = l_lck->prev;
    }
    else {
	ASSERT(l_lcks->required.last == l_lck);
	l_lcks->required.last = l_lck->prev;
    }
    lc_free((void *) l_lck);
}

void erts_lc_lock_flg(erts_lc_lock_t *lck, Uint16 op_flags)
{
    erts_lc_locked_locks_t *l_lcks;
    erts_lc_locked_lock_t *l_lck;

    if (lck->inited != ERTS_LC_INITITALIZED)
	uninitialized_lock();

    if (lck->id < 0)
	return;

    l_lcks = make_my_locked_locks();
    l_lck = new_locked_lock(lck, op_flags);

    if (!l_lcks->locked.last) {
	ASSERT(!l_lcks->locked.first);
	l_lcks->locked.last = l_lcks->locked.first = l_lck;
    }
    else if (l_lcks->locked.last->id < lck->id
	     || (l_lcks->locked.last->id == lck->id
		 && l_lcks->locked.last->extra < lck->extra)) {
	if (LOCK_IS_TYPE_ORDER_VIOLATION(lck->flags, l_lcks->locked.last->flags))
	    type_order_violation("locking ", l_lcks, lck);
	l_lck->prev = l_lcks->locked.last;
	l_lcks->locked.last->next = l_lck;
	l_lcks->locked.last = l_lck;
    }
    else if (l_lcks->locked.last->id == lck->id && l_lcks->locked.last->extra == lck->extra)
	lock_twice("Locking", l_lcks, lck, op_flags);
    else
	lock_order_violation(l_lcks, lck);
}

void erts_lc_unlock_flg(erts_lc_lock_t *lck, Uint16 op_flags)
{
    erts_lc_locked_locks_t *l_lcks;
    erts_lc_locked_lock_t *l_lck;

    if (lck->inited != ERTS_LC_INITITALIZED)
	uninitialized_lock();

    if (lck->id < 0)
	return;

    l_lcks = get_my_locked_locks();

    if (l_lcks) {
	l_lck = l_lcks->required.first;
	if (find_lock(&l_lck, lck))
	    unlock_of_required_lock(l_lcks, lck);
    }

    for (l_lck = l_lcks ? l_lcks->locked.last : NULL; l_lck; l_lck = l_lck->prev) {
	if (l_lck->id == lck->id && l_lck->extra == lck->extra) {
	    if ((l_lck->flags & ERTS_LC_FLG_LO_ALL) != op_flags)
		unlock_op_mismatch(l_lcks, lck, op_flags);
	    if (l_lck->prev)
		l_lck->prev->next = l_lck->next;
	    else
		l_lcks->locked.first = l_lck->next;
	    if (l_lck->next)
		l_lck->next->prev = l_lck->prev;
	    else
		l_lcks->locked.last = l_lck->prev;
	    lc_free((void *) l_lck);
	    return;
	}
    }
    
    unlock_of_not_locked(l_lcks, lck);
}

void erts_lc_might_unlock_flg(erts_lc_lock_t *lck, Uint16 op_flags)
{
    erts_lc_locked_locks_t *l_lcks;
    erts_lc_locked_lock_t *l_lck;

    if (lck->inited != ERTS_LC_INITITALIZED)
	uninitialized_lock();

    if (lck->id < 0)
	return;

    l_lcks = get_my_locked_locks();

    if (l_lcks) {
	l_lck = l_lcks->required.first;
	if (find_lock(&l_lck, lck))
	    unlock_of_required_lock(l_lcks, lck);
    }

    l_lck = l_lcks->locked.first;
    if (!find_lock(&l_lck, lck))
	unlock_of_not_locked(l_lcks, lck);
}

int
erts_lc_trylock_force_busy(erts_lc_lock_t *lck)
{
    return erts_lc_trylock_force_busy_flg(lck, 0);
}

void
erts_lc_trylock(int locked, erts_lc_lock_t *lck)
{
    erts_lc_trylock_flg(locked, lck, 0);
}

void
erts_lc_lock(erts_lc_lock_t *lck)
{
    erts_lc_lock_flg(lck, 0);
}

void
erts_lc_unlock(erts_lc_lock_t *lck)
{
    erts_lc_unlock_flg(lck, 0);
}

void erts_lc_might_unlock(erts_lc_lock_t *lck)
{
    erts_lc_might_unlock_flg(lck, 0);
}

void erts_lc_require_lock(erts_lc_lock_t *lck)
{
    erts_lc_require_lock_flg(lck, 0);
}

void erts_lc_unrequire_lock(erts_lc_lock_t *lck)
{
    erts_lc_unrequire_lock_flg(lck, 0);
}

void
erts_lc_init_lock(erts_lc_lock_t *lck, char *name, Uint16 flags)
{
    lck->id = erts_lc_get_lock_order_id(name);
    lck->extra = make_boxed(&lck->extra);
    lck->flags = flags;
    lck->inited = ERTS_LC_INITITALIZED;
}

void
erts_lc_init_lock_x(erts_lc_lock_t *lck, char *name, Uint16 flags, Eterm extra)
{
    lck->id = erts_lc_get_lock_order_id(name);
    lck->extra = extra;
    lck->flags = flags;
    lck->inited = ERTS_LC_INITITALIZED;
}

void
erts_lc_destroy_lock(erts_lc_lock_t *lck)
{
    if (lck->inited != ERTS_LC_INITITALIZED)
	uninitialized_lock();

    lck->inited = 0;
    lck->id = -1;
    lck->extra = THE_NON_VALUE;
    lck->flags = 0;
}

void
erts_lc_init(void)
{
#ifdef ERTS_LC_STATIC_ALLOC
    int i;
    static erts_lc_free_block_t fbs[ERTS_LC_FB_CHUNK_SIZE];
    for (i = 0; i < ERTS_LC_FB_CHUNK_SIZE - 1; i++) {
#ifdef DEBUG
	memset((void *) &fbs[i], 0xdf, sizeof(erts_lc_free_block_t));
#endif
	fbs[i].next = &fbs[i+1];
    }
#ifdef DEBUG
    memset((void *) &fbs[ERTS_LC_FB_CHUNK_SIZE-1],
	   0xdf, sizeof(erts_lc_free_block_t));
#endif
    fbs[ERTS_LC_FB_CHUNK_SIZE-1].next = NULL;
    free_blocks = &fbs[0]; 
#else /* #ifdef ERTS_LC_STATIC_ALLOC */
    free_blocks = NULL;
#endif /* #ifdef ERTS_LC_STATIC_ALLOC */

#ifdef ETHR_HAVE_NATIVE_LOCKS
    if (ethr_spinlock_init(&free_blocks_lock) != 0)
	abort();
#else
    if (ethr_mutex_init(&free_blocks_lock) != 0)
	abort();
#endif

    erts_tsd_key_create(&locks_key);
}

void
erts_lc_late_init(void)
{
    erts_thr_install_exit_handler(thread_exit_handler);
}


/*
 * erts_lc_pll(): print locked locks...
 */
void
erts_lc_pll(void)
{
    print_curr_locks(get_my_locked_locks());
}


#endif /* #ifdef ERTS_ENABLE_LOCK_CHECK */
