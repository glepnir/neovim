// match.c: functions for highlighting matches

#include <assert.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include "nvim/ascii_defs.h"
#include "nvim/buffer_defs.h"
#include "nvim/charset.h"
#include "nvim/decoration.h"
#include "nvim/decoration_defs.h"
#include "nvim/drawscreen.h"
#include "nvim/errors.h"
#include "nvim/eval/funcs.h"
#include "nvim/eval/typval.h"
#include "nvim/eval/window.h"
#include "nvim/ex_cmds_defs.h"
#include "nvim/ex_docmd.h"
#include "nvim/fold.h"
#include "nvim/gettext_defs.h"
#include "nvim/globals.h"
#include "nvim/grid.h"
#include "nvim/highlight.h"
#include "nvim/highlight_defs.h"
#include "nvim/highlight_group.h"
#include "nvim/macros_defs.h"
#include "nvim/match.h"
#include "nvim/mbyte.h"
#include "nvim/mbyte_defs.h"
#include "nvim/memline.h"
#include "nvim/memory.h"
#include "nvim/message.h"
#include "nvim/option_vars.h"
#include "nvim/pos_defs.h"
#include "nvim/profile.h"
#include "nvim/regexp.h"
#include "nvim/strings.h"
#include "nvim/types_defs.h"
#include "nvim/vim_defs.h"

#include "match.c.generated.h"

static const char *e_invalwindow = N_("E957: Invalid window number");

#define SEARCH_HL_PRIORITY 0

/// Add match to the match list of window "wp".
/// If "pat" is not NULL the pattern will be highlighted with the group "grp"
/// with priority "prio".
/// If "pos_list" is not NULL the list of positions defines the highlights.
/// Optionally, a desired ID "id" can be specified (greater than or equal to 1).
/// If no particular ID is desired, -1 must be specified for "id".
///
/// @param[in] conceal_char pointer to conceal replacement char
/// @return ID of added match, -1 on failure.
static int match_add(win_T *wp, const char *const grp, const char *const pat, int prio, int id,
                     list_T *pos_list, const char *const conceal_char)
  FUNC_ATTR_NONNULL_ARG(1, 2)
{
  int hlg_id;
  regprog_T *regprog = NULL;
  int rtype = UPD_SOME_VALID;

  if (*grp == NUL || (pat != NULL && *pat == NUL)) {
    return -1;
  }
  if (id < -1 || id == 0) {
    semsg(_("E799: Invalid ID: %" PRId64
            " (must be greater than or equal to 1)"),
          (int64_t)id);
    return -1;
  }
  if (id == -1) {
    // use the next available match ID
    id = wp->w_next_match_id++;
  } else {
    // check the given ID is not already in use
    for (matchitem_T *cur = wp->w_match_head; cur != NULL; cur = cur->mit_next) {
      if (cur->mit_id == id) {
        semsg(_("E801: ID already taken: %" PRId64), (int64_t)id);
        return -1;
      }
    }

    // Make sure the next match ID is always higher than the highest
    // manually selected ID.  Add some extra in case a few more IDs are
    // added soon.
    if (wp->w_next_match_id < id + 100) {
      wp->w_next_match_id = id + 100;
    }
  }

  if ((hlg_id = syn_check_group(grp, strlen(grp))) == 0) {
    return -1;
  }
  if (pat != NULL && (regprog = vim_regcomp(pat, RE_MAGIC)) == NULL) {
    semsg(_(e_invarg2), pat);
    return -1;
  }

  // Build new match.
  matchitem_T *m = xcalloc(1, sizeof(matchitem_T));
  if (tv_list_len(pos_list) > 0) {
    m->mit_pos_array = xcalloc((size_t)tv_list_len(pos_list), sizeof(llpos_T));
    m->mit_pos_count = tv_list_len(pos_list);
  }
  m->mit_id = id;
  m->mit_priority = prio;
  m->mit_pattern = pat == NULL ? NULL : xstrdup(pat);
  m->mit_hlg_id = hlg_id;
  m->mit_match.regprog = regprog;
  m->mit_match.rmm_ic = false;
  m->mit_match.rmm_maxcol = 0;
  m->mit_conceal_char = 0;
  if (conceal_char != NULL) {
    m->mit_conceal_char = utf_ptr2char(conceal_char);
  }

  // Set up position matches
  if (pos_list != NULL) {
    linenr_T toplnum = 0;
    linenr_T botlnum = 0;

    int i = 0;
    TV_LIST_ITER(pos_list, li, {
      linenr_T lnum = 0;
      colnr_T col = 0;
      int len = 1;
      bool error = false;

      if (TV_LIST_ITEM_TV(li)->v_type == VAR_LIST) {
        const list_T *const subl = TV_LIST_ITEM_TV(li)->vval.v_list;
        const listitem_T *subli = tv_list_first(subl);
        if (subli == NULL) {
          semsg(_("E5030: Empty list at position %d"),
                (int)tv_list_idx_of_item(pos_list, li));
          goto fail;
        }
        lnum = (linenr_T)tv_get_number_chk(TV_LIST_ITEM_TV(subli), &error);
        if (error) {
          goto fail;
        }
        if (lnum <= 0) {
          continue;
        }
        m->mit_pos_array[i].lnum = lnum;
        subli = TV_LIST_ITEM_NEXT(subl, subli);
        if (subli != NULL) {
          col = (colnr_T)tv_get_number_chk(TV_LIST_ITEM_TV(subli), &error);
          if (error) {
            goto fail;
          }
          if (col < 0) {
            continue;
          }
          subli = TV_LIST_ITEM_NEXT(subl, subli);
          if (subli != NULL) {
            len = (colnr_T)tv_get_number_chk(TV_LIST_ITEM_TV(subli), &error);
            if (len < 0) {
              continue;
            }
            if (error) {
              goto fail;
            }
          }
        }
        m->mit_pos_array[i].col = col;
        m->mit_pos_array[i].len = len;
      } else if (TV_LIST_ITEM_TV(li)->v_type == VAR_NUMBER) {
        if (TV_LIST_ITEM_TV(li)->vval.v_number <= 0) {
          continue;
        }
        m->mit_pos_array[i].lnum = (linenr_T)TV_LIST_ITEM_TV(li)->vval.v_number;
        m->mit_pos_array[i].col = 0;
        m->mit_pos_array[i].len = 0;
      } else {
        semsg(_("E5031: List or number required at position %d"),
              (int)tv_list_idx_of_item(pos_list, li));
        goto fail;
      }
      if (toplnum == 0 || lnum < toplnum) {
        toplnum = lnum;
      }
      if (botlnum == 0 || lnum >= botlnum) {
        botlnum = lnum + 1;
      }
      i++;
    });

    // Calculate top and bottom lines for redrawing area
    if (toplnum != 0) {
      redraw_win_range_later(wp, toplnum, botlnum);
      m->mit_toplnum = toplnum;
      m->mit_botlnum = botlnum;
      rtype = UPD_VALID;
    }
  }

  // Insert new match.  The match list is in ascending order with regard to
  // the match priorities.
  matchitem_T *cur = wp->w_match_head;
  matchitem_T *prev = cur;
  while (cur != NULL && prio >= cur->mit_priority) {
    prev = cur;
    cur = cur->mit_next;
  }
  if (cur == prev) {
    wp->w_match_head = m;
  } else {
    prev->mit_next = m;
  }
  m->mit_next = cur;

  redraw_later(wp, rtype);
  return id;

fail:
  vim_regfree(regprog);
  xfree(m->mit_pattern);
  xfree(m->mit_pos_array);
  xfree(m);
  return -1;
}

