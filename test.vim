"set rightleft

func Changed()
  let word = get(v:event, 'completed_item', {})
  echomsg word
endfunc

autocmd CompleteChanged * call Changed()

func Omni_test(findstart, base)
  if a:findstart
    return col(".")
  endif
  return [#{word: "foo"}, #{word: "foobar"}, #{word: "fooBaz"}, #{word: "foobala"}]
endfunc
set omnifunc=Omni_test
set completeopt+=noinsert
set completeopt+=fuzzy
set completeopt-=preview

"hi PmenuMatch ctermfg=Green ctermbg=225 guibg=LightMagenta
"hi PmenuMatchSel  ctermfg=Red ctermbg=7 guibg=Grey
