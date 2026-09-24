#!/bin/bash

#build reshimboot inside a container, so that it works on any linux distro
#(arch, fedora...) and on WSL without installing debian's build tools.
#all arguments are passed on to build_complete.sh, for example:
#  sudo ./build_docker.sh desktop=kde

set -e
cd "$(dirname "$0")"

engine="${CONTAINER_ENGINE:-}"
if [ ! "$engine" ]; then
  for candidate in docker podman; do
    if command -v "$candidate" > /dev/null; then
      engine="$candidate"
      break
    fi
  done
fi
if [ ! "$engine" ]; then
  echo "error: docker or podman is needed to build in a container." >&2
  exit 1
fi
if [ "$EUID" -ne 0 ] && [ "$engine" = "podman" ]; then
  echo "error: rootless podman cannot create the device nodes that debootstrap needs. run this with sudo." >&2
  exit 1
fi

image="reshimboot-builder"
build_proxy_args=()
for var in http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY; do
  if [ "${!var}" ]; then
    build_proxy_args+=(--build-arg "$var")
  fi
done
echo ">> building the $image container with $engine"
#the dockerfile is passed on stdin so there is no build context. the repo is
#mounted instead of copied, which avoids sending gigabytes from ./data.
# shellcheck disable=SC2206  # CONTAINER_BUILD_ARGS is split into words on purpose
extra_build_args=($CONTAINER_BUILD_ARGS)
"$engine" build -t "$image" "${build_proxy_args[@]}" "${extra_build_args[@]}" - < Dockerfile

tty_flags=()
if [ -t 0 ] && [ -t 1 ]; then
  tty_flags=(-it)
fi

#proxy settings are passed through if they are set. CONTAINER_BUILD_ARGS and
#CONTAINER_RUN_ARGS can add anything else, like "--network host"
proxy_flags=()
for var in http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY; do
  if [ "${!var}" ]; then
    proxy_flags+=(-e "$var")
  fi
done
# shellcheck disable=SC2206  # CONTAINER_RUN_ARGS is split into words on purpose
extra_args=($CONTAINER_RUN_ARGS)

echo ">> running the build"
#--privileged is needed for the chroot's mounts and for loop devices (luks)
exec "$engine" run --rm "${tty_flags[@]}" --privileged "${proxy_flags[@]}" "${extra_args[@]}" \
  -v "$PWD:/reshimboot" "$image" "$@"
