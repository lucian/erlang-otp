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

#ifdef HAVE_CONFIG_H
#  include "config.h"
#endif

#include "sys.h"
#include "erl_vm.h"
#include "global.h"
#include "erl_process.h"
#include "error.h"
#include "erl_driver.h"
#include "bif.h"
#include "external.h"
#include "beam_load.h"
#include "big.h"
#include "erl_bits.h"
#include "beam_catches.h"
#include "erl_binary.h"

#ifdef HIPE
#include "hipe_mode_switch.h"
#include "hipe_bif0.h"
#endif

/* Imported from drv/gzio.c. Why not in any header file? */
ErlDrvBinary* gzinflate_buffer(char*, int);

#define MAX_OPARGS 8
#define CALLED    0
#define DEFINED   1
#define EXPORTED  2

#ifdef NO_JUMP_TABLE
#  define BeamOpCode(Op) ((Uint)(Op))
#else
#  define BeamOpCode(Op) ((Eterm)beam_ops[Op])
#endif

#if defined(WORDS_BIGENDIAN)
# define NATIVE_ENDIAN(F)			\
  if ((F).val & BSF_NATIVE) {			\
     (F).val &= ~(BSF_LITTLE|BSF_NATIVE);	\
  } else {}
#else
# define NATIVE_ENDIAN(F)			\
  if ((F).val & BSF_NATIVE) {			\
      (F).val &= ~BSF_NATIVE;			\
      (F).val |= BSF_LITTLE;			\
  } else {}
#endif

/*
 * Errors returned from tranform_engine().
 */
#define TE_OK 0
#define TE_FAIL (-1)
#define TE_SHORT_WINDOW (-2)

typedef struct {
    Uint value;			/* Value of label (NULL if not known yet). */
    Uint patches;		/* Index (into code buffer) to first location
				 * which must be patched with the value of this label.
				 */
} Label;

/*
 * Type for a operand for a generic instruction.
 */

typedef struct {
    unsigned type;		/* Type of operand. */
    Uint val;			/* Value of operand. */
    Uint bigarity;		/* Arity for bignumbers (only). */
} GenOpArg;

/*
 * A generic operation.
 */

typedef struct genop {
    int op;			/* Opcode. */
    int arity;			/* Number of arguments. */
    GenOpArg def_args[MAX_OPARGS]; /* Default buffer for arguments. */
    GenOpArg* a;		/* The arguments. */
    struct genop* next;		/* Next genop. */
} GenOp;

/*
 * The allocation unit for generic blocks.
 */
  
typedef struct genop_block {
    GenOp genop[32];
    struct genop_block* next;
} GenOpBlock;

/*
 * This structure contains information for a imported function or BIF.
 */
typedef struct {
    Eterm module;		/* Tagged atom for module. */
    Eterm function;		/* Tagged atom for function. */
    int arity;			/* Arity. */
    Uint patches;		/* Index to locations in code to
				 * eventually patch with a pointer into
				 * the export entry.
				 */
    BifFunction bf;		/* Pointer to BIF function if BIF;
				 * NULL otherwise.
				 */
} ImportEntry;

/*
 * This structure contains information for a function exported from a module.
 */

typedef struct {
    Eterm function;		/* Tagged atom for function. */
    int arity;			/* Arity. */
    Eterm* address;		/* Address to function in code. */
} ExportEntry;

#define MakeIffId(a, b, c, d) \
  (((Uint) (a) << 24) | ((Uint) (b) << 16) | ((Uint) (c) << 8) | (Uint) (d))

#define ATOM_CHUNK 0
#define CODE_CHUNK 1
#define STR_CHUNK 2
#define IMP_CHUNK 3
#define EXP_CHUNK 4
#define NUM_MANDATORY 5

#define LAMBDA_CHUNK 5
#define ATTR_CHUNK 6
#define COMPILE_CHUNK 7

#define NUM_CHUNK_TYPES (sizeof(chunk_types)/sizeof(chunk_types[0]))

/*
 * An array with all chunk types recognized by the loader.
 */

static Uint chunk_types[] = {
    /*
     * Mandatory chunk types -- these MUST be present.
     */
    MakeIffId('A', 't', 'o', 'm'), /* 0 */
    MakeIffId('C', 'o', 'd', 'e'), /* 1 */
    MakeIffId('S', 't', 'r', 'T'), /* 2 */
    MakeIffId('I', 'm', 'p', 'T'), /* 3 */
    MakeIffId('E', 'x', 'p', 'T'), /* 4 */

    /*
     * Optional chunk types -- the loader will use them if present.
     */
    MakeIffId('F', 'u', 'n', 'T'), /* 5 */
    MakeIffId('A', 't', 't', 'r'), /* 6 */
    MakeIffId('C', 'I', 'n', 'f'), /* 7 */
};

/*
 * This structure keeps load-time information about a lambda.
 */

typedef struct {
    ErlFunEntry* fe;		/* Entry in fun table. */
    unsigned label;		/* Label of function entry. */
    Uint32 num_free;		/* Number of free variables. */
    Eterm function;		/* Name of local function. */
    int arity;			/* Arity (including free variables). */
} Lambda;

/*
 * This structure contains all information about the module being loaded.
 */  

typedef struct {
    /*
     * The current logical file within the binary.
     */

    char* file_name;		/* Name of file we are reading (usually chunk name). */
    byte* file_p;		/* Current pointer within file. */
    unsigned file_left;		/* Number of bytes left in file. */

    /*
     * The following are used mainly for diagnostics.
     */

    Eterm group_leader;		/* Group leader (for diagnostics). */
    Eterm module;		/* Tagged atom for module name. */
    Eterm function;		/* Tagged atom for current function
				 * (or 0 if none).
				 */
    unsigned arity;		/* Arity for current function. */

    /*
     * All found chunks.
     */

    struct {
	byte* start;		/* Start of chunk (in binary). */
	unsigned size;		/* Size of chunk. */
    } chunks[NUM_CHUNK_TYPES];

    /*
     * Used for code loading (mainly).
     */

    byte* code_start;		/* Start of code file. */
    unsigned code_size;		/* Size of code file. */
    int specific_op;		/* Specific opcode (-1 if not found). */
    int num_functions;		/* Number of functions in module. */
    int num_labels;		/* Number of labels. */
    int code_buffer_size;	/* Size of code buffer in words.  */
    Eterm* code;		/* Loaded code. */
    int ci;			/* Current index into loaded code. */
    Label* labels;
    Uint put_strings;		/* Linked list of put_string instructions. */
    Uint bs_put_strings;	/* Linked list of bs_put_string instructions. */
    Uint catches;		/* Linked list of catch_yf instructions. */
    unsigned loaded_size;	/* Final size of code when loaded. */
    byte mod_md5[16];		/* MD5 for module code. */

    /*
     * Atom table.
     */

    int num_atoms;		/* Number of atoms in atom table. */
    Eterm* atom;		/* Atom table. */

    int num_exps;		/* Number of exports. */
    ExportEntry* export;	/* Pointer to export table. */

    int num_imports;		/* Number of imports. */
    ImportEntry* import;	/* Import entry (translated information). */

    /*
     * Generic instructions.
     */
    GenOp* genop;		/* The last generic instruction seen. */
    GenOp* free_genop;		/* List of free genops. */
    GenOpBlock* genop_blocks;	/* List of all block of allocated genops. */

    /*
     * Heap for floats and bignums.
     */

    Uint* temp_heap;		/* Pointer to base of temporary heap. */
    Uint temp_heap_top;		/* Index of next free word on heap. */
    Uint temp_heap_size;	/* Points to the word beyond the heap. */

    /*
     * Lambda table.
     */

    int num_lambdas;		/* Number of lambdas in table. */
    int lambdas_allocated;	/* Size of allocated lambda table. */
    Lambda* lambdas;		/* Pointer to lambdas. */
    Lambda def_lambdas[16];	/* Default storage for lambda table. */
    char* lambda_error;		/* Delayed missing 'FunT' error. */

    /*
     * Bit syntax.
     */

    int generate_heap_bin;	/* Safe to generate a heap bin. */
} LoaderState;

typedef struct {
    unsigned num_functions;	/* Number of functions. */
    Eterm* func_tab[1];		/* Pointers to each function. */
} LoadedCode;

#define GetTagAndValue(Stp, Tag, Val) \
   do { \
      Uint __w; \
      GetByte(Stp, __w); \
      Tag = __w & 0x07; \
      if ((__w & 0x08) == 0) { \
	 Val = __w >> 4; \
      } else if ((__w & 0x10) == 0) { \
	 Val = ((__w >> 5) << 8); \
	 GetByte(Stp, __w); \
	 Val |= __w; \
      } else { \
	if (!get_int_val(Stp, __w, &(Val))) goto load_error; \
      } \
   } while (0)

#define TempAlloc(Stp, Sz) \
    (((Stp)->temp_heap_size <= ((Stp)->temp_heap_top + (Sz))) ? \
        temp_alloc((Stp), (Sz)) : \
        ((Stp)->temp_heap_top = (Stp)->temp_heap_top + (Sz), \
         (Stp)->temp_heap_top - (Sz)))

#define LoadError0(Stp, Fmt) \
    do { \
	load_printf(__LINE__, Stp, Fmt); \
	goto load_error; \
    } while (0)

#define LoadError1(Stp, Fmt, Arg1) \
    do { \
	load_printf(__LINE__, stp, Fmt, Arg1); \
	goto load_error; \
    } while (0)

#define LoadError2(Stp, Fmt, Arg1, Arg2) \
    do { \
	load_printf(__LINE__, Stp, Fmt, Arg1, Arg2); \
	goto load_error; \
    } while (0)

#define LoadError3(Stp, Fmt, Arg1, Arg2, Arg3) \
    do { \
	load_printf(__LINE__, stp, Fmt, Arg1, Arg2, Arg3); \
	goto load_error; \
    } while (0)

#define EndOfFile(Stp) (stp->file_left == 0)

#define GetInt(Stp, N, Dest) \
    if (Stp->file_left < (N)) { \
       short_file(__LINE__, Stp, (N)); \
       goto load_error; \
    } else { \
       int __n = (N); \
       Uint __result = 0; \
       Stp->file_left -= (unsigned) __n; \
       while (__n-- > 0) { \
          __result = __result << 8 | *Stp->file_p++; \
       } \
       Dest = __result; \
    } while (0)

#define GetByte(Stp, Dest) \
    if ((Stp)->file_left < 1) { \
       short_file(__LINE__, (Stp), 1); \
       goto load_error; \
    } else { \
       Dest = *(Stp)->file_p++; \
       (Stp)->file_left--; \
    }

#define GetString(Stp, Dest, N) \
    if (Stp->file_left < (N)) { \
       short_file(__LINE__, Stp, (N)); \
       goto load_error; \
    } else { \
       Dest = (Stp)->file_p; \
       (Stp)->file_p += (N); \
       (Stp)->file_left -= (N); \
    }

#define GetAtom(Stp, Index, Dest) \
    if ((Index) == 0) { \
       LoadError1((Stp), "bad atom index 0 ([]) in %s", stp->file_name); \
    } else if ((Index) < (Stp)->num_atoms) { \
       Dest = (Stp)->atom[(Index)]; \
    } else { \
       LoadError2((Stp), "bad atom index %d in %s", (Index), stp->file_name); \
    }

#ifdef DEBUG
# define GARBAGE 0xCC
# define DEBUG_INIT_GENOP(Dst) memset(Dst, GARBAGE, sizeof(GenOp))
#else
# define DEBUG_INIT_GENOP(Dst)
#endif

#define NEW_GENOP(Stp, Dst) \
  do { \
    if ((Stp)->free_genop == NULL) { \
       new_genop((Stp)); \
    } \
   Dst = (Stp)->free_genop; \
   (Stp)->free_genop = (Stp)->free_genop->next; \
   DEBUG_INIT_GENOP(Dst); \
   (Dst)->a = (Dst)->def_args; \
  } while (0)

#define FREE_GENOP(Stp, Genop) \
 do { \
   if ((Genop)->a != (Genop)->def_args) { erts_sl_free((Genop)->a); } \
   (Genop)->next = (Stp)->free_genop; \
   (Stp)->free_genop = (Genop); \
 } while (0)

#define GENOP_ARITY(Genop, Arity) \
  do { \
   ASSERT((Genop)->a == (Genop)->def_args); \
   (Genop)->arity = (Arity); \
   (Genop)->a = erts_safe_sl_alloc_from(257, \
					(Genop)->arity * sizeof(GenOpArg)); \
  } while (0)


static int bin_load(Eterm group_leader, Eterm* modp, byte* bytes, int unloaded_size);
static void init_state(LoaderState* stp);
static int insert_new_code(Eterm group_leader, Eterm module,
			   Eterm* code, Uint size, Uint catches);
static int scan_iff_file(LoaderState* stp, Uint* chunk_types,
			 Uint num_types, Uint num_mandatory);
static int load_atom_table(LoaderState* stp);
static int load_import_table(LoaderState* stp);
static int read_export_table(LoaderState* stp);
static int read_lambda_table(LoaderState* stp);
static int read_code_header(LoaderState* stp);
static int load_code(LoaderState* stp);
static GenOp* gen_element(LoaderState* stp, GenOpArg Fail, GenOpArg Index,
			  GenOpArg Tuple, GenOpArg Dst);
static GenOp* gen_split_values(LoaderState* stp, GenOpArg S, GenOpArg Fail,
			       GenOpArg Size, GenOpArg* Rest);
static GenOp* gen_select_val(LoaderState* stp, GenOpArg S, GenOpArg Fail,
			     GenOpArg Size, GenOpArg* Rest);
static GenOp* gen_select_big(LoaderState* stp, GenOpArg S, GenOpArg Fail,
			     GenOpArg Size, GenOpArg* Rest);
static GenOp* const_select_val(LoaderState* stp, GenOpArg S, GenOpArg Fail,
			       GenOpArg Size, GenOpArg* Rest);
static GenOp* gen_func_info(LoaderState* stp, GenOpArg mod, GenOpArg Func,
			    GenOpArg arity, GenOpArg label);
static int freeze_code(LoaderState* stp);

static void final_touch(LoaderState* stp);
static void short_file(int line, LoaderState* stp, unsigned needed);
static void load_printf(int line, LoaderState* context, char *fmt, ...);
static int transform_engine(LoaderState* st);
static void id_to_string(Uint id, char* s);
static void new_genop(LoaderState* stp);
static int get_int_val(LoaderState* stp, Uint len_code, Uint* result);
static int get_erlang_integer(LoaderState* stp, Uint len_code, Uint* result);
static Uint temp_alloc(LoaderState* stp, unsigned needed);
static int new_label(LoaderState* stp);
static int genopargcompare(GenOpArg* a, GenOpArg* b);
static Eterm exported_from_module(Process* p, Eterm mod);
static Eterm functions_in_module(Process* p, Eterm mod);
static Eterm attributes_for_module(Process* p, Eterm mod);
static Eterm compilation_info_for_module(Process* p, Eterm mod);
static Eterm native_addresses(Process* p, Eterm mod);
int patch_funentries(Eterm Patchlist);
int patch(Eterm Addresses, Uint fe);

static int must_swap_floats;

/*
 * The following variables keep a sorted list of address ranges for
 * each module.  It allows us to quickly find a function given an
 * instruction pointer.
 */
Range* modules = NULL;	    /* Sorted lists of module addresses. */
int num_loaded_modules;	    /* Number of loaded modules. */
int allocated_modules;	    /* Number of slots allocated. */
Range* mid_module = NULL;   /* Cached search start point */

/**********************************************************************/


void init_load(void)
{
    FloatDef f;

    beam_catches_init();

    f.fd = 1.0;
    must_swap_floats = (f.fw[0] == 0);

    allocated_modules = 128;
    modules = (Range *) sys_alloc_from(250, allocated_modules*sizeof(Range));
    mid_module = modules;
    num_loaded_modules = 0;
}

