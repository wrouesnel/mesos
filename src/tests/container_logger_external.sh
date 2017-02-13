#!/bin/bash
# This script provides a dummy logging process for testing the external
# container logger.

# Check we are a process group leader
if ! ps -o pid,sid | grep ^$$ ; then
    echo "Log process is not the session group leader."
    exit 1
fi

# This is the one extra path we get.
if [ -z "$MESOS_LOG_SANDBOX_DIRECTORY" ]; then
    echo "MESOS_LOG_SANDBOX_DIRECTORY was empty."
    exit 1
fi

if [ -z "$MESOS_LOG_STREAM" ]; then
    echo "MESOS_LOG_STREAM was empty."
    exit 1
fi

if [ -z "$MESOS_LOG_MESOS_EXECUTORINFO_JSON" ]; then
    echo "MESOS_LOG_MESOS_EXECUTORINFO_JSON was empty."
    exit 1
fi

output_name=${MESOS_LOG_SANDBOX_DIRECTORY}/${MESOS_LOG_STREAM}.log

# Write the parsed data to some separate files so the test can read it.
echo "$MESOS_LOG_MESOS_EXECUTORINFO_JSON" > ${MESOS_LOG_SANDBOX_DIRECTORY}/${MESOS_LOG_STREAM}.json

# Very simple logging implementation.
while read line; do
    echo "$line" >> $output_name
done
