---
title: Apache Mesos - Logging
layout: documentation
---

# Logging

Mesos handles the logs of each Mesos component differently depending on the
degree of control Mesos has over the source code of the component.

Roughly, these categories are:

* [Internal](#Internal) - Master and Agent.
* [Containers](#Containers) - Executors and Tasks.
* External - Components launched outside of Mesos, like
  Frameworks and [ZooKeeper](high-availability.md).  These are expected to
  implement their own logging solution.

## <a name="Internal"></a>Internal

The Mesos Master and Agent use the
[Google's logging library](https://github.com/google/glog).
For information regarding the command-line options used to configure this
library, see the [configuration documentation](configuration.md).
Google logging options that are not explicitly mentioned there can be
configured via environment variables.

Both Master and Agent also expose a [/logging/toggle](endpoints/logging/toggle.md)
HTTP endpoint which temporarily toggles verbose logging:

```
POST <ip:port>/logging/toggle?level=[1|2|3]&duration=VALUE
```

The effect is analogous to setting the `GLOG_v` environment variable prior
to starting the Master/Agent, except the logging level will revert to the
original level after the given duration.

## <a name="Containers"></a>Containers

For background, see [the containerizer documentation](containerizer.md).

Mesos does not assume any structured logging for entities running inside
containers.  Instead, Mesos will store the stdout and stderr of containers
into plain files ("stdout" and "stderr") located inside
[the sandbox](sandbox.md#where-is-it).

In some cases, the default Container logger behavior of Mesos is not ideal:

* Logging may not be standardized across containers.
* Logs are not easily aggregated.
* Log file sizes are not managed.  Given enough time, the "stdout" and "stderr"
  files can fill up the Agent's disk.

## `ContainerLogger` Module

The `ContainerLogger` module was introduced in Mesos 0.27.0 and aims to address
the shortcomings of the default logging behavior for containers.  The module
can be used to change how Mesos redirects the stdout and stderr of containers.

The [interface for a `ContainerLogger` can be found here](https://github.com/apache/mesos/blob/master/include/mesos/slave/container_logger.hpp).

Mesos comes with three `ContainerLogger` modules:

* The `SandboxContainerLogger` implements the existing logging behavior as
  a `ContainerLogger`.  This is the default behavior.
* The `LogrotateContainerLogger` addresses the problem of unbounded log file
  sizes.
* The `ExternalContainerLogger` allows executing a custom program to handle
  logs passed to it via standard input.

### `LogrotateContainerLogger`

The `LogrotateContainerLogger` constrains the total size of a container's
stdout and stderr files.  The module does this by rotating log files based
on the parameters to the module.  When a log file reaches its specified
maximum size, it is renamed by appending a `.N` to the end of the filename,
where `N` increments each rotation.  Older log files are deleted when the
specified maximum number of files is reached.

#### Invoking the module

The `LogrotateContainerLogger` can be loaded by specifying the library
`liblogrotate_container_logger.so` in the
[`--modules` flag](modules.md#Invoking) when starting the Agent and by
setting the `--container_logger` Agent flag to
`org_apache_mesos_LogrotateContainerLogger`.

#### Module parameters

<table class="table table-striped">
  <thead>
    <tr>
      <th width="30%">
        Key
      </th>
      <th>
        Explanation
      </th>
    </tr>
  </thead>

  <tr>
    <td>
      <code>max_stdout_size</code>/<code>max_stderr_size</code>
    </td>
    <td>
      Maximum size, in bytes, of a single stdout/stderr log file.
      When the size is reached, the file will be rotated.

      Defaults to 10 MB.  Minimum size of 1 (memory) page, usually around 4 KB.
    </td>
  </tr>

  <tr>
    <td>
      <code>logrotate_stdout_options</code>/
      <code>logrotate_stderr_options</code>
    </td>
    <td>
      Additional config options to pass into <code>logrotate</code> for stdout.
      This string will be inserted into a <code>logrotate</code> configuration
      file. i.e. For "stdout":
      <pre>
/path/to/stdout {
  [logrotate_stdout_options]
  size [max_stdout_size]
}</pre>
      NOTE: The <code>size</code> option will be overridden by this module.
    </td>
  </tr>

  <tr>
    <td>
      <code>environment_variable_prefix</code>
    </td>
    <td>
      Prefix for environment variables meant to modify the behavior of
      the logrotate logger for the specific executor being launched.
      The logger will look for four prefixed environment variables in the
      <code>ExecutorInfo</code>'s <code>CommandInfo</code>'s
      <code>Environment</code>:
      <ul>
        <li><code>MAX_STDOUT_SIZE</code></li>
        <li><code>LOGROTATE_STDOUT_OPTIONS</code></li>
        <li><code>MAX_STDERR_SIZE</code></li>
        <li><code>LOGROTATE_STDERR_OPTIONS</code></li>
      </ul>
      If present, these variables will overwrite the global values set
      via module parameters.

      Defaults to <code>CONTAINER_LOGGER_</code>.
    </td>
  </tr>

  <tr>
    <td>
      <code>launcher_dir</code>
    </td>
    <td>
      Directory path of Mesos binaries.
      The <code>LogrotateContainerLogger</code> will find the
      <code>mesos-logrotate-logger</code> binary under this directory.

      Defaults to <code>/usr/local/libexec/mesos</code>.
    </td>
  </tr>

  <tr>
    <td>
      <code>logrotate_path</code>
    </td>
    <td>
      If specified, the <code>LogrotateContainerLogger</code> will use the
      specified <code>logrotate</code> instead of the system's
      <code>logrotate</code>.  If <code>logrotate</code> is not found, then
      the module will exit with an error.
    </td>
  </tr>
</table>

#### How it works

1. Every time a container starts up, the `LogrotateContainerLogger`
   starts up companion subprocesses of the `mesos-logrotate-logger` binary.
2. The module instructs Mesos to redirect the container's stdout/stderr
   to the `mesos-logrotate-logger`.
3. As the container outputs to stdout/stderr, `mesos-logrotate-logger` will
   pipe the output into the "stdout"/"stderr" files.  As the files grow,
   `mesos-logrotate-logger` will call `logrotate` to keep the files strictly
   under the configured maximum size.
4. When the container exits, `mesos-logrotate-logger` will finish logging before
   exiting as well.

The `LogrotateContainerLogger` is designed to be resilient across Agent
failover.  If the Agent process dies, any instances of `mesos-logrotate-logger`
will continue to run.

### `ExternalContainerLogger`

The `ExternalContainerLogger` executes a process on the Mesos agent host in
order to handle logs from a mesos task. The process is specified globally as
part of the module configuration when the mesos agent is launched.

One logger process is spawned for each unique log stream from a Mesos task, i.e.
a process for stdout and stderr will be independantly spawned. Context
information for the log process is provided by environment variables so the
spawned process may determine how to handle logs (see below). Any valid host
executable is allowed (e.g. an executable shell script is valid, and can be
handy for debugging/development).

#### Invoking the module

The `ExternalContainerLogger` is invoked in the same way as the logrotate
logger. Specify the library `libexternal_container_logger.so` in the
[`--modules` flag](modules.md#Invoking)  when starting the Agent and by setting
the `--container_logger` Agent flag to
`org_apache_mesos_ExternalContainerLogger`.

#### Module parameters

<table class="table table-striped">
  <thead>
    <tr>
      <th width="30%">
        Key
      </th>
      <th>
        Explanation
      </th>
    </tr>
  </thead>

  <tr>
    <td>
      <code>external_logger_binary</code>
    </td>
    <td>
      Path to the external command which will read STDIN for logs.

      Must be specified and must point to an existing executable file on the
      host system.
    </td>
  </tr>

  <tr>
    <td>
      <code>mesos_field_prefix</code>
    </td>
    <td>
      Prefix to add to environment variables containing mesos task data passed
      to the external logger process. This is used for "special" data which is
      automatically exposed from executorInfo (currently
      <code>SANDBOX_DIRECTORY</code> and <code>STREAM</code>).

      Defaults to <code>MESOS_LOG_</code>.
    </td>
  </tr>

  <tr>
    <td>
      <code>stream_name_field</code>
    </td>
    <td>
      Name of the field to store the stdout/stderr stream identifier under.

      Defaults to <code>STREAM</code>.

      Example: with default settings, this would produce the environment
      variable <code>MESOS_LOG_STREAM</code>.

      Values of this field can be <code>STDOUT</code> and <code>STDERR</core>.
    </td>
  </tr>

  <tr>
    <td>
      <code>executor_info_json_field</code>
    </td>
    <td>
      Name of the environment variable to store the JSON protocol buffer of the
      Mesos task's ExecutorInfo. This is probably the easiest field to consume
      for external processes.

      Defaults to <code>MESOS_EXECUTORINFO_JSON</code>.

      Note: this field is prefixed by the value of mesos_field_prefix as well,
      so the result of the default value is <code>MESOS_LOG_MESOS_EXECUTORINFO_JSON</code>.
    </td>
  </tr>
</table>

#### How it works

This module is very similar to the logrotate logger, but allows using a custom
user specified process and receives more context about the process being logged.

On container startup, the `ExternalContainerLogger` spawns two processes with
the command specified by `external_logger_cmd` and passes the context to
via environment variables.

With default parameters these will be:
 * `MESOS_LOG_STREAM`
 * `MESOS_LOG_SANDBOX_DIRECTORY`
 * `MESOS_LOG_USER`
 * `MESOS_EXECUTORINFO_JSON`

`MESOS_LOG_USER` may or may not be present depending on if the Mesos Task
has specified to run as a different user. It's presence should be checked for
and reacted to appropriately (i.e. there is no requirement to switch to this
user, but a logging script or program may wish to do so to allow access to
files).

`MESOS_LOG_STREAM` will contain either `STDOUT` or `STDERR` to indicate which
log stream is being received on standard input. The other environment variables
will be the same between both processes. Note: no environment is passed from
the mesos-agent to the spawned logger process - this includes standard
environment variables like `PATH`. Any setup script for logging, or process,
should configure these variables itself to the necessary values.

All logging is then the responsibility of the spawned process.

It is worth noting that no method is provided to pass command line to the
spawned process, as it is possible to pass an executable wrapper script to
accomplish arbitrary setup and tear down before exec'ing the real logging
process.

### Writing a Custom `ContainerLogger`

For basics on module writing, see [the modules documentation](modules.md).

There are several caveats to consider when designing a new `ContainerLogger`:

* Logging by the `ContainerLogger` should be resilient to Agent failover.
  If the Agent process dies (which includes the `ContainerLogger` module),
  logging should continue.  This is usually achieved by using subprocesses.
* When containers shut down, the `ContainerLogger` is not explicitly notified.
  Instead, encountering `EOF` in the container's stdout/stderr signifies
  that the container has exited.  This provides a stronger guarantee that the
  `ContainerLogger` has seen all the logs before exiting itself.
* The `ContainerLogger` should not assume that containers have been launched
  with any specific `ContainerLogger`.  The Agent may be restarted with a
  different `ContainerLogger`.
* Each [containerizer](containerizer.md) running on an Agent uses its own
  instance of the `ContainerLogger`.  This means more than one `ContainerLogger`
  may be running in a single Agent.  However, each Agent will only run a single
  type of `ContainerLogger`.