static void
define_file(LoaderState* stp, char* name, int idx)
{
    stp->file_name = name;
    stp->file_p = stp->chunks[idx].start;
    stp->file_left = stp->chunks[idx].size;
}

int
erts_load_module(Eterm group_leader, /* Group leader or NIL if none. */
		 Eterm* modp,	/*
				 * Module name as an atom (NIL to not check).
				 * On return, contains the actual module name.
				 */
		 byte* code,	/* Points to the code to load */
		 int size)	/* Size of code to load. */
{
    ErlDrvBinary* bin;
    int result;

    if ((bin = (ErlDrvBinary *) gzinflate_buffer(code, size)) == NULL) {
	return -1;
    }
    result = bin_load(group_leader, modp, bin->orig_bytes, bin->orig_size);
    driver_free_binary(bin);
    return result;
}


static int
bin_load(Eterm group_leader, Eterm* modp, byte* bytes, int unloaded_size)
{
    LoaderState state;
    int rval = -1;

    init_state(&state);
    state.module = *modp;
    state.group_leader = group_leader;

    /*
     * Scan the IFF file.
     */

    state.file_name = "IFF header for Beam file";
    state.file_p = bytes;
    state.file_left = unloaded_size;
    if (!scan_iff_file(&state, chunk_types, NUM_CHUNK_TYPES, NUM_MANDATORY)) {
	goto load_error;
    }

    /*
     * Read the header for the code chunk.
     */

    define_file(&state, "code chunk header", CODE_CHUNK);
    if (!read_code_header(&state)) {
	goto load_error;
    }

    /*
     * Read the atom table.
     */

    define_file(&state, "atom table", ATOM_CHUNK);
    if (!load_atom_table(&state)) {
	goto load_error;
    }

    /*
     * Read the import table.
     */

    define_file(&state, "import table", IMP_CHUNK);
    if (!load_import_table(&state)) {
	goto load_error;
    }

    /*
     * Read the lambda (fun) table.
     */

    if (state.chunks[LAMBDA_CHUNK].size > 0) {
	define_file(&state, "lambda (fun) table", LAMBDA_CHUNK);
	if (!read_lambda_table(&state)) {
	    goto load_error;
	}
    }

    /*
     * Load the code chunk.
     */

    state.file_name = "code chunk";
    state.file_p = state.code_start;
    state.file_left = state.code_size;
    if (!load_code(&state) || !freeze_code(&state)) {
	goto load_error;
    }

    /*
     * Read and validate the export table.  (This must be done after
     * loading the code, because it contains labels.)
     */
    
    define_file(&state, "export table", EXP_CHUNK);
    if (!read_export_table(&state)) {
	goto load_error;
    }

    /*
     * Ready for the final touch: fixing the export table entries for
     * exported and imported functions.  This can't fail.
     */
    
    rval = insert_new_code(state.group_leader, state.module,
			   state.code, state.loaded_size, state.catches);
    if (rval < 0) {
	goto load_error;
    }
    final_touch(&state);

    /*
     * Loading succeded.
     */
    rval = 0;
    state.code = NULL;		/* Prevent code from being freed. */
    *modp = state.module;

 load_error:
    if (state.code != 0) {
	sys_free(state.code);
    }
    if (state.labels != NULL) {
	erts_sl_free((void *) state.labels);
    }
    if (state.atom != NULL) {
	erts_sl_free((void *) state.atom);
    }
    if (state.import != NULL) {
	erts_sl_free((void *) state.import);
    }
    if (state.export != NULL) {
	erts_sl_free((void *) state.export);
    }
    if (state.temp_heap != NULL) {
	erts_sl_free((void *) state.temp_heap);
    }
    if (state.lambdas != state.def_lambdas) {
	erts_sl_free((void *) state.lambdas);
    }
    while (state.genop_blocks) {
	GenOpBlock* next = state.genop_blocks->next;
	erts_sl_free((void *) state.genop_blocks);
	state.genop_blocks = next;
    }

    return rval;
}


static void
init_state(LoaderState* stp)
{
    stp->function = THE_NON_VALUE; /* Function not known yet */
    stp->arity = 0;
    stp->specific_op = -1;
    stp->genop = NULL;
    stp->atom = NULL;
    stp->code = NULL;
    stp->labels = NULL;
    stp->import = NULL;
    stp->export = NULL;
    stp->free_genop = NULL;
    stp->genop_blocks = NULL;
    stp->temp_heap = NULL;
    stp->temp_heap_top = 0;
    stp->temp_heap_size = 0;
    stp->num_lambdas = 0;
    stp->lambdas_allocated = sizeof(stp->def_lambdas)/sizeof(Lambda);
    stp->lambdas = stp->def_lambdas;
    stp->lambda_error = NULL;
    stp->generate_heap_bin = 0;
}

static int
insert_new_code(Eterm group_leader, Eterm module, Eterm* code, Uint size, Uint catches)
{
    Module* modp;
    int rval;
    int i;

    if ((rval = beam_make_current_old(module)) < 0) {
	cerr_pos = 0;
	erl_printf(CBUF, "Module ");
	print_atom(atom_val(module), CBUF);
	erl_printf(CBUF, " must be purged before loading\n");
	send_error_to_logger(group_leader);
	return rval;
    }

    /*
     * Update module table.
     */

    modp = erts_put_module(module);
    modp->code = code;
    modp->code_length = size;
    modp->catches = catches;

    /*
     * Update address table (used for finding a function from a PC value).
     */

    if (num_loaded_modules == allocated_modules) {
	allocated_modules *= 2;
	modules = (Range *) sys_realloc(modules, allocated_modules * sizeof(Range));
    }
    for (i = num_loaded_modules; i > 0; i--) {
	if (code > modules[i-1].start) {
	    break;
	}
	modules[i] = modules[i-1];
    }
    modules[i].start = code;
    modules[i].end = (Eterm *) (((byte *)code) + size);
    num_loaded_modules++;
    mid_module = &modules[num_loaded_modules/2];
    return 0;
}

static int
scan_iff_file(LoaderState* stp, Uint* chunk_types, Uint num_types, Uint num_mandatory)
{
    MD5_CTX context;
    Uint id;
    Uint count;
    int i;

    /*
     * The old magic identifier for Beam files.
     */

    static char beam_magic[6] = {0x7F, 'B', 'E', 'A', 'M', '!'};

    /*
     * Be kind to old Beam files.
     */

    if (stp->file_left >= sizeof(beam_magic) &&
	memcmp(stp->file_p, beam_magic, sizeof(beam_magic)) == 0) {
	LoadError0(stp, "can't load Beam files for OTP R4 or earlier (sorry)");
    }

    /*
     * The binary must start with an IFF 'FOR1' chunk.
     */

    GetInt(stp, 4, id);
    if (id != MakeIffId('F', 'O', 'R', '1')) {
	LoadError0(stp, "not a BEAM file: no IFF 'FOR1' chunk");
    }

    /*
     * Retrieve the chunk size and verify it.  If the size is equal to
     * or less than the size of the binary, it is ok and we will use it
     * as the limit for the logical file size.
     */

    GetInt(stp, 4, count);
    if (count > stp->file_left) {
	LoadError2(stp, "form size %ld greater than size %ld of binary",
		  count, stp->file_left);
    }
    stp->file_left = count;

    /*
     * Verify that this is a BEAM file.
     */

    GetInt(stp, 4, id);
    if (id != MakeIffId('B', 'E', 'A', 'M')) {
	LoadError0(stp, "not a BEAM file: IFF form type is not 'BEAM'");
    }

    /*
     * Initialize the chunks[] array in the state.
     */

    for (i = 0; i < num_types; i++) {
	stp->chunks[i].start = NULL;
	stp->chunks[i].size = 0;
    }

    /*
     * Now we can go ahead and read all chunks in the BEAM form.
     */

    while (!EndOfFile(stp)) {

	/*
	 * Read the chunk id and verify that it contains ASCII characters.
	 */
	GetInt(stp, 4, id);
	for (i = 0; i < 4; i++) {
	    unsigned c = (id >> i*8) & 0xff;
	    if (c < ' ' || c > 0x7E) {
		LoadError1(stp, "non-ascii garbage '%lx' instead of chunk type id",
			   id);
	    }
	}

	/*
	 * Read the count and verify it.
	 */

	GetInt(stp, 4, count);
	if (count > stp->file_left) {
	    LoadError2(stp, "chunk size %ld for '%lx' greater than size %ld of binary",
		       count, stp->file_left);
	}

	/*
	 * See if the chunk is useful for the loader.
	 */
	for (i = 0; i < num_types; i++) {
	    if (chunk_types[i] == id) {
		stp->chunks[i].start = stp->file_p;
		stp->chunks[i].size = count;
		break;
	    }
	}

	/*
	 * Go on to the next chunk.
	 */
	count = 4*((count+3)/4);
	stp->file_p += count;
	stp->file_left -= count;
    }

    /*
     * At this point, we have read the entire IFF file, and we
     * know that it is syntactically correct.
     *
     * Now check that it contains all mandatory chunks. At the
     * same time calculate the MD5 for the module.
     */

    MD5Init(&context);
    for (i = 0; i < num_mandatory; i++) {
	if (stp->chunks[i].start != NULL) {
	    MD5Update(&context, stp->chunks[i].start, stp->chunks[i].size);
	} else {
	    char sbuf[5];

	    id_to_string(chunk_types[i], sbuf);
	    LoadError1(stp, "mandatory chunk of type '%s' not found\n", sbuf);
	}
    }
    if (num_mandatory >= LAMBDA_CHUNK && stp->chunks[LAMBDA_CHUNK].start != 0) {
	MD5Update(&context, stp->chunks[LAMBDA_CHUNK].start,
		  stp->chunks[LAMBDA_CHUNK].size);
    }
    MD5Final(stp->mod_md5, &context);
    return 1;

 load_error:
    return 0;
}


static int
load_atom_table(LoaderState* stp)
{
    int i;

    GetInt(stp, 4, stp->num_atoms);
    stp->num_atoms++;
    stp->atom = erts_safe_sl_alloc_from(252,
					erts_next_heap_size((stp->num_atoms *
							     sizeof(Eterm)),
							    0));

    /*
     * Read all atoms.
     */

    for (i = 1; i < stp->num_atoms; i++) {
	byte* atom;
	Uint n;

	GetByte(stp, n);
	GetString(stp, atom, n);
	stp->atom[i] = am_atom_put(atom, n);
    }

    /*
     * Check the module name if a module name was given.
     */

    if (is_nil(stp->module)) {
	stp->module = stp->atom[1];
    } else if (stp->atom[1] != stp->module) {
	char sbuf[256];
	Atom* ap;

	ap = atom_tab(atom_val(stp->atom[1]));
	memcpy(sbuf, ap->name, ap->len);
	sbuf[ap->len] = '\0';
	LoadError1(stp, "module name in object code is %s", sbuf);
    }

    return 1;

 load_error:
    return 0;
}


static int
load_import_table(LoaderState* stp)
{
    int i;

    GetInt(stp, 4, stp->num_imports);
    stp->import = erts_safe_sl_alloc_from(253,
					  erts_next_heap_size(stp->num_imports *
							      sizeof(ImportEntry),
							      0));
    for (i = 0; i < stp->num_imports; i++) {
	int n;
	Eterm mod;
	Eterm func;
	Uint arity;
	Export* e;

	GetInt(stp, 4, n);
	if (n >= stp->num_atoms) {
	    LoadError2(stp, "import entry %d: invalid atom number %d", i, n);
	}
	mod = stp->import[i].module = stp->atom[n];
	GetInt(stp, 4, n);
	if (n >= stp->num_atoms) {
	    LoadError2(stp, "import entry %d: invalid atom number %d", i, n);
	}
	func = stp->import[i].function = stp->atom[n];
	GetInt(stp, 4, arity);
	if (arity > MAX_REG) {
	    LoadError2(stp, "import entry %d: invalid arity %d", i, arity);
	}
	stp->import[i].arity = arity;
	stp->import[i].patches = 0;
	stp->import[i].bf = NULL;

	/*
	 * If the export entry refers to a BIF, get the pointer to
	 * the BIF function.
	 */
	if ((e = erts_find_export_entry(mod, func, arity)) != NULL) {
	    if (e->code[3] == (Uint) em_apply_bif) {
		stp->import[i].bf = (BifFunction) e->code[4];
	    }
	}
    }
    return 1;

 load_error:
    return 0;
}


static int
read_export_table(LoaderState* stp)
{
    int i;

    GetInt(stp, 4, stp->num_exps);
    if (stp->num_exps > stp->num_functions) {
	LoadError2(stp, "%d functions exported; only %d functions defined",
		   stp->num_exps, stp->num_functions);
    }
    stp->export
	= (ExportEntry *) erts_safe_sl_alloc_from(254,
						  (stp->num_exps
						   * sizeof(ExportEntry)));

    for (i = 0; i < stp->num_exps; i++) {
	Uint n;
	Uint value;

	GetInt(stp, 4, n);
	GetAtom(stp, n, stp->export[i].function);
	GetInt(stp, 4, n);
	if (n > MAX_REG) {
	    LoadError2(stp, "export table entry %d: absurdly high arity %d", i, n);
	}
	stp->export[i].arity = n;
	GetInt(stp, 4, n);
	if (n >= stp->num_labels) {
	    LoadError3(stp, "export table entry %d: invalid label %d (highest defined label is %d)", i, n, stp->num_labels);
	}
	value = stp->labels[n].value;
	if (value == 0) {
	    LoadError2(stp, "export table entry %d: label %d not resolved", i, n);
	}
	stp->export[i].address = stp->code + value;
    }
    return 1;

 load_error:
    return 0;
}

static int
read_lambda_table(LoaderState* stp)
{
    int i;

    GetInt(stp, 4, stp->num_lambdas);
    stp->lambdas_allocated = stp->num_lambdas;
    stp->lambdas = (Lambda *) erts_safe_sl_alloc(stp->num_lambdas
						 * sizeof(Lambda));
    for (i = 0; i < stp->num_lambdas; i++) {
	Uint n;
	Uint32 Index;
	Uint32 OldUniq;
	ErlFunEntry* fe;
	Uint arity;

	GetInt(stp, 4, n);	/* Function. */
	GetAtom(stp, n, stp->lambdas[i].function);
	GetInt(stp, 4, arity);
	if (arity > MAX_REG) {
	    LoadError2(stp, "lambda entry %d: absurdly high arity %d", i, arity);
	}
	stp->lambdas[i].arity = arity;
	GetInt(stp, 4, n);
	if (n >= stp->num_labels) {
	    LoadError3(stp, "lambda entry %d: invalid label %d (highest defined label is %d)",
		       i, n, stp->num_labels);
	}
	stp->lambdas[i].label = n;
	GetInt(stp, 4, Index);
	GetInt(stp, 4, stp->lambdas[i].num_free);
	GetInt(stp, 4, OldUniq);
	fe = erts_put_fun_entry2(stp->module, OldUniq, i, stp->mod_md5,
				 Index, arity-stp->lambdas[i].num_free);
	stp->lambdas[i].fe = fe;
    }
    return 1;

 load_error:
    return 0;
}


