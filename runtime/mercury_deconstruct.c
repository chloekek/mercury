/*
** vim:ts=4 sw=4 expandtab
*/
/*
** Copyright (C) 2002 The University of Melbourne.
** This file may only be copied under the terms of the GNU Library General
** Public License - see the file COPYING.LIB in the Mercury distribution.
*/

/*
** mercury_deconstruct.c
**
** This file provides utility functions for deconstructing terms, for use by
** the standard library.
*/

#include "mercury_imp.h"
#include "mercury_deconstruct.h"
#include "mercury_deconstruct_macros.h"

#define EXPAND_FUNCTION_NAME        MR_expand_functor_args
#define EXPAND_TYPE_NAME            MR_Expand_Functor_Args_Info
#define EXPAND_FUNCTOR_FIELD        functor
#define EXPAND_ARGS_FIELD           args
#include "mercury_ml_expand_body.h"
#undef  EXPAND_FUNCTION_NAME
#undef  EXPAND_TYPE_NAME
#undef  EXPAND_FUNCTOR_FIELD
#undef  EXPAND_ARGS_FIELD

#define EXPAND_FUNCTION_NAME        MR_expand_functor_args_limit
#define EXPAND_TYPE_NAME            MR_Expand_Functor_Args_Limit_Info
#define EXPAND_FUNCTOR_FIELD        functor
#define EXPAND_ARGS_FIELD           args
#define EXPAND_APPLY_LIMIT
#include "mercury_ml_expand_body.h"
#undef  EXPAND_FUNCTION_NAME
#undef  EXPAND_TYPE_NAME
#undef  EXPAND_FUNCTOR_FIELD
#undef  EXPAND_ARGS_FIELD
#undef  EXPAND_APPLY_LIMIT

#define EXPAND_FUNCTION_NAME        MR_expand_functor_only
#define EXPAND_TYPE_NAME            MR_Expand_Functor_Only_Info
#define EXPAND_FUNCTOR_FIELD        functor_only
#include "mercury_ml_expand_body.h"
#undef  EXPAND_FUNCTION_NAME
#undef  EXPAND_TYPE_NAME
#undef  EXPAND_FUNCTOR_FIELD

#define EXPAND_FUNCTION_NAME        MR_expand_args_only
#define EXPAND_TYPE_NAME            MR_Expand_Args_Only_Info
#define EXPAND_ARGS_FIELD           args_only
#include "mercury_ml_expand_body.h"
#undef  EXPAND_FUNCTION_NAME
#undef  EXPAND_TYPE_NAME
#undef  EXPAND_ARGS_FIELD

#define EXPAND_FUNCTION_NAME        MR_expand_chosen_arg_only
#define EXPAND_TYPE_NAME            MR_Expand_Chosen_Arg_Only_Info
#define EXPAND_CHOSEN_ARG
#include "mercury_ml_expand_body.h"
#undef  EXPAND_FUNCTION_NAME
#undef  EXPAND_TYPE_NAME
#undef  EXPAND_CHOSEN_ARG

#define EXPAND_FUNCTION_NAME        MR_expand_named_arg_only
#define EXPAND_TYPE_NAME            MR_Expand_Chosen_Arg_Only_Info
#define EXPAND_NAMED_ARG
#include "mercury_ml_expand_body.h"
#undef  EXPAND_FUNCTION_NAME
#undef  EXPAND_TYPE_NAME
#undef  EXPAND_NAMED_ARG

/*
** MR_arg() is a subroutine used to implement arg/2, argument/2,
** and also store__arg_ref/5 in store.m.
** It takes the address of a term, its type, and an argument index.
** If the selected argument exists, it succeeds and returns the address
** of the argument, and its type; if it doesn't, it fails (i.e. returns FALSE).
**
** You need to wrap MR_{save/restore}_transient_hp() around
** calls to this function.
*/

