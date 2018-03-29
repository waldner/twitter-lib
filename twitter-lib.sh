#!/bin/bash

declare -A tt_log_levels=( [DEBUG]=0 [INFO]=1 [NOTICE]=2 [WARNING]=3 [ERROR]=4 )

tt_get_curtime(){
  # avoid spawning a process if we have a capable bash
  if [ ${BASH_VERSINFO[0]} -ge 4 ] && [ ${BASH_VERSINFO[1]} -ge 2 ]; then
    printf '%(%Y-%m-%d %H:%M:%S)T\n' -1
  else
    $tt_date +"%Y-%m-%d %H:%M:%S"
  fi
}

tt_set_log_level(){
  tt_current_log_level=${tt_log_levels[$1]}

  if [ "$tt_current_log_level" = "" ]; then
    tt_current_log_level=${tt_log_levels[INFO]}
  fi
}

tt_set_logging_enabled(){
  tt_logging_enabled=$1    # 0 disabled, anything else enabled
}

tt_set_log_destination(){
  if [ "$1" = "" ]; then
    if [ -t 1 ]; then
      # log to stdout
      tt_log_destination="stdout"
    else
      # log to file
      tt_log_destination="file"
    fi
  else
    tt_log_destination="$1"
    [[ "$tt_log_destination" =~ ^(stdout|file)$ ]] && tt_log_destination=stdout
  fi
}

tt_curtime=$(tt_get_curtime)
tt_curtime=${tt_curtime/ /_}
tt_log_file="/tmp/tt_${tt_curtime}.log"
tt_set_log_level INFO
tt_set_logging_enabled "1"
tt_set_log_destination
tt_binaries_checked=0

tt_log(){

  local level=$1 msg=$2

  local curtime=$(tt_get_curtime)

  if [ "$tt_logging_enabled" != "0" ] && [ ${tt_log_levels[$level]} -ge ${tt_current_log_level} ]; then
    if [ "$tt_log_destination" = "stdout" ]; then
      echo "$curtime $level: $msg"
    else
      echo "$curtime $level: $msg" >> "${tt_log_file}"
    fi
  fi
}

check_required_binaries(){

  tt_log DEBUG "Checking required binaries..."

  local retcode=0

  tt_curl=$(command -v curl)
  tt_awk=$(command -v awk)
  tt_openssl=$(command -v openssl)
  tt_sort=$(command -v sort)
  tt_date=$(command -v date)

  ( [ "$tt_curl" != "" ] && \
    [ "$tt_awk" != "" ] && \
    [ "$tt_openssl" != "" ] && \
    [ "$tt_sort" != "" ] && \
    [ "$tt_date" != "" ] ) || \
  { tt_log ERROR "Cannot find needed binaries, make sure you have curl, awk, openssl, sort and date in your PATH" && return 1; }

  tt_binaries_checked=1
}

tt_get_credentials(){

  if [ "$tt_binaries_checked" = "0" ]; then
    check_required_binaries || return 1
  fi

  tt_log DEBUG "Getting Twitter credentials..."

  local tt_userdef_cred_function=tt_get_userdef_credentials

  if ! declare -F $tt_userdef_cred_function >/dev/null; then
    tt_log ERROR "Function '$tt_userdef_cred_function()' does not exist, must define it and make sure it sets variables 'tt_oauth_consumer_key', 'tt_oauth_consumer_secret', 'tt_oauth_token', 'tt_oauth_token_secret'"
    return 1
  fi

  $tt_userdef_cred_function   # user MUST implement this

  ( [ "$tt_oauth_consumer_key" != "" ] && \
    [ "$tt_oauth_consumer_secret" != "" ] && \
    [ "$tt_oauth_token" != "" ] && \
    [ "$tt_oauth_token_secret" != "" ] ) || \

    { tt_log ERROR "Cannot get Twitter credentials; make sure '$tt_userdef_cred_function()' sets variables 'tt_oauth_consumer_key', 'tt_oauth_consumer_secret', 'tt_oauth_token', 'tt_oauth_token_secret'" && return 1; }

  if [ "$tt_user_agent" = "" ]; then
    tt_user_agent="twitter-lib"
  fi
}

# pure bash URL enconding, thanks to
# https://gist.github.com/cdown/1163649
tt_percent_encode() {

  local old_lc_collate=$LC_COLLATE
  LC_COLLATE=C

  local length=${#1}
  local offset char

  local result=

  for (( offset = 0; offset < length; offset++ )); do
    char=${1:$offset:1}

    case "$char" in
      [a-zA-Z0-9.~_-])
        result="${result}${char}"
        ;;
      *)
        result="${result}$(printf '%%%X' "'$char")"
         ;;
    esac
  done

  LC_COLLATE=$old_lc_collate

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
  local oauth_timestamp local oauth_auth
  local oauth_parstring nl arg local
  local sig_base_string sig_key oauth_signature

  http_method=${1^^}
  http_url=$2
  shift 2

  oauth_nonce="$($tt_openssl rand -base64 15)"
  oauth_timestamp="$($tt_date +%s)"

  local -A sig_parms=( [oauth_consumer_key]="$tt_oauth_consumer_key"
                       [oauth_token]="$tt_oauth_token"
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

  oauth_parstring=$(printf '%s' "$oauth_parstring" | $tt_sort | $tt_awk '{printf "%s%s", sep, $0; sep="&"}')

  sig_base_string="${http_method}&$(tt_percent_encode "${http_url}")&$(tt_percent_encode "${oauth_parstring}")"
  sig_key="$(tt_percent_encode "${tt_oauth_consumer_secret}")&$(tt_percent_encode "${tt_oauth_token_secret}")"
  oauth_signature="$(tt_percent_encode "$(printf '%s' "${sig_base_string}" | $tt_openssl sha1 -hmac "${sig_key}" -binary | $tt_openssl base64)")"

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

  tt_log DEBUG "Running query: ${http_method} ${http_url}${url_parms}"

  tt_do_curl "${http_url}${url_parms}" \
  -X "${http_method}" \
  -H "Authorization: OAuth ${oauth_auth}"

  tt_log DEBUG "HTTP return code is $tt_last_http_code"
  tt_log DEBUG "HTTP reply is $tt_last_http_body"

}

tt_do_curl(){

  local result

  result=$(
    $tt_curl --compressed -s \
      -H "Expect:" \
      -D- -A "$tt_user_agent" \
      "$@"
  )

  tt_last_http_headers=$($tt_awk '/^\r$/{ exit }1' <<< "$result")
  tt_last_http_body=$($tt_awk 'ok; /^\r$/ { ok = 1 }' <<< "$result")
  tt_last_http_code=$($tt_awk '/^HTTP/ { print $2; exit }' <<< "$result")

}

