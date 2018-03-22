#!/bin/bash
set -exu

SCRIPTDIR=$(cd $(dirname "$0") && pwd)
ROOTDIR="$SCRIPTDIR/../../"
cd $ROOTDIR

COMMIT=$(git rev-parse HEAD | cut -c 1-7)
VERSION=${1:-$COMMIT}

# docker login -u "${DOCKER_USER}" -p "${DOCKER_PASSWORD}"

publish() {
  prefix="$1"
  name="$2"
  tag="$3"
  dir="$4"
  image="${prefix}/${name}:${tag}"

  docker build ${dir} --tag ${image}
  if [ "${tag}" != "openshift-latest" ]; then
    docker push ${image}
  fi
}

publish projectodd whisk_couchdb $VERSION docker/couchdb
publish projectodd whisk_catalog $VERSION docker/catalog
publish projectodd whisk_alarms $VERSION docker/alarms

for i in $(ls docker/runtimes/); do
  publish projectodd $i $VERSION docker/runtimes/$i
done
