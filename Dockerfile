# Remember some variables are defined by Docker.
# For details see https://docs.docker.com/engine/reference/builder/#automatic-platform-args-in-the-global-scope
# Short Summary:
# TARGETPLATFORM - platform of the build result. Eg linux/amd64, linux/arm/v7, windows/amd64.
# TARGETOS - OS component of TARGETPLATFORM
# TARGETARCH - architecture component of TARGETPLATFORM
# TARGETVARIANT - variant component of TARGETPLATFORM

FROM archlinux:base-devel AS base-linux-amd64
ENV ARCHLINUX_ARG=x86_64

FROM menci/archlinuxarm:base-devel as base-linux-arm64
ENV ARCHLINUX_ARG=aarch64

FROM base-${TARGETOS}-${TARGETARCH}${TARGETVARIANT}

# Create a local user for building since aur tools should be run as normal user.
# Also update all packages (-u), so that the newly installed tools use up-to-date packages.
#       For example, gcc (in base-devel) fails if it uses an old glibc (from
#       base image).
RUN \
	# workaround, probably solved when both archlinux x86_64 and aarch64 update
	# to gnupg 2.4.x
	echo allow-weak-key-signatures >>/etc/pacman.d/gnupg/gpg.conf && \
    \
    pacman-key --init && \
    pacman -Syu --noconfirm --needed sudo expect && \
    groupadd builder && \
    useradd -m -g builder builder && \
    echo 'builder ALL = NOPASSWD: ALL' > /etc/sudoers.d/builder_pacman

USER builder

# Build aurutils as unprivileged user.
RUN \
    cd /tmp/ && \
    curl --output aurutils.tar.gz https://aur.archlinux.org/cgit/aur.git/snapshot/aurutils.tar.gz && \
    tar xf aurutils.tar.gz && \
    cd aurutils && \
    makepkg --syncdeps --noconfirm && \
    sudo pacman -U --noconfirm aurutils-*.pkg.tar.* && \
    mkdir /home/builder/workspace

USER root
# Note: Github actions require the dockerfile to be run as root, so do not
#       switch back to the unprivileged user.
#       Use `sudo --user <user> <command>` to run a command as this user.

CMD ["/update_repository.sh"]

COPY update_repository.sh /