bool
MR_arg(MR_TypeInfo type_info, MR_Word *term_ptr, int arg_index,
    MR_TypeInfo *arg_type_info_ptr, MR_Word **arg_ptr,
    MR_non_canon_handling noncanon_handling, MR_ConstString msg)
{
    MR_Expand_Chosen_Arg_Only_Info  expand_info;

    MR_expand_chosen_arg_only(type_info, term_ptr, arg_index, &expand_info);
    if (expand_info.non_canonical_type) {
        switch (noncanon_handling) {
            case MR_ALLOW_NONCANONICAL:
                break;

            case MR_FAIL_ON_NONCANONICAL:
                return FALSE;
                break;

            case MR_ABORT_ON_NONCANONICAL:
                MR_fatal_error(msg);
                break;

            default:
                MR_fatal_error("MR_arg: bad noncanon_handling");
                break;
        }
	}

        /* Check range */
    if (expand_info.chosen_index_exists) {
        *arg_type_info_ptr = expand_info.chosen_type_info;
        *arg_ptr = expand_info.chosen_value_ptr;
        return TRUE;
    }

    return FALSE;
}

/*
** MR_named_arg() is a subroutine used to implement named_arg/2.
** It takes the address of a term, its type, and an argument name.
** If an argument with that name exists, it succeeds and returns the address
** of the argument, and its type; if it doesn't, it fails (i.e. returns FALSE).
**
** You need to wrap MR_{save/restore}_transient_hp() around
** calls to this function.
*/

bool
MR_named_arg(MR_TypeInfo type_info, MR_Word *term_ptr, MR_ConstString arg_name,
    MR_TypeInfo *arg_type_info_ptr, MR_Word **arg_ptr,
    MR_non_canon_handling noncanon_handling, MR_ConstString msg)
{
    MR_Expand_Chosen_Arg_Only_Info  expand_info;

    MR_expand_named_arg_only(type_info, term_ptr, arg_name, &expand_info);
    if (expand_info.non_canonical_type) {
        switch (noncanon_handling) {
            case MR_ALLOW_NONCANONICAL:
                break;

            case MR_FAIL_ON_NONCANONICAL:
                return FALSE;
                break;

            case MR_ABORT_ON_NONCANONICAL:
                MR_fatal_error(msg);
                break;

            default:
                MR_fatal_error("MR_named_arg: bad noncanon_handling");
                break;
        }
	}

        /* Check range */
    if (expand_info.chosen_index_exists) {
        *arg_type_info_ptr = expand_info.chosen_type_info;
        *arg_ptr = expand_info.chosen_value_ptr;
        return TRUE;
    }

    return FALSE;
}

/*
** MR_named_arg_num() takes the address of a term, its type, and an argument
** name. If the given term has an argument with the given name, it succeeds and
** returns the argument number (counted starting from 0) of the argument;
** if it doesn't, it fails (i.e. returns FALSE).
**
** You need to wrap MR_{save/restore}_transient_hp() around
** calls to this function.
*/

