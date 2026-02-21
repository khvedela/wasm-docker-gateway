#!/usr/bin/env bash
set -euo pipefail
IN="${1:?input csv}"
# outputs: avg_rss_kb,max_rss_kb,avg_cpu,max_cpu
awk -F',' '
NR==1{next}
{
  rss=$2; cpu=$3;
  rss_sum+=rss; cpu_sum+=cpu; n+=1;
  if(rss>rss_max) rss_max=rss;
  if(cpu>cpu_max) cpu_max=cpu;
}
END{
  if(n==0){print "0,0,0,0"; exit}
  printf "%.2f,%d,%.2f,%.2f\n", rss_sum/n, rss_max, cpu_sum/n, cpu_max
}' "$IN"