/// Delete match with ID 'id' in the match list of window 'wp'.
///
/// @param perr  print error messages if true.
static int match_delete(win_T *wp, int id, bool perr)
{
  matchitem_T *cur = wp->w_match_head;
  matchitem_T *prev = cur;
  int rtype = UPD_SOME_VALID;

  if (id < 1) {
    if (perr) {
      semsg(_("E802: Invalid ID: %" PRId64 " (must be greater than or equal to 1)"),
            (int64_t)id);
    }
    return -1;
  }
  while (cur != NULL && cur->mit_id != id) {
    prev = cur;
    cur = cur->mit_next;
  }
  if (cur == NULL) {
    if (perr) {
      semsg(_("E803: ID not found: %" PRId64), (int64_t)id);
    }
    return -1;
  }
  if (cur == prev) {
    wp->w_match_head = cur->mit_next;
  } else {
    prev->mit_next = cur->mit_next;
  }
  vim_regfree(cur->mit_match.regprog);
  xfree(cur->mit_pattern);
  if (cur->mit_toplnum != 0) {
    redraw_win_range_later(wp, cur->mit_toplnum, cur->mit_botlnum);
    rtype = UPD_VALID;
  }
  xfree(cur->mit_pos_array);
  xfree(cur);
  redraw_later(wp, rtype);
  return 0;
}

/// Delete all matches in the match list of window 'wp'.
void clear_matches(win_T *wp)
{
  while (wp->w_match_head != NULL) {
    matchitem_T *m = wp->w_match_head->mit_next;
    vim_regfree(wp->w_match_head->mit_match.regprog);
    xfree(wp->w_match_head->mit_pattern);
    xfree(wp->w_match_head->mit_pos_array);
    xfree(wp->w_match_head);
    wp->w_match_head = m;
  }
  redraw_later(wp, UPD_SOME_VALID);
}

/// Get match from ID 'id' in window 'wp'.
/// Return NULL if match not found.
static matchitem_T *get_match(win_T *wp, int id)
{
  matchitem_T *cur = wp->w_match_head;

  while (cur != NULL && cur->mit_id != id) {
    cur = cur->mit_next;
  }
  return cur;
}

/// Init for calling prepare_search_hl().
void init_search_hl(win_T *wp, match_T *search_hl)
  FUNC_ATTR_NONNULL_ALL
{
  // Setup for 'hlsearch' highlighting only.
  // matchadd()/matchaddpos() are handled per-line by match_fill_line_extmarks().
  search_hl->buf = wp->w_buffer;
  search_hl->lnum = 0;
  search_hl->first_lnum = 0;
  search_hl->attr = win_hl_attr(wp, HLF_L);

  // Initialise multi-line prescan state for regex-based matchadd() items.
  for (matchitem_T *cur = wp->w_match_head; cur != NULL; cur = cur->mit_next) {
    if (cur->mit_match.regprog == NULL || !re_multiline(cur->mit_match.regprog)) {
      cur->mit_ml_first_lnum = 0;
      continue;
    }
    // Shared regprog pointer — do NOT free cur->mit_ml_rm.regprog independently.
    cur->mit_ml_rm = cur->mit_match;
    cur->mit_ml_first_lnum = 0;  // computed lazily on first prescan call
    cur->mit_ml_tm = profile_setlimit(p_rdt);
  }

  // time limit is set at the toplevel, for all windows
}

