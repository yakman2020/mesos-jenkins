#!/usr/bin/env bash

if [[ $# -ne 1 ]]; then
    echo "USAGE: $0 <cron_job_parameters_file>"
    exit 1
fi

source "$1" || (echo "ERROR: Failed to source the cron job parameters file" && exit 1)

if [[ -z $LOGS_DIR ]]; then echo "ERROR: LOGS_DIR environment variable was not set" ; exit 1 ; fi
if [[ -z $GEARMAN_SERVERS_LIST ]]; then echo "ERROR: GEARMAN_SERVERS_LIST environment variable was not set" ; exit 1 ; fi

DIR=$(dirname $0)
PYTHON_SCRIPT=$(realpath "$DIR/../../Mesos/utils/trigger-gearman-jobs.py") || (echo "ERROR: Failed to get the absolute path for trigger-gearman-jobs.py" && exit 1)
LOG_FILE=$(realpath "$LOGS_DIR/cron-spartan-nightly-build.log") || (echo "ERROR: Failed to get the absolute path for cron-spartan-nightly-build.log" && exit 1)

JOB_NAME="spartan-nightly-build"
ps aux | grep -v " grep " | grep "$PYTHON_SCRIPT" | grep -q "$JOB_NAME" && echo -e "$(date +%m-%d-%y-%T) - The script $PYTHON_SCRIPT for $JOB_NAME is already running\n" >> $LOG_FILE && exit 0

python $PYTHON_SCRIPT -s "$GEARMAN_SERVERS_LIST" -j "$JOB_NAME" --params '{"BRANCH": "master", "MESOS_JENKINS_BRANCH": "master"}' 2>&1 >> $LOG_FILE

echo -e "\n" >> $LOG_FILE
