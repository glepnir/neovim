
  new
  " gUe must uppercase a whole word, also when ß changes to SS
  exe "normal Gothe youtußeuu end\<Esc>Ypk0wgUe\r"
  " gUfx must uppercase until x, inclusive.
  exe "normal O- youßtußexu -\<Esc>0fogUfx\r"
  " VU must uppercase a whole line
  exe "normal YpkVU\r"
  " same, when it's the last line in the buffer
  exe "normal YPGi111\<Esc>VUddP\r"
  " Uppercase two lines
  exe "normal Oblah di\rdoh dut\<Esc>VkUj\r"
  " Uppercase part of two lines
  exe "normal ddppi333\<Esc>k0i222\<Esc>fyllvjfuUk"