/// Search for a next 'hlsearch' match.
/// Uses shl->buf.
/// Sets shl->lnum and shl->rm contents.
/// Note: Assumes a previous match is always before "lnum", unless
/// shl->lnum is zero.
/// Careful: Any pointers for buffer lines will become invalid.
///
/// @param shl     points to search_hl
/// @param mincol  minimal column for a match
static void next_search_hl(win_T *win, match_T *shl, linenr_T lnum, colnr_T mincol)
  FUNC_ATTR_NONNULL_ALL
{
  colnr_T matchcol;
  int nmatched = 0;
  const int called_emsg_before = called_emsg;

  // for :{range}s/pat only highlight inside the range
  if (lnum < search_first_line || lnum > search_last_line) {
    shl->lnum = 0;
    return;
  }

  if (shl->lnum != 0) {
    linenr_T l = shl->lnum + shl->rm.endpos[0].lnum - shl->rm.startpos[0].lnum;
    if (lnum > l) {
      shl->lnum = 0;
    } else if (lnum < l || shl->rm.endpos[0].col > mincol) {
      return;
    }
  }

  while (true) {
    if (profile_passed_limit(shl->tm)) {
      shl->lnum = 0;
      break;
    }
    if (shl->lnum == 0) {
      matchcol = 0;
    } else if (vim_strchr(p_cpo, CPO_SEARCH) == NULL
               || (shl->rm.endpos[0].lnum == 0
                   && shl->rm.endpos[0].col <= shl->rm.startpos[0].col)) {
      matchcol = shl->rm.startpos[0].col;
      char *ml = ml_get_buf(shl->buf, lnum) + matchcol;
      if (*ml == NUL) {
        matchcol++;
        shl->lnum = 0;
        break;
      }
      matchcol += utfc_ptr2len(ml);
    } else {
      matchcol = shl->rm.endpos[0].col;
    }

    shl->lnum = lnum;
    if (shl->rm.regprog != NULL) {
      int timed_out = false;
      nmatched = vim_regexec_multi(&shl->rm, win, shl->buf, lnum, matchcol,
                                   &(shl->tm), &timed_out);
      if (called_emsg > called_emsg_before || got_int || timed_out) {
        vim_regfree(shl->rm.regprog);
        set_no_hlsearch(true);
        shl->rm.regprog = NULL;
        shl->lnum = 0;
        got_int = false;
        break;
      }
    } else {
      nmatched = 0;
    }
    if (nmatched == 0) {
      shl->lnum = 0;
      break;
    }
    if (shl->rm.startpos[0].lnum > 0
        || shl->rm.startpos[0].col >= mincol
        || nmatched > 1
        || shl->rm.endpos[0].col > mincol) {
      shl->lnum += shl->rm.startpos[0].lnum;
      break;
    }
  }
}

/// Advance to the match in window "wp" line "lnum" or past it.
void prepare_search_hl(win_T *wp, match_T *search_hl, linenr_T lnum)
  FUNC_ATTR_NONNULL_ALL
{
  // Only handle hlsearch multi-line pattern prescan.
  // matchadd() regex matches are handled by match_fill_line_extmarks().
  match_T *shl = search_hl;

  if (shl->rm.regprog != NULL
      && shl->lnum == 0
      && re_multiline(shl->rm.regprog)) {
    if (shl->first_lnum == 0) {
      for (shl->first_lnum = lnum;
           shl->first_lnum > wp->w_topline;
           shl->first_lnum--) {
        if (hasFolding(wp, shl->first_lnum - 1, NULL, NULL)) {
          break;
        }
      }
    }
    int n = 0;
    while (shl->first_lnum < lnum && shl->rm.regprog != NULL) {
      next_search_hl(wp, shl, shl->first_lnum, (colnr_T)n);
      if (shl->lnum != 0) {
        shl->first_lnum = shl->lnum
                          + shl->rm.endpos[0].lnum
                          - shl->rm.startpos[0].lnum;
        n = shl->rm.endpos[0].col;
      } else {
        shl->first_lnum++;
        n = 0;
      }
    }
  }
}

/// Update "shl->has_cursor" based on the match in "shl" and the cursor
/// position.
static void check_cur_search_hl(win_T *wp, match_T *shl)
{
  linenr_T linecount = shl->rm.endpos[0].lnum - shl->rm.startpos[0].lnum;

  if (wp->w_cursor.lnum >= shl->lnum
      && wp->w_cursor.lnum <= shl->lnum + linecount
      && (wp->w_cursor.lnum > shl->lnum || wp->w_cursor.col >= shl->rm.startpos[0].col)
      && (wp->w_cursor.lnum < shl->lnum + linecount || wp->w_cursor.col < shl->rm.endpos[0].col)) {
    shl->has_cursor = true;
  } else {
    shl->has_cursor = false;
  }
}

