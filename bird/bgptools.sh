#!/bin/sh

# Resources:
# https://bgp.tools

PROV="bgptools"
URL="https://bgp.tools/table.txt"

AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/154.0.0.0 Safari/537.36"

DIR_CONF="/etc/bird/static.conf.d"
DIR_PROV="/etc/bird/${PROV}"
DIR_TEMP="${DIR_PROV}/conf"

FILE_TAB="${DIR_PROV}/table.txt"

FILE_AS_MAP="/etc/bird/as.mapping.txt"
FILE_NAMES="${DIR_PROV}/names.txt"

CR="$(printf '\r')"

# Succeeds if $1 is a number from 0 to 4294967295 without leading zeros
is_uint32() {
	case "$1" in
		''|0?*|*[!0-9]*)
			return 1
			;;
	esac
	[ "${#1}" -lt 10 ] || { [ "${#1}" -eq 10 ] && ! [ "$1" \> "4294967295" ]; }
}

# Checks every line of a mapping file and appends its group names to ${FILE_NAMES}
# $1 - mapping file, $2 - item type: asn (AS numbers) or iso (ISO alpha-2 codes)
check_map() {
	N=0
	while IFS= read -r LINE || [ -n "${LINE}" ]; do
		N=$((N+1))
		LINE="${LINE%"${CR}"}" # strip CR of CRLF line endings
		LINE="${LINE%%#*}" # strip comments

		read -r ID GROUP ITEMS <<-EOF
		${LINE}
		EOF

		if [ -z "${ID}" ]; then
			continue
		fi

		ERROR=""
		if ! is_uint32 "${ID}"; then
			ERROR="ID ${ID} is not a number from 0 to 4294967295"
		elif [ "$2" = "asn" ] && [ "${ID}" = "100" ]; then
			ERROR="ID 100 is taken by custom static routes"
		elif [ -z "${GROUP}" ] || [ -z "${ITEMS}" ]; then
			ERROR="a line must have an ID, a name and a list of items"
		else
			case "${GROUP}" in
				*[!A-Za-z0-9_]*)
					ERROR="name ${GROUP} may only contain letters, digits and _"
					;;
			esac
			case "${ITEMS}" in
				,*|*,|*,,*|*[!A-Za-z0-9,]*)
					ERROR="${ITEMS} is not a comma-separated list without spaces"
					;;
			esac
		fi

		if [ -z "${ERROR}" ]; then
			for ITEM in $(echo "${ITEMS}" | tr "," "\n"); do
				if [ "$2" = "asn" ]; then
					if ! is_uint32 "${ITEM}" || [ "${ITEM}" = "0" ]; then
						ERROR="${ITEM} is not an AS number from 1 to 4294967295"
						break
					fi
				else
					case "${ITEM}" in
						[A-Za-z][A-Za-z])
							;;
						*)
							ERROR="${ITEM} is not an ISO alpha-2 code"
							break
							;;
					esac
				fi
			done
		fi

		if [ -n "${ERROR}" ]; then
			echo "Error: ${1}, line ${N}: ${ERROR}. Exiting."
			return 1
		fi

		echo "${GROUP}" >> "${FILE_NAMES}"
	done < "$1"
}

if [ ! -d "${DIR_CONF}" ]; then
	echo "Error: Directory ${DIR_CONF} doesn't exist. Exiting."
	exit 1
fi

if [ ! -d "${DIR_PROV}" ]; then
	mkdir -p "${DIR_PROV}"
