#!/bin/bash

################################################################################
# Configurable Variables
################################################################################

# Local address of your influx instance
export INFLUX_HOST=${INFLUX_HOST:-"localhost"}
export INFLUX_PORT=${INFLUX_PORT:-"8086"}
# Top level folder where all data is staged. This is cleaned up after archiving
export WRITE_DIR=${WRITE_DIR:-"/tmp/influxdb_sampler"}
# This is where the sampled data is output
export ARCHIVE_FILE=${ARCHIVE_FILE:-"/tmp/influxdb_sampler.tar.gz"}
# Number of samples to gather from each measurement
export SAMPLE_SIZE=${SAMPLE_SIZE:-10}
# Sleep after this many consecutive queries. Use for throttling the load on InfluxDB
export MAX_CONSECUTIVE_QUERIES=${MAX_CONSECUTIVE_QUERIES:-100}
# Time to sleep between consecutive query batches
export CONSECUTIVE_QUERY_SLEEP_TIME=${CONSECUTIVE_QUERY_SLEEP_TIME:-2}

################################################################################
# Execution Variables
################################################################################
# Global arrays for iterating
export DBS_ARR=()
export MEASUREMENTS_ARR=()
export PLACEHOLDER_ARR=()
# Global variables used for querying
export INFLUX_QUERY_URI="http://${INFLUX_HOST}:${INFLUX_PORT}/query?pretty=true"
export BASE_CMD="curl -s -G '${INFLUX_QUERY_URI}'"

# Stat keeping variables
export SECONDS=0
export TOTAL_MEASUREMENTS=0
export TOTAL_DBS=0
export TOTAL_VALUES=0
export SAMPLED_VALUES=0
export TOTAL_QUERIES=0
export TOTAL_SLEEP_TIME=0

################################################################################
# Functions
################################################################################

log(){
    echo "[`date`] ${@}"
}

increment_queries(){
    TOTAL_QUERIES=$((TOTAL_QUERIES + 1))
    if [[ $(( TOTAL_QUERIES % MAX_CONSECUTIVE_QUERIES)) -eq 0 ]]; then
        log "Throttling consecutive queries by sleeping ${CONSECUTIVE_QUERY_SLEEP_TIME} seconds. Total queries: ${TOTAL_QUERIES}"
        smart_sleep $CONSECUTIVE_QUERY_SLEEP_TIME;
    fi 
}

smart_sleep(){
    local sleep_time=${1}
    TOTAL_SLEEP_TIME=$(( TOTAL_SLEEP_TIME + sleep_time))
    sleep $sleep_time
}

get_dbs(){
    local db_cmd="${BASE_CMD} --data-urlencode 'q=SHOW DATABASES'"
    local dump="${WRITE_DIR}/dbs.txt"
    local dbs=$(eval "${db_cmd}")
    increment_queries
    mkdir -p "${WRITE_DIR}"
    echo "${db_cmd}" >> "${WRITE_DIR}/cmd.sh"
    echo "${dbs}" >> "${WRITE_DIR}/dbs.json"
    
    local dbs_raw_values=$(get_raw_values "${dbs}")
    echo "${dbs_raw_values}" >> "${WRITE_DIR}/raw_dbs.txt"
    get_values_as_array "${dbs_raw_values}"
    DBS_ARR=("${PLACEHOLDER_ARR[@]}")
    log "DBs are ${DBS_ARR[@]}"
    echo "${DBS_ARR[@]}" >> "${WRITE_DIR}/dbs.txt"
}

get_raw_values(){
    local raw_values=$(echo "${@}" | jq -c ".results[0].series[0].values | flatten | .[]")
    echo "${raw_values//\"}"
}

get_values_as_array(){
    local values="${1}"
    PLACEHOLDER_ARR=()
    while read -r line;
    do 
        PLACEHOLDER_ARR+=("${line}");
    done< <(echo "${values}")
}