/// Prepare for 'hlsearch' highlighting in one window line.
///
/// @return  true if there is such highlighting and set "search_attr" to the
///          current highlight attribute.
bool prepare_search_hl_line(win_T *wp, linenr_T lnum, colnr_T mincol, char **line,
                            match_T *search_hl, int *search_attr)
{
  // Only handle hlsearch. matchadd() is handled by match_fill_line_extmarks().
  match_T *shl = search_hl;
  bool area_highlighting = false;

  shl->startcol = MAXCOL;
  shl->endcol = MAXCOL;
  shl->attr_cur = 0;
  shl->is_addpos = false;
  shl->has_cursor = false;
  next_search_hl(wp, shl, lnum, mincol);

  // Need to get the line again, a multi-line regexp may have made it invalid.
  *line = ml_get_buf(wp->w_buffer, lnum);

  if (shl->lnum != 0 && shl->lnum <= lnum) {
    if (shl->lnum == lnum) {
      shl->startcol = shl->rm.startpos[0].col;
    } else {
      shl->startcol = 0;
    }
    if (lnum == shl->lnum + shl->rm.endpos[0].lnum - shl->rm.startpos[0].lnum) {
      shl->endcol = shl->rm.endpos[0].col;
    } else {
      shl->endcol = MAXCOL;
    }

    check_cur_search_hl(wp, shl);

    // Highlight one character for an empty match.
    if (shl->startcol == shl->endcol) {
      if ((*line)[shl->endcol] != NUL) {
        shl->endcol += utfc_ptr2len(*line + shl->endcol);
      } else {
        shl->endcol++;
      }
    }
    if (shl->startcol < mincol) {  // match at leftcol
      shl->attr_cur = shl->attr;
      *search_attr = shl->attr;
    }
    area_highlighting = true;
  }
  return area_highlighting;
}

/// For a position in a line: Check for start/end of 'hlsearch'.
/// After end, check for start/end of next match.
/// When another match, have to check for start again.
/// Watch out for matching an empty string!
/// "on_last_col" is set to true with non-zero search_attr and the next column
/// is endcol.
/// Return the updated search_attr.
int update_search_hl(win_T *wp, linenr_T lnum, colnr_T col, char **line, match_T *search_hl,
                     bool lcs_eol_todo, bool *on_last_col)
{
  // Only handle hlsearch. matchadd() highlights are in DecorState.
  match_T *shl = search_hl;
  int search_attr = 0;

  while (shl->rm.regprog != NULL) {
    if (shl->startcol != MAXCOL
        && col >= shl->startcol
        && col < shl->endcol) {
      int next_col = col + utfc_ptr2len(*line + col);

      if (shl->endcol < next_col) {
        shl->endcol = next_col;
      }
      // Highlight the match where the cursor is using the CurSearch group.
      if (shl->has_cursor) {
        shl->attr_cur = win_hl_attr(wp, HLF_LC);
        if (shl->attr_cur != shl->attr) {
          search_hl_has_cursor_lnum = lnum;
        }
      } else {
        shl->attr_cur = shl->attr;
      }
    } else if (col == shl->endcol) {
      shl->attr_cur = 0;

      next_search_hl(wp, shl, lnum, col);

      // Need to get the line again, a multi-line regexp may have made it invalid.
      *line = ml_get_buf(wp->w_buffer, lnum);

      if (shl->lnum == lnum) {
        shl->startcol = shl->rm.startpos[0].col;
        if (shl->rm.endpos[0].lnum == 0) {
          shl->endcol = shl->rm.endpos[0].col;
        } else {
          shl->endcol = MAXCOL;
        }

        check_cur_search_hl(wp, shl);

        if (shl->startcol == shl->endcol) {
          // highlight empty match, try again after it
          char *p = *line + shl->endcol;
          if (*p == NUL) {
            shl->endcol++;
          } else {
            shl->endcol += utfc_ptr2len(p);
          }
        }

        // Loop to check if the match starts at the current position.
        continue;
      }
    }
    break;
  }

  search_attr = shl->attr_cur;
  if (search_attr != 0) {
    *on_last_col = col + 1 >= shl->endcol;
  }
  // Only highlight one character after the last column.
  if (*(*line + col) == NUL && (wp->w_p_list && !lcs_eol_todo)) {
    search_attr = 0;
  }
  return search_attr;
}

bool get_prevcol_hl_flag(win_T *wp, match_T *search_hl, colnr_T curcol)
{
  colnr_T prevcol = curcol;

  // we're not really at that column when skipping some text
  if ((wp->w_p_wrap ? wp->w_skipcol : wp->w_leftcol) > prevcol) {
    prevcol++;
  }

  // hlsearch: highlight char after EOL if match started/continues there.
  if (prevcol == search_hl->startcol
      || (prevcol > search_hl->startcol && search_hl->endcol == MAXCOL)) {
    return true;
  }

  // matchadd() multi-line ranges use end_col=MAXCOL and remain in
  // current_end through decor_redraw_col(col=NUL).  Any such range means
  // we need to highlight the EOL cell.
  int *const indices = decor_state.ranges_i.items;
  DecorRangeSlot *const slots = decor_state.slots.items;
  for (int i = 0; i < decor_state.current_end; i++) {
    if (slots[indices[i]].range.end_col == MAXCOL) {
      return true;
    }
  }

  return false;
}