static int
read_code_header(LoaderState* stp)
{
    unsigned head_size;
    unsigned version;
    unsigned opcode_max;
    int i;

    /*
     * Read size of sub-header for code information and from it calculate
     * where the code begins.  Also, use the size to limit the file size
     * for header reading, so that we automatically get an error if the
     * size is set too small.
     */

    GetInt(stp, 4, head_size);
    stp->code_start = stp->file_p + head_size;
    stp->code_size = stp->file_left - head_size;
    stp->file_left = head_size;

    /*
     * Get and verify version of instruction set.
     */

    GetInt(stp, 4, version);
    if (version != BEAM_FORMAT_NUMBER) {
	LoadError2(stp, "wrong instruction set %d; expected %d",
		   version, BEAM_FORMAT_NUMBER);
    }

    /*
     * Verify the number of the highest opcode used.
     */

    GetInt(stp, 4, opcode_max);
    if (opcode_max > MAX_GENERIC_OPCODE) {
	LoadError2(stp, "use of opcode %d; this emulator supports only up to %d",
		   opcode_max, MAX_GENERIC_OPCODE);
    }

    GetInt(stp, 4, stp->num_labels);
    GetInt(stp, 4, stp->num_functions);

    /*
     * Initialize label table.
     */

    stp->labels = (Label *) erts_safe_sl_alloc_from(255,
						    (stp->num_labels
						     * sizeof(Label)));
    for (i = 0; i < stp->num_labels; i++) {
	stp->labels[i].value = 0;
	stp->labels[i].patches = 0;
    }

    /*
     * Initialize code area.
     */
    stp->code_buffer_size = erts_next_heap_size(2048 + stp->num_functions, 0);
    stp->code = (Eterm*) safe_alloc_from(251,
					  (sizeof(Eterm)
					   * stp->code_buffer_size));

    stp->code[MI_NUM_FUNCTIONS] = stp->num_functions;
    stp->ci = MI_FUNCTIONS + stp->num_functions + 1;

    stp->code[MI_ATTR_PTR] = 0;
    stp->code[MI_ATTR_SIZE_ON_HEAP] = 0;
    stp->code[MI_COMPILE_PTR] = 0;
    stp->code[MI_COMPILE_SIZE_ON_HEAP] = 0;
    stp->code[MI_NUM_BREAKPOINTS] = 0;

    stp->put_strings = 0;
    stp->bs_put_strings = 0;
    stp->catches = 0;
    return 1;

 load_error:
    return 0;
}


#define VerifyTag(Stp, Actual, Expected) \
    if (Actual != Expected) { \
       LoadError2(Stp, "bad tag %d; expected %d", Actual, Expected); \
    } else {}

#define Need(w) \
    ASSERT(ci <= code_buffer_size); \
    if (code_buffer_size < ci+(w)) { \
        code_buffer_size = erts_next_heap_size(ci+(w), 0); \
	stp->code = code = (Eterm *) safe_realloc((char *) code, \
               code_buffer_size * sizeof(Eterm)); \
    }
    


static int
load_code(LoaderState* stp)
{
    int i;
    int tmp;
    int ci;
    char* sign;
    int arg;			/* Number of current argument. */
    int num_specific;		/* Number of specific ops for current. */
    Eterm* code;
    int code_buffer_size;
    int specific;
    Uint last_label = 0;	/* Number of last label. */
    Uint function_number = 0;
    GenOp* last_op = NULL;
    GenOp** last_op_next = NULL;
    int arity;

    code = stp->code;
    code_buffer_size = stp->code_buffer_size;
    ci = stp->ci;

    for (;;) {
	int new_op;
	GenOp* tmp_op;

	ASSERT(ci <= code_buffer_size);

    get_next_instr:
	GetByte(stp, new_op);
	if (new_op >= NUM_GENERIC_OPS) {
	    LoadError1(stp, "invalid opcode %d", new_op);
	}
	if (gen_opc[new_op].name[0] == '\0') {
	    LoadError1(stp, "invalid opcode %d", new_op);
	}

	/*
	 * Create a new generic operation and put it last in the chain.
	 */
	if (last_op_next == NULL) {
	    last_op_next = &(stp->genop);
	    while (*last_op_next != NULL) {
		last_op_next = &(*last_op_next)->next;
	    }
	}

	NEW_GENOP(stp, last_op);
	last_op->next = NULL;
	last_op->op = new_op;
	*last_op_next = last_op;
	last_op_next = &(last_op->next);
	stp->specific_op = -1;

	/*
	 * Read all arguments for the current operation.
	 */

	arity = gen_opc[last_op->op].arity;
	last_op->arity = 0;
	ASSERT(arity <= MAX_OPARGS);

#define GetValue(Stp, First, Val) \
   do { \
      if (((First) & 0x08) == 0) { \
	 Val = (First) >> 4; \
      } else if (((First) & 0x10) == 0) { \
         Uint __w; \
	 GetByte(Stp, __w); \
	 Val = (((First) >> 5) << 8) | __w; \
      } else { \
	if (!get_int_val(Stp, (First), &(Val))) goto load_error; \
      } \
   } while (0)

	for (arg = 0; arg < arity; arg++) {
	    Uint first;

	    GetByte(stp, first);
	    last_op->a[arg].type = first & 0x07;
	    switch (last_op->a[arg].type) {
	    case TAG_i:
		if ((first & 0x08) == 0) {
		    last_op->a[arg].val = make_small(first >> 4);
		} else if ((first & 0x10) == 0) {
		    Uint w;
		    GetByte(stp, w);
		    ASSERT(first < 0x800);
		    last_op->a[arg].val = make_small(((first >> 5) << 8) | w);
		} else {
		    int i = get_erlang_integer(stp, first, &(last_op->a[arg].val));
		    if (i < 0) {
			goto load_error;
		    }
		    last_op->a[arg].type = i;
		}
		break;
	    case TAG_u:
		GetValue(stp, first, last_op->a[arg].val);
		break;
	    case TAG_x:
		GetValue(stp, first, last_op->a[arg].val);
		if (last_op->a[arg].val == 0) {
		    last_op->a[arg].type = TAG_r;
		}
		break;
	    case TAG_y:
		GetValue(stp, first, last_op->a[arg].val);
		last_op->a[arg].val += CP_SIZE;
		break;
	    case TAG_a:
		GetValue(stp, first, last_op->a[arg].val);
		if (last_op->a[arg].val == 0) {
		    last_op->a[arg].type = TAG_n;
		} else if (last_op->a[arg].val >= stp->num_atoms) {
		    LoadError1(stp, "bad atom index: %d", last_op->a[arg].val);
		} else {
		    last_op->a[arg].val = stp->atom[last_op->a[arg].val];
		}
		break;
	    case TAG_f:
		GetValue(stp, first, last_op->a[arg].val);
		if (last_op->a[arg].val == 0) {
		    last_op->a[arg].type = TAG_p;
		} else if (last_op->a[arg].val >= stp->num_labels) {
		    LoadError1(stp, "bad label: %d", last_op->a[arg].val);
		}
		break;
	    case TAG_h:
		GetValue(stp, first, last_op->a[arg].val);
		if (last_op->a[arg].val > 65535) {
		    LoadError1(stp, "invalid range for character data type: %u",
			       last_op->a[arg].val);
		}
		break;
	    case TAG_z:
		{
		    Uint ext_tag;
		    unsigned tag;

		    GetValue(stp, first, ext_tag);
		    switch (ext_tag) {
		    case 0:	/* Floating point number */
#ifdef ARCH_64
			last_op->a[arg].type = TAG_o;
			GetInt(stp, 8, last_op->a[arg].val);
#else
			{
			    Uint hp;
			    Uint high, low;
			    GetInt(stp, 4, high);
			    GetInt(stp, 4, low);
			    if (must_swap_floats) {
				Uint t = high;
				high = low;
				low = t;
			    }
			    hp = TempAlloc(stp, 2);
			    stp->temp_heap[hp] = high;
			    stp->temp_heap[hp+1] = low;
			    last_op->a[arg].type = TAG_o;
			    last_op->a[arg].val = hp;
			}
#endif
			break;
		    case 1:	/* List. */
			if (arg+1 != arity) {
			    LoadError0(stp, "list argument must be the last argument");
			}
			GetTagAndValue(stp, tag, last_op->a[arg].val);
			VerifyTag(stp, tag, TAG_u);
			last_op->a[arg].type = TAG_u;
			last_op->a =
			    erts_safe_sl_alloc_from(258,
						    (arity+last_op->a[arg].val)
						    *sizeof(GenOpArg));
			memcpy(last_op->a, last_op->def_args,
			       arity*sizeof(GenOpArg));
			arity += last_op->a[arg].val;
			break;
		    case 2:	/* Float register. */
			GetTagAndValue(stp, tag, last_op->a[arg].val);
			VerifyTag(stp, tag, TAG_u);
			last_op->a[arg].type = TAG_l;
			break;
		    default:
			LoadError1(stp, "invalid extended tag %d", ext_tag);
			break;
		    }
		}
		break;
	    default:
		LoadError1(stp, "bad tag %d", last_op->a[arg].type);
		break;
	    }
	    last_op->arity++;
	}
#undef GetValue

    do_transform:
	if (stp->genop == NULL) {
	    last_op_next = NULL;
	    goto get_next_instr;
	}

	if (gen_opc[stp->genop->op].transform != -1) {
	    int need;
	    tmp_op = stp->genop;

	    for (need = gen_opc[stp->genop->op].min_window-1; need > 0; need--) {
		if (tmp_op == NULL) {
		    goto get_next_instr;
		}
		tmp_op = tmp_op->next;
	    }
	    switch (transform_engine(stp)) {
	    case TE_FAIL:
		last_op_next = NULL;
		last_op = NULL;
		break;
	    case TE_OK:
		last_op_next = NULL;
		last_op = NULL;
		goto do_transform;
	    case TE_SHORT_WINDOW:
		last_op_next = NULL;
		last_op = NULL;
		goto get_next_instr;
	    }
	}

	if (stp->genop == NULL) {
	    last_op_next = NULL;
	    goto get_next_instr;
	}

	/*
	 * From the collected generic instruction, find the specific
	 * instruction.
	 */

	{
	    Uint mask[2] = {0, 0};

	    tmp_op = stp->genop;
	    arity = gen_opc[tmp_op->op].arity;
	    ASSERT(arity <= 4);
	    for (arg = 0; arg < arity; arg++) {
		mask[arg/2] |= (1 << (tmp_op->a[arg].type)) << ((arg%2)*16);
	    }
	    specific = gen_opc[tmp_op->op].specific;
	    num_specific = gen_opc[tmp_op->op].num_specific;
	    for (i = 0; i < num_specific; i++) {
		if (((opc[specific].mask[0] & mask[0]) == mask[0]) &&
		    ((opc[specific].mask[1] & mask[1]) == mask[1])) {
		    break;
		}
		specific++;
	    }
	    if (i == num_specific) {
		stp->specific_op = -1;
		for (arg = 0; arg < tmp_op->arity; arg++) {
		    /*
		     * We'll give the error message here (instead of earlier)
		     * to get a printout of the offending operation.
		     */
		    if (tmp_op->a[arg].type == TAG_h) {
			LoadError0(stp, "the character data type not supported");
		    }
		}
		LoadError0(stp, "no specific operation found");
	    }

	    stp->specific_op = specific;
	    Need(opc[stp->specific_op].sz+2); /* Extra margin for packing */
	    code[ci++] = BeamOpCode(stp->specific_op);
	}
	
	/*
	 * Load the found specific operation.
	 */

	sign = opc[stp->specific_op].sign;
	ASSERT(sign != NULL);
	arg = 0;
	while (*sign) {
	    Uint tag;

	    ASSERT(arg < stp->genop->arity);
	    tag = stp->genop->a[arg].type;
	    switch (*sign) {
	    case 'r':	/* x(0) */
	    case 'n':	/* Nil */
		VerifyTag(stp, tag_to_letter[tag], *sign);
		break;
	    case 'x':	/* x(N) */
	    case 'y':	/* y(N) */
		VerifyTag(stp, tag_to_letter[tag], *sign);
		code[ci++] = tmp_op->a[arg].val * sizeof(Eterm);
		break;
	    case 'a':		/* Tagged atom */
		VerifyTag(stp, tag_to_letter[tag], *sign);
		code[ci++] = tmp_op->a[arg].val;
		break;
	    case 'i':		/* Tagged integer */
		ASSERT(is_small(tmp_op->a[arg].val));
		VerifyTag(stp, tag_to_letter[tag], *sign);
		code[ci++] = tmp_op->a[arg].val;
		break;
	    case 'w':		/* Big number */
		{
		    Eterm* bigp;
		    Uint size;

		    VerifyTag(stp, tag_to_letter[tag], *sign);
		    bigp = stp->temp_heap+tmp_op->a[arg].val;
		    size = thing_arityval(*bigp);
		    code[ci++] = *bigp++;
		    Need(size+50);
		    while (size-- > 0) {
			code[ci++] = *bigp++;
		    }
		}
		break;
	    case 'c':		/* Tagged constant */
		switch (tag) {
		case TAG_i:
		    ASSERT(is_small(tmp_op->a[arg].val));
		    code[ci++] = tmp_op->a[arg].val;
		    break;
		case TAG_a:
		    code[ci++] = tmp_op->a[arg].val;
		    break;
		case TAG_n:
		    code[ci++] = NIL;
		    break;
		default:
		    LoadError1(stp, "bad tag %d for tagged constant",
			       tmp_op->a[arg].type);
		    break;
		}
		break;
	    case 's':	/* Any source (tagged constant or register) */
		switch (tag) {
		case TAG_r:
		    code[ci++] = make_rreg();
		    break;
		case TAG_x:
		    code[ci++] = make_xreg(tmp_op->a[arg].val);
		    break;
		case TAG_y:
		    code[ci++] = make_yreg(tmp_op->a[arg].val);
		    break;
		case TAG_i:
		    ASSERT(is_small(tmp_op->a[arg].val));
		    code[ci++] = tmp_op->a[arg].val;
		    break;
		case TAG_a:
		    code[ci++] = tmp_op->a[arg].val;
		    break;
		case TAG_n:
		    code[ci++] = NIL;
		    break;
		default:
		    LoadError1(stp, "bad tag %d for general source",
			       tmp_op->a[arg].type);
		    break;
		}
		break;
	    case 'd':	/* Destination (x(0), x(N), y(N) */
		switch (tag) {
		case TAG_r:
		    code[ci++] = make_rreg();
		    break;
		case TAG_x:
		    code[ci++] = make_xreg(tmp_op->a[arg].val);
		    break;
		case TAG_y:
		    code[ci++] = make_yreg(tmp_op->a[arg].val);
		    break;
		default:
		    LoadError1(stp, "bad tag %d for destination",
			       tmp_op->a[arg].type);
		    break;
		}
		break;
	    case 'I':	/* Untagged integer (or pointer). */
		VerifyTag(stp, tag, TAG_u);
		code[ci++] = tmp_op->a[arg].val;
		break;
	    case 't':	/* Small untagged integer -- can be packed. */
		VerifyTag(stp, tag, TAG_u);
		code[ci++] = tmp_op->a[arg].val;
		break;
	    case 'A':	/* Arity value. */
		VerifyTag(stp, tag, TAG_u);
		code[ci++] = make_arityval(tmp_op->a[arg].val);
		break;
	    case 'f':		/* Destination label */
		VerifyTag(stp, tag_to_letter[tag], *sign);
		code[ci] = stp->labels[tmp_op->a[arg].val].patches;
		stp->labels[tmp_op->a[arg].val].patches = ci;
		ci++;
		break;
	    case 'j':		/* 'f' or 'p' */
		if (tag == TAG_p) {
		    code[ci] = 0;
		} else if (tag == TAG_f) {
		    code[ci] = stp->labels[tmp_op->a[arg].val].patches;
		    stp->labels[tmp_op->a[arg].val].patches = ci;
		} else {
		    LoadError3(stp, "bad tag %d; expected %d or %d",
			       tag, TAG_f, TAG_p);
		}
		ci++;
		break;
	    case 'L':		/* Define label */
		ci--;		/* Remove label from loaded code */
		ASSERT(stp->specific_op == op_label_L);
		VerifyTag(stp, tag, TAG_u);
		last_label = tmp_op->a[arg].val;
		if (!(0 < last_label && last_label < stp->num_labels)) {
		    LoadError2(stp, "invalid label num %d (0 < label < %d)",
			       tmp_op->a[arg].val, stp->num_labels);
		}
		if (stp->labels[last_label].value != 0) {
		    LoadError1(stp, "label %d defined more than once", last_label);
		}
		stp->labels[last_label].value = ci;
		ASSERT(stp->labels[last_label].patches < ci);
		break;
	    case 'e':		/* Export entry */
		VerifyTag(stp, tag, TAG_u);
		if (tmp_op->a[arg].val >= stp->num_imports) {
		    LoadError1(stp, "invalid import table index %d", tmp_op->a[arg].val);
		}
		code[ci] = stp->import[tmp_op->a[arg].val].patches;
		stp->import[tmp_op->a[arg].val].patches = ci;
		ci++;
		break;
	    case 'b':
		VerifyTag(stp, tag, TAG_u);
		i = tmp_op->a[arg].val;
		if (i >= stp->num_imports) {
		    LoadError1(stp, "invalid import table index %d", i);
		}
		if (stp->import[i].bf == NULL) {
		    LoadError1(stp, "not a BIF: import table index %d", i);
		}
		code[ci++] = (Eterm) stp->import[i].bf;
		break;
	    case 'P':		/* Byte offset into tuple */
		VerifyTag(stp, tag, TAG_u);
		tmp = tmp_op->a[arg].val;
		code[ci++] = (Eterm) ((tmp_op->a[arg].val+1) * sizeof(Eterm *));
		break;
	    case 'o':		/* Floating point number. */
#ifdef ARCH_64
		VerifyTag(stp, tag, TAG_o);
		code[ci++] = HEADER_FLONUM;
		code[ci++] = tmp_op->a[arg].val;
		code[ci++] = 0;
#else
		{
		    Eterm* fptr;
		    VerifyTag(stp, tag, TAG_o);
		    fptr = stp->temp_heap + tmp_op->a[arg].val;
		    code[ci++] = HEADER_FLONUM;
		    code[ci++] = *fptr++;
		    code[ci++] = *fptr++;
		}
#endif
		break;
	    case 'l':		/* Floating point register. */
		VerifyTag(stp, tag_to_letter[tag], *sign);
		code[ci++] = tmp_op->a[arg].val * 2 * sizeof(Eterm);
		break;
	    default:
		LoadError1(stp, "bad argument tag: %d", *sign);
	    }
	    sign++;
	    arg++;
	}

	/*
	 * Load any list arguments using the primitive tags.
	 */

	for ( ; arg < tmp_op->arity; arg++) {
	    switch (tmp_op->a[arg].type) {
	    case TAG_u:
	    case TAG_i:
	    case TAG_a:
	    case TAG_v:
		Need(1);
		code[ci++] = tmp_op->a[arg].val;
		break;
	    case TAG_w:
		{
		    Eterm* bigp;
		    Uint size;

		    bigp = stp->temp_heap+tmp_op->a[arg].val;
		    size = thing_arityval(*bigp);
		    Need(size+1);
		    code[ci++] = *bigp++;
		    while (size-- > 0) {
			code[ci++] = *bigp++;
		    }
		}
		break;
	    case TAG_f:
		Need(1);
		code[ci] = stp->labels[tmp_op->a[arg].val].patches;
		stp->labels[tmp_op->a[arg].val].patches = ci;
		ci++;
		break;
	    case TAG_o:
		{
		    Eterm* fptr;

		    fptr = stp->temp_heap + tmp_op->a[arg].val;
		    Need(2);
		    code[ci++] = *fptr++;
		    code[ci++] = *fptr++;
		    break;
		}
	    default:
		LoadError1(stp, "unsupported primitive type %d",
			   tmp_op->a[arg].type);
	    }
	}

	/*
	 * The packing engine.
	 */
	if (opc[stp->specific_op].pack[0]) {
	    char* prog;		/* Program for packing engine. */
	    Uint stack[8];	/* Stack. */
	    Uint* sp = stack;	/* Points to next free position. */
	    Uint packed = 0;	/* Accumulator for packed operations. */
	    
	    for (prog = opc[stp->specific_op].pack; *prog; prog++) {
		switch (*prog) {
		case 'g':	/* Get instruction; push on stack. */
		    *sp++ = code[--ci];
		    break;
		case 'i':	/* Initialize packing accumulator. */
		    packed = code[--ci];
		    break;
		case '0':	/* Shift 10 steps */
		    packed = (packed << 10) | code[--ci];
		    break;
		case '2':	/* Shift 12 steps */
		    packed = (packed << 12) | code[--ci];
		    break;
		case '6':	/* Shift 16 steps */
		    packed = (packed << 16) | code[--ci];
		    break;
		case 'p':	/* Put instruction (from stack). */
		    code[ci++] = *--sp;
		    break;
		case 'P':	/* Put packed operands. */
		    *sp++ = packed;
		    packed = 0;
		    break;
		default:
		    ASSERT(0);
		}
	    }
	    ASSERT(sp == stack); /* Incorrect program? */
	}

	/*
	 * Handle a few special cases.
	 */
	switch (stp->specific_op) {
	case op_i_func_info_IaaI:
	    {
		Uint offset;

		if (function_number >= stp->num_functions) {
		    LoadError1(stp, "too many functions in module (header said %d)",
			       stp->num_functions); 
		}

		/*
		 * Save context for error messages.
		 */
		stp->function = code[ci-2];
		stp->arity = code[ci-1];

		offset = MI_FUNCTIONS + function_number;
		code[offset] = stp->labels[last_label].patches;
		stp->labels[last_label].patches = offset;
		function_number++;
#ifdef DEBUG
		ASSERT(stp->labels[0].patches == 0); /* Should not be referenced. */
		for (i = 1; i < stp->num_labels; i++) {
		    ASSERT(stp->labels[i].patches < ci);
		}
#endif
	    }
	    break;

	case op_put_string_IId:
	    {
		/*
		 * At entry:
		 *
		 * code[ci-4]	&&lb_put_string_IId
		 * code[ci-3]	length of string
		 * code[ci-2]   offset into string table
		 * code[ci-1]   destination register
		 *
		 * Since we don't know the address of the string table yet,
		 * just check the offset and length for validity, and use
		 * the instruction field as a link field to link all put_string
		 * instructions into a single linked list.  At exit:
		 *
		 * code[ci-4]	pointer to next put_string instruction (or 0
		 *		if this is the last)
		 */
		Uint offset = code[ci-2];
		Uint len = code[ci-3];
		unsigned strtab_size = stp->chunks[STR_CHUNK].size;
		if (offset > strtab_size || offset + len > strtab_size) {
		    LoadError2(stp, "invalid string reference %d, size %d", offset, len);
		}
		code[ci-4] = stp->put_strings;
		stp->put_strings = ci - 4;
	    }
	    break;

	case op_bs_put_string_II:
	    {
		/*
		 * At entry:
		 *
		 * code[ci-3]	&&lb_bs_put_string_II
		 * code[ci-2]	length of string
		 * code[ci-1]   offset into string table
		 *
		 * Since we don't know the address of the string table yet,
		 * just check the offset and length for validity, and use
		 * the instruction field as a link field to link all put_string
		 * instructions into a single linked list.  At exit:
		 *
		 * code[ci-3]	pointer to next bs_put_string instruction (or 0
		 *		if this is the last)
		 */
		Uint offset = code[ci-1];
		Uint len = code[ci-2];
		unsigned strtab_size = stp->chunks[STR_CHUNK].size;
		if (offset > strtab_size || offset + len > strtab_size) {
		    LoadError2(stp, "invalid string reference %d, size %d", offset, len);
		}
		code[ci-3] = stp->bs_put_strings;
		stp->bs_put_strings = ci - 3;
	    }
	    break;

	case op_catch_yf:
	    /* code[ci-3]	&&lb_catch_yf
	     * code[ci-2]	y-register offset in E
	     * code[ci-1]	label; index tagged as CATCH at runtime
	     */
	    code[ci-3] = stp->catches;
	    stp->catches = ci-3;
	    break;

	    /*
	     * End of code found.
	     */
	case op_int_code_end:
	    stp->code_buffer_size = code_buffer_size;
	    stp->ci = ci;
	    return 1;
	}

	/*
	 * Delete the generic instruction just loaded.
	 */
	{
	    GenOp* next = stp->genop->next;
	    FREE_GENOP(stp, stp->genop);
	    stp->genop = next;
	    goto do_transform;
	}
    }
    
#undef Need

 load_error:
    return 0;
}