get_measurements_for_db(){
    local db="${1}"
    log "Getting measurements for DB ${db}"
    local measurements_dir="${WRITE_DIR}/${db}/"
    local cmd="${BASE_CMD} --data-urlencode 'q=SHOW MEASUREMENTS' --data-urlencode 'db=${db}'"
    mkdir -p "${measurements_dir}"
    echo "${cmd}" >> "${measurements_dir}/cmd.sh"
    local measurements=$(eval "${cmd}")
    increment_queries
    echo "${measurements}" >> "${measurements_dir}/measurements.json"
    local measurements_raw=$(get_raw_values "${measurements}")
    echo "${measurements_raw}" >> "${measurements_dir}/raw_measurements.txt"
    get_values_as_array "${measurements_raw}"
    MEASUREMENTS_ARR=("${PLACEHOLDER_ARR[@]}")
    echo "${MEASUREMENTS_ARR[@]}" >> "${measurements_dir}/measurements.txt"
}

get_measurement_sample(){
    local db="${1}"
    local measurement="${2}"
    local sanitized_name=$(echo "${measurement}" | sed -e  's/[^A-Za-z0-9._-]/_/g')
    local sample_write_dir="${WRITE_DIR}/${db}/measurements/${sanitized_name}"
    local sample_output="${sample_write_dir}/sample.json"
    
    if [[ "${sanitized_name}" != "${measurement}" ]]; then
        log "Writing measurement ${measurement} to ${sample_write_dir} due to illegal path characters";
    fi 

    mkdir -p "${sample_write_dir}"
    
    local sample_cmd="curl -s -o ${sample_output} -w \"%{http_code}\" -G '${INFLUX_QUERY_URI}' --data-urlencode 'q= SELECT * FROM \"${measurement}\" LIMIT ${SAMPLE_SIZE}' --data-urlencode 'db=${db}'"
    echo "${sample_cmd}" >> "${sample_write_dir}/cmd.sh"

    local timeout=2
    for i in {1..5}
    do 
        local http_code=$(eval "${sample_cmd}")
        increment_queries
        if [[ "${http_code}" =~ "20" ]]; then
            # Increment the sample values count
            SAMPLED_VALUES=$(( SAMPLED_VALUES + SAMPLE_SIZE ))
            # Fetch information about number of values in this measurement
            get_measurements_count "${db}" "${measurement}" "${sample_write_dir}"
            return;
        elif [[ "${i}" == "5" ]]; then
            log "Measurement ${measurement} failed. Exiting";
            exit 1;
        else
            log "Received invalid status code for measurement: ${measurement} of ${http_code}"
            log "Retrying after sleeping ${timeout} seconds";
            smart_sleep $timeout;
            # Exponential backoff - increase time by squared
            timeout=$((timeout * timeout))
        fi
    done
}

get_measurements_count(){
    local db="${1}"
    local measurement="${2}"
    local write_dir="${3}"
    # Get the count of the values after sampling the values
    local values_cmd="${BASE_CMD} --data-urlencode 'q= SELECT COUNT(*) FROM \"${measurement}\"' --data-urlencode 'db=${db}'"
    echo "${values_cmd}" >> "${write_dir}/count_cmd.sh"
    local response=$(eval "${values_cmd}")
    increment_queries
    echo "${response}" >> "${write_dir}/count.json"

    # Get all of the counts in an array for comparison
    local raw_count=$(get_raw_values "${response}")
    get_values_as_array "${raw_count}"
    # Get rid of the "time" component that is returned - https://docs.influxdata.com/influxdb/v1.7/query_language/functions/#count
    unset PLACEHOLDER_ARR[0]

    # Get the max count of all the columns. Use this as the total number of values
    local count_arr=("${PLACEHOLDER_ARR[@]}")
    local max=0
    for n in "${count_arr[@]}";
    do
        ((n > max)) && max=$n
    done

    # Store the max count for exploratory use later
    echo "${max}" >> "${write_dir}/max_count.txt"
    # Keep track of the total values in this DB
    TOTAL_VALUES=$(( TOTAL_VALUES + max ))
}

