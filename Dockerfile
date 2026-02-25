# Remember some variables are defined by Docker.
#editorconfig-checker-disable-next-line
# For details see https://docs.docker.com/engine/reference/builder/#automatic-platform-args-in-the-global-scope
# Short Summary:
# TARGETPLATFORM - platform of the build result.
#     Eg linux/amd64, linux/arm/v7, windows/amd64.
# TARGETOS - OS component of TARGETPLATFORM
# TARGETARCH - architecture component of TARGETPLATFORM
# TARGETVARIANT - variant component of TARGETPLATFORM

#checkov:skip=CKV2_DOCKER_1: sudo is used intentionally
#checkov:skip=CKV_DOCKER_2: HEALTHCHECK not useful for "batch" container
#checkov:skip=CKV_DOCKER_7: using latest tag intentionally
#checkov:skip=CKV_DOCKER_8: last user must be root for Github actions
# hadolint global ignore=DL3002,DL3003,DL3004,DL3006,DL3007
	# DL3002 warning: Last USER should not be root
	# DL3003 warning: Use WORKDIR to switch to a directory
	# DL3004 error: Do not use sudo as it leads to unpredictable behavior.
	#        Use a tool like gosu to enforce root
	# DL3006 warning: Always tag the version of an image explicitly
	# DL3007 warning: Using latest is prone to errors if the image will ever
	#        update. Pin the version explicitly to a release tag

FROM archlinux:base-devel AS base-linux-amd64
ENV ARCHLINUX_ARG=x86_64

FROM menci/archlinuxarm:base-devel AS base-linux-arm64
ENV ARCHLINUX_ARG=aarch64
RUN \
	sed -i 's/CheckSpace/#CheckSpace/' /etc/pacman.conf

FROM base-${TARGETOS}-${TARGETARCH}${TARGETVARIANT}

# Create a local user for building since makepkg should be run as normal user.
# Also update all packages (-u), so that the newly installed tools use
# up-to-date packages.
#       For example, gcc (in base-devel) fails if it uses an old glibc (from
#       base image).
RUN \
	sed -i 's/#DisableSandbox/DisableSandbox/' /etc/pacman.conf && \
	pacman-key --init && \
	pacman -Syu --noconfirm --needed sudo expect pacutils git && \
	groupadd builder && \
	useradd -m -g builder builder && \
	echo 'builder ALL = NOPASSWD: ALL' > /etc/sudoers.d/builder_pacman

USER builder

WORKDIR /home/builder

USER root
# Note: Github actions require the dockerfile to be run as root, so do not
#       switch back to the unprivileged user.
#       Use `sudo --user <user> <command>` to run a command as this user.

CMD ["/update_repository.sh"]

COPY update_repository.sh /
