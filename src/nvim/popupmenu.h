#pragma once

#include <stdbool.h>

#include "nvim/extmark_defs.h"
#include "nvim/grid_defs.h"
#include "nvim/macros.h"
#include "nvim/types.h"
#include "nvim/vim.h"

/// Used for popup menu items.
typedef enum {
  PumText = 0,
  PumKind,
  PumExtra,
  PumInfo,
} PUMTEXTKIND;

typedef VirtTextChunk PumItemChunk;
typedef kvec_t(PumItemChunk) PumItem;

#define hlattr(id) (win_hl_attr(curwin, id))

EXTERN ScreenGrid pum_grid INIT( = SCREEN_GRID_INIT);

/// state for pum_ext_select_item.
EXTERN struct {
  bool active;
  int item;
  bool insert;
  bool finish;
} pum_want;

#ifdef INCLUDE_GENERATED_DECLARATIONS
# include "popupmenu.h.generated.h"
#endif
