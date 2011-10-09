-record(job, {name, cmd_line, start_time, frequency, timeout}).

-record(job_instance, {name, cmd_line, timeout, run_time}).

-record(archive_job, {name, version, cmd_line, start_time, frequency, timeout}).

-define(NAME, {global, node()}).
