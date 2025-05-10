#!/usr/bin/env bash

function setup_pacman {
	## Register the local repository with pacman.
	cat >> /etc/pacman.conf <<-EOF

		# local repository (required by aur tools to be set up)
		[$INPUT_REPONAME]
		SigLevel = Optional
		Server = file:///home/builder/workspace
		EOF

	# create directories
	mkdir -p /home/builder/workspace || return 1

	# create an empty repository file
	if [ ! -f "/home/builder/workspace/$INPUT_REPONAME.db.tar.gz" ] ; then
		tar cvfz "/home/builder/workspace/$INPUT_REPONAME.db.tar.gz" \
			-T /dev/null
	fi
	if [ -f "/home/builder/workspace/$INPUT_REPONAME.db" ] ; then
		rm "/home/builder/workspace/$INPUT_REPONAME.db"
	fi
	ln -s "$INPUT_REPONAME.db.tar.gz" \
		"/home/builder/workspace/$INPUT_REPONAME.db"

	chown -R builder:alpm /home/builder
	chmod g+rx /home/builder

	pacman -Sy

	return 0
}

function import_pkgs {
	# Copy workspace to local repo to avoid rebuilding and keep
	# existing packages, even older versions
	printf "Preserving existing files:\n"
	# ignore error if dir does not exist (yet)
	ls -l "$GITHUB_WORKSPACE/$INPUT_REPODIR" 2>/dev/null || true
	if [ -n "$(ls "$GITHUB_WORKSPACE/$INPUT_REPODIR" 2>/dev/null)" ] ; then
		cp -a "$GITHUB_WORKSPACE/$INPUT_REPODIR"/* /home/builder/workspace/
	fi
}

function export_pkgs {
	local updated

	if [ "$INPUT_KEEP" == "true" ] &&
		[ -n "$GITHUB_WORKSPACE" ] &&
		cmp --quiet \
			"/home/builder/workspace/$INPUT_REPONAME.db" \
			"$GITHUB_WORKSPACE/$INPUT_REPODIR/$INPUT_REPONAME.db"
	then
		updated=false
	else
		updated=true
	fi

	if [ -n "$GITHUB_OUTPUT" ] ; then
		printf "updated=%s\n" "$updated" >>"$GITHUB_OUTPUT"
	fi

	if [ -n "$GITHUB_WORKSPACE" ] && [ "$updated" == "true" ] ; then
		printf "Updating workspace with Build results\n"
		# Move the local repository to the workspace.
		rm -f /home/builder/workspace/*.old
		printf "Moving repository to github workspace\n"
		mkdir -p "$GITHUB_WORKSPACE/$INPUT_REPODIR"
		mv /home/builder/workspace/* "$GITHUB_WORKSPACE/$INPUT_REPODIR/"
		# make sure that the .db/.files files are in place
		# Note: Symlinks fail to upload, so copy those files
		cd "$GITHUB_WORKSPACE/$INPUT_REPODIR"
		rm "$INPUT_REPONAME.db" "$INPUT_REPONAME.files"
		cp "$INPUT_REPONAME.db.tar.gz" "$INPUT_REPONAME.db"
		cp "$INPUT_REPONAME.files.tar.gz" "$INPUT_REPONAME.files"
	elif [ -n "$GITHUB_WORKSPACE" ] ; then
		printf "Not updating workspace (no updates)\n"
	else
		printf "No github workspace known (GITHUB_WORKSPACE is unset).\n"
	fi

	return 0
}

function build {
	local inp_pkgs inp_addpkg_aur inp_addpkg_pacman pkgs_aur

	# remove newlines from any input parameters
	inp_pkgs="${INPUT_PACKAGES//$'\n'/ }"
	inp_addpkg_aur="${INPUT_MISSING_AUR_DEPENDENCIES//$'\n'/ }"
	inp_addpkg_pacman="${INPUT_MISSING_PACMAN_DEPENDENCIES//$'\n'/ }"

	# Get list of all packages with dependencies to install.
	printf "AUR Packages requested to install: %s/n" "$inp_pkgs"
	printf "AUR Packages to fix missing dependencies: %s\n" "$inp_addpkg_aur"
	printf "Name of pacman repository: %s\n" "$INPUT_REPONAME"
	printf "Keep existing packages: %s\n" "$INPUT_KEEP"

	#shellcheck disable=SC2086
	# vars intentionally expand to >1 words
	pkgs_aur="$(
		aur depends --pkgname $inp_pkgs $inp_addpkg_aur
		)"
	pkgs_aur="${pkgs_aur//$'\n'/ }"
	for f in $inp_pkgs $inp_addpkg_aur ; do
		if [ "${pkgs_aur/*${f}*/FOUND}" != "FOUND" ] ; then
			printf "ERROR: Package %s not found.\n" "$f"
			exit 1
		fi
	done
	printf "AUR Packages to install (including dependencies): %s\n" \
		"$pkgs_aur"

	# Check for optional missing pacman dependencies to install.
	if [ -n "$inp_addpkg_pacman" ] ; then
		printf "Additional Pacman packages to install: %s\n" \
			"$inp_addpkg_pacman"
		#shellcheck disable=SC2086
		# vars intentionally expand to >1 words
		sudo pacman --needed --noconfirm -S $inp_addpkg_pacman
	fi

	#overrride architecture if requested
	if [ "$INPUT_ARCH_OVERRIDE" == "true" ] ; then
		aurparmarchoverrride="--ignore-arch"
	else
		aurparmarchoverrride=""
	fi

	# Add the packages to the local repository.
	#shellcheck disable=SC2086
	# vars intentionally expand to >1 words
	aur sync \
		--noconfirm --noview \
		--database "$INPUT_REPONAME" \
		--root /home/builder/workspace \
		$aurparmarchoverrride \
		$pkgs_aur

	return 0
}

# Fail if anything goes wrong.
set -e

# Print each line before executing if Github arction debug logging is enabled
if [ "$RUNNER_DEBUG" == "1" ] ; then
	set -x
fi

if [ "$UID" == 0 ] ; then
	# invoked as root. Lets do some setup and then restart as builder

	setup_pacman

	if [ "$INPUT_KEEP" == "true" ] ; then
		import_pkgs
	fi

	sudo --user builder --group alpm --preserve-env --set-home \
		"${BASH_SOURCE[0]}" || exit 1

	export_pkgs
else
	build
fi
