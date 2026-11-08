#!/bin/bash
# Ventoy build — official Docker CI route first, release-base fallback.
# Run on InstaBox main-1. Logs to /data/home/logs/
set -x
cd /data/home/build
[ -d Ventoy ] || git clone --depth 1 https://github.com/ventoy/Ventoy.git Ventoy
cd Ventoy
# Official route (DOC/BuildVentoyFromSource.txt + INSTALL/docker_ci_build.sh):
#   docker build -t ventoy-build ./INSTALL  (CentOS 7 base, downloads vtoytoolchain)
#   docker run ... /bin/bash docker_ci_build.sh  (or all_in_one.sh)
# CentOS 7 is EOL; mirror/vault + toolchain download failures are expected failure points.
# If the Docker route fails, this script falls back to the official release tarball
# as the base and applies the AI-Rescue customisation (ventoy.json + theme label).
# The fallback MUST be reported as a fallback, not as a successful source build.
docker build -t ventoy-build ./INSTALL > /data/home/logs/ventoy-docker-build.log 2>&1
echo "docker build exit: $?"
