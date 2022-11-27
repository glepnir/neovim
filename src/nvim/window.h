#ifndef NVIM_WINDOW_H
#define NVIM_WINDOW_H

#include <stdbool.h>
#include <stddef.h>

#include "nvim/buffer.h"
#include "nvim/buffer_defs.h"
#include "nvim/mark.h"
#include "nvim/os/os.h"
#include "nvim/os/os_defs.h"
#include "nvim/vim.h"

// Values for file_name_in_line()
#define FNAME_MESS      1       // give error message
#define FNAME_EXP       2       // expand to path
#define FNAME_HYP       4       // check for hypertext link
#define FNAME_INCL      8       // apply 'includeexpr'
#define FNAME_REL       16      // ".." and "./" are relative to the (current)
                                // file instead of the current directory
#define FNAME_UNESC     32      // remove backslashes used for escaping

// arguments for win_split()
#define WSP_ROOM        0x01    // require enough room
#define WSP_VERT        0x02    // split/equalize vertically
#define WSP_HOR         0x04    // equalize horizontally
#define WSP_TOP         0x08    // window at top-left of shell
#define WSP_BOT         0x10    // window at bottom-right of shell
#define WSP_HELP        0x20    // creating the help window
#define WSP_BELOW       0x40    // put new window below/right
#define WSP_ABOVE       0x80    // put new window above/left
#define WSP_NEWLOC      0x100   // don't copy location list

// Minimum screen size
#define MIN_COLUMNS     12      // minimal columns for screen
#define MIN_LINES       2       // minimal lines for screen

/// Structure used by switch_win() to pass values to restore_win()
typedef struct {
  win_T *sw_curwin;
  tabpage_T *sw_curtab;
  bool sw_same_win;  ///< VIsual_active was not reset
  bool sw_visual_active;
} switchwin_T;

/// Execute a block of code in the context of window `wp` in tabpage `tp`.
/// Ensures the status line is redrawn and cursor position is valid if it is moved.
#define WIN_EXECUTE(wp, tp, block) \
  do { \
    win_T *const wp_ = (wp); \
    const pos_T curpos_ = wp_->w_cursor; \
    char cwd_[MAXPATHL]; \
    char autocwd_[MAXPATHL]; \
    bool apply_acd_ = false; \
    int cwd_status_ = FAIL; \
    /* Getting and setting directory can be slow on some systems, only do */ \
    /* this when the current or target window/tab have a local directory or */ \
    /* 'acd' is set. */ \
    if (curwin != wp \
        && (curwin->w_localdir != NULL || wp->w_localdir != NULL \
            || (curtab != tp && (curtab->tp_localdir != NULL || tp->tp_localdir != NULL)) \
            || p_acd)) { \
      cwd_status_ = os_dirname((char_u *)cwd_, MAXPATHL); \
    } \
    /* If 'acd' is set, check we are using that directory.  If yes, then */ \
    /* apply 'acd' afterwards, otherwise restore the current directory. */ \
    if (cwd_status_ == OK && p_acd) { \
      do_autochdir(); \
      apply_acd_ = os_dirname((char_u *)autocwd_, MAXPATHL) == OK && strcmp(cwd_, autocwd_) == 0; \
    } \
    switchwin_T switchwin_; \
    if (switch_win_noblock(&switchwin_, wp_, (tp), true) == OK) { \
      check_cursor(); \
      block; \
    } \
    restore_win_noblock(&switchwin_, true); \
    if (apply_acd_) { \
      do_autochdir(); \
    } else if (cwd_status_ == OK) { \
      os_chdir(cwd_); \
    } \
    /* Update the status line if the cursor moved. */ \
    if (win_valid(wp_) && !equalpos(curpos_, wp_->w_cursor)) { \
      wp_->w_redr_status = true; \
    } \
    /* In case the command moved the cursor or changed the Visual area, */ \
    /* check it is valid. */ \
    check_cursor(); \
    if (VIsual_active) { \
      check_pos(curbuf, &VIsual); \
    } \
  } while (false)

#ifdef INCLUDE_GENERATED_DECLARATIONS
# include "window.h.generated.h"
#endif
#endif  // NVIM_WINDOW_H