/// Get highlighting for the char after the text in "char_attr" from 'hlsearch'.
void get_search_match_hl(win_T *wp, match_T *search_hl, colnr_T col, int *char_attr)
{
  // hlsearch only. matchadd() highlights are in DecorState.
  if (col - 1 == search_hl->startcol) {
    *char_attr = search_hl->attr;
  }
}

static int matchadd_dict_arg(typval_T *tv, const char **conceal_char, win_T **win)
{
  dictitem_T *di;

  if (tv->v_type != VAR_DICT) {
    emsg(_(e_dictreq));
    return FAIL;
  }

  if ((di = tv_dict_find(tv->vval.v_dict, S_LEN("conceal"))) != NULL) {
    *conceal_char = tv_get_string(&di->di_tv);
  }

  if ((di = tv_dict_find(tv->vval.v_dict, S_LEN("window"))) == NULL) {
    return OK;
  }

  *win = find_win_by_nr_or_id(&di->di_tv);
  if (*win == NULL) {
    emsg(_(e_invalwindow));
    return FAIL;
  }

  return OK;
}

/// "clearmatches()" function
void f_clearmatches(typval_T *argvars, typval_T *rettv, EvalFuncData fptr)
{
  win_T *win = get_optional_window(argvars, 0);

  if (win != NULL) {
    clear_matches(win);
  }
}

/// "getmatches()" function
void f_getmatches(typval_T *argvars, typval_T *rettv, EvalFuncData fptr)
{
  win_T *win = get_optional_window(argvars, 0);

  tv_list_alloc_ret(rettv, kListLenMayKnow);
  if (win == NULL) {
    return;
  }

  matchitem_T *cur = win->w_match_head;
  while (cur != NULL) {
    dict_T *dict = tv_dict_alloc();
    if (cur->mit_match.regprog == NULL) {
      // match added with matchaddpos()
      for (int i = 0; i < cur->mit_pos_count; i++) {
        llpos_T *llpos;
        char buf[30];  // use 30 to avoid compiler warning

        llpos = &cur->mit_pos_array[i];
        if (llpos->lnum == 0) {
          break;
        }
        list_T *const l = tv_list_alloc(1 + (llpos->col > 0 ? 2 : 0));
        tv_list_append_number(l, (varnumber_T)llpos->lnum);
        if (llpos->col > 0) {
          tv_list_append_number(l, (varnumber_T)llpos->col);
          tv_list_append_number(l, (varnumber_T)llpos->len);
        }
        int len = snprintf(buf, sizeof(buf), "pos%d", i + 1);
        assert((size_t)len < sizeof(buf));
        tv_dict_add_list(dict, buf, (size_t)len, l);
      }
    } else {
      tv_dict_add_str(dict, S_LEN("pattern"), cur->mit_pattern);
    }
    tv_dict_add_str(dict, S_LEN("group"), syn_id2name(cur->mit_hlg_id));
    tv_dict_add_nr(dict, S_LEN("priority"), (varnumber_T)cur->mit_priority);
    tv_dict_add_nr(dict, S_LEN("id"), (varnumber_T)cur->mit_id);

    if (cur->mit_conceal_char) {
      char buf[MB_MAXCHAR + 1];

      buf[utf_char2bytes(cur->mit_conceal_char, buf)] = NUL;
      tv_dict_add_str(dict, S_LEN("conceal"), buf);
    }

    tv_list_append_dict(rettv->vval.v_list, dict);
    cur = cur->mit_next;
  }
}

