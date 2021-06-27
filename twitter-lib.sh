#!/bin/bash

declare -A tt_log_levels=( [DEBUG]=0 [INFO]=1 [NOTICE]=2 [WARNING]=3 [ERROR]=4 )

declare -A tt_lib=()

tt_get_curtime(){
  # avoid spawning a process if we have a capable bash
  if ( [ "${BASH_VERSINFO[0]}" -ge 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ] ) ||
     ( [ "${BASH_VERSINFO[0]}" -gt 4 ] ); then
    printf '%(%Y-%m-%d %H:%M:%S)T\n' -1
  else
    "${tt_lib['date']}" +"%Y-%m-%d %H:%M:%S"
  fi
}

tt_set_log_level(){
  tt_lib['current_log_level']=${tt_log_levels[$1]}

  if [ "${tt_lib['current_log_level']}" = "" ]; then
    tt_lib['current_log_level']=${tt_log_levels[INFO]}
  fi
}

tt_set_logging_enabled(){
  tt_lib['logging_enabled']=$1    # 0 disabled, anything else enabled
}

tt_set_log_destination(){
  if [ "$1" = "" ]; then
    if [ -t 1 ]; then
      # log to stdout
      tt_lib['log_destination']="stdout"
    else
      # log to file
      tt_lib['log_destination']="file"
    fi
  else
    tt_lib['log_destination']="$1"
    [[ ! "${tt_lib['log_destination']}" =~ ^(stdout|file)$ ]] && tt_lib['log_destination']=stdout
  fi
}

tt_lib['curtime']=$(tt_get_curtime)
tt_lib['curtime']=${tt_lib['curtime']/ /_}
tt_lib['log_file']="/tmp/tt_${tt_lib['curtime']}.log"
tt_set_log_level INFO
tt_set_logging_enabled "1"
tt_set_log_destination ""
tt_lib['binaries_checked']=0

tt_log(){

  local level=$1 msg=$2

  local curtime
  curtime=$(tt_get_curtime)

  if [ "${tt_lib['logging_enabled']}" != "0" ] && [ "${tt_log_levels[$level]}" -ge "${tt_lib['current_log_level']}" ]; then
    if [ "${tt_lib['log_destination']}" = "stdout" ]; then
      echo "$curtime $level: $msg"
    else
      echo "$curtime $level: $msg" >> "${tt_lib['log_file']}"
    fi
  fi
}

check_required_binaries(){

  tt_log DEBUG "Checking required binaries..."

  tt_lib['curl']=$(command -v curl)
  tt_lib['awk']=$(command -v awk)
  tt_lib['openssl']=$(command -v openssl)
  tt_lib['sort']=$(command -v sort)
  tt_lib['date']=$(command -v date)

  { [ "${tt_lib['curl']}" != "" ] && \
    [ "${tt_lib['awk']}" != "" ] && \
    [ "${tt_lib['openssl']}" != "" ] && \
    [ "${tt_lib['sort']}" != "" ] && \
    [ "${tt_lib['date']}" != "" ]; } || \
  { tt_log ERROR "Cannot find needed binaries, make sure you have curl, awk, openssl, sort and date in your PATH" && return 1; }

  tt_lib['binaries_checked']=1
}

tt_get_credentials(){

  if [ "${tt_lib['binaries_checked']}" = "0" ]; then
    check_required_binaries || return 1
  fi

  tt_log DEBUG "Getting Twitter credentials..."

  local tt_userdef_cred_function=tt_get_userdef_credentials

  if ! declare -F $tt_userdef_cred_function >/dev/null; then
    tt_log ERROR "Function '$tt_userdef_cred_function()' does not exist, must define it and make sure it sets variables 'tt_lib[oauth_consumer_key]', 'tt_lib[oauth_consumer_secret]', 'tt_lib[oauth_token]', 'tt_lib[oauth_token_secret]'"
    return 1
  fi

  $tt_userdef_cred_function   # user MUST implement this

  { [ "${tt_lib['oauth_consumer_key']}" != "" ] && \
    [ "${tt_lib['oauth_consumer_secret']}" != "" ] && \
    [ "${tt_lib['oauth_token']}" != "" ] && \
    [ "${tt_lib['oauth_token_secret']}" != "" ]; } || \

    { tt_log ERROR "Cannot get Twitter credentials; make sure '$tt_userdef_cred_function()' sets variables 'tt_lib[oauth_consumer_key]', 'tt_lib[oauth_consumer_secret]', 'tt_lib[oauth_token]', 'tt_lib[oauth_token_secret]'" && return 1; }

  if [ "${tt_lib['user_agent']}" = "" ]; then
    tt_lib['user_agent']="twitter-lib"
  fi
}

