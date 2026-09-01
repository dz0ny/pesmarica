# Buildroot's build host. Buildroot does not run on macOS at all (it needs a
# Linux toolchain, and it refuses to build on a case-insensitive filesystem),
# so everything below the "make image" line happens in here.
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
	bash bc binutils build-essential bzip2 ca-certificates cpio \
	file g++ gcc git gzip libncurses-dev locales make patch perl \
	python3 rsync sed tar unzip wget which xz-utils cmake pkg-config \
	openssl libssl-dev bison flex \
	&& rm -rf /var/lib/apt/lists/*

# Buildroot refuses to run as root.
RUN useradd -m -u 1000 br
USER br
WORKDIR /home/br

# Create the volume mountpoints as `br`: docker seeds a new named volume with
# the ownership of the image directory it covers, so a missing (or root-owned)
# directory here means a root-owned volume the build cannot write to.
RUN mkdir -p /home/br/output /home/br/dl

ARG BUILDROOT_VERSION=2026.05.2
RUN git clone --depth 1 --branch ${BUILDROOT_VERSION} \
	https://gitlab.com/buildroot.org/buildroot.git /home/br/buildroot

ENV BR2_EXTERNAL=/home/br/external
ENV BR2_DL_DIR=/home/br/dl
ENV O=/home/br/output
WORKDIR /home/br/buildroot