#define succ(St, X, Y) ((X).type == (Y).type && (X).val + 1 == (Y).val)
#define succ2(St, X, Y) ((X).type == (Y).type && (X).val + 2 == (Y).val)
#define succ3(St, X, Y) ((X).type == (Y).type && (X).val + 3 == (Y).val)

#ifdef NO_FPE_SIGNALS 
#define no_fpe_signals(St) 1
#else
#define no_fpe_signals(St) 0
#endif

/*
 * Predicate that tests if a jump table can be used.
 */

static int
use_jump_tab(LoaderState* stp, GenOpArg Size, GenOpArg* Rest)
{
    int min, max;
    int i;

    if (Size.val < 2 || Size.val % 2 != 0) {
	return 0;
    }

    /* we may be called with sequences of tagged fixnums or atoms;
       return early in latter case, before we access the values */
    if (Rest[0].type != TAG_i || Rest[1].type != TAG_f)
	return 0;
    min = max = signed_val(Rest[0].val);
    for (i = 2; i < Size.val; i += 2) {
	if (Rest[i].type != TAG_i || Rest[i+1].type != TAG_f) {
	    return 0;
	}
	if (signed_val(Rest[i].val) < min) {
	    min = signed_val(Rest[i].val);
	} else if (max < signed_val(Rest[i].val)) {
	    max = signed_val(Rest[i].val);
	}
    }

    return max - min <= Size.val;
}

/*
 * Predicate to test if all values in a table are big numbers.
 */

static int
all_values_are_big(LoaderState* stp, GenOpArg Size, GenOpArg* Rest)
{
    int i;

    if (Size.val < 2 || Size.val % 2 != 0) {
	return 0;
    }

    for (i = 0; i < Size.val; i += 2) {
	if (Rest[i].type != TAG_w || Rest[i+1].type != TAG_f) {
	    return 0;
	}
    }

    return 1;
}


/*
 * Predicate to test if all values in a table have a fixed size.
 */

static int
fixed_size_values(LoaderState* stp, GenOpArg Size, GenOpArg* Rest)
{
    int i;

    if (Size.val < 2 || Size.val % 2 != 0) {
	return 0;
    }

    for (i = 0; i < Size.val; i += 2) {
	if (Rest[i+1].type != TAG_f)
	    return 0;
	switch (Rest[i].type) {
	case TAG_a:
	case TAG_i:
	case TAG_v:
	case TAG_o:
	    break;
	default:
	    return 0;
	}
    }

    return 1;
}

static int
mixed_types(LoaderState* stp, GenOpArg Size, GenOpArg* Rest)
{
    int i;
    Uint type;

    if (Size.val < 2 || Size.val % 2 != 0) {
	return 0;
    }

    type = Rest[0].type;
    for (i = 0; i < Size.val; i += 2) {
	if (Rest[i].type != type)
	    return 1;
    }

    return 0;
}

static int
assign_heap_bin_flag(LoaderState* stp, GenOpArg Flags, GenOpArg Bits)
{
    stp->generate_heap_bin = (Flags.val & BSF_EXACT) != 0 &&
	(Bits.val % 8) == 0 &&
	    Bits.val / 8 <= ERL_ONHEAP_BIN_LIMIT;
    return 1;
}

#define reset_heap_bin_flag(stp) (stp->generate_heap_bin = 0, 1)
#define generate_heap_bin(stp) (stp->generate_heap_bin)

/*
 * Generate an instruction for element/2.
 */

static GenOp*
gen_element(LoaderState* stp, GenOpArg Fail, GenOpArg Index,
		      GenOpArg Tuple, GenOpArg Dst)
{
    GenOp* op;

    NEW_GENOP(stp, op);
    op->op = genop_i_element_4;
    op->arity = 4;
    op->a[0] = Fail;
    op->a[1] = Index;
    op->a[2] = Tuple;
    op->a[3] = Dst;
    op->next = NULL;

    /*
     * If safe, generate a faster instruction.
     */

    if (Index.type == TAG_i && signed_val(Index.val) > 0 &&
	(Tuple.type == TAG_r || Tuple.type == TAG_x || Tuple.type == TAG_y)) {
	op->op = genop_i_fast_element_4;
	op->a[1].type = TAG_u;
	op->a[1].val = signed_val(Index.val);
    }

    return op;
}

/*
 * Generate the fastest instruction to fetch an integer from a binary.
 */

static GenOp*
gen_get_integer(LoaderState* stp, GenOpArg Fail, GenOpArg Size, GenOpArg Unit,
		GenOpArg Flags, GenOpArg Dst)
{
    GenOp* op;
    NEW_GENOP(stp, op);

    NATIVE_ENDIAN(Flags);
    if (Size.type == TAG_i) {
	if (Flags.val & BSF_ALIGNED && (Flags.val & BSF_SIGNED) == 0) {
	    Uint bits = signed_val(Size.val) * Unit.val;
	    if (bits == 8) {
		op->op = genop_i_bs_get_integer8_2;
		op->arity = 2;
		op->a[0] = Fail;
		op->a[1] = Dst;
	    } else if (bits == 16 && (Flags.val & BSF_LITTLE) == 0) {
		op->op = genop_i_bs_get_integer16_2;
		op->arity = 2;
		op->a[0] = Fail;
		op->a[1] = Dst;
	    } else if (bits == 32 && (Flags.val & BSF_LITTLE) == 0) {
		op->op = genop_i_bs_get_integer32_2;
		op->arity = 2;
		op->a[0] = Fail;
		op->a[1] = Dst;
	    } else {
		goto generic;
	    }
	} else {
	generic:
	    op->op = genop_i_bs_get_integer_imm_4;
	    op->arity = 4;
	    op->a[0] = Fail;
	    op->a[1].type = TAG_u;
	    op->a[1].val = signed_val(Size.val) * Unit.val;
	    op->a[2] = Flags;
	    op->a[3] = Dst;
	}
    } else {
	op->op = genop_i_bs_get_integer_4;
	op->arity = 4;
	op->a[0] = Fail;
	op->a[1] = Size;
	op->a[2].type = TAG_u;
	op->a[2].val = (Unit.val << 3) | Flags.val;
	op->a[3] = Dst;
    }
    op->next = NULL;
    return op;
}

/*
 * Generate the fastest instruction to fetch a binary from a binary.
 */

static GenOp*
gen_get_binary(LoaderState* stp, GenOpArg Fail, GenOpArg Size, GenOpArg Unit,
		GenOpArg Flags, GenOpArg Dst)
{
    GenOp* op;
    NEW_GENOP(stp, op);

    NATIVE_ENDIAN(Flags);
    if (Size.type == TAG_a && Size.val == am_all) {
	op->op = genop_i_bs_get_binary_all_2;
	op->arity = 2;
	op->a[0] = Fail;
	op->a[1] = Dst;
    } else if (Size.type == TAG_i) {
	op->op = genop_i_bs_get_binary_imm_4;
	op->arity = 4;
	op->a[0] = Fail;
	op->a[1].type = TAG_u;
	op->a[1].val = signed_val(Size.val) * Unit.val;
	op->a[2] = Flags;
	op->a[3] = Dst;
    } else {
	op->op = genop_i_bs_get_binary_4;
	op->arity = 4;
	op->a[0] = Fail;
	op->a[1] = Size;
	op->a[2].type = TAG_u;
	op->a[2].val = (Unit.val << 3) | Flags.val;
	op->a[3] = Dst;
    }
    op->next = NULL;
    return op;
}