iterate_measurements(){
    local db="${1}"
    local write_base_dir="${WRITE_DIR}/${db}/measurements"
    for measurement in "${MEASUREMENTS_ARR[@]}"
    do
        local measurement_write_dir="${write_base_dir}/${measurement}"
        mkdir -p "${measurement_write_dir}"
        log "Getting measurement sample for DB: ${db} Measurement: ${measurement}"
        get_measurement_sample "${db}" "${measurement}"
    done
}

iterate_dbs() {
    TOTAL_DBS=${#DBS_ARR[@]}
    log "Influx has ${TOTAL_DBS} Databases"
    for db in "${DBS_ARR[@]}"
    do 
        get_measurements_for_db "${db}";
        local measurements_size=${#MEASUREMENTS_ARR[@]}
        log "DB: ${db} has ${measurements_size} measurements";
        TOTAL_MEASUREMENTS=$((TOTAL_MEASUREMENTS + measurements_size))
        iterate_measurements "${db}";
    done
}

archive(){
    if [[ -f "${ARCHIVE_FILE}" ]]; then
        log "Cleaning up conflicting archive ${ARCHIVE_FILE}"
        rm -rf "${ARCHIVE_FILE}"
    fi 

    log "Archiving data to ${ARCHIVE_FILE}"
    tar -czf "${ARCHIVE_FILE}" "${WRITE_DIR}"
    log "Total compressed size: $(du -ch ${ARCHIVE_FILE} | sort -rh | head -1 | awk '{print $1}')"
}

stats(){
    local uncompressed_size=$(du -ch ${WRITE_DIR} | sort -rh | head -1 | awk '{print $1}')
    local duration=${SECONDS}
    local minutes=$((duration / 60))
    local seconds=$((duration % 60))
    local execution_time=$((duration - TOTAL_SLEEP_TIME))

    local stats_file="${WRITE_DIR}/stats.txt"

    log "Writing stats to ${stats_file}"
    echo "TOTAL_TIME: ${minutes} minute(s) ${seconds} second(s)" >> "${stats_file}"
    echo "SLEEP_TIME: ${TOTAL_SLEEP_TIME} second(s)" >> "${stats_file}"
    echo "EXECUTION_TIME: ${execution_time} second(s)" >> "${stats_file}"
    echo "DBS: ${TOTAL_DBS}" >> "${stats_file}"
    echo "MEASUREMENTS: ${TOTAL_MEASUREMENTS}" >> "${stats_file}"
    echo "SAMPLED_VALUES: ${SAMPLED_VALUES}" >> "${stats_file}"
    echo "TOTAL_VALUES: ${TOTAL_VALUES}" >> "${stats_file}"
    echo "VALUES PERCENTAGE: $(echo "scale=5; ${SAMPLED_VALUES}*100/${TOTAL_VALUES}" | bc )%" >> "${stats_file}"
    echo "QUERIES: ${TOTAL_QUERIES}" >> "${stats_file}"
    echo "COLLECTED DATA SIZE: ${uncompressed_size}" >> "${stats_file}"

    log "Execution finished after ${minutes} minutes and ${seconds} seconds"
    log "Queried ${TOTAL_DBS} Databases to get data."
    log "Sampled ${TOTAL_MEASUREMENTS} measurements to get ${TOTAL_ROWS} rows of data."
    log "Total queries executed: ${TOTAL_QUERIES}"
    log "Total Uncompressed data size (before deletion): ${uncompressed_size}"  
}

cleanup() {
    rm -rf "${WRITE_DIR}"
}

################################################################################
# Main function
################################################################################

main(){
    # Cleanup before starting execution
    cleanup
    # Get the DBs for this instance
    get_dbs
    # iterate the DBs and sample the measurements
    iterate_dbs
    # Record and print the stats for the run
    stats
    # Compress the sampled data to minimize usage
    archive
    # Cleanup the uncompressed data
    cleanup    
}

main