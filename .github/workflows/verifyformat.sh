#!/bin/bash

function greprc {
	local stepRC=0
	grep "$@" | sed -n l || stepRC=$?
	if [ "$stepRC" -gt 1 ] ; then
		# grep RC 2+ means severe error detected
		exit $stepRC
	elif [ "$stepRC" -eq 0 ] ; then
		# grep RC 0 means some lines found
		RC=1
	else
		# grep RC 1 means no lines found
		:
	fi

	return 0
}

##### Main ###################################################################
export LC_ALL=C # override any user-defined locale
set -e # abort on any error
set -o pipefail
RC=0

# search for leading non-tab spaces
greprc -E -n -r '^[\t]* ' . \
	--exclude-dir=.git \
	--exclude="*.yaml*" \
	--exclude="*.yml*" \
	--exclude="*.md" \
	--exclude="*.patch"

# search for mix of tabs and blanks
greprc -E -n -r '^[\t]+ ' . \
	--exclude-dir=.git \
	--exclude="*.patch"

# search for tab spaces in yaml files
greprc -n -r $'[\t]' . \
	--exclude-dir=.git \
	--exclude=* \
	--include="*.yaml*" \
	--include="*.yml*"

# search Trailing spaces
greprc -E -n -r '[[:space:]]$' . \
	--exclude-dir=.git \
	--exclude-dir=client \
	--exclude="*.patch"

# search 2 consecutive empty lines
# TODO!!!

# search protected spaces
greprc -n -r -P "[^\n\t-~]" . \
	--exclude-dir=.git \
	--exclude-dir=raspi4-vdr-setup \
	--exclude="channelsSort.sh" \
	--exclude="find-dups-onedrive.txt" \
	--exclude="importOwnNotes.awk"

exit $RC
