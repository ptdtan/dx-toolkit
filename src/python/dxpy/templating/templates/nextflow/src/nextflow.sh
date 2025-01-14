#!/usr/bin/env bash

set -f

dx-registry-login() {
CREDENTIALS=${HOME}/credentials
dx download "${docker_creds}" -o $CREDENTIALS

command -v docker >/dev/null 2>&1 || (echo "ERROR: docker is required when running with the Docker credentials."; exit 1)

export REGISTRY=$(jq '.docker_registry.registry' "$CREDENTIALS" | tr -d '"')
export REGISTRY_USERNAME=$(jq '.docker_registry.username' "$CREDENTIALS" | tr -d '"')
export REGISTRY_ORGANIZATION=$(jq '.docker_registry.organization' "$CREDENTIALS" | tr -d '"')
if [[  -z $REGISTRY_ORGANIZATION || $REGISTRY_ORGANIZATION == "null" ]]; then
    export REGISTRY_ORGANIZATION=$REGISTRY_USERNAME
fi

if [[ -z $REGISTRY || $REGISTRY == "null" \
      || -z $REGISTRY_USERNAME  || $REGISTRY_USERNAME == "null" ]]; then
    echo "Error parsing the credentials file. The expected format to specify a Docker registry is: "
    echo "{"
    echo "    docker_registry: {"
    echo "        registry": "<Docker registry name, e.g. quay.io or docker.io>",
    echo "        username": "<registry login name>",
    echo "        organization": "<(optional, default value equals username) organization as defined by DockerHub or Quay.io>",
    echo "        token": "<API token>"
    echo "    }"
    echo "}"
    exit 1
fi

jq '.docker_registry.token' "$CREDENTIALS" -r | docker login $REGISTRY --username $REGISTRY_USERNAME --password-stdin 2> >(grep -v -E "WARNING! Your password will be stored unencrypted in |Configure a credential helper to remove this warning. See|https://docs.docker.com/engine/reference/commandline/login/#credentials-store")
}

generate_runtime_config() {
  set +x
  touch nxf_runtime.config
  # make a runtime config file to override optional inputs
  # whose defaults are defined in the default pipeline config such as RESOURCES_SUBPATH/nextflow.config
  @@GENERATE_RUNTIME_CONFIG@@

  if [[ -s nxf_runtime.config ]]; then
    if [[ $debug == true ]]; then
      cat nxf_runtime.config
      set -x
    fi
    RUNTIME_CONFIG_CMD='-c nxf_runtime.config'
  fi
}

on_exit() {
  ret=$?

  properties=$(dx describe ${DX_JOB_ID} --json 2>/dev/null | jq -r ".properties")
  if [[ $properties != "null" ]]; then
    if [[ $(jq .nextflow_errorStrategy <<<${properties} -r) == "ignore" ]]; then
      ignored_subjobs=$(jq .nextflow_errored_subjobs <<<${properties} -r)
      if [[ ${ignored_subjobs} != "null" ]]; then
        echo "Subjob(s) ${ignored_subjobs} ran into Nextflow process errors. \"ignore\" errorStrategy was applied."
      fi
    fi
  fi
  set +x
  if [[ $debug == true ]]; then
    # DEVEX-1943 Wait up to 30 seconds for log forwarders to terminate
    set +e
    i=0
    while [[ $i -lt 30 ]];
    do
        if kill -0 "$LOG_MONITOR_PID" 2>/dev/null; then
            sleep 1
        else
            break
        fi
        ((i++))
    done
    kill $LOG_MONITOR_PID 2>/dev/null || true
    set -xe
  fi

  # backup cache
  if [[ $preserve_cache == true ]]; then
    echo "=== Execution complete — caching current session to $DX_CACHEDIR/$NXF_UUID"

    # wrap cache folder and upload cache.tar
    if [[ -n "$(ls -A .nextflow)" ]]; then
      tar -cf cache.tar .nextflow

      CACHE_ID=$(dx upload "cache.tar" --path "$DX_CACHEDIR/$NXF_UUID/cache.tar" --no-progress --brief --wait -p -r) &&
        echo "Upload cache of current session as file: $CACHE_ID" &&
        rm -f cache.tar ||
        echo "Failed to upload cache of current session $NXF_UUID"
    else
      echo "No cache is generated from this execution. Skip uploading cache."
    fi

  # preserve_cache is false
  # clean up files of this session
  else
    echo "=== Execution complete — cache and working files will not be resumable"
  fi

  # remove .nextflow from the current folder /home/dnanexus/nextflow_execution
  rm -rf .nextflow
  rm nxf_runtime.config

  # try uploading the log file if it is not empty
  if [[ -s $LOG_NAME ]]; then
    mkdir -p /home/dnanexus/out/nextflow_log
    mv "$LOG_NAME" "/home/dnanexus/out/nextflow_log/$LOG_NAME" || true
  else
    echo "No nextflow log file available."
  fi

  # upload the log file and published files if any
  mkdir -p /home/dnanexus/out/published_files
  find . -type f -newermt "$BEGIN_TIME" -exec cp --parents {} /home/dnanexus/out/published_files/ \; -delete

  dx-upload-all-outputs --parallel --wait-on-close || echo "No log file or published files has been generated."
  # done
  exit $ret
}

