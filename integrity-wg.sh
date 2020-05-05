#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Copyright (C) 2016-2018 Jason A. Donenfeld <Jason@zx2c4.com>. All Rights Reserved.

die() {
	echo "[-] Error: $1" >&2
	exit 1
}

PROGRAM="${0##*/}"
ARGS=( "$@" )
SELF="${BASH_SOURCE[0]}"
[[ $SELF == */* ]] || SELF="./$SELF"
SELF="$(cd "${SELF%/*}" && pwd -P)/${SELF##*/}"
[[ $UID == 0 ]] || exec sudo -p "[?] $PROGRAM must be run as root. Please enter the password for %u to continue: " -- "$BASH" -- "$SELF" "${ARGS[@]}"

[[ ${BASH_VERSINFO[0]} -ge 4 ]] || die "bash ${BASH_VERSINFO[0]} detected, when bash 4+ required"

type curl >/dev/null || die "Please install curl and then try again."
type jq >/dev/null || die "Please install jq and then try again."
set -e

read -p "[?] Please enter your Integrity account username: " -r USER
read -p "[?] Please enter your IntegrityVPN password $PASS_TYPE: " -rs PASS

echo "[+] Contacting Integrity API for server locations."
declare -A SERVER_ENDPOINTS
declare -A SERVER_PUBLIC_KEYS
declare -A SERVER_LOCATIONS
declare -a SERVER_CODES

RESPONSE="$(curl -LsS https://api.5july.net/1.0/locations)" || die "Unable to connect to Integrity API."
FIELDS="$(jq -r '.[] | .hostname,.country,.city,.public_key,.dest_addr,.port' <<<"$RESPONSE")" || die "Unable to parse response."
while read -r HOSTNAME && read -r COUNTRY && read -r CITY && read -r PUBKEY && read -r IPADDR && read -r PORT; do
	CODE="${HOSTNAME%-wireguard}"
	SERVER_CODES+=( "$CODE" )
	SERVER_LOCATIONS["$CODE"]="$CITY, $COUNTRY"
	SERVER_PUBLIC_KEYS["$CODE"]="$PUBKEY"
	SERVER_ENDPOINTS["$CODE"]="$IPADDR:$PORT"
done <<<"$FIELDS"


shopt -s nocasematch
for CODE in "${SERVER_CODES[@]}"; do
	CONFIGURATION_FILE="/etc/wireguard/integrity-$CODE.conf"
	[[ -f $CONFIGURATION_FILE ]] || continue
	while read -r line; do
		[[ $line =~ ^PrivateKey\ *=\ *([a-zA-Z0-9+/]{43}=)\ *$ ]] && PRIVATE_KEY="${BASH_REMATCH[1]}" && break
	done < "$CONFIGURATION_FILE"
	[[ -n $PRIVATE_KEY ]] && echo "[+] Using existing private key." && break
done
shopt -u nocasematch


if [[ -z $PRIVATE_KEY ]]; then
	echo "[+] Generating new private key."
	PRIVATE_KEY="$(wg genkey)"
fi

echo "[+] Contacting Integrity API."
RESPONSE="$(curl -LsS https://api.5july.net/1.0/wireguard -X 'POST' -H "Content-Type: application/json" -d '{"username": "'$USER'", "password": "'$PASS'", "pubkey": "'$(wg pubkey <<< $PRIVATE_KEY)'"}')" || die "Could not talk to Integrity API."
#[[ $RESPONSE =~ ^[0-9a-f:/.,]+$ ]] || die "$RESPONSE"
FIELDS="$(jq -r '.success' <<<"$RESPONSE")" || die "Unable to parse response."
IFS=$'\n' read -r -d '' STATUS <<<"$FIELDS" || true
if [[ $STATUS != ok ]]; then
	die "An unknown API error has occurred. Please try again later. $RESPONSE"
fi
FIELDS="$(jq -r '.dns,.ipv4,.ipv6' <<<"$RESPONSE")" || die "Unable to parse response."
IFS=$'\n' read -r -d '' DNS IPV4 IPV6 <<<"$FIELDS" || true
#ADDRESS="$RESPONSE"
#DNS="1.1.1.1"

echo "[+] Writing WriteGuard configuration files."
for CODE in "${SERVER_CODES[@]}"; do
	CONFIGURATION_FILE="/etc/wireguard/integrity-$CODE.conf"
	umask 077
	mkdir -p /etc/wireguard/
	rm -f "$CONFIGURATION_FILE.tmp"
	cat > "$CONFIGURATION_FILE.tmp" <<-_EOF
		[Interface]
		PrivateKey = $PRIVATE_KEY
		Address = $IPV4,$IPV6
		DNS = $DNS

		[Peer]
		PublicKey = ${SERVER_PUBLIC_KEYS["$CODE"]}
		Endpoint = ${SERVER_ENDPOINTS["$CODE"]}
		AllowedIPs = 0.0.0.0/0, ::/0
	_EOF
	mv "$CONFIGURATION_FILE.tmp" "$CONFIGURATION_FILE"
done

echo "[+] Success. The following commands may be run for connecting to Integrity:"
for CODE in "${SERVER_CODES[@]}"; do
	echo "- ${SERVER_LOCATIONS["$CODE"]}:"
	echo "  \$ wg-quick up integrity-$CODE"
done

echo "Please wait up to 60 seconds for your public key to be added to the servers."
