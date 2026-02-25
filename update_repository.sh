#!/usr/bin/env bash

function makeList {
	local arrname="$1" ; shift
	local values="$*" trimValue

	trimValue="${values//$'\n'/ }"
	trimValue="${trimValue//$'\t'/ }"

	eval "$arrname=($trimValue)"

	return 0
}

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

	# disable debug builds
	cat >/etc/makepkg.conf.d/nafets227-build-aur-package-nodebug.conf \
			<<-"EOF" || return 1
		OPTIONS+=( '!debug' )
		EOF

	# create an empty repository file
	if [ ! -f "/home/builder/workspace/$INPUT_REPONAME.db.tar.gz" ] ; then
		tar cvfz "/home/builder/workspace/$INPUT_REPONAME.db.tar.gz" \
			-T /dev/null &&
		touch --date=1970-01-01 \
			"/home/builder/workspace/$INPUT_REPONAME.db.tar.gz" &&
		true || return 1
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
		# load preserved packages into pacman-db. This is needed if a
		# to be built package has a dependency to a previously built package,
		# especially if using versioned dependency, e.g. vdr-api=6
		pacman -Sy
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

function load_pkg_deps {
	local pkgbase="$1"
	local pkgdeps=() pkgdeplist p

	printf -v pkgdeplist "%s\t%s\n" "$pkgbase" "$pkgbase"
	pkgs_dependency+="$pkgdeplist"

	mapfile -t pkgdeps < <(
		#shellcheck disable=SC1090,SC2154
		. "/home/builder/pkgsrc/$pkgbase/PKGBUILD" &&
		printf '%s\n' "${depends[@]}" "${makedepends[@]}" \
		|| printf "###ERROR###\n"
		)

	for p in "${pkgdeps[@]}" ; do
		if [ -z "$p" ] ; then
			continue
		elif [ "$p" == "###ERROR###" ] ; then
			return 1
		elif pacman -S --print "$p" >/dev/null 2>/dev/null ; then
			printf "ignoring pacman dependency %s of %s\n" "$p" "$pkgbase"
		elif [[ "$p" =~ [\<\>=] ]] ; then
			p=${p%%<*}
			p=${p%%>*}
			p=${p%%=*}
			printf -v pkgdeplist "%s\t%s\n" "$pkgbase" "[${p}]"
			pkgs_dependency+="$pkgdeplist"
		else
			printf "resolving aur dependency %s of %s\n" "$p" "$pkgbase"
			load_pkg "$p" || return 1
			printf -v pkgdeplist "%s\t%s\n" "$pkgbase" "$p"
			pkgs_dependency+="$pkgdeplist"
		fi
	done

	mapfile -t pkgprovides < <(
		set -o pipefail
		makepkg --printsrcinfo \
			--dir /home/builder/pkgsrc/"$pkgbase" \
		| sed -n 's/.*provides = //p' \
		|| printf "###ERROR###\n"
		)
	# result e.g. "vdr-api=6"
	for p in "${pkgprovides[@]}" ; do
		if [ "$p" == "###ERROR###" ] ; then
			return 1
		fi
		p=${p%%<*}
		p=${p%%>*}
		p=${p%%=*}
		printf -v pkgdeplist "%s\t%s\n" "[${p}]" "$pkgbase"
		pkgs_dependency+="$pkgdeplist"
	done

	return 0
}

