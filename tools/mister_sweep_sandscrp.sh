#!/bin/sh
# Sand Scorpion three-set sweep. Per game: load, settle, shot A (attract),
# coin+coin+start, settle, shot B (gameplay). One line per game to the log so
# a dropped ssh cannot lose the run.
LOG=/media/fat/ss_sweep_log.txt
: > $LOG
sweep() {
  SET="$1"; MRA="$2"
  rm -rf "/media/fat/screenshots/$SET"
  echo "load_core $MRA" > /dev/MiSTer_cmd
  sleep 45
  timeout 10 sh -c "echo screenshot > /dev/MiSTer_cmd" >/dev/null 2>&1
  sleep 5
  python3 /media/fat/mister_keys.py 5 5 1 >/dev/null 2>&1
  sleep 12
  timeout 10 sh -c "echo screenshot > /dev/MiSTer_cmd" >/dev/null 2>&1
  sleep 5
  python3 /media/fat/mister_keys.py lctrl lctrl left:0.5 lctrl >/dev/null 2>&1
  sleep 4
  timeout 10 sh -c "echo screenshot > /dev/MiSTer_cmd" >/dev/null 2>&1
  sleep 5
  N=$(ls "/media/fat/screenshots/$SET" 2>/dev/null | wc -l)
  RUN=$(ps aux | grep -c "[M]iSTer /media")
  echo "$SET shots=$N mister=$RUN" >> $LOG
}
sweep sandscrp  "/media/fat/_Arcade/Sand Scorpion.mra"
sweep sandscrpa "/media/fat/_Arcade/_alternatives/_Sand Scorpion/Sand Scorpion (Earlier).mra"
sweep sandscrpb "/media/fat/_Arcade/_alternatives/_Sand Scorpion/Kuai Da Shizi Huangdi (China, Revised Hardware).mra"
echo "SWEEP COMPLETE" >> $LOG