bool
MR_named_arg_num(MR_TypeInfo type_info, MR_Word *term_ptr,
    const char *arg_name, int *arg_num_ptr)
{
    MR_TypeCtorInfo             type_ctor_info;
    MR_DuTypeLayout             du_type_layout;
    const MR_DuPtagLayout       *ptag_layout;
    const MR_DuFunctorDesc      *functor_desc;
    const MR_NotagFunctorDesc   *notag_functor_desc;
    MR_Word                     data;
    int                         ptag;
    MR_Word                     sectag;
    MR_TypeInfo                 eqv_type_info;
    int                         i;

    type_ctor_info = MR_TYPEINFO_GET_TYPE_CTOR_INFO(type_info);

    switch (MR_type_ctor_rep(type_ctor_info)) {
        case MR_TYPECTOR_REP_RESERVED_ADDR_USEREQ:
        case MR_TYPECTOR_REP_RESERVED_ADDR:
        {
            MR_ReservedAddrTypeLayout ra_layout;
        
            ra_layout = MR_type_ctor_layout(type_ctor_info).
                layout_reserved_addr;
            data = *term_ptr;

            /*
            ** First check if this value is one of
            ** the numeric reserved addresses.
            */
            if ((MR_Unsigned) data <
                (MR_Unsigned) ra_layout->MR_ra_num_res_numeric_addrs)
            {
                /*
                ** If so, it must be a constant, and constants never have
                ** any arguments.
                */
                return FALSE;
            }

            /*
            ** Next check if this value is one of the
            ** the symbolic reserved addresses.
            */
            for (i = 0; i < ra_layout->MR_ra_num_res_symbolic_addrs; i++) {
                if (data == (MR_Word) ra_layout->MR_ra_res_symbolic_addrs[i]) {
                    return FALSE;
                }
            }
            
            /*
            ** Otherwise, it is not one of the reserved addresses,
            ** so handle it like a normal DU type.
            */
            du_type_layout = ra_layout->MR_ra_other_functors;
            goto du_type;
        }


        case MR_TYPECTOR_REP_DU_USEREQ:
        case MR_TYPECTOR_REP_DU:
            data = *term_ptr;
            du_type_layout = MR_type_ctor_layout(type_ctor_info).layout_du;
            /* fall through */

        /*
        ** This label handles both the DU case and the second half of the
        ** RESERVED_ADDR case.  `du_type_layout' and `data' must both be
        ** set before this code is entered.
        */
        du_type:
            ptag = MR_tag(data);
            ptag_layout = &du_type_layout[ptag];

            switch (ptag_layout->MR_sectag_locn) {
                case MR_SECTAG_NONE:
                    functor_desc = ptag_layout->MR_sectag_alternatives[0];
                    break;
                case MR_SECTAG_LOCAL:
                    sectag = MR_unmkbody(data);
                    functor_desc = ptag_layout->MR_sectag_alternatives[sectag];
                    break;
                case MR_SECTAG_REMOTE:
                    sectag = MR_field(ptag, data, 0);
                    functor_desc = ptag_layout->MR_sectag_alternatives[sectag];
                    break;
                case MR_SECTAG_VARIABLE:
                    MR_fatal_error("MR_named_arg_num(): unexpected variable");
            }

            if (functor_desc->MR_du_functor_arg_names == NULL) {
                return FALSE;
            }

            for (i = 0; i < functor_desc->MR_du_functor_orig_arity; i++) {
                if (functor_desc->MR_du_functor_arg_names[i] != NULL
                && streq(arg_name, functor_desc->MR_du_functor_arg_names[i]))
                {
                    *arg_num_ptr = i;
                    return TRUE;
                }
            }

            return FALSE;

        case MR_TYPECTOR_REP_EQUIV:
            eqv_type_info = MR_create_type_info(
                MR_TYPEINFO_GET_FIRST_ORDER_ARG_VECTOR(type_info),
                MR_type_ctor_layout(type_ctor_info).layout_equiv);
            return MR_named_arg_num(eqv_type_info, term_ptr, arg_name,
                arg_num_ptr);

        case MR_TYPECTOR_REP_EQUIV_GROUND:
            eqv_type_info = MR_pseudo_type_info_is_ground(
                MR_type_ctor_layout(type_ctor_info).layout_equiv);
            return MR_named_arg_num(eqv_type_info, term_ptr, arg_name,
                arg_num_ptr);

        case MR_TYPECTOR_REP_NOTAG:
        case MR_TYPECTOR_REP_NOTAG_USEREQ:
        case MR_TYPECTOR_REP_NOTAG_GROUND:
        case MR_TYPECTOR_REP_NOTAG_GROUND_USEREQ:
            notag_functor_desc = MR_type_ctor_functors(type_ctor_info).
                functors_notag;

            if (notag_functor_desc->MR_notag_functor_arg_name != NULL
            && streq(arg_name, notag_functor_desc->MR_notag_functor_arg_name))
            {
                *arg_num_ptr = 0;
                return TRUE;
            }

            return FALSE;

        default:
            return FALSE;
    }
}