static GenOp*
gen_put_binary(LoaderState* stp, GenOpArg Fail,GenOpArg Size,
	       GenOpArg Unit, GenOpArg Flags, GenOpArg Src)
{
    GenOp* op;
    NEW_GENOP(stp, op);

    NATIVE_ENDIAN(Flags);
    if (Size.type == TAG_a && Size.val == am_all) {
	op->op = genop_i_bs_put_binary_all_2;
	op->arity = 2;
	op->a[0] = Fail;
	op->a[1] = Src;
    } else if (Size.type == TAG_i) {
	op->op = genop_i_bs_put_binary_imm_3;
	op->arity = 3;
	op->a[0] = Fail;
	op->a[1].type = TAG_u;
	op->a[1].val = signed_val(Size.val) * Unit.val;
	op->a[2] = Src;
    } else {
	op->op = genop_i_bs_put_binary_4;
	op->arity = 4;
	op->a[0] = Fail;
	op->a[1] = Size;
	op->a[2].type = TAG_u;
	op->a[2].val = (Unit.val << 3) | Flags.val;
	op->a[3] = Src;
    }

    op->next = NULL;
    return op;
}

static GenOp*
gen_put_integer(LoaderState* stp, GenOpArg Fail, GenOpArg Size,
		GenOpArg Unit, GenOpArg Flags, GenOpArg Src)
{
    GenOp* op;
    NEW_GENOP(stp, op);

    NATIVE_ENDIAN(Flags);
    if (Size.type == TAG_i && signed_val(Size.val) < 0) {
	/* Negative size must fail */
	op->op = genop_badarg_1;
	op->arity = 1;
	op->a[0] = Fail;
    } else if (Size.type == TAG_i) {
	op->op = genop_i_bs_put_integer_imm_4;
	op->arity = 4;
	op->a[0] = Fail;
	op->a[1].type = TAG_u;
	op->a[1].val = signed_val(Size.val) * Unit.val;
	op->a[2] = Flags;
	op->a[3] = Src;
    } else {
	op->op = genop_i_bs_put_integer_4;
	op->arity = 4;
	op->a[0] = Fail;
	op->a[1] = Size;
	op->a[2].type = TAG_u;
	op->a[2].val = (Unit.val << 3) | Flags.val;
	op->a[3] = Src;
    }
    op->next = NULL;
    return op;
}

static GenOp*
gen_put_float(LoaderState* stp, GenOpArg Fail, GenOpArg Size,
	      GenOpArg Unit, GenOpArg Flags, GenOpArg Src)
{
    GenOp* op;
    NEW_GENOP(stp, op);

    NATIVE_ENDIAN(Flags);
    if (Size.type == TAG_i) {
	op->op = genop_i_bs_put_float_imm_4;
	op->arity = 4;
	op->a[0] = Fail;
	op->a[1].type = TAG_u;
	op->a[1].val = signed_val(Size.val) * Unit.val;
	op->a[2] = Flags;
	op->a[3] = Src;
    } else {
	op->op = genop_i_bs_put_float_4;
	op->arity = 4;
	op->a[0] = Fail;
	op->a[1] = Size;
	op->a[2].type = TAG_u;
	op->a[2].val = (Unit.val << 3) | Flags.val;
	op->a[3] = Src;
    }
    op->next = NULL;
    return op;
}

/*
 * Generate an instruction to fetch a float from a binary.
 */

static GenOp*
gen_get_float(LoaderState* stp, GenOpArg Fail, GenOpArg Size, GenOpArg Unit,
	      GenOpArg Flags, GenOpArg Dst)
{
    GenOp* op;
    NEW_GENOP(stp, op);

    NATIVE_ENDIAN(Flags);
    op->op = genop_i_bs_get_float_4;
    op->arity = 4;
    op->a[0] = Fail;
    op->a[1] = Size;
    op->a[2].type = TAG_u;
    op->a[2].val = (Unit.val << 3) | Flags.val;
    op->a[3] = Dst;
    op->next = NULL;
    return op;
}

/*
 * Generate the fastest instruction for bs_skip_bits.
 */

static GenOp*
gen_skip_bits(LoaderState* stp, GenOpArg Fail, GenOpArg Size,
	      GenOpArg Unit, GenOpArg Flags)
{
    GenOp* op;

    NATIVE_ENDIAN(Flags);
    NEW_GENOP(stp, op);
    if (Size.type == TAG_a && Size.val == am_all) {
	if (Flags.val & BSF_ALIGNED) {
	    op->op = genop_i_bs_skip_bits_all_aligned_0;
	    op->arity = 0;
	} else {
	    op->op = genop_i_bs_skip_bits_all_1;
	    op->arity = 1;
	    op->a[0] = Fail;
	}
    } else if (Size.type == TAG_i) {
	op->op = genop_i_bs_skip_bits_imm_2;
	op->arity = 2;
	op->a[0] = Fail;
	op->a[1].type = TAG_u;
	op->a[1].val = signed_val(Size.val) * Unit.val;
    } else {
	op->op = genop_i_bs_skip_bits_3;
	op->arity = 3;
	op->a[0] = Fail;
	op->a[1] = Size;
	op->a[2] = Unit;
    }
    op->next = NULL;
    return op;
}

/*
 * Generate a timeout instruction for a literal timeout.
 */

static GenOp*
gen_literal_timeout(LoaderState* stp, GenOpArg Fail, GenOpArg Time)
{
    GenOp* op;
    int timeout;

    NEW_GENOP(stp, op);
    op->op = genop_wait_timeout_2;
    op->next = NULL;
    op->arity = 2;
    op->a[0] = Fail;
    op->a[1].type = TAG_u;
    
    if (Time.type == TAG_i && (timeout = signed_val(Time.val)) >= 0) {
	op->a[1].val = timeout;
    } else if (Time.type == TAG_w) {
	Eterm* bigp = stp->temp_heap + Time.val;
	if (thing_arityval(*bigp) > 1 || BIG_SIGN(bigp)) {
	    op->op = genop_i_wait_error_0;
	    op->arity = 0;
	} else {
	    ASSERT(sizeof(unsigned) == 4);
	    bigp++;
	    op->a[1].val = (((unsigned) (((unsigned short *)bigp)[1])) << 16) |
		((unsigned short *)bigp)[0];
	}
    } else {
	op->op = genop_i_wait_error_0;
	op->arity = 0;
    }
    return op;
}

/*
 * Tag the list of values with tuple arity tags.
 */

static GenOp*
gen_select_tuple_arity(LoaderState* stp, GenOpArg S, GenOpArg Fail,
		       GenOpArg Size, GenOpArg* Rest)

{
    GenOp* op;
    int arity = Size.val + 3;
    int size = Size.val / 2;
    int i;

    /*
     * Verify the validity of the list.
     */

    if (Size.val % 2 != 0)
	return NULL;
    for (i = 0; i < Size.val; i += 2) {
	if (Rest[i].type != TAG_u || Rest[i+1].type != TAG_f) {
	    return NULL;
	}
    }

    /*
     * Generate the generic instruction.
     */

    NEW_GENOP(stp, op);
    op->next = NULL;
    op->op = genop_i_select_tuple_arity_3;
    GENOP_ARITY(op, arity);
    op->a[0] = S;
    op->a[1] = Fail;
    op->a[2].type = TAG_u;
    op->a[2].val = Size.val / 2;
    for (i = 0; i < Size.val; i += 2) {
	op->a[i+3].type = TAG_v;
	op->a[i+3].val = make_arityval(Rest[i].val);
	op->a[i+4] = Rest[i+1];
    }

    /*
     * Sort the values to make them useful for a binary search.
     */

    qsort(op->a+3, size, 2*sizeof(GenOpArg), 
	   (int (*)(const void *, const void *)) genopargcompare);
#ifdef DEBUG
    for (i = 3; i < arity-2; i += 2) {
	ASSERT(op->a[i].val < op->a[i+2].val);
    }
#endif
    return op;
}

/*
 * Split a list consisting of both small and bignumbers into two
 * select_val instructions.
 */

static GenOp*
gen_split_values(LoaderState* stp, GenOpArg S, GenOpArg Fail,
		 GenOpArg Size, GenOpArg* Rest)

{
    GenOp* op1;
    GenOp* op2;
    GenOp* label;
    Uint type;
    int i;

    ASSERT(Size.val >= 2 && Size.val % 2 == 0);

    NEW_GENOP(stp, label);
    label->op = genop_label_1;
    label->arity = 1;
    label->a[0].type = TAG_u;
    label->a[0].val = new_label(stp);

    NEW_GENOP(stp, op1);
    op1->op = genop_select_val_3;
    GENOP_ARITY(op1, 3 + Size.val);
    op1->arity = 3;
    op1->a[0] = S;
    op1->a[1].type = TAG_f;
    op1->a[1].val = label->a[0].val;
    op1->a[2].type = TAG_u;
    op1->a[2].val = 0;

    NEW_GENOP(stp, op2);
    op2->op = genop_select_val_3;
    GENOP_ARITY(op2, 3 + Size.val);
    op2->arity = 3;
    op2->a[0] = S;
    op2->a[1] = Fail;
    op2->a[2].type = TAG_u;
    op2->a[2].val = 0;

    op1->next = label;
    label->next = op2;
    op2->next = NULL;

    type = Rest[0].type;

    ASSERT(Size.type == TAG_u);
    for (i = 0; i < Size.val; i += 2) {
	GenOp* op = (Rest[i].type == type) ? op1 : op2;
	int dst = 3 + op->a[2].val;

	ASSERT(Rest[i+1].type == TAG_f);
	op->a[dst] = Rest[i];
	op->a[dst+1] = Rest[i+1];
	op->arity += 2;
	op->a[2].val += 2;
    }

    /*
     * None of the instructions should have zero elements in the list.
     */

    ASSERT(op1->a[2].val > 0);
    ASSERT(op2->a[2].val > 0);

    return op1;
}

/*
 * Generate a jump table.
 */

static GenOp*
gen_jump_tab(LoaderState* stp, GenOpArg S, GenOpArg Fail, GenOpArg Size, GenOpArg* Rest)
{
    int min, max;
    int i;
    int size;
    int arity;
    int fixed_args;
    GenOp* op;

    ASSERT(Size.val >= 2 && Size.val % 2 == 0);

    /*
     * Calculate the minimum and maximum values and size of jump table.
     */

    ASSERT(Rest[0].type == TAG_i);
    min = max = signed_val(Rest[0].val);
    for (i = 2; i < Size.val; i += 2) {
	ASSERT(Rest[i].type == TAG_i && Rest[i+1].type == TAG_f);
	if (signed_val(Rest[i].val) < min) {
	    min = signed_val(Rest[i].val);
	} else if (max < signed_val(Rest[i].val)) {
	    max = signed_val(Rest[i].val);
	}
    }
    size = max - min + 1;


    /*
     * Allocate structure and fill in the fixed fields.
     */

    NEW_GENOP(stp, op);
    op->next = NULL;
    if (min == 0) {
	op->op = genop_i_jump_on_val_zero_3;
	fixed_args = 3;
    } else {
	op->op = genop_i_jump_on_val_4;
	fixed_args = 4;
    }
    arity = fixed_args + size;
    GENOP_ARITY(op, arity);
    op->a[0] = S;
    op->a[1] = Fail;
    op->a[2].type = TAG_u;
    op->a[2].val = size;
    op->a[3].type = TAG_u;
    op->a[3].val = min;


    /*
     * Fill in the jump table.
     */

    for (i = fixed_args; i < arity; i++) {
	op->a[i] = Fail;
    }
    for (i = 0; i < Size.val; i += 2) {
	int index;
	ASSERT(is_small(Rest[i].val));
	index = fixed_args+signed_val(Rest[i].val)-min;
	ASSERT(fixed_args <= index && index < arity);
	op->a[index] = Rest[i+1];
    }
    return op;
}

/* 
 *  Compare function for qsort().
 */

static int
genopargcompare(GenOpArg* a, GenOpArg* b)
{
    if (a->val < b->val)
	return -1;
    else if (a->val == b->val)
	return 0;
    else
	return 1;
}

/*
 * Generate a select_val instruction.  We know that a jump table is not suitable.
 */

static GenOp*
gen_select_val(LoaderState* stp, GenOpArg S, GenOpArg Fail,
	       GenOpArg Size, GenOpArg* Rest)
{
    GenOp* op;
    int arity = Size.val + 3;
    int size = Size.val / 2;
    int i;

    NEW_GENOP(stp, op);
    op->next = NULL;
    op->op = (Rest[0].type == TAG_o) ? genop_i_select_float_3 : genop_i_select_val_3;
    GENOP_ARITY(op, arity);
    op->a[0] = S;
    op->a[1] = Fail;
    op->a[2].type = TAG_u;
    op->a[2].val = size;
    for (i = 3; i < arity; i++) {
	op->a[i] = Rest[i-3];
    }

    /*
     * Sort the values to make them useful for a binary search.
     */

    qsort(op->a+3, size, 2*sizeof(GenOpArg), 
	  (int (*)(const void *, const void *)) genopargcompare);
#ifdef DEBUG
    for (i = 3; i < arity-2; i += 2) {
	ASSERT(op->a[i].val < op->a[i+2].val);
    }
#endif

    return op;
}

/* 
 *  Compare function for qsort().
 */

static int
genbigcompare(GenOpArg* a, GenOpArg* b)
{
    int val = (int)(b->bigarity - a->bigarity);
    
    return val != 0 ? val : ((int) (a->val - b->val));
}

/*
 * Generate a select_val instruction for big numbers.
 */

static GenOp*
gen_select_big(LoaderState* stp, GenOpArg S, GenOpArg Fail,
	       GenOpArg Size, GenOpArg* Rest)
{
    GenOp* op;
    int arity = Size.val + 2 + 1;
    int size = Size.val / 2;
    int i;

    NEW_GENOP(stp, op);
    op->next = NULL;
    op->op = genop_i_select_big_2;
    GENOP_ARITY(op, arity);
    op->a[0] = S;
    op->a[1] = Fail;
    for (i = 0; i < Size.val; i += 2) {
	op->a[i+2] = Rest[i];
	op->a[i+2].bigarity = stp->temp_heap[op->a[i+2].val];
	op->a[i+3] = Rest[i+1];
    }
    ASSERT(i+2 == arity-1);
    op->a[arity-1].type = TAG_u;
    op->a[arity-1].val = 0;

    /*
     * Sort the values to make them useful for a binary search.
     */

    qsort(op->a+2, size, 2*sizeof(GenOpArg), 
	  (int (*)(const void *, const void *)) genbigcompare);

    return op;
}


/*
 * Replace a select_val instruction with a constant controlling expression
 * with a jump instruction.
 */

static GenOp*
const_select_val(LoaderState* stp, GenOpArg S, GenOpArg Fail,
		 GenOpArg Size, GenOpArg* Rest)
{
    GenOp* op;
    int i;

    ASSERT(Size.type == TAG_u);
    ASSERT(S.type == TAG_w || S.type == TAG_o);

    NEW_GENOP(stp, op);
    op->next = NULL;
    op->op = genop_jump_1;
    op->arity = 1;

    /*
     * Search for a literal matching the controlling expression.
     */

    if (S.type == TAG_w) {
	Eterm* given_big = stp->temp_heap + S.val;
	Uint given_arity = *given_big;
	Uint given_size = (thing_arityval(given_arity) + 1) * sizeof(Uint);
	for (i = 0; i < Size.val; i += 2) {
	    if (Rest[i].type == TAG_w) {
		Eterm* big = stp->temp_heap + Rest[i].val;
		if (*big == given_arity) {
		    if (memcmp(given_big, big, given_size) == 0) {
			ASSERT(Rest[i+1].type == TAG_f);
			op->a[0] = Rest[i+1];
			return op;
		    }
		}
	    }
	}
    } else if (S.type == TAG_o) {
	Eterm* given_float = stp->temp_heap + S.val;
	for (i = 0; i < Size.val; i += 2) {
	    if (Rest[i].type == TAG_o) {
		Eterm* fl = stp->temp_heap + Rest[i].val;
		if (given_float[0] == fl[0] && given_float[1] == fl[1]) {
		    ASSERT(Rest[i+1].type == TAG_f);
		    op->a[0] = Rest[i+1];
		    return op;
		}
	    }
	}
    }

    /*
     * No match.  Use the failure label.
     */

    op->a[0] = Fail;
    return op;
}