/// "setmatches()" function
void f_setmatches(typval_T *argvars, typval_T *rettv, EvalFuncData fptr)
{
  dict_T *d;
  list_T *s = NULL;
  win_T *win = get_optional_window(argvars, 1);

  rettv->vval.v_number = -1;
  if (argvars[0].v_type != VAR_LIST) {
    emsg(_(e_listreq));
    return;
  }
  if (win == NULL) {
    return;
  }

  list_T *const l = argvars[0].vval.v_list;
  // To some extent make sure that we are dealing with a list from
  // "getmatches()".
  int li_idx = 0;
  TV_LIST_ITER_CONST(l, li, {
    if (TV_LIST_ITEM_TV(li)->v_type != VAR_DICT
        || (d = TV_LIST_ITEM_TV(li)->vval.v_dict) == NULL) {
      semsg(_("E474: List item %d is either not a dictionary "
              "or an empty one"), li_idx);
      return;
    }
    if (!(tv_dict_find(d, S_LEN("group")) != NULL
          && (tv_dict_find(d, S_LEN("pattern")) != NULL
              || tv_dict_find(d, S_LEN("pos1")) != NULL)
          && tv_dict_find(d, S_LEN("priority")) != NULL
          && tv_dict_find(d, S_LEN("id")) != NULL)) {
      semsg(_("E474: List item %d is missing one of the required keys"),
            li_idx);
      return;
    }
    li_idx++;
  });

  clear_matches(win);
  bool match_add_failed = false;
  TV_LIST_ITER_CONST(l, li, {
    int i = 0;

    d = TV_LIST_ITEM_TV(li)->vval.v_dict;
    dictitem_T *const di = tv_dict_find(d, S_LEN("pattern"));
    if (di == NULL) {
      if (s == NULL) {
        s = tv_list_alloc(9);
      }

      // match from matchaddpos()
      for (i = 1; i < 9; i++) {
        char buf[30];  // use 30 to avoid compiler warning
        snprintf(buf, sizeof(buf), "pos%d", i);
        dictitem_T *const pos_di = tv_dict_find(d, buf, -1);
        if (pos_di != NULL) {
          if (pos_di->di_tv.v_type != VAR_LIST) {
            return;
          }

          tv_list_append_tv(s, &pos_di->di_tv);
          tv_list_ref(s);
        } else {
          break;
        }
      }
    }

    // Note: there are three number buffers involved:
    // - group_buf below.
    // - numbuf in tv_dict_get_string().
    // - mybuf in tv_get_string().
    //
    // If you change this code make sure that buffers will not get
    // accidentally reused.
    char group_buf[NUMBUFLEN];
    const char *const group = tv_dict_get_string_buf(d, "group", group_buf);
    const int priority = (int)tv_dict_get_number(d, "priority");
    const int id = (int)tv_dict_get_number(d, "id");
    dictitem_T *const conceal_di = tv_dict_find(d, S_LEN("conceal"));
    const char *const conceal = (conceal_di != NULL
                                 ? tv_get_string(&conceal_di->di_tv)
                                 : NULL);
    if (i == 0) {
      if (match_add(win, group,
                    tv_dict_get_string(d, "pattern", false),
                    priority, id, NULL, conceal) != id) {
        match_add_failed = true;
      }
    } else {
      if (match_add(win, group, NULL, priority, id, s, conceal) != id) {
        match_add_failed = true;
      }
      tv_list_unref(s);
      s = NULL;
    }
  });
  if (!match_add_failed) {
    rettv->vval.v_number = 0;
  }
}

/// "matchadd()" function
void f_matchadd(typval_T *argvars, typval_T *rettv, EvalFuncData fptr)
{
  char grpbuf[NUMBUFLEN];
  char patbuf[NUMBUFLEN];
  // group
  const char *const grp = tv_get_string_buf_chk(&argvars[0], grpbuf);
  // pattern
  const char *const pat = tv_get_string_buf_chk(&argvars[1], patbuf);
  // default priority
  int prio = 10;
  int id = -1;
  bool error = false;
  const char *conceal_char = NULL;
  win_T *win = curwin;

  rettv->vval.v_number = -1;

  if (grp == NULL || pat == NULL) {
    return;
  }
  if (argvars[2].v_type != VAR_UNKNOWN) {
    prio = (int)tv_get_number_chk(&argvars[2], &error);
    if (argvars[3].v_type != VAR_UNKNOWN) {
      id = (int)tv_get_number_chk(&argvars[3], &error);
      if (argvars[4].v_type != VAR_UNKNOWN
          && matchadd_dict_arg(&argvars[4], &conceal_char, &win) == FAIL) {
        return;
      }
    }
  }
  if (error) {
    return;
  }
  if (id >= 1 && id <= 3) {
    semsg(_("E798: ID is reserved for \":match\": %d"), id);
    return;
  }

  rettv->vval.v_number = match_add(win, grp, pat, prio, id, NULL, conceal_char);
}

/// "matchaddpo()" function
void f_matchaddpos(typval_T *argvars, typval_T *rettv, EvalFuncData fptr)
{
  rettv->vval.v_number = -1;

  char buf[NUMBUFLEN];
  const char *const group = tv_get_string_buf_chk(&argvars[0], buf);
  if (group == NULL) {
    return;
  }

  if (argvars[1].v_type != VAR_LIST) {
    semsg(_(e_listarg), "matchaddpos()");
    return;
  }

  list_T *l;
  l = argvars[1].vval.v_list;
  if (tv_list_len(l) == 0) {
    return;
  }

  bool error = false;
  int prio = 10;
  int id = -1;
  const char *conceal_char = NULL;
  win_T *win = curwin;

  if (argvars[2].v_type != VAR_UNKNOWN) {
    prio = (int)tv_get_number_chk(&argvars[2], &error);
    if (argvars[3].v_type != VAR_UNKNOWN) {
      id = (int)tv_get_number_chk(&argvars[3], &error);
      if (argvars[4].v_type != VAR_UNKNOWN
          && matchadd_dict_arg(&argvars[4], &conceal_char, &win) == FAIL) {
        return;
      }
    }
  }
  if (error == true) {
    return;
  }

  // id == 3 is ok because matchaddpos() is supposed to substitute :3match
  if (id == 1 || id == 2) {
    semsg(_("E798: ID is reserved for \"match\": %d"), id);
    return;
  }

  rettv->vval.v_number = match_add(win, group, NULL, prio, id, l, conceal_char);
}

/// "matcharg()" function
void f_matcharg(typval_T *argvars, typval_T *rettv, EvalFuncData fptr)
{
  const int id = (int)tv_get_number(&argvars[0]);

  tv_list_alloc_ret(rettv, (id >= 1 && id <= 3
                            ? 2
                            : 0));

  if (id >= 1 && id <= 3) {
    matchitem_T *const m = get_match(curwin, id);

    if (m != NULL) {
      tv_list_append_string(rettv->vval.v_list, syn_id2name(m->mit_hlg_id), -1);
      tv_list_append_string(rettv->vval.v_list, m->mit_pattern, -1);
    } else {
      tv_list_append_string(rettv->vval.v_list, NULL, 0);
      tv_list_append_string(rettv->vval.v_list, NULL, 0);
    }
  }
}