# pure bash URL enconding, thanks to
# https://gist.github.com/cdown/1163649#gistcomment-1639097
tt_percent_encode() {

  local old_lang=$LANG
  LANG=C

  local length="${#1}"
  local offset char result=

  for (( offset = 0; offset < length; offset++ )); do
    char=${1:$offset:1}
    case $char in
      [a-zA-Z0-9.~_-])
        result="${result}${char}"
        ;;
      *)
        result="${result}$(printf '%%%02X' "'$char")"
        ;; 
    esac
  done

  LANG=$old_lang

  echo "$result"
}

# receive a "key=value" string and separately percent-encode the two parts
tt_encode_key_value(){
  local key value
  key=${1%%=*}
  value=${1#*=}
  echo "$(tt_percent_encode "${key}")=$(tt_percent_encode "${value}")"
}


tt_compute_oauth(){

  local http_method http_url oauth_nonce
  local oauth_timestamp oauth_auth
  local oauth_parstring nl arg
  local sig_base_string sig_key oauth_signature

  http_method=${1^^}
  http_url=$2
  shift 2

  oauth_nonce="$(${tt_lib['openssl']} rand -base64 15)"
  oauth_timestamp="$(${tt_lib['date']} +%s)"

  local -A sig_parms=( [oauth_consumer_key]="${tt_lib['oauth_consumer_key']}"
                       [oauth_token]="${tt_lib['oauth_token']}"
                       [oauth_nonce]="$oauth_nonce"
                       [oauth_signature_method]="HMAC-SHA1"
                       [oauth_timestamp]="$oauth_timestamp"
                       [oauth_version]="1.0"
                     )

  oauth_auth=
  oauth_parstring=

  nl=$'\n'

  # mandatory parameters
  for arg in "${!sig_parms[@]}"; do

    local key value
    key="$(tt_percent_encode "${arg}")"
    value="$(tt_percent_encode "${sig_parms[$arg]}")"

    local str_parstring="${key}=${value}"
    local str_oauth="${key}=\"${value}\""

    oauth_parstring="${oauth_parstring}${str_parstring}${nl}"
    oauth_auth="${oauth_auth}${str_oauth}, "
  done

  # remaining parameters (only for parstring)
  for arg in "$@"; do
    oauth_parstring="${oauth_parstring}$(tt_encode_key_value "${arg}")${nl}"
  done

  oauth_parstring=$(printf '%s' "$oauth_parstring" | ${tt_lib['sort']} | ${tt_lib['awk']} '{printf "%s%s", sep, $0; sep="&"}')

  sig_base_string="${http_method}&$(tt_percent_encode "${http_url}")&$(tt_percent_encode "${oauth_parstring}")"
  sig_key="$(tt_percent_encode "${tt_lib['oauth_consumer_secret']}")&$(tt_percent_encode "${tt_lib['oauth_token_secret']}")"
  oauth_signature="$(tt_percent_encode "$(printf '%s' "${sig_base_string}" | ${tt_lib['openssl']} sha1 -hmac "${sig_key}" -binary | ${tt_lib['openssl']} base64)")"

  echo "${oauth_auth}oauth_signature=\"${oauth_signature}\""

}

# $1 method
# $2 url without parameters
# $3, $4... key=value pairs
tt_do_call(){

  tt_get_credentials || { tt_log ERROR "Credentials not found, returning" && return 1; }

  local url_parms oauth_auth http_method http_url sep arg

  oauth_auth=$(tt_compute_oauth "$@")

  tt_log DEBUG "OAuth header is $oauth_auth"

  http_method=$1
  http_url=$2
  shift 2

  # encode parameters for use in actual request URL
  url_parms=
  sep=
  for arg in "$@"; do
    url_parms="${url_parms}${sep}$(tt_encode_key_value "${arg}")"
    sep="&"
  done

  [ "${url_parms}" != "" ] && url_parms="?${url_parms}"

  tt_do_curl "${http_url}${url_parms}" \
  -X "${http_method}" \
  -H "Authorization: OAuth ${oauth_auth}"

  if [ $? -ne 0 ]; then
    return 1
  fi

  tt_log DEBUG "HTTP return code is ${tt_lib['last_http_code']}"
  tt_log DEBUG "HTTP reply is ${tt_lib['last_http_body']}"

}

tt_do_curl(){

  local result
  local code

  local -a fixed_args=( "${tt_lib['curl']}" "--compressed" "-s" \
                        "-H" "Expect:" "-D-" "-A" "${tt_lib['user_agent']}" )

  tt_log DEBUG "About to run request:$(printf " '%s'" "${fixed_args[@]}" "$@")"

  result=$( "${fixed_args[@]}" "$@" )

  code=$?
  if [ $code -ne 0 ]; then
    tt_log ERROR "Got error after curl call ($code)"
    return 1
  fi

  tt_lib['last_http_headers']=$(${tt_lib['awk']} '/^\r$/{ exit }1' <<< "$result")
  tt_lib['last_http_body']=$(${tt_lib['awk']} 'ok; /^\r$/ { ok = 1 }' <<< "$result")
  tt_lib['last_http_code']=$(${tt_lib['awk']} '/^HTTP/ { print $2; exit }' <<< "$result")

}