get_resume_session_id() {
  if [[ $resume == 'true' || $resume == 'last' ]]; then
    # find the latest job run by applet with the same name
    echo "Will try to find the session ID of the latest session run by $EXECUTABLE_NAME."
    PREV_JOB_SESSION_ID=$(
      dx api system findExecutions \
        '{"state":["done","failed"],
          "created": {"after":'$((($(date +%s) - 6 * 60 * 60 * 24 * 30) * 1000))'},
          "project":"'$DX_PROJECT_CONTEXT_ID'",
          "limit":1,
          "includeSubjobs":false,
          "describe":{"fields":{"properties":true}},
          "properties":{
            "nextflow_session_id":true,
            "nextflow_preserve_cache":"true",
            "nextflow_executable":"'$EXECUTABLE_NAME'"}}' 2>/dev/null |
        jq -r '.results[].describe.properties.nextflow_session_id'
    )

    [[ -n $PREV_JOB_SESSION_ID ]] ||
      dx-jobutil-report-error "Cannot find any jobs within the last 6 months to resume from. Please provide the exact sessionID for \"resume\" value or run without resume."
  else
    PREV_JOB_SESSION_ID=$resume
  fi

  valid_id_pattern='^\{?[A-Z0-9a-z]{8}-[A-Z0-9a-z]{4}-[A-Z0-9a-z]{4}-[A-Z0-9a-z]{4}-[A-Z0-9a-z]{12}\}?$'
  [[ "$PREV_JOB_SESSION_ID" =~ $valid_id_pattern ]] ||
    dx-jobutil-report-error "Invalid resume value. Please provide either \"true\", \"last\", or \"sessionID\". 
    If a sessionID was provided, Nextflow cached content could not be found under $DX_CACHEDIR/$PREV_JOB_SESSION_ID/. 
    Please provide the exact sessionID for \"resume\" or run without resume."

  NXF_UUID=$PREV_JOB_SESSION_ID
}

restore_cache() {
  # download latest cache.tar from $DX_CACHEDIR/$PREV_JOB_SESSION_ID/
  PREV_JOB_CACHE_FILE=$(
    dx api system findDataObjects \
      '{"visibility": "either", 
        "name":"cache.tar",
        "scope": {
          "project": "'$DX_PROJECT_CONTEXT_ID'", 
          "folder": "/.nextflow_cache_db/'$NXF_UUID'", 
          "recurse": false}, 
        "describe": true}' 2>/dev/null |
      jq -r '.results | sort_by(.describe.created)[-1] | .id // empty'
  )

  [[ -n $PREV_JOB_CACHE_FILE ]] ||
    dx-jobutil-report-error "Cannot find any $DX_CACHEDIR/$PREV_JOB_SESSION_ID/cache.tar. Please provide a valid sessionID."

  local ret
  ret=$(dx download $PREV_JOB_CACHE_FILE --no-progress -f -o cache.tar 2>&1) ||
    {
      if [[ $ret == *"FileNotFoundError"* || $ret == *"ResolutionError"* ]]; then
        dx-jobutil-report-error "Nextflow cached content cannot be downloaded from $DX_CACHEDIR/$PREV_JOB_SESSION_ID/cache.tar. Please provide the exact sessionID for \"resume\" value or run without resume."
      else
        dx-jobutil-report-error "$ret"
      fi
    }

  # untar cache.tar, which needs to contain
  # 1. cache folder .nextflow/cache/$PREV_JOB_SESSION_ID
  tar -xf cache.tar
  [[ -n "$(ls -A .nextflow/cache/$PREV_JOB_SESSION_ID)" ]] ||
    dx-jobutil-report-error "Previous execution cache of session $PREV_JOB_SESSION_ID is empty."
  rm cache.tar

  # resume succeeded, set session id and add it to job properties
  echo "Will resume from previous session: $PREV_JOB_SESSION_ID"
  RESUME_CMD="-resume $NXF_UUID"
  dx tag "$DX_JOB_ID" "resumed"
}

