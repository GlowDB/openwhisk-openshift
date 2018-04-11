#!/bin/bash

#################
# Helper functions for verifying pod creation
#################

deleteTerminatingPods () {
  for pod in $(oc get pod | grep Terminating | cut -f 1 -d ' '); do
    oc delete pod $pod --force --grace-period=0
  done
}

couchdbHealthCheck () {
  # wait for the pod to be created before getting the job name
  sleep 5
  POD_NAME=$(oc get pods -o wide --show-all | grep "couchdb" | awk '{print $1}')

  PASSED=false
  TIMEOUT=0
  until [ $TIMEOUT -eq 60 ]; do
    if [ -n "$(oc logs $POD_NAME | grep "successfully setup and configured CouchDB")" ]; then
      PASSED=true
      break
    fi

    let TIMEOUT=TIMEOUT+1
    sleep 10
  done

  if [ "$PASSED" = false ]; then
    echo "Failed to finish deploying CouchDB"

    REPLICA_SET=$(oc get rs -o wide --show-all | grep "couchdb" | awk '{print $1}')
    oc describe rs $REPLICA_SET
    oc describe pod $POD_NAME
    oc logs $POD_NAME
    exit 1
  fi

  echo "CouchDB is up and running"
}

deploymentHealthCheck () {
  if [ -z "$1" ]; then
    echo "Error, component health check called without a component parameter"
    exit 1
  fi

  deleteTerminatingPods

  PASSED=false
  TIMEOUT=0
  until $PASSED || [ $TIMEOUT -eq 60 ]; do
    DEPLOY_STATUS=$(oc get pods -o wide | grep "$1" | awk '{print $3}')
    if [ "$DEPLOY_STATUS" == "Running" ]; then
      PASSED=true
      break
    fi

    oc get pods -o wide --show-all

    let TIMEOUT=TIMEOUT+1
    sleep 10
  done

  if [ "$PASSED" = false ]; then
    echo "Failed to finish deploying $1"

    oc logs $(oc get pods -o wide | grep "$1" | awk '{print $1}')
    exit 1
  fi

  echo "$1 is up and running"
}

statefulsetHealthCheck () {
  if [ -z "$1" ]; then
    echo "Error, StatefulSet health check called without a parameter"
    exit 1
  fi

  PASSED=false
  TIMEOUT=0
  until $PASSED || [ $TIMEOUT -eq 60 ]; do
    DEPLOY_STATUS=$(oc get pods -o wide | grep "^$1"-0 | awk '{print $3}')
    if [ "$DEPLOY_STATUS" == "Running" ]; then
      PASSED=true
      break
    fi

    oc get pods -o wide --show-all

    let TIMEOUT=TIMEOUT+1
    sleep 10
  done

  if [ "$PASSED" = false ]; then
    echo "Failed to finish deploying $1"

    oc logs $(oc get pods -o wide | grep "$1"-0 | awk '{print $1}')
    exit 1
  fi

  echo "$1-0 is up and running"

}

jobHealthCheck () {
  if [ -z "$1" ]; then
    echo "Error, job health check called without a component parameter"
    exit 1
  fi

  PASSED=false
  TIMEOUT=0
  until $PASSED || [ $TIMEOUT -eq 60 ]; do
    SUCCESSFUL_JOB=$(oc get jobs -o wide | grep "$1" | awk '{print $3}')
    if [ "$SUCCESSFUL_JOB" == "1" ]; then
      PASSED=true
      break
    fi

    oc get jobs -o wide --show-all

    let TIMEOUT=TIMEOUT+1
    sleep 10
  done

  if [ "$PASSED" = false ]; then
    echo "Failed to finish running $1"

    oc logs jobs/$1
    exit 1
  fi

  echo "$1 completed"
}

invokerHealthCheck () {
  PASSED=false
  TIMEOUT=0
  until [ $TIMEOUT -eq 60 ]; do
    if [ -n "$(oc logs controller-0 | grep "invoker status changed to 0 -> Healthy")" ]; then
      PASSED=true
      break
    fi

    let TIMEOUT=TIMEOUT+1
    sleep 5
  done

  if [ "$PASSED" = false ]; then
    echo "Failed to find a healthy Invoker"

    oc logs controller-0
    oc logs invoker-0
    exit 1
  fi

  echo "Invoker online and healthy"
}


#################
# Main body of script -- deploy OpenWhisk
#################

set -x

SCRIPTDIR=$(cd $(dirname "$0") && pwd)
ROOTDIR="$SCRIPTDIR/../../"
cd $ROOTDIR

TEMPLATE_PARAMS="INVOKER_MEMORY_REQUEST=512Mi INVOKER_MEMORY_LIMIT=512Mi INVOKER_JAVA_OPTS=-Xmx256m INVOKER_MAX_CONTAINERS=2 COUCHDB_MEMORY_REQUEST=256Mi COUCHDB_MEMORY_LIMIT=256Mi"
if [ -n "$1" ]; then            # additional template params may be passed to this script
  TEMPLATE_PARAMS="${TEMPLATE_PARAMS} $1"
fi

oc new-project openwhisk
oc process -f ${OPENSHIFT_TEMPLATE:-template.yml} $TEMPLATE_PARAMS | oc create -f -

couchdbHealthCheck

# # setup apigateway
# echo "Deploying apigateway"
# pushd kubernetes/apigateway
#   kubectl apply -f apigateway.yml

#   deploymentHealthCheck "apigateway"
# popd

deploymentHealthCheck "zookeeper"
deploymentHealthCheck "kafka"
statefulsetHealthCheck "controller"
statefulsetHealthCheck "invoker"
deploymentHealthCheck "nginx"
deploymentHealthCheck "alarmprovider"
deploymentHealthCheck "kafka"

# # install routemgmt
# echo "Installing routemgmt"
# pushd kubernetes/routemgmt
#   kubectl apply -f install-routemgmt.yml
#   jobHealthCheck "install-routemgmt"
# popd

jobHealthCheck "install-catalog"

invokerHealthCheck

# configure wsk CLI
AUTH_SECRET=$(oc get secret whisk.auth -o yaml | grep "system:" | awk '{print $2}' | base64 --decode)
wsk property set --auth $AUTH_SECRET --apihost $(oc get route/openwhisk --template={{.spec.host}})

# list packages and actions now installed in /whisk.system
wsk -i list
