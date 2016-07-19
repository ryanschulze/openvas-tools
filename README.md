# openvas-tools

A repository with some tools I created and use together with OpenVAS

----

**openvas-configuration.sh**

Script to export/import openvas configuration, is useful for backing up configuration or migrating from different storage backends (sqlite / PostgreSQL). Can only export data visable via the [OMP](www.openvas.org/omp-6-0.html) protocol (notably no slave passwords, no credentials). Stores the results in a .tgz file.

Currently exports/imports the following settings:
 - filters
 - report_formats
 - scan_config
 - slaves
 - schedules
 - alerts
 - targets 
 - tasks
 - notes
 - overrides

```
Usage: openvas-configuration.sh -a import|export [ -f <filename> ] [ -c <configfile> ] [ -h ]
  -a import|export  import or export the configuration
  -f <filename>     Filename to store/load the configuration, use - for stdin/stdout (default)
  -c <configfile>   Specific omp config file to use, mandatory on imports
  -h                prints this help

  e.g. 
    ./openvas-configuration.sh -a export -f configuration.tgz
    ./openvas-configuration.sh -a import -f configuration.tgz
```