check_cache_db_storage() {
  MAX_CACHE_STORAGE=20
  existing_cache=$(dx ls $DX_CACHEDIR --folders 2>/dev/null | wc -l)
  [[ $existing_cache -le MAX_CACHE_STORAGE ]] ||
    dx-jobutil-report-error "The number of preserved sessions is already at the limit (N=20) and preserve_cache is true. Please remove the folders in $DX_CACHEDIR to be under the limit, or run without preserve_cache set to true. "
}

validate_run_opts() {
  IFS=" " read -r -a arr <<<"$nextflow_run_opts"
  for i in "${!arr[@]}"; do
    case ${arr[i]} in
    -w=* | -work-dir=*)
      NXF_WORK="${i#*=}"
      break
      ;;
    -w | -work-dir)
      NXF_WORK=${arr[i + 1]}
      break
      ;;
    *) ;;
    esac
  done

  # if there is a user specified workdir, error out as currently user workdir is not supported
  if [[ -n $NXF_WORK ]]; then
    dx-jobutil-report-error "Nextflow workDir is set as $DX_CACHEDIR/<session_id>/work/ if preserve_cache=true, or $DX_WORKSPACE_ID:/work/ if preserve_cache=false. Please remove workDir specification (-w|-work-dir path) in nextflow_run_opts and run again."
  fi
}

check_running_jobs() {
  FIRST_RESUMED_JOB=$(
    dx api system findExecutions \
      '{"state":["idle", "waiting_on_input", "runnable", "running", "debug_hold", "waiting_on_output", "restartable", "terminating"],
        "project":"'$DX_PROJECT_CONTEXT_ID'",
        "includeSubjobs":false,
        "properties":{
          "nextflow_session_id":"'$NXF_UUID'",
          "nextflow_preserve_cache":"true",
          "nextflow_executable":"'$EXECUTABLE_NAME'"}}' 2>/dev/null |
      jq -r '.results[-1].id // empty'
  )

  [[ -n $FIRST_RESUMED_JOB && $DX_JOB_ID == $FIRST_RESUMED_JOB ]] ||
    dx-jobutil-report-error "There is at least one other non-terminal state job with the same sessionID $NXF_UUID. 
    Please wait until all other jobs sharing the same sessionID to enter their terminal state and rerun, 
    or run without preserve_cache set to true."
}

setup_workdir() {
  if [[ $preserve_cache == true ]]; then
    [[ -n $resume ]] || dx mkdir -p $DX_CACHEDIR/$NXF_UUID/work/
    NXF_WORK="dx://$DX_CACHEDIR/$NXF_UUID/work/"
  else
    NXF_WORK="dx://$DX_WORKSPACE_ID:/work/"
  fi
}

dx_path() {
  local str=${1#"dx://"}
  local tmp=$(mktemp -t nf-XXXXXXXXXX)
  case $str in
    project-*)
      dx download $str -o $tmp --no-progress --recursive -f
      echo file://$tmp
      ;;
    container-*)
      dx download $str -o $tmp --no-progress --recursive -f
      echo file://$tmp
      ;;
    *)
      echo "Invalid $2 path: $1"
      return 1
      ;;
  esac
}