function load_pkg {
	local gitsrv="$1"
	local gitpath="/"
	local pkgbase
	pkgbase="$(basename "$1" .git)" || return 1

	if [ -f /home/builder/pkgsrc/"$pkgbase"/PKGBUILD ] ; then
		# package already loaded
		return 0
	fi

	mkdir -p /home/builder/git/"$pkgbase" /home/builder/pkgsrc/"$pkgbase" \
		|| return 1

	# download from aur if only package name is given
	if [ "${gitsrv:0:8}" != "https://" ] ; then
		gitsrv=https://aur.archlinux.org/"$gitsrv".git
	fi

	while true ; do
		printf "trying to clone %s from %s\n" "$pkgbase" "$gitsrv"
		if git clone \
			-c init.defaultBranch=master \
			"$gitsrv" \
			/home/builder/git/"$pkgbase"
		then
			# success
			break
		else
			# failed -> retry
			gitpath="/$(basename "$gitsrv")$gitpath"
			gitsrv="$(dirname "$gitsrv")"
			if [ "$gitsrv" == "https:" ] || [ "$gitsrv" == "." ] ; then
				# no clone worked, so URL is probably wrong
				printf "Could not download package from %s\n" "$1"
				return 1
			fi
		fi
	done

	if [ ! -d /home/builder/git/"$pkgbase"/"$gitpath" ] ; then
		printf "Cloned %s from %s, but path %s does not exist. Aborting.\n" \
			"$pkgbase" "$gitsrv" "$gitpath"
		return 1
	fi

	mv \
		/home/builder/git/"$pkgbase"/"$gitpath"/* \
		/home/builder/git/"$pkgbase"/"$gitpath"/.* \
		/home/builder/pkgsrc/"$pkgbase" \
	|| return 1

	printf "Loaded package from %s at %s\n" "$gitsrv" "$gitpath"

	load_pkg_deps "$pkgbase" || return 1

	return 0
}

function build {
	local inp_pkgs inp_addpkg_aur inp_addpkg_pacman pkgs_bydep pkgs_dependency
	local pkgfiles=()

	# remove newlines from any input parameters
	makeList inp_pkgs "$INPUT_PACKAGES" &&
	makeList inp_addpkg_aur "$INPUT_MISSING_AUR_DEPENDENCIES"
	makeList inp_addpkg_pacman "$INPUT_MISSING_PACMAN_DEPENDENCIES"

	# Get list of all packages with dependencies to install.
	printf "AUR Packages requested to install: %s\n" "${inp_pkgs[*]}"
	printf "AUR Packages to fix missing dependencies: %s\n" "${inp_addpkg_aur[*]}"
	printf "Name of pacman repository: %s\n" "$INPUT_REPONAME"
	printf "Keep existing packages: %s\n" "$INPUT_KEEP"

	# Check for optional missing pacman dependencies to install.
	if [ -n "${inp_addpkg_pacman[*]}" ] ; then
		printf "Additional Pacman packages to install: %s\n" \
			"${inp_addpkg_pacman[*]}"
		sudo pacman --needed --noconfirm -S "${inp_addpkg_pacman[@]}"
	fi

	pkgs_dependency=""
	for f in "${inp_pkgs[@]}" "${inp_addpkg_aur[@]}" ;
	do
		load_pkg "$f" || exit 1
	done

	#override architecture if requested
	if [ "$INPUT_ARCH_OVERRIDE" == "true" ] ; then
		aurparmarchoverrride="--ignorearch"
	else
		aurparmarchoverrride=""
	fi

	mapfile -t pkgs_bydep < <(
		set -o pipefail
		tsort <<<"$pkgs_dependency" | tac \
		|| printf "###ERROR###\n"
		)

	for p in "${pkgs_bydep[@]}" ; do
		if [ "$p" == "###ERROR###" ] ; then
			return 1
		elif [[ "$p" =~ \[.+\] ]] ; then
			# ignore dummy package in brackets
			continue
		fi
		# update version if it is a vcs version package
		# i.e. pkgver function is defined
		makepkg \
			--dir "/home/builder/pkgsrc/$p" \
			--nodeps \
			--nobuild \
			PKGDEST=/home/builder/workspace \
			$aurparmarchoverrride \
		|| return 1
		mapfile -t pkgfiles < <(
			makepkg \
				--dir "/home/builder/pkgsrc/$p" \
				--packagelist \
				PKGDEST=/home/builder/workspace \
				$aurparmarchoverrride \
			|| printf "###ERROR###\n"
			)
		for pkg in "${pkgfiles[@]}" ; do
			if [ "$pkg" == "###ERROR###" ] ; then
				return 1
			elif [ ! -f "$pkg" ] ; then
				makepkg \
					--syncdeps \
					--dir "/home/builder/pkgsrc/$p" \
					--noconfirm \
					--force \
					--holdver \
					PKGDEST=/home/builder/workspace \
					$aurparmarchoverrride
				repo-add \
					"/home/builder/workspace/$INPUT_REPONAME.db.tar.gz" \
					"${pkgfiles[@]}"
				sudo pacsync "$INPUT_REPONAME"
				break
			fi
		done
	done

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
	. /etc/profile # load PATH
	build
fi