/// "matchdelete()" function
void f_matchdelete(typval_T *argvars, typval_T *rettv, EvalFuncData fptr)
{
  win_T *win = get_optional_window(argvars, 1);
  if (win == NULL) {
    rettv->vval.v_number = -1;
  } else {
    rettv->vval.v_number = match_delete(win,
                                        (int)tv_get_number(&argvars[0]), true);
  }
}

/// ":[N]match {group} {pattern}"
/// Sets nextcmd to the start of the next command, if any.  Also called when
/// skipping commands to find the next command.
void ex_match(exarg_T *eap)
{
  char *g = NULL;
  char *end;
  int id;

  if (eap->line2 <= 3) {
    id = (int)eap->line2;
  } else {
    emsg(e_invcmd);
    return;
  }

  // First clear any old pattern.
  if (!eap->skip) {
    match_delete(curwin, id, false);
  }

  if (ends_excmd(*eap->arg)) {
    end = eap->arg;
  } else if ((STRNICMP(eap->arg, "none", 4) == 0
              && (ascii_iswhite(eap->arg[4]) || ends_excmd(eap->arg[4])))) {
    end = eap->arg + 4;
  } else {
    char *p = skiptowhite(eap->arg);
    if (!eap->skip) {
      g = xmemdupz(eap->arg, (size_t)(p - eap->arg));
    }
    p = skipwhite(p);
    if (*p == NUL) {
      // There must be two arguments.
      xfree(g);
      semsg(_(e_invarg2), eap->arg);
      return;
    }
    end = skip_regexp(p + 1, *p, true);
    if (!eap->skip) {
      if (*end != NUL && !ends_excmd(*skipwhite(end + 1))) {
        xfree(g);
        eap->errmsg = ex_errmsg(e_trailing_arg, end);
        return;
      }
      if (*end != *p) {
        xfree(g);
        semsg(_(e_invarg2), p);
        return;
      }

      int c = (uint8_t)(*end);
      *end = NUL;
      match_add(curwin, g, p + 1, 10, id, NULL, NULL);
      xfree(g);
      *end = (char)c;
    }
  }
  eap->nextcmd = find_nextcmd(end);
}

/// Add a single highlight decoration range to DecorState for the current line.
static void match_add_decor(int row, colnr_T start_col, colnr_T end_col,
                            DecorHighlightInline *hl_base)
{
  DecorSignHighlight sh = decor_sh_from_inline(*hl_base);
  decor_range_add_sh(&decor_state, row, start_col, row, end_col,
                     &sh, true, 0, 0, 0);
}

/// For multi-line regex patterns, find matches that started on a line before
/// `lnum` and extend into it, injecting the visible portion into DecorState.
/// Mirrors the old prepare_search_hl() prescan loop for matchadd items.
static void match_prescan_multiline(win_T *wp, matchitem_T *cur, linenr_T lnum,
                                    int row, DecorHighlightInline *hl_base)
{
  buf_T *buf = wp->w_buffer;

  // Initialise first_lnum once per redraw: walk backward from lnum to
  // w_topline, stopping just after a closed fold.
  if (cur->mit_ml_first_lnum == 0) {
    cur->mit_ml_first_lnum = lnum;
    for (; cur->mit_ml_first_lnum > wp->w_topline; cur->mit_ml_first_lnum--) {
      if (hasFolding(wp, cur->mit_ml_first_lnum - 1, NULL, NULL)) {
        break;
      }
    }
  }

  colnr_T n = 0;
  linenr_T scan_lnum = cur->mit_ml_first_lnum;

  while (scan_lnum < lnum) {
    if (profile_passed_limit(cur->mit_ml_tm)) {
      break;
    }
    // Re-sync regprog: vim_regexec_multi() may recompile it internally.
    cur->mit_ml_rm.regprog = cur->mit_match.regprog;

    int timed_out = false;
    int nmatched = vim_regexec_multi(&cur->mit_ml_rm, wp, buf,
                                     scan_lnum, n, &cur->mit_ml_tm, &timed_out);
    cur->mit_match.regprog = cur->mit_ml_rm.regprog;

    // Clear got_int: don't show "Type :quit" from a regexp error in redraw.
    if (got_int || timed_out) {
      got_int = false;
      break;
    }
    if (nmatched == 0) {
      scan_lnum++;
      n = 0;
      continue;
    }

    linenr_T match_start = scan_lnum + cur->mit_ml_rm.startpos[0].lnum;
    linenr_T match_end   = scan_lnum + cur->mit_ml_rm.endpos[0].lnum;

    if (match_end >= lnum && match_start <= lnum) {
      colnr_T s_col = (match_start < lnum) ? 0 : cur->mit_ml_rm.startpos[0].col;
      // Use MAXCOL when match continues past lnum: keeps range alive through
      // decor_redraw_col(col=NUL), so get_prevcol_hl_flag() can find it.
      colnr_T e_col = (match_end > lnum) ? MAXCOL : cur->mit_ml_rm.endpos[0].col;
      if (s_col < e_col) {
        match_add_decor(row, s_col, e_col, hl_base);
      }
      // Leave first_lnum at scan_lnum so the next call (for lnum+1, lnum+2…)
      // re-executes the regex from here and re-discovers the same match,
      // injecting the correct column range for each successive covered line.
      cur->mit_ml_first_lnum = scan_lnum;
      return;
    }

    // Match entirely before lnum: advance past it.
    scan_lnum = match_end;
    n = cur->mit_ml_rm.endpos[0].col;
    // Guard against empty match causing infinite loop.
    if (cur->mit_ml_rm.endpos[0].lnum == cur->mit_ml_rm.startpos[0].lnum
        && n == cur->mit_ml_rm.startpos[0].col) {
      char *ml = ml_get_buf(buf, scan_lnum);
      if (ml[n] == NUL) {
        scan_lnum++;
        n = 0;
      } else {
        n += utfc_ptr2len(ml + n);
      }
    }
  }
  cur->mit_ml_first_lnum = scan_lnum;
}

