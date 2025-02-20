#!/usr/bin/env sh

#Rcode0 API Integration
#https://my.rcodezero.at/api-doc
#
#
#
#RCODE0_URL="https://my.rcodezero.at"
#RCODE0_API_TOKEN="0123456789ABCDEF"
#RCODE0_TTL=60

DEFAULT_RCODE0_URL="https://my.rcodezero.at"
DEFAULT_RCODE0_TTL=60

########  Public functions #####################
#Usage: add _acme-challenge.www.domain.com "123456789ABCDEF0000000000000000000000000000000000000"
#fulldomain
#txtvalue
dns_rcode0_add() {
  fulldomain=$1
  txtvalue=$2

  if [ -z "$RCODE0_URL" ]; then
    RCODE0_URL="$DEFAULT_RCODE0_URL"
  fi


  if [ -z "$RCODE0_API_TOKEN" ]; then
    RCODE0_API_TOKEN=""
    _err "Missing Rcode0 API Token."
    _err "Please login and create your token at httsp://my.rcodezero.at/enableapi and try again."
    return 1
  fi

  if [ -z "$RCODE0_TTL" ]; then
    RCODE0_TTL="$DEFAULT_RCODE0_TTL"
  fi

  #save the api addr and key to the account conf file.
  _saveaccountconf RCODE0_URL "$RCODE0_URL"
  _saveaccountconf RCODE0_API_TOKEN "$RCODE0_API_TOKEN"

  if [ "$RCDOE0_TTL" != "$DEFAULT_RCODE0_TTL" ]; then
    _saveaccountconf RCODE0_TTL "$RCODE0_TTL"
  fi

  _debug "Detect root zone"
  if ! _get_root "$fulldomain"; then
    _err "invalid domain"
    return 1
  fi
  _debug _domain "$_domain"

  if ! set_record "$_domain" "$fulldomain" "$txtvalue"; then
    return 1
  fi

  return 0
}

#fulldomain
dns_rcode0_rm() {
  fulldomain=$1
  txtvalue=$2

  if [ -z "$RCODE0_TTL" ]; then
    RCODE0_TTL="$DEFAULT_RCODE0_TTL"
  fi

  _debug "Detect root zone"
  if ! _get_root "$fulldomain"; then
    _err "invalid domain"
    return 1
  fi

  _debug _domain "$_domain"

  if ! rm_record "$_domain" "$fulldomain" "$txtvalue"; then
    return 1
  fi

  return 0
}

set_record() {
  _info "Adding record"
  root=$1
  full=$2
  new_challenge=$3

  _record_string=""
  _build_record_string "$new_challenge"
  _list_existingchallenges
  for oldchallenge in $_existing_challenges; do
    _build_record_string "$oldchallenge"
  done

  if ! _rcode0_rest "PATCH" "/api/v1/zones/$root/rrsets" "[{\"changetype\": \"add\", \"name\": \"$full.\", \"type\": \"TXT\", \"ttl\": $RCODE0_TTL, \"records\": [$_record_string]}]"; then
    _err "Set txt record error."
    return 1
  fi

  if ! notify_slaves "$root"; then
    return 1
  fi

  return 0
}

rm_record() {
  _info "Remove record"
  root=$1
  full=$2
  txtvalue=$3

  #Enumerate existing acme challenges
  _list_existingchallenges

  if _contains "$_existing_challenges" "$txtvalue"; then
    #Delete all challenges (PowerDNS API does not allow to delete content)
    if ! _rcode0_rest "PATCH" "/api/v1/zones/$root/rrsets" "{\"rrsets\": [{\"changetype\": \"delete\", \"name\": \"$full.\", \"type\": \"TXT\"}]}"; then
      _err "Delete txt record error."
      return 1
    fi
    _record_string=""
    #If the only existing challenge was the challenge to delete: nothing to do
    if ! [ "$_existing_challenges" = "$txtvalue" ]; then
      for oldchallenge in $_existing_challenges; do
        #Build up the challenges to re-add, ommitting the one what should be deleted
        if ! [ "$oldchallenge" = "$txtvalue" ]; then
          _build_record_string "$oldchallenge"
        fi
      done
      #Recreate the existing challenges
      if ! _rcode0_rest "PATCH" "/api/v1/zones/$root/rrsets" "{\"rrsets\": [{\"changetype\": \"update\", \"name\": \"$full.\", \"type\": \"TXT\", \"ttl\": $RCODE0_TTL, \"records\": [$_record_string]}]}"; then
        _err "Set txt record error."
        return 1
      fi
    fi
  else
    _info "Record not found, nothing to remove"
  fi

  return 0
}

notify_slaves() {
  root=$1

  return 0
}

####################  Private functions below ##################################
#_acme-challenge.www.domain.com
#returns
# _domain=domain.com
_get_root() {
  domain=$1
  i=1

  if _rcode0_rest "GET" "/api/v1/zones"; then
    _zones_response="$response"
  fi

 _debug "$response"
  while true; do
    h=$(printf "%s" "$domain" | cut -d . -f $i-100)

    _debug "H: $h"
    if _contains "$_zones_response" "\"domain\":\"$h\""; then
      _domain="$h"
      if [ -z "$h" ]; then
        _domain="=2E"
      fi
      return 0
    fi

    if [ -z "$h" ]; then
      return 1
    fi
    i=$(_math $i + 1)
  done
  _debug "$domain not found"

  return 1
}

_rcode0_rest() {
  method=$1
  ep=$2
  data=$3

  export _H1="Authorization: Bearer $RCODE0_API_TOKEN"

  if [ ! "$method" = "GET" ]; then
    _debug data "$data"
    response="$(_post "$data" "$RCODE0_URL$ep" "" "$method")"
  else
    response="$(_get "$RCODE0_URL$ep")"
  fi

  if [ "$?" != "0" ]; then
    _err "error $ep"
    return 1
  fi
  _debug2 response "$response"

  return 0
}

_build_record_string() {
  _record_string="${_record_string:+${_record_string}, }{\"content\": \"\\\"${1}\\\"\", \"disabled\": false}"
}

_list_existingchallenges() {
  _rcode0_rest "GET" "/api/v1/zones/$root/rrsets"
  _existing_challenges=$(echo "$response" | _normalizeJson | _egrep_o "\"name\":\"${fulldomain}[^]]*}" | _egrep_o 'content\":\"\\"[^\\]*' | sed -n 's/^content":"\\"//p')
}