static GenOp*
gen_func_info(LoaderState* stp, GenOpArg mod, GenOpArg func,
	      GenOpArg arity, GenOpArg label)
{
    GenOp* fi;
    GenOp* op;

    NEW_GENOP(stp, fi);
    fi->op = genop_i_func_info_4;
    fi->arity = 4;
    fi->a[0].type = TAG_u;	/* untagged Zero */
    fi->a[0].val = 0;
    fi->a[1] = mod;
    fi->a[2] = func;
    fi->a[3] = arity;

    NEW_GENOP(stp, op);
    op->op = genop_label_1;
    op->arity = 1;
    op->a[0] = label;
    
    fi->next = op;
    op->next = NULL;

    if (func.val == am_module_info && arity.val < 2) {
	NEW_GENOP(stp, op->next);
	op = op->next;
	op->op = arity.val == 0 ? genop_i_module_info_0_0 :
	    genop_i_module_info_1_0;
	op->arity = 1;
	op->a[0] = mod;
	op->next = NULL;
    }
    return fi;
}


static GenOp*
gen_make_fun(LoaderState* stp, GenOpArg lbl, GenOpArg uniq, GenOpArg num_free)
{
    ErlFunEntry* fe;
    int old_uniq;
    int old_index;
    GenOp* op;

    old_uniq = uniq.val;
    old_index = stp->num_lambdas;
    fe = erts_put_fun_entry(stp->module, old_uniq, old_index);

    NEW_GENOP(stp, op);
    op->op = genop_i_make_fun_2;
    op->arity = 2;
    op->a[0].type = TAG_u;
    op->a[0].val = (Uint) fe;
    op->a[1] = num_free;
    op->next = NULL;

    if (stp->num_lambdas >= stp->lambdas_allocated) {
	unsigned need;
	unsigned old_need;

	old_need = stp->lambdas_allocated * sizeof(Lambda);
	stp->lambdas_allocated *= 2;
	need = stp->lambdas_allocated * sizeof(Lambda);
	if (stp->lambdas == stp->def_lambdas) {
	    stp->lambdas = erts_safe_sl_alloc_from(260, need);
	    memcpy(stp->lambdas, stp->def_lambdas, sizeof(stp->def_lambdas));
	} else {
	    stp->lambdas = erts_safe_sl_realloc((void *) stp->lambdas,
						old_need,
						need);
	}
    }
    stp->lambdas[stp->num_lambdas].fe = fe;
    stp->lambdas[stp->num_lambdas].label = lbl.val;
    /* The number_of free vars is needed to create the right native-stub */
    stp->lambdas[stp->num_lambdas].num_free = num_free.val;
    stp->num_lambdas++;
    return op;
}

static GenOp*
gen_make_fun2(LoaderState* stp, GenOpArg idx)
{
    ErlFunEntry* fe;
    GenOp* op;

    if (idx.val >= stp->num_lambdas) {
	stp->lambda_error = "missing or short chunk 'FunT'";
	fe = 0;
    } else {
	fe = stp->lambdas[idx.val].fe;
    }

    NEW_GENOP(stp, op);
    op->op = genop_i_make_fun_2;
    op->arity = 2;
    op->a[0].type = TAG_u;
    op->a[0].val = (Uint) fe;
    op->a[1].type = TAG_u;
    op->a[1].val = stp->lambdas[idx.val].num_free;
    op->next = NULL;
    return op;
}


/*
 * Freeze the code in memory, move the string table into place,
 * resolve all labels.
 */

static int
freeze_code(LoaderState* stp)
{
    Eterm* code = stp->code;
    Uint index;
    int i;
    byte* str_table;
    unsigned strtab_size = stp->chunks[STR_CHUNK].size;
    unsigned attr_size = stp->chunks[ATTR_CHUNK].size;
    unsigned compile_size = stp->chunks[COMPILE_CHUNK].size;
    Uint size;
    unsigned catches;
    int decoded_size;

    /*
     * Verify that there was a correct 'FunT' chunk if there were
     * make_fun2 instructions in the file.
     */

    if (stp->lambda_error != NULL) {
	LoadError0(stp, stp->lambda_error);
    }

    
    /*
     * Calculate the final size of the code.
     */

    size = stp->ci * sizeof(Eterm) + strtab_size + attr_size + compile_size;

    /*
     * Move the code to its final location and place the string table
     * and, optionally, attributes, after the code.
     */

    code = (Eterm *) safe_realloc((char *) code, size);
    memcpy(code+stp->ci, stp->chunks[STR_CHUNK].start, strtab_size);
    str_table = (byte *) (code+stp->ci);
    if (attr_size) {
	byte* attr = str_table + strtab_size;
	memcpy(attr, stp->chunks[ATTR_CHUNK].start, stp->chunks[ATTR_CHUNK].size);
	code[MI_ATTR_PTR] = (Eterm) attr;
	decoded_size = decode_size(attr, attr_size);
	if (decoded_size < 0) {
 	    LoadError0(stp, "bad external term representation of module attributes");
 	}
	code[MI_ATTR_SIZE_ON_HEAP] = decoded_size;
    }
    if (compile_size) {
	byte* compile_info = str_table + strtab_size + attr_size;
	memcpy(compile_info, stp->chunks[COMPILE_CHUNK].start,
	       stp->chunks[COMPILE_CHUNK].size);
	code[MI_COMPILE_PTR] = (Eterm) compile_info;
	decoded_size = decode_size(compile_info, compile_size);
	if (decoded_size < 0) {
 	    LoadError0(stp, "bad external term representation of compilation information");
 	}
	code[MI_COMPILE_SIZE_ON_HEAP] = decoded_size;
    }


    /*
     * Place a pointer to the op_int_code_end instruction in the
     * function table in the beginning of the file.
     */

    code[MI_FUNCTIONS+stp->num_functions] = (Eterm) (code + stp->ci - 1);

    /*
     * Go through all put_strings instructions, restore the pointer to
     * the instruction and convert string offsets to pointers (to the
     * LAST character).
     */

    index = stp->put_strings;
    while (index != 0) {
	Uint next = code[index];
	code[index] = BeamOpCode(op_put_string_IId);
	code[index+2] = (Uint) (str_table + code[index+2] + code[index+1] - 1);
	index = next;
    }

    /*
     * Go through all bs_put_strings instructions, restore the pointer to
     * the instruction and convert string offsets to pointers (to the
     * FIRST character).
     */

    index = stp->bs_put_strings;
    while (index != 0) {
	Uint next = code[index];
	code[index] = BeamOpCode(op_bs_put_string_II);
	code[index+2] = (Uint) (str_table + code[index+2]);
	index = next;
    }

    /*
     * Resolve all labels.
     */

    for (i = 0; i < stp->num_labels; i++) {
	Uint this_patch;
	Uint next_patch;
	Uint value = stp->labels[i].value;
	
	if (value == 0 && stp->labels[i].patches != 0) {
	    LoadError1(stp, "label %d not resolved", i);
	}
	ASSERT(value < stp->ci);
	this_patch = stp->labels[i].patches;
	while (this_patch != 0) {
	    ASSERT(this_patch < stp->ci);
	    next_patch = code[this_patch];
	    ASSERT(next_patch < stp->ci);
	    code[this_patch] = (Uint) (code + value);
	    this_patch = next_patch;
	}
    }

    /*
     * Fix all catch_yf instructions.
     */
    index = stp->catches;
    catches = BEAM_CATCHES_NIL;
    while (index != 0) {
	Uint next = code[index];
	code[index] = BeamOpCode(op_catch_yf);
	catches = beam_catches_cons((Uint*)code[index+2], catches);
	code[index+2] = make_catch(catches);
	index = next;
    }
    stp->catches = catches;

    /*
     * Save the updated code size.
     */

    stp->code = code;
    stp->loaded_size = size;

    return 1;

 load_error:
    return 0;
}


static void
final_touch(LoaderState* stp)
{
    int i;

    /*
     * Export functions.
     */

    for (i = 0; i < stp->num_exps; i++) {
	Export* ep = erts_export_put(stp->module, stp->export[i].function,
				     stp->export[i].arity);
	ep->address = stp->export[i].address;
    }

    /*
     * Import functions and patch all callers.
     */

    for (i = 0; i < stp->num_imports; i++) {
	Eterm mod;
	Eterm func;
	Uint arity;
	Uint import;
	Uint current;
	Uint next;

	mod = stp->import[i].module;
	func = stp->import[i].function;
	arity = stp->import[i].arity;
	import = (Uint) erts_export_put(mod, func, arity);
	current = stp->import[i].patches;
	while (current != 0) {
	    ASSERT(current < stp->ci);
	    next = stp->code[current];
	    stp->code[current] = import;
	    current = next;
	}
    }

    /*
     * Fix all funs.
     */ 

    if (stp->num_lambdas > 0) {
	for (i = 0; i < stp->num_lambdas; i++) {
	    unsigned entry_label = stp->lambdas[i].label;
	    ErlFunEntry* fe = stp->lambdas[i].fe;
	    Eterm* code_ptr = (Eterm *) (stp->code + stp->labels[entry_label].value);

	    if (fe->address[0] != 0) {
		/*
		 * We are hiding a pointer into older code.
		 */
		fe->refc--;
	    }
	    fe->address = code_ptr;
#ifdef HIPE
	    hipe_set_closure_stub(fe, stp->lambdas[i].num_free);
#endif
	}
    }
}


static int
transform_engine(LoaderState* st)
{
    Uint op;
    int ap;			/* Current argument. */
    Uint* restart;		/* Where to restart if current match fails. */
    GenOpArg def_vars[TE_MAX_VARS]; /* Default buffer for variables. */
    GenOpArg* var = def_vars;
    int i;			/* General index. */
    Uint mask;
    GenOp* instr;
    Uint* pc;
    int rval;

    ASSERT(gen_opc[st->genop->op].transform != -1);
    pc = op_transform + gen_opc[st->genop->op].transform;
    restart = pc;

 restart:
    if (var != def_vars) {
	erts_sl_free((void *) var);
	var = def_vars;
    }
    ASSERT(restart != NULL);
    pc = restart;
    ASSERT(*pc < NUM_TOPS);	/* Valid instruction? */
    ASSERT(*pc == TOP_try_me_else || *pc == TOP_fail);
    instr = st->genop;

#define RETURN(r) rval = (r); goto do_return;

#ifdef DEBUG
    restart = NULL;
#endif
    ap = 0;
    for (;;) {
	op = *pc++;

	switch (op) {
	case TOP_is_op:
	    if (instr == NULL) {
		/*
		 * We'll need at least one more instruction to decide whether
		 * this combination matches or not.
		 */
		RETURN(TE_SHORT_WINDOW);
	    }
	    if (*pc++ != instr->op)
		goto restart;
	    break;
	case TOP_is_type:
	    mask = *pc++;

	    ASSERT(ap < instr->arity);
	    ASSERT(instr->a[ap].type < 15);
	    if (((1 << instr->a[ap].type) & mask) == 0)
		goto restart;
	    break;
	case TOP_pred:
	    i = *pc++;
	    switch (i) {
#define RVAL i
#include "beam_pred_funcs.h"
#undef RVAL
	    default:
		ASSERT(0);
	    }
	    if (i == 0)
		goto restart;
	    break;
	case TOP_is_eq:
	    ASSERT(ap < instr->arity);
	    if (*pc++ != instr->a[ap].val)
		goto restart;
	    break;
	case TOP_is_same_var:
	    ASSERT(ap < instr->arity);
	    i = *pc++;
	    ASSERT(i < TE_MAX_VARS);
	    if (var[i].type != instr->a[ap].type)
		goto restart;
	    switch (var[i].type) {
	    case TAG_r: case TAG_n: break;
	    default:
		if (var[i].val != instr->a[ap].val)
		    goto restart;
	    }
	    break;
#if defined(TOP_is_bif)
	case TOP_is_bif:
	    {
		int bif_number = *pc++;
		
		/*
		 * In debug build, the type must be 'u'.
		 * In a real build, don't match.  (I.e. retain the original
		 * call instruction, this will work, but it will be a
		 * slight performance loss.)
		 */

		ASSERT(instr->a[ap].type == TAG_u);
		if (instr->a[ap].type != TAG_u)
		    goto restart;

		/*
		 * In debug build, the assertion will catch invalid indexes
		 * immediately.  In a real build, the loader will issue
		 * an diagnostic later when the instruction is loaded.
		 */

		i = instr->a[ap].val;
		ASSERT(i < st->num_imports);
		if (i >= st->num_imports || st->import[i].bf == NULL)
		    goto restart;
		if (bif_number != -1 &&
		    bif_export[bif_number]->code[4] != (Uint) st->import[i].bf) {
		    goto restart;
		}
	    }
	    break;

#endif
#if defined(TOP_is_func)
	case TOP_is_func:
	    {
		Eterm mod = *pc++;
		Eterm func = *pc++;
		int arity = *pc++;

		ASSERT(instr->a[ap].type == TAG_u);
		if (instr->a[ap].type != TAG_u) {
		    goto restart;
		}
		i = instr->a[ap].val;
		ASSERT(i < st->num_imports);
		if (i >= st->num_imports || st->import[i].module != mod ||
		    st->import[i].function != func ||
		    st->import[i].arity != arity) {
		    goto restart;
		}
	    }
	    break;
#endif
	case TOP_set_var:
	    ASSERT(ap < instr->arity);
	    i = *pc++;
	    ASSERT(i < TE_MAX_VARS);
	    var[i].type = instr->a[ap].type;
	    var[i].val = instr->a[ap].val;
	    break;

#if defined(TOP_rest_args)
	case TOP_rest_args:
	    i = *pc++;
	    var = erts_safe_sl_alloc_from(259, instr->arity * sizeof(GenOpArg));
	    memcpy(var, def_vars, sizeof(def_vars));
	    while (i < instr->arity) {
		var[i] = instr->a[i];
		i++;
	    }
	    break;
#endif

	case TOP_next_arg:
	    ap++;
	    break;
	case TOP_next_instr:
	    instr = instr->next;
	    ap = 0;
	    break;
	case TOP_commit:
	    instr = instr->next; /* The next_instr was optimized away. */

	    /*
	     * The left-hand side of this transformation matched.
	     * Delete all matched instructions.
	     */
	    while (st->genop != instr) {
		GenOp* next = st->genop->next;
		FREE_GENOP(st, st->genop);
		st->genop = next;
	    }
#ifdef DEBUG
	    instr = 0;
#endif
	    break;

#if defined(TOP_call)
	case TOP_call:
	    {
		GenOp** lastp;
		GenOp* new_instr;

		i = *pc++;
		switch (i) {
#define RVAL new_instr
#include "beam_tr_funcs.h"
#undef RVAL
		default:
		    ASSERT(0);
		}
		if (new_instr == NULL) {
		    goto restart;
		}

		lastp = &new_instr;
		while (*lastp != NULL) {
		    lastp = &((*lastp)->next);
		}
		 
		instr = instr->next; /* The next_instr was optimized away. */

		/*
		 * The left-hand side of this transformation matched.
		 * Delete all matched instructions.
		 */
		while (st->genop != instr) {
		    GenOp* next = st->genop->next;
		    FREE_GENOP(st, st->genop);
		    st->genop = next;
		}
		*lastp = st->genop;
		st->genop = new_instr;
	    }
	    break;
#endif
	case TOP_new_instr:
	    /*
	     * Note that the instructions are generated in reverse order.
	     */
	    NEW_GENOP(st, instr);
	    instr->next = st->genop;
	    st->genop = instr;
	    ap = 0;
	    break;
	case TOP_store_op:
	    instr->op = *pc++;
	    instr->arity = *pc++;
	    break;
	case TOP_store_type:
	    i = *pc++;
	    instr->a[ap].type = i;
	    instr->a[ap].val = 0;
	    break;
	case TOP_store_var:
	    i = *pc++;
	    ASSERT(i < TE_MAX_VARS);
	    instr->a[ap].type = var[i].type;
	    instr->a[ap].val = var[i].val;
	    break;
	case TOP_try_me_else:
	    restart = pc + 1;
	    restart += *pc++;
	    ASSERT(*pc < NUM_TOPS); /* Valid instruction? */
	    break;
	case TOP_end:
	    RETURN(TE_OK);
	case TOP_fail:
	    RETURN(TE_FAIL)
	default:
	    ASSERT(0);
	}
    }
#undef RETURN

 do_return:
    if (var != def_vars) {
	erts_sl_free((void *) var);
    }
    return rval;
}


