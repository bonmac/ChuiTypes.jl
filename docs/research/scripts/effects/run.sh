#!/bin/sh
# run.sh <channel: release|lts> <script> [args...]   -- 30s watchdog via perl alarm (no coreutils timeout here)
S=/private/tmp/claude-501/-Users-bonmac-personal-projects-julia-data-analysis/5c1f011c-1151-4765-9a79-8eba6d64f4e6/scratchpad/types-p1/effects
ch=$1; shift
if [ "$ch" = lts ]; then env=$S/env10; else env=$S/env13; fi
cd $S && perl -e 'alarm shift; exec @ARGV' 30 julia +$ch --startup-file=no -t 4 --project=$env "$@" 2>&1
rc=$?
[ $rc -eq 142 ] && echo "WATCHDOG: killed after 30s (hang)"
[ $rc -ne 0 ] && [ $rc -ne 142 ] && echo "exit code $rc"
exit 0
