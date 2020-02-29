# influxdb-sampler
Easily sample the existing data in an [InfluxDB](https://www.influxdata.com/products/influxdb-overview/) instance. This uses InfluxDB's [REST API](https://docs.influxdata.com/influxdb/v1.7/tools/api/) to sample all data and store it hierarchically in a file tree.

---
### To Use
Ensure the influxdb_sampler.sh file has executable permissions
```
chmod +x ./influxdb_sampler.sh
```
Since the sampler can be kind of verbose and intentionally executes in a single threaded manner to reduce the load on InfluxDB, it is recommended to fork a separate process and redirect the output to a log file.
```
./influxdb_sampler.sh > /var/log/influxdb_sampler.log 2>&1 & 
```
You can then tail that log file or allow it to finish execution on its own.
```
tail -f /var/log/influxdb_sampler.log
```

---
### Configuration
You can configure execution parameters by exporting the appropriate environment variables.

* `INFLUX_HOST` - Default: localhost
>The domain of your InfluxDB instance
* `INFLUX_PORT` - Default: 8086
>Port to use for communicating with InfluxDB's REST API
* `WRITE_DIR` - Default: /tmp/influx_sampler
>Staging directory location where data is written to while sampling. This is cleaned up before and after execution. Ensure you are executing as a user with write permissions here
* `ARCHIVE_FILE` - Default: /tmp/influx_sampler.tar.gz
>Absolute path to the tar.gz archive where data should be persisted once execution has finished.
* `SAMPLE_SIZE` - Default: 10
>Number of samples to gather from each measurement
* `MAX_CONSECUTIVE_QUERIES` - Default: 100
>The maximum number of consecutive queries that should be executed without sleeping. Used for throttling the load on InfluxDB
* `CONSECUTIVE_QUERY_SLEEP_TIME` - Default: 2
>Number of seconds to sleep between batches of consecutive queries
---

### Output Format
The InfluxDB sampler writes data to disk in a hierarchical structure. At the top level, there is a file called `stats.txt` which stores high-level information about the InfluxDB sampler's execution as well as some insights to your data as whole. The sampler creates one directory tree per database with one subdirectory per measurement in that database. The directory for a measurement contains the count and a sample of the measurement's values. At each level in the directory tree, the command(s) that were used for execution are saved to corresponding `.sh` files so that you can reproduce the data on your own. All of the `.json` files are the exact response returned by InfluxDB, and the `.txt` files contain the returned data with some basic massaging applied to them. Below is an example of the directory structure where `app_metrics` is an InfluxDB database containing the masurements `cpu`, `disk`, and `mem`.
```
$ tree
.
`-- influxdb_sampler
    |-- cmd.sh
    |-- dbs.json
    |-- dbs.txt
    |-- raw_dbs.txt
    |-- stats.txt
    `-- app_metrics
        |-- cmd.sh
        |-- measurements
        |   |-- cpu
        |   |   |-- cmd.sh
        |   |   |-- count.json
        |   |   |-- count_cmd.sh
        |   |   |-- max_count.txt
        |   |   |-- raw_count.txt
        |   |   `-- sample.json
        |   |-- disk
        |   |   |-- cmd.sh
        |   |   |-- count.json
        |   |   |-- count_cmd.sh
        |   |   |-- max_count.txt
        |   |   |-- raw_count.txt
        |   |   `-- sample.json
        |   `-- mem
        |       |-- cmd.sh
        |       |-- count.json
        |       |-- count_cmd.sh
        |       |-- max_count.txt
        |       |-- raw_count.txt
        |       `-- sample.json
        |-- measurements.json
        |-- measurements.txt
        `-- raw_measurements.txt
```


---
### Limitations
* Tested on Ubuntu with InfluxDB v1.7.1
* Requires `jq`, `curl`, `sed`, `du`, `date`, and `awk` packages
* Executes by default with `/bin/bash`
* Does not support Authorization at this point in time
* Not tested with [InfluxDB 2.0](https://v2.docs.influxdata.com/v2.0/)


---
https://github.com/msugas19/influxdb-sampler