/// Inject matchadd()/matchaddpos() highlights for `lnum` into DecorState as
/// ephemeral ranges.  Called once per line from win_line(), after
/// decor_redraw_line() and before the main character loop.
void match_fill_line_extmarks(win_T *wp, linenr_T lnum)
{
  buf_T *buf = wp->w_buffer;
  int row = (int)lnum - 1;
  int conceal_hlg_id = syn_name2id("Conceal");

  for (matchitem_T *cur = wp->w_match_head; cur != NULL; cur = cur->mit_next) {
    if (cur->mit_hlg_id == 0) {
      continue;
    }

    DecorHighlightInline hl_base = DECOR_HIGHLIGHT_INLINE_INIT;
    hl_base.hl_id = cur->mit_hlg_id;
    hl_base.priority = (DecorPriority)cur->mit_priority;

    if (cur->mit_conceal_char != 0) {
      hl_base.conceal_char = schar_from_char(cur->mit_conceal_char);
      hl_base.flags |= kSHConceal;
    } else if (cur->mit_hlg_id == conceal_hlg_id) {
      // matchadd('Conceal', pat) without replacement char still conceals.
      hl_base.flags |= kSHConceal;
    }

    if (cur->mit_match.regprog != NULL) {
      // --- matchadd() regex branch ---
      if (re_multiline(cur->mit_match.regprog)) {
        match_prescan_multiline(wp, cur, lnum, row, &hl_base);
      }

      regmmatch_T regmatch = cur->mit_match;
      colnr_T matchcol = 0;
      proftime_T tm = profile_setlimit(p_rdt);

      while (true) {
        if (profile_passed_limit(tm)) {
          break;
        }
        int timed_out = false;
        int nmatched = vim_regexec_multi(&regmatch, wp, buf, lnum, matchcol,
                                         &tm, &timed_out);
        cur->mit_match.regprog = regmatch.regprog;
        if (nmatched == 0 || timed_out || got_int) {
          got_int = false;
          break;
        }
        if (regmatch.startpos[0].lnum > 0) {
          break;  // match starts on a later line
        }

        colnr_T start_col = regmatch.startpos[0].col;
        // Use MAXCOL for multi-line match: keeps range alive at NUL position
        // so decor_redraw_col contributes the attr to wlv.char_attr, and
        // get_prevcol_hl_flag() finds it in current_end.
        colnr_T end_col = (regmatch.endpos[0].lnum == 0)
                          ? regmatch.endpos[0].col : MAXCOL;

        // Empty match: highlight one character.
        if (start_col == end_col) {
          char *ml = ml_get_buf(buf, lnum);
          if (ml[end_col] != NUL) {
            end_col += utfc_ptr2len(ml + end_col);
          } else {
            end_col = MAXCOL;
          }
        }

        match_add_decor(row, start_col, end_col, &hl_base);

        if (end_col == MAXCOL) {
          break;  // highlighted to EOL; no further matches on this line
        }
        matchcol = regmatch.endpos[0].col;
        // Guard against zero-width match causing infinite loop.
        if (matchcol == regmatch.startpos[0].col) {
          char *ml = ml_get_buf(buf, lnum);
          if (ml[matchcol] == NUL) {
            break;
          }
          matchcol += utfc_ptr2len(ml + matchcol);
        }
      }
    } else {
      // --- matchaddpos() position list branch ---
      char *ml = ml_get_buf(buf, lnum);
      int line_len = (int)strlen(ml);

      for (int j = 0; j < cur->mit_pos_count; j++) {
        llpos_T *pos = &cur->mit_pos_array[j];
        if (pos->lnum == 0) {
          break;
        }
        if (pos->lnum != lnum) {
          continue;
        }
        colnr_T start_col, end_col;
        if (pos->col == 0) {
          start_col = 0;
          end_col = line_len;
        } else {
          start_col = pos->col - 1;
          if (start_col >= line_len) {
            continue;
          }
          end_col = start_col + MAX(pos->len, 1);
          if (end_col > line_len) {
            end_col = line_len;
          }
        }
        match_add_decor(row, start_col, end_col, &hl_base);
      }
    }
  }
}