static void
short_file(int line, LoaderState* stp, unsigned needed)
{
    load_printf(line, stp, "unexpected end of %s when reading %d byte(s)",
		stp->file_name, needed);
}


static void
load_printf(int line, LoaderState* context, char *fmt,...)
{
    char sbuf[1024];
    char error[1024];
    char module_name[256];	/* Module name as string. */
    va_list va;
    char* ep = error;
    Atom* ap;

    if (is_non_value(context->module)) {
	/* Suppressed by code:get_chunk/2 */
	return;
    }

    va_start(va, fmt);
    vsprintf(sbuf, fmt, va);
    va_end(va);

    sprintf(ep, "%s(%d): Error loading ", __FILE__, line);
    ep += strlen(ep);

    /*
     * Convert atom for module to a string.
     */
    ap = atom_tab(atom_val(context->module));
    memcpy(module_name, ap->name, ap->len);
    module_name[ap->len] = '\0';

    if (is_atom(context->function)) {
	char function[256];

	ap = atom_tab(atom_val(context->function));
	memcpy(function, ap->name, ap->len);
	function[ap->len] = '\0';
	sprintf(ep, "function %s:%s/%d", module_name, function, context->arity);
    } else {
	sprintf(ep, "module %s", module_name);
    }
    ep += strlen(ep);
    if (context->genop) {
	sprintf(ep, ": op %s", gen_opc[context->genop->op].name);
    }
    ep += strlen(ep);
    if (context->specific_op != -1) {
	sprintf(ep, ": %s", opc[context->specific_op].sign);
    } else if (context->genop) {
	int i;
	for (i = 0; i < context->genop->arity; i++) {
	    sprintf(ep, " %c", tag_to_letter[context->genop->a[i].type]);
	    ep += strlen(ep);
	}
    }
    ep += strlen(ep);
    cerr_pos = 0;
    sys_printf(CBUF, "%s:\n  %s\n", error, sbuf);
#ifdef DEBUG
    sys_printf(CERR, "%s:\n  %s\n", error, sbuf);
#endif
    send_error_to_logger(context->group_leader);
}


static int
get_int_val(LoaderState* stp, Uint len_code, Uint* result)
{
    Uint count;
    int val;

    len_code >>= 5;
    ASSERT(len_code < 8);
    if (len_code == 7) {
	LoadError0(stp, "can't load integers bigger than 8 bytes yet\n");
    }
    count = len_code + 2;
    if (count == 5) {
	Uint msb;
	GetByte(stp, msb);
	if (msb == 0) {
	    count--;
	}
	GetInt(stp, 4, *result);
    } else if (count <= 4) {
	GetInt(stp, count, val);
	*result = (int) ((val << 8*(sizeof(val)-count)) >> 8*(sizeof(val)-count));
    } else {
	LoadError1(stp, "too big integer; %d bytes\n", count);
    }
    return 1;

 load_error:
    return 0;
}


static int
get_erlang_integer(LoaderState* stp, Uint len_code, Uint* result)
{
    Uint count;
    int val;
    byte default_buf[128];
    byte* bigbuf = default_buf;
    byte* s;
    int i;
    int neg = 0;
    Uint arity;
    Eterm* hp;
    Uint hindex;

    /*
     * Retrieve the size of the value in bytes.
     */

    len_code >>= 5;
    if (len_code < 7) {
	count = len_code + 2;
    } else {
	Uint tag;

	ASSERT(len_code == 7);
	GetTagAndValue(stp, tag, len_code);
	VerifyTag(stp, TAG_u, tag);
	count = len_code + 9;
    }

    /*
     * Handle values up to the size of an int, meaning either a small or bignum.
     */

    if (count <= sizeof(val)) {
	GetInt(stp, count, val);

	val = (int) ((val << 8*(sizeof(val)-count)) >> 8*(sizeof(val)-count));
	if (IS_SSMALL(val)) {
	    *result = make_small(val);
	    return TAG_i;
	} else {
	    hindex = TempAlloc(stp, 2);
	    (void) small_to_big(val, stp->temp_heap+hindex);
	    *result = hindex;
	    return TAG_w;
	}
    }

    /*
     * Make sure that the number will fit in our temporary buffer
     * (including margin).
     */

    if (count+8 > sizeof(default_buf)) {
	bigbuf = erts_safe_sl_alloc_from(261, count+8);
    }

    /*
     * Copy the number reversed to our temporary buffer.
     */

    GetString(stp, s, count);
    for (i = 0; i < count; i++) {
	bigbuf[count-i-1] = *s++;
    }

    /*
     * Check if the number is negative, and negate it if so.
     */

    if ((bigbuf[count-1] & 0x80) != 0) {
	unsigned carry = 1;

	neg = 1;
	for (i = 0; i < count; i++) {
	    bigbuf[i] = ~bigbuf[i] + carry;
	    carry = (bigbuf[i] == 0 && carry == 1);
	}
	ASSERT(carry == 0);
    }

    /*
     * Align to word boundary.
     */

    if (bigbuf[count-1] == 0) {
	count--;
    }
    if (bigbuf[count-1] == 0) {
	LoadError0(stp, "bignum not normalized");
    }
    while (count % sizeof(Eterm) != 0) {
	bigbuf[count++] = 0;
    }

    /*
     * Allocate heap space for the bignum and copy it.
     */

    arity = count/sizeof(Eterm);
    hindex = TempAlloc(stp, arity+1);
    hp = stp->temp_heap + hindex;
    *hp++ = neg ? make_neg_bignum_header(arity) : make_pos_bignum_header(arity);
    for (i = 0; i < arity; i++) {
	byte* bp = bigbuf + sizeof(Eterm)*i;
	((unsigned short *)hp)[0] = bp[0] | (bp[1] << 8);
	((unsigned short *)hp)[1] = bp[2] | (bp[3] << 8);
	if (sizeof(Eterm) == 8) {
	    ((unsigned short *)hp)[2] = bp[4] | (bp[5] << 8);
	    ((unsigned short *)hp)[3] = bp[6] | (bp[7] << 8);
	}
	hp++;
    }

    if (bigbuf != default_buf) {
	erts_sl_free((void *) bigbuf);
    }

    *result = hindex;
    return TAG_w;


 load_error:
    if (bigbuf != default_buf) {
	erts_sl_free((void *) bigbuf);
    }
    return -1;
}


/*
 * Converts an IFF id to a printable string.
 */

static void
id_to_string(Uint id, char* s)
{
    int i;

    for (i = 3; i >= 0; i--) {
	*s++ = (id >> i*8) & 0xff;
    }
    *s++ = '\0';
}


static void
new_genop(LoaderState* stp)
{
    GenOpBlock* p = (GenOpBlock *) erts_safe_sl_alloc_from(256,
							   sizeof(GenOpBlock));
    int i;

    p->next = stp->genop_blocks;
    stp->genop_blocks = p;
    for (i = 0; i < sizeof(p->genop)/sizeof(p->genop[0])-1; i++) {
	p->genop[i].next = p->genop + i + 1;
    }
    p->genop[i].next = NULL;
    stp->free_genop = p->genop;
}


static Uint
temp_alloc(LoaderState* stp, unsigned needed)
{
    Uint rval = stp->temp_heap_top;

    needed += rval;
    while (stp->temp_heap_size < needed) {
	stp->temp_heap_size = erts_next_heap_size(needed, 0);
    }
    if (stp->temp_heap == NULL) {
	stp->temp_heap =
	    erts_safe_sl_alloc_from(262, stp->temp_heap_size * sizeof(Eterm));
    } else {
	stp->temp_heap =
	    erts_safe_sl_realloc((void *) stp->temp_heap,
				 stp->temp_heap_top * sizeof(Eterm),
				 stp->temp_heap_size * sizeof(Eterm));
    }
    stp->temp_heap_top = needed;
    return rval;
}


static int
new_label(LoaderState* stp)
{
    int num = stp->num_labels;

    stp->num_labels++;
    stp->labels = (Label *) erts_safe_sl_realloc((char *) stp->labels,
						 num * sizeof(Label),
						 (stp->num_labels
						  * sizeof(Label)));
    stp->labels[num].value = 0;
    stp->labels[num].patches = 0;
    return num;
}


Eterm
erts_module_info_0(Process* p, Eterm module)
{
    Eterm *hp;
    Eterm list = NIL;
    Eterm tup;

#define BUILD_INFO(What) \
    tup = erts_module_info_1(p, module, What); \
    hp = HAlloc(p, 5); \
    tup = TUPLE2(hp, What, tup); \
    hp += 3; \
    list = CONS(hp, tup, list)

    BUILD_INFO(am_compile);
    BUILD_INFO(am_attributes);
    BUILD_INFO(am_imports);
    BUILD_INFO(am_exports);
#undef BUILD_INFO
    return list;
}

Eterm
erts_module_info_1(Process* p, Eterm module, Eterm what)
{
    if (what == am_module) {
	return module;
    } else if (what == am_imports) {
	return NIL;
    } else if (what == am_exports) {
	return exported_from_module(p, module);
    } else if (what == am_functions) {
	return functions_in_module(p, module);
    } else if (what == am_attributes) {
	return attributes_for_module(p, module);
    } else if (what == am_compile) {
	return compilation_info_for_module(p, module);
    } else if (what == am_native_addresses) {
	return native_addresses(p, module);
    }
    return THE_NON_VALUE;
}

/*
 * Builds a list of all functions in the given module:
 *     [{Name, Arity},...]
 *
 * Returns a tagged term, or 0 on error.
 */

Eterm
functions_in_module(Process* p, /* Process whose heap to use. */
		     Eterm mod) /* Tagged atom for module. */
{
    Module* modp;
    Eterm* code;
    int i;
    Eterm* hp = NULL;
    Eterm* hend = NULL;
    Eterm result = NIL;

    if (is_not_atom(mod)) {
	return THE_NON_VALUE;
    }

    modp = erts_get_module(mod);
    if (modp == NULL) {
	return THE_NON_VALUE;
    }
    code = modp->code;
    for (i = code[MI_NUM_FUNCTIONS]-1; i >= 0 ; i--) {
	Eterm* func_info = (Eterm *) code[MI_FUNCTIONS+i];
	Eterm name = func_info[3];
	int arity = func_info[4];
	Eterm tuple;

	ASSERT(is_atom(name));
	if (hp == hend) {
	    int need = 10 * 5;
	    hp = HAlloc(p, need);
	    hend = hp + need;
	}
	tuple = TUPLE2(hp, name, make_small(arity));
	hp += 3;
	result = CONS(hp, tuple, result);
	hp += 2;
    }
    return result;
}

/*
 * Builds a list of all functions including native addresses.
 *     [{Name,Arity,NativeAddress},...]
 *
 * Returns a tagged term, or 0 on error.
 */

static Eterm
native_addresses(Process* p, Eterm mod)
{
    Module* modp;
    Eterm* code;
    int i;
    Eterm* hp = NULL;
    Eterm* hend = NULL;
    Eterm result = NIL;

    if (is_not_atom(mod)) {
	return THE_NON_VALUE;
    }

    modp = erts_get_module(mod);
    if (modp == NULL) {
	return THE_NON_VALUE;
    }
    code = modp->code;
    for (i = code[MI_NUM_FUNCTIONS]-1; i >= 0 ; i--) {
	Eterm* func_info = (Eterm *) code[MI_FUNCTIONS+i];
	Eterm name = func_info[3];
	int arity = func_info[4];
	Eterm tuple;

	ASSERT(is_atom(name));
	if (func_info[1] != 0) {
	    Eterm addr = make_small_or_big(func_info[1], p);

	    if (hp == hend) {
		int need = 10 * 6;
		hp = HAlloc(p, need);
		hend = hp + need;
	    }
	    tuple = TUPLE3(hp, name, make_small(arity), addr);
	    hp += 4;
	    result = CONS(hp, tuple, result);
	    hp += 2;
	}
    }
    return result;
}


/*
 * Builds a list of all exported functions in the given module:
 *     [{Name, Arity},...]
 *
 * Returns a tagged term, or 0 on error.
 */

Eterm
exported_from_module(Process* p, /* Process whose heap to use. */
		     Eterm mod) /* Tagged atom for module. */
{
    Module* modp;
    Eterm* code;
    int i;
    Eterm* hp = NULL;
    Eterm* hend = NULL;
    Eterm result = NIL;

    if (is_not_atom(mod)) {
	return THE_NON_VALUE;
    }
    modp = erts_get_module(mod);
    if (modp == NULL) {
	return THE_NON_VALUE;
    }
    code = modp->code;
    for (i = code[MI_NUM_FUNCTIONS]-1; i >= 0 ; i--) {
	Eterm* func_info = (Eterm *) code[MI_FUNCTIONS+i];
	Eterm name = func_info[3];
	int arity = func_info[4];
	Eterm tuple;

	if (erts_find_function(mod, name, arity) != NULL) {
	    ASSERT(is_atom(name));
	    if (hp == hend) {
		int need = 10 * 5;
		hp = HAlloc(p, need);
		hend = hp + need;
	    }
	    tuple = TUPLE2(hp, name, make_small(arity));
	    hp += 3;
	    result = CONS(hp, tuple, result);
	    hp += 2;
	}
    }
    return result;
}


/*
 * Returns a list of all attributes for the module.
 *
 * Returns a tagged term, or 0 on error.
 */

Eterm
attributes_for_module(Process* p, /* Process whose heap to use. */
		      Eterm mod) /* Tagged atom for module. */

{
    Module* modp;
    Eterm* code;
    Eterm* hp;
    byte* ext;
    Eterm result = NIL;
#ifdef DEBUG
    Eterm* end;
#endif

    if (is_not_atom(mod) || (is_not_list(result) && is_not_nil(result))) {
	return THE_NON_VALUE;
    }

    modp = erts_get_module(mod);
    if (modp == NULL) {
	return THE_NON_VALUE;
    }
    code = modp->code;
    ext = (byte *) code[MI_ATTR_PTR];
    if (ext != NULL) {
	hp = HAlloc(p, code[MI_ATTR_SIZE_ON_HEAP]);
#ifdef DEBUG
	end = hp + code[MI_ATTR_SIZE_ON_HEAP];
#endif
	result = erts_from_external_format(NULL, &hp, &ext, &MSO(p));
	if (is_value(result)) {
	    ASSERT(hp <= end);
	}
    }
    return result;
}


/*
 * Returns a list containing compilation information.
 *
 * Returns a tagged term, or 0 on error.
 */

Eterm
compilation_info_for_module(Process* p, /* Process whose heap to use. */
			    Eterm mod) /* Tagged atom for module. */
{
    Module* modp;
    Eterm* code;
    Eterm* hp;
    byte* ext;
    Eterm result = NIL;
#ifdef DEBUG
    Eterm* end;
#endif

    if (is_not_atom(mod) || (is_not_list(result) && is_not_nil(result))) {
	return THE_NON_VALUE;
    }

    modp = erts_get_module(mod);
    if (modp == NULL) {
	return THE_NON_VALUE;
    }
    code = modp->code;
    ext = (byte *) code[MI_COMPILE_PTR];
    if (ext != NULL) {
	hp = HAlloc(p, code[MI_COMPILE_SIZE_ON_HEAP]);
#ifdef DEBUG
	end = hp + code[MI_COMPILE_SIZE_ON_HEAP];
#endif
	result = erts_from_external_format(NULL, &hp, &ext, &MSO(p));
	if (is_value(result)) {
	    ASSERT(hp <= end);
	}
    }
    return result;
}


