#!/bin/bash
#

max=${1:-120}

init_timestamp=$(stat -c %Z /proc)

function latest_in_dir {
    local dir="$1"
    local latest=
    read -r latest < <(ls -t "${dir}")
    echo "${dir}/${latest}"
}

declare -a earliest=()
declare -i first=9999999999

declare -i warnings=0
start_log='attempting to acquire leader lease'
acquired_log='successfully acquired lease'
logdirs=$(grep -rl -e "${start_log}" -e "${acquired_log}" /var/log/pods | xargs --no-run-if-empty -n 1 dirname | sort -u)
for logdir in ${logdirs}; do
    lf=$(latest_in_dir "${logdir}")

    #echo "#### Checking ${lf}"

    lines=$(grep -c -e "${start_log}" "${lf}")
    if [ "${lines}" -ne 1 ]; then
        echo "### Starting log: Expected count=1, found ${lines}: ${lf}"
        continue
    fi

    lines=$(grep -c -e "${acquired_log}" "${lf}")
    if [ "${lines}" -ne 1 ]; then
        echo "### Acquired log: Expected count=1, found ${lines}: ${lf}"
        continue
    fi

    start_timestamp=$(grep -e "${start_log}" "${lf}" | awk '{print $1}')
    start_secs=$(date +%s --date "${start_timestamp}")

    if [ ${start_secs} -lt ${init_timestamp} ]; then
        # Log from previous boot
        continue
    fi

    acquired_timestamp=$(grep -e "${acquired_log}" "${lf}" | awk '{print $1}')
    acquired_secs=$(date +%s --date "${acquired_timestamp}")

    # Record the first pod to acquire leader lease
    if [ ${acquired_secs} -lt ${first} ]; then
        earliest=( "${lf}" )
        first=${acquired_secs}
    elif [ ${acquired_secs} -eq ${first} ]; then
        earliest+=( "${lf}" )
    fi

    duration=$((acquired_secs-start_secs))

    #echo "### Duration: ${duration} seconds: ${lf}"
    if [ ${duration} -gt ${max} ]; then
        echo "WARNING: Took ${duration} seconds for ${lf}"
        warnings=$((warnings+1))
    fi
done

#echo
#echo "First:"
#for lf in ${earliest[@]}; do
#    echo ${lf}
#done

[ ${warnings} -eq 0 ]

