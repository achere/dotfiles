#!/bin/sh
# Machine-wide CPU and RAM for herdr's tab_bar_right (see config.toml).
# Prints one line, e.g. "cpu 27% · ram 26G/36G"; herdr shows the last line.
#
# CPU: `top -l 2`. The first sample is an average since boot, the second is
# the delta over -s seconds, so only the last CPU line is kept.
cpu=$(top -l 2 -n 0 -s 1 | awk '/^CPU usage/ { gsub("%", ""); c = 100 - $7 } END { printf "%.0f", c }')

# RAM: Activity Monitor's "Memory Used" = app + wired + compressed, from
# vm_stat. top's PhysMem "used" also counts inactive file cache (~6G here),
# which the kernel hands back on demand, so it reads far too full.
vm_stat | awk -v cpu="$cpu" -v total="$(sysctl -n hw.memsize)" '
  /page size/                  { ps = $8 }
  /^Anonymous pages/           { anon = $3 }
  /^Pages purgeable/           { pur = $3 }
  /^Pages wired down/          { wired = $4 }
  /^Pages occupied by compres/ { comp = $5 }
  END {
    if (cpu == "" || ps == "") exit 1
    printf "cpu %s%% · ram %.0fG/%.0fG\n", cpu, (anon - pur + wired + comp) * ps / 2^30, total / 2^30
  }'