/*
 * Returns a pointer to {module, function, arity}, or NULL if not found.
 */
Eterm*
find_function_from_pc(Eterm* pc)
{
    Range* low = modules;
    Range* high = low + num_loaded_modules;
    Range* mid = mid_module;

    while (low < high) {
	if (pc < mid->start) {
	    high = mid;
	} else if (pc > mid->end) {
	    low = mid + 1;
	} else {
	    Eterm** low1 = (Eterm **) (mid->start + MI_FUNCTIONS);
	    Eterm** high1 = low1 + mid->start[MI_NUM_FUNCTIONS];
	    Eterm** mid1;

	    while (low1 < high1) {
		mid1 = low1 + (high1-low1) / 2;
		if (pc < mid1[0]) {
		    high1 = mid1;
		} else if (pc < mid1[1]) {
		    mid_module = mid;
		    return mid1[0]+2;
		} else {
		    low1 = mid1 + 1;
		}
	    }
	    return NULL;
	}
	mid = low + (high-low) / 2;
    }
    return NULL;
}

/*
 * Read a specific chunk from a Beam binary.
 */

Eterm
code_get_chunk_2(Process* p, Eterm Bin, Eterm Chunk)
{
    LoaderState state;
    Uint chunk = 0;
    ErlSubBin* sb;
    Uint offset;
    byte* start;
    int i;

    if (is_not_binary(Bin)) {
	goto error;
    }
    state.module = THE_NON_VALUE; /* Suppress diagnostiscs */
    state.file_name = "IFF header for Beam file";
    GET_BINARY_BYTES(Bin, start);
    state.file_p = start;
    state.file_left = binary_size(Bin);
    for (i = 0; i < 4; i++) {
	Eterm* chunkp;
	Eterm num;
	if (is_not_list(Chunk)) {
	    goto error;
	}
	chunkp = list_val(Chunk);
	num = CAR(chunkp);
	Chunk = CDR(chunkp);
	if (!is_byte(num)) {
	    goto error;
	}
	chunk = chunk << 8 | unsigned_val(num);
    }
    if (is_not_nil(Chunk)) {
	goto error;
    }

    if (!scan_iff_file(&state, &chunk, 1, 1)) {
	return am_undefined;
    }
    sb = (ErlSubBin *) HAlloc(p, ERL_SUB_BIN_SIZE);
    GET_REAL_BIN(Bin, sb->orig, offset);
    sb->thing_word = HEADER_SUB_BIN;
    sb->size = state.chunks[0].size;
    sb->offs = offset + (state.chunks[0].start-start);
    return make_binary(sb);

 error:
    BIF_ERROR(p, BADARG);
}

/*
 * Calculate the MD5 for a module.
 */
  
Eterm
code_module_md5_1(Process* p, Eterm Bin)
{
    LoaderState state;
    byte* start;

    if (is_not_binary(Bin)) {
	BIF_ERROR(p, BADARG);
    }
    state.module = THE_NON_VALUE; /* Suppress diagnostiscs */
    state.file_name = "IFF header for Beam file";
    GET_BINARY_BYTES(Bin, start);
    state.file_p = start;
    state.file_left = binary_size(Bin);

    if (!scan_iff_file(&state, chunk_types, NUM_CHUNK_TYPES, NUM_MANDATORY)) {
	return am_undefined;
    }
    return new_binary(p, state.mod_md5, sizeof(state.mod_md5));
}

#define WORDS_PER_FUNCTION 6

static Eterm*
make_stub(Eterm* fp, Eterm mod, Eterm func, Uint arity, Uint native, Eterm OpCode)
{
    fp[0] = (Eterm) BeamOp(op_i_func_info_IaaI);
    fp[1] = native;
    fp[2] = mod;
    fp[3] = func;
    fp[4] = arity;
    fp[5] = OpCode;
    return fp + WORDS_PER_FUNCTION;
}

static void
stub_init_state(LoaderState* stp, Eterm Bin)
{
    byte* start;

    init_state(stp);
    stp->file_name = "IFF header for Beam file";
    GET_BINARY_BYTES(Bin, start);
    stp->file_p = start;
    stp->file_left = binary_size(Bin);
}

static byte*
stub_copy_info(LoaderState* stp,
	       int chunk,	/* Chunk: ATTR_CHUNK or COMPILE_CHUNK */
	       byte* info,	/* Where to store info. */
	       Eterm* ptr_word,	/* Where to store pointer into info. */
	       Eterm* size_word) /* Where to store size of info. */
{
    int decoded_size;
    Uint size = stp->chunks[chunk].size;
    if (size != 0) {
	memcpy(info, stp->chunks[chunk].start, size);
	*ptr_word = (Eterm) info;
	decoded_size = decode_size(info, size);
	if (decoded_size < 0) {
 	    return 0;
 	}
	*size_word = decoded_size;
    }
    return info + size;
}

static int
stub_read_export_table(LoaderState* stp)
{
    int i;

    GetInt(stp, 4, stp->num_exps);
    if (stp->num_exps > stp->num_functions) {
	LoadError2(stp, "%d functions exported; only %d functions defined",
		   stp->num_exps, stp->num_functions);
    }
    stp->export
	= (ExportEntry *) erts_safe_sl_alloc(stp->num_exps
					     * sizeof(ExportEntry));

    for (i = 0; i < stp->num_exps; i++) {
	Uint n;

	GetInt(stp, 4, n);
	GetAtom(stp, n, stp->export[i].function);
	GetInt(stp, 4, n);
	if (n > MAX_REG) {
	    LoadError2(stp, "export table entry %d: absurdly high arity %d", i, n);
	}
	stp->export[i].arity = n;
	GetInt(stp, 4, n);	/* Ignore label */
    }
    return 1;

 load_error:
    return 0;
}

static void
stub_final_touch(LoaderState* stp, Eterm* fp)
{
    int i;
    int n = stp->num_exps;
    Eterm function = fp[3];
    int arity = fp[4];
#ifdef HIPE
    Lambda* lp;
#endif

    /*
     * Test if the function should be exported.
     */

    for (i = 0; i < n; i++) {
	if (stp->export[i].function == function && stp->export[i].arity == arity) {
	    Export* ep = erts_export_put(fp[2], function, arity);
	    ep->address = fp+5;
	    return;
	}
    }

    /*
     * Must be a plain local function or a lambda local function.
     * Search the lambda table to find out which.
     */
    
#ifdef HIPE
    n = stp->num_lambdas;
    for (i = 0, lp = stp->lambdas; i < n; i++, lp++) {
        ErlFunEntry* fe = stp->lambdas[i].fe;
	if (lp->function == function && lp->arity == arity) {
	    fp[5] = (Eterm) BeamOpCode(op_hipe_trap_call_closure);
            fe->address = &(fp[5]);
	}
    }
#endif
    return;
}


/* Takes an erlang list of addresses:
   [{Adr, Patchtyppe} | Addresses]
   and the address of a fun_entry.
*/
int 
patch(Eterm Addresses, Uint fe) 
 {
#ifdef HIPE
  Eterm* listp;
  Eterm tuple;
  Eterm* tp;
  Eterm  patchtype;
  Uint AddressToPatch;

  while (!is_nil(Addresses)) {
    listp = list_val(Addresses);

    tuple = CAR(listp);
    if (is_not_tuple(tuple)) {
      return 0; /* Signal error */
    }

    tp = tuple_val(tuple);
    if (tp[0] != make_arityval(2)) {
      return 0; /* Signal error */
    }
    
    if(term_to_Uint(tp[1], &AddressToPatch) == 0) {
      return 0; /* Signal error */
    }

    patchtype = tp[2];    
    if (is_not_atom(patchtype)) {
      return 0; /* Signal error */
    }
    
    hipe_patch_address((Uint *)AddressToPatch, patchtype, fe);

    Addresses = CDR(listp);


  }

#endif
  return 1;
}


int
patch_funentries(Eterm Patchlist) 
 {
#ifdef HIPE   
  while (!is_nil(Patchlist)) {
    Eterm Info;
    Eterm MFA;
    Eterm Addresses;
    Eterm tuple;
    Eterm Mod;
    Eterm* listp;
    Eterm* tp;
    ErlFunEntry* fe;
    Uint index;
    Uint uniq;
    Uint native_address;
     
    listp = list_val(Patchlist);
    tuple = CAR(listp);
    Patchlist = CDR(listp);

    if (is_not_tuple(tuple)) {
      return 0; /* Signal error */
    }

    tp = tuple_val(tuple);
    if (tp[0] != make_arityval(3)) {
      return 0; /* Signal error */
    }
    
    Info = tp[1];
    if (is_not_tuple(Info)) {
      return 0; /* Signal error */
    }
    Addresses = tp[2];    
     if (is_not_list(Addresses)) {
       return 0; /* Signal error */
    }
    
    if(term_to_Uint(tp[3], &native_address) == 0) {
      return 0; /* Signal error */
    }



    tp = tuple_val(Info);
    if (tp[0] != make_arityval(3)) {
      return 0; /* Signal error */
    }
    MFA = tp[1];
    if (is_not_tuple(MFA)) {
      return 0; /* Signal error */
    }
    if(term_to_Uint(tp[2], &uniq) == 0){
      return 0; /* Signal error */
    }
    if(term_to_Uint(tp[3], &index) == 0) {
      return 0; /* Signal error */
    }




    tp = tuple_val(MFA);
    if (tp[0] != make_arityval(3)) {
      return 0; /* Signal error */
     }
    Mod = tp[1];
    if (is_not_atom(Mod)) {
      return 0; /* Signal error */
    }
      
  

    fe = erts_get_fun_entry(Mod, uniq, index);
    fe->native_address = (Uint *)native_address;


    if (!patch(Addresses, (Uint) fe))
      return 0;

  }
#endif
  return 1; /* Signal that all went well */
}


/*
 * Do a dummy load of a module. No threaded code will be loaded.
 * Used for loading native code.
 * Will also patch all referenses to fun_entries to point to 
 * the new fun_entries created.
 */

Eterm
code_make_stub_module_3(Process* p, Eterm Mod, Eterm Beam, Eterm Info)
{
    LoaderState state;
    Eterm Funcs;
    Eterm Patchlist;
    Eterm* tp;
    Eterm* code = NULL;
    Eterm* ptrs;
    Eterm* fp;
    byte* info;
    Uint ci;
    int n;
    int code_size;
    int rval;
    int i;

    if (is_not_atom(Mod)) {
	goto error;
    }
    if (is_not_tuple(Info)) {
	goto error;
    }
    tp = tuple_val(Info);
    if (tp[0] != make_arityval(2)) {
      goto error;
    }
    Funcs = tp[1];
    Patchlist = tp[2];        
   
    if ((n = list_length(Funcs)) < 0) {
	goto error;
    }
    n += 2;			/* module_info/0 and module_info/1 */

    /*
     * Scan the Beam binary and read the interesting sections.
     */

    stub_init_state(&state, Beam);
    state.module = Mod;
    state.group_leader = p->group_leader;
    state.num_functions = n;
    if (!scan_iff_file(&state, chunk_types, NUM_CHUNK_TYPES, NUM_MANDATORY)) {
	goto error;
    }
    define_file(&state, "code chunk header", CODE_CHUNK);
    if (!read_code_header(&state)) {
	goto error;
    }
    define_file(&state, "atom table", ATOM_CHUNK);
    if (!load_atom_table(&state)) {
	goto error;
    }
    define_file(&state, "export table", EXP_CHUNK);
    if (!stub_read_export_table(&state)) {
	goto error;
    }
    
    if (state.chunks[LAMBDA_CHUNK].size > 0) {
	define_file(&state, "lambda (fun) table", LAMBDA_CHUNK);
	if (!read_lambda_table(&state)) {
	    goto error;
	}
    }

    /*
     * Allocate memory for the stub module.
     */

    code_size = ((WORDS_PER_FUNCTION+1)*n + MI_FUNCTIONS + 2) * sizeof(Eterm);
    code_size += state.chunks[ATTR_CHUNK].size;
    code_size += state.chunks[COMPILE_CHUNK].size;
    if ((code = sys_alloc_from(251, code_size)) == NULL) {
	goto error;
    }

    /*
     * Initialize code area.
     */

    code[MI_NUM_FUNCTIONS] = n;
    code[MI_ATTR_PTR] = 0;
    code[MI_ATTR_SIZE_ON_HEAP] = 0;
    code[MI_COMPILE_PTR] = 0;
    code[MI_COMPILE_SIZE_ON_HEAP] = 0;
    code[MI_NUM_BREAKPOINTS] = 0;
    ci = MI_FUNCTIONS + n + 1;

    /*
     * Make stubs for all functions.
     */

    ptrs = code + MI_FUNCTIONS;
    fp = code + ci;
    for (i = 0; i < n; i++) {
	Eterm* listp;
	Eterm tuple;
	Eterm* tp;
	Eterm func;
	Eterm arity_term;
	Uint arity;
	Uint native_address;
	Eterm op;

	if (is_nil(Funcs)) {
	    break;
	}
	listp = list_val(Funcs);
	tuple = CAR(listp);
	Funcs = CDR(listp);

	/* Error checking */
	if (is_not_tuple(tuple)) {
	    goto error;
	}
	tp = tuple_val(tuple);
	if (tp[0] != make_arityval(3)) {
	    goto error;
	}
	func = tp[1];
	arity_term = tp[2];
	if (is_not_atom(func) || is_not_small(arity_term)) {
	    goto error;
	}
	arity = signed_val(arity_term);
	if (arity < 0) {
	    goto error;
	}
	if (term_to_Uint(tp[3], &native_address) == 0) {
	    goto error;
	}

	/*
	 * Set the pointer and make the stub. Put a return instruction
	 * as the body until we know what kind of trap we should put there.
	 */
	ptrs[i] = (Eterm) fp;
#ifdef HIPE
	op = (Eterm) BeamOpCode(op_hipe_trap_call); /* Might be changed later. */
#else
	op = (Eterm) BeamOpCode(op_move_return_nr);
#endif
	fp = make_stub(fp, Mod, func, arity, (Uint)native_address, op);
    }

    /*
     * Add the module_info/0,1 functions.
     */

    ptrs[i++] = (Eterm) fp;
    fp = make_stub(fp, Mod, am_module_info, 0, 0, (Eterm) BeamOp(op_i_module_info_0));
    ptrs[i++] = (Eterm) fp;
    fp = make_stub(fp, Mod, am_module_info, 1, 0, (Eterm) BeamOp(op_i_module_info_1));

    /*
     * Insert the last pointer and the int_code_end instruction.
     */

    ptrs[i] = (Eterm) fp;
    *fp++ = (Eterm) BeamOp(op_int_code_end);

    /*
     * Copy attributes and compilation information.
     */

    info = (byte *) fp;
    info = stub_copy_info(&state, ATTR_CHUNK, info,
			  code+MI_ATTR_PTR, code+MI_ATTR_SIZE_ON_HEAP);
    if (info == NULL) {
	goto error;
    }
    info = stub_copy_info(&state, COMPILE_CHUNK, info,
			  code+MI_COMPILE_PTR, code+MI_COMPILE_SIZE_ON_HEAP);
    if (info == NULL) {
	goto error;
    }

    /*
     * Insert the module in the module table.
     */

    rval = insert_new_code(p->group_leader, Mod, code, code_size, BEAM_CATCHES_NIL);
    if (rval < 0) {
	goto error;
    }

    /*
     * Export all stub functions and insert the correct type of HiPE trap.
     */

    fp = code + ci;
    for (i = 0; i < n; i++) {
	stub_final_touch(&state, fp);
	fp += WORDS_PER_FUNCTION;
    }

    if (patch_funentries(Patchlist))
      return Mod;

 error:
    if (code != NULL) {
	sys_free(code);
    }
    BIF_ERROR(p, BADARG);
}

#undef WORDS_PER_FUNCTION