else
	rm -f "${DIR_PROV}"/*.table.txt
fi

# Generate into a temporary directory, the previous config is replaced only when the run succeeds
rm -rf "${DIR_TEMP}"
mkdir -p "${DIR_TEMP}"

if [ ! -s "${FILE_AS_MAP}" ]; then
	echo "Error: File ${FILE_AS_MAP} doesn't exist. Exiting."
	exit 1
fi

truncate -s 0 "${FILE_NAMES}"
check_map "${FILE_AS_MAP}" asn || exit 1

# Names become file and protocol names in lower case, so they must differ ignoring case
DUPLICATES="$(tr '[:upper:]' '[:lower:]' < "${FILE_NAMES}" | sort | uniq -d | tr '\n' ' ')"
if [ -n "${DUPLICATES}" ]; then
	echo "Error: Names ${DUPLICATES% } are used more than once in ${FILE_AS_MAP}, ignoring case. Exiting."
	exit 1
fi

if [ ! -s "${FILE_TAB}" ] || [ "$(($(date +%s)-$(date -r "${FILE_TAB}" +%s)))" -gt 86400 ]; then
	if ! curl --fail --silent --location --user-agent "${AGENT}" --output "${FILE_TAB}.tmp" "${URL}" || ! mv -f "${FILE_TAB}.tmp" "${FILE_TAB}"; then
		rm -f "${FILE_TAB}.tmp"
		echo "Error: File ${FILE_TAB} is missing or obsolete and can't be downloaded. Exiting."
		exit 1
	fi
fi

while IFS= read -r LINE || [ -n "${LINE}" ]; do
	LINE="${LINE%"${CR}"}" # strip CR of CRLF line endings
	LINE="${LINE%%#*}" # strip comments

	read -r ID GROUP NUMBERS <<-EOF
	${LINE}
	EOF

	if [ -n "${ID}" ] && [ -n "${GROUP}" ] && [ -n "${NUMBERS}" ]; then
		GROUP_LC="$(echo "${GROUP}" | tr '[:upper:]' '[:lower:]')"

		FILE_GROUP="${DIR_PROV}/${GROUP_LC}.table.txt"
		truncate -s 0 "${FILE_GROUP}"

		grep -E " ($(echo "${NUMBERS}" | tr ',' '|'))\$" "${FILE_TAB}" > "${FILE_GROUP}"

		FILE_IPV4="${DIR_TEMP}/${GROUP_LC}.ipv4.${PROV}.conf"
		FILE_IPV6="${DIR_TEMP}/${GROUP_LC}.ipv6.${PROV}.conf"
		truncate -s 0 "${FILE_IPV4}"
		truncate -s 0 "${FILE_IPV6}"

		for NUMBER in $(echo "${NUMBERS}" | tr "," "\n"); do
			echo "# AS${NUMBER}" | tee -a "${FILE_IPV4}" "${FILE_IPV6}" > /dev/null
			grep -E ".*\..* ${NUMBER}\$" "${FILE_GROUP}" | awk -v asn="${NUMBER}" '{printf "route %s unreachable { asn_origin = %s; };\n", $1, asn}' >> "${FILE_IPV4}"
			grep -E ".*:.* ${NUMBER}\$" "${FILE_GROUP}" | awk -v asn="${NUMBER}" '{printf "route %s unreachable { asn_origin = %s; };\n", $1, asn}' >> "${FILE_IPV6}"
		done

		FILE_PROTO="${DIR_TEMP}/${GROUP_LC}.proto.${PROV}.conf"
		cat <<EOF > "${FILE_PROTO}"
protocol static s4_${PROV}_${GROUP_LC} {
	description "Static IPv4 ${GROUP} ID ${ID} [${NUMBERS}]";
	ipv4 {
		table mixed4;
		import filter {
			bgp_large_community.add((asn_bird, tag_asn_group, ${ID}));
			if defined(asn_origin) then bgp_large_community.add((asn_bird, tag_asn_origin, asn_origin));
			accept;
		};
		export none;
	};
	include "${DIR_CONF}/${GROUP_LC}.ipv4.${PROV}.conf";
}

protocol static s6_${PROV}_${GROUP_LC} {
	description "Static IPv6 ${GROUP} ID ${ID} [${NUMBERS}]";
	ipv6 {
		table mixed6;
		import filter {
			bgp_large_community.add((asn_bird, tag_asn_group, ${ID}));
			if defined(asn_origin) then bgp_large_community.add((asn_bird, tag_asn_origin, asn_origin));
			accept;
		};
		export none;
	};
	include "${DIR_CONF}/${GROUP_LC}.ipv6.${PROV}.conf";
}
EOF
	fi
done < "${FILE_AS_MAP}"

rm -f "${DIR_CONF}"/*.${PROV}.conf
for FILE in "${DIR_TEMP}"/*.${PROV}.conf; do
	if [ -e "${FILE}" ] && ! mv -f "${FILE}" "${DIR_CONF}/"; then
		echo "Error: File ${FILE} can't be moved to ${DIR_CONF}. Exiting."
		exit 1
	fi
done

exit 0