main() {
  if [[ $debug == true ]]; then
    export NXF_DEBUG=2
    TRACE_CMD="-trace nextflow.plugin"
    env | grep -v DX_SECURITY_CONTEXT | sort
    set -x
  fi

  DX_CACHEDIR=$DX_PROJECT_CONTEXT_ID:/.nextflow_cache_db
  NXF_PLUGINS_VERSION=1.3.1

  # check if all run opts provided by user are supported
  validate_run_opts

  # check if the number of preserved cache in current project does not exceed the limit (20)
  if [[ $preserve_cache == true ]]; then
    check_cache_db_storage
  fi

  if [ -n "$docker_creds" ]; then
    dx-registry-login
  fi

  # set default NXF env constants
  export NXF_DOCKER_LEGACY=true
  #export NXF_DOCKER_CREDS_FILE=$docker_creds_file
  #[[ $scm_file ]] && export NXF_SCM_FILE=$(dx_path $scm_file 'Nextflow CSM file')
  export NXF_HOME=/opt/nextflow
  export NXF_ANSI_LOG=false
  export NXF_PLUGINS_DEFAULT=nextaur@$NXF_PLUGINS_VERSION
  export NXF_EXECUTOR='dnanexus'

  # use /home/dnanexus/nextflow_execution as the temporary nextflow execution folder
  mkdir -p /home/dnanexus/nextflow_execution
  cd /home/dnanexus/nextflow_execution
  required_inputs=""
  @@REQUIRED_RUNTIME_PARAMS@@

  # get job output destination
  DX_JOB_OUTDIR=$(jq -r '[.project, .folder] | join(":")' /home/dnanexus/dnanexus-job.json)
  # initiate log file
  LOG_NAME="nextflow-$DX_JOB_ID.log"

  # get current executable name
  EXECUTABLE_NAME=$(jq -r .executableName /home/dnanexus/dnanexus-job.json)

  # set/create current session id
  if [[ -n $resume ]]; then
    get_resume_session_id
  else
    NXF_UUID=$(uuidgen)
  fi
  export NXF_UUID

  # Using the lenient mode to caching makes it possible to reuse working files for resume on the platform
  export NXF_CACHE_MODE=LENIENT

  if [[ $preserve_cache == true ]]; then
    dx set_properties "$DX_JOB_ID" \
      nextflow_executable="$EXECUTABLE_NAME" \
      nextflow_session_id="$NXF_UUID" \
      nextflow_preserve_cache="$preserve_cache"
  fi

  # check if there are any ongoing jobs resuming
  # and generating new cache for the session to resume
  if [[ $preserve_cache == true && -n $resume ]]; then
    check_running_jobs
  fi

  # restore previous cache and create resume argument to nextflow run
  RESUME_CMD=""
  if [[ -n $resume ]]; then
    restore_cache
  fi

  # set workdir based on preserve_cache option
  setup_workdir
  export NXF_WORK

  # for optional inputs, pass to the run command by using a runtime config
  RUNTIME_CONFIG_CMD=""
  generate_runtime_config

  # set beginning timestamp
  BEGIN_TIME="$(date +"%Y-%m-%d %H:%M:%S")"

  # execution starts
  NEXTFLOW_CMD="nextflow \
    ${TRACE_CMD} \
    $nextflow_top_level_opts \
    ${RUNTIME_CONFIG_CMD} \
    -log ${LOG_NAME} \
    run @@RESOURCES_SUBPATH@@ \
    @@PROFILE_ARG@@ \
    -name $DX_JOB_ID \
    $RESUME_CMD \
    $nextflow_run_opts \
    $nextflow_pipeline_params \
    $required_inputs
      "

  trap on_exit EXIT
  echo "============================================================="
  echo "=== NF projectDir   : @@RESOURCES_SUBPATH@@"
  echo "=== NF session ID   : ${NXF_UUID}"
  echo "=== NF log file     : dx://${DX_JOB_OUTDIR%/}/${LOG_NAME}"
  if [[ $preserve_cache == true ]]; then
    echo "=== NF cache folder : dx://${DX_CACHEDIR}/${NXF_UUID}/"
  fi
  echo "=== NF command      :" $NEXTFLOW_CMD
  echo "============================================================="

    $NEXTFLOW_CMD & NXF_EXEC_PID=$!
    # forwarding nextflow log file to job monitor
    set +x
    if [[ $debug == true ]] ; then
      touch $LOG_NAME
      tail --follow -n 0 $LOG_NAME -s 60 >&2 & LOG_MONITOR_PID=$!
      disown $LOG_MONITOR_PID
      set -x
    fi
    
    wait $NXF_EXEC_PID
    ret=$?
    exit $ret
}

nf_task_exit() {
  ret=$?
  if [ -f .command.log ]; then
    dx upload .command.log --path "${cmd_log_file}" --brief --wait --no-progress || true
  else
    >&2 echo "Missing Nextflow .command.log file"
  fi
  # mark the job as successful in any case, real task
  # error code is managed by nextflow via .exitcode file
  if [ -z ${exit_code} ]; then export exit_code=0; fi
  dx-jobutil-add-output exit_code $exit_code --class=int
}

nf_task_entry() {
  if [ -n "$docker_creds" ]; then
    dx-registry-login
  fi
  # capture the exit code
  trap nf_task_exit EXIT
  # remove the line in .command.run to disable printing env vars if debugging is on
  dx cat "${cmd_launcher_file}" | sed 's/\[\[ $NXF_DEBUG > 0 ]] && nxf_env//' > .command.run
  set +e
  # enable debugging mode
  [[ $NXF_DEBUG ]] && set -x
  # run the task
  bash .command.run > >(tee .command.log) 2>&1
  export exit_code=$?
  dx set_properties ${DX_JOB_ID} exit_code=$exit_code
  set -e
}
