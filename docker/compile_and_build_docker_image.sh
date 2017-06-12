#!/bin/bash

# MAINTAINER Matthieu Faure <mfaure@asqatasun.org>

set -o errexit

#############################################
# Variables
#############################################

TIMESTAMP=$(date +%Y-%m-%d) # format 2015-11-23, cf man date

#############################################
# Usage
#############################################
usage () {
    cat <<EOF

$0 launches a sequence that:
- builds Contrast-Finder from sources,
- builds a Docker image
- runs a container based the freshly built image

usage: $0 -s <directory> -d <directory> [OPTIONS]

  -s | --source-dir     <directory> MANDATORY Absolute path to Contrast-Finder sources directory
  -d | --docker-dir     <directory> MANDATORY Path to directory containing the Dockerfile.
                                              Path must be relative to SOURCE_DIR
  -p | --port           <port>      Default value: 8087
  -n | --container-name <name>      Default value: contrast.finder
  -i | --image-name     <name>      Default value: asqatasun/contrast-finder
  -t | --tag-name       <name>      Default value: ${TIMESTAMP}

  -b | --build-only-dir <directory> Build only webapp and <directory> (relative to SOURCE_DIR)
  -w | --build-only-webapp          Build only webapp (relies on previous build)
  -l | --only-localhost             Container available only on localhost
       --use-sudo-docker            Use "sudo docker" instead of "docker"
       --skip-build-test            Skip unit tests on Maven build
       --skip-build                 Skip Maven build (relies on previous build, that must exists)
       --skip-copy                  Skip copying .war (relies on previous .war, that must exist)
       --skip-docker-build          Skip docker build
       --skip-docker-run            Skip docker run

  -h | --help                       Show this help
  -t | --functional-tests           Also execute functional tests. @@@TODO
EOF
    exit 2
}

#############################################
# Manage options and usage
#############################################
TEMP=`getopt -o s:d:p:n:i:t:b:lwht --long source-dir:,docker-dir:,port:,container-name:,image-name:,tag-name:,build-only-dir:,only-localhost,build-only-webapp,help,functional-tests,skip-build-test,skip-build,skip-copy,skip-docker-build,skip-docker-run,use-sudo-docker -- "$@"`

if [[ $? != 0 ]] ; then
    echo "Terminating..." >&2 ;
    exit 1 ;
fi

# Note the quotes around `$TEMP': they are essential!
eval set -- "${TEMP}"

declare SOURCE_DIR
declare DOCKER_DIR
declare HELP=false
declare FTESTS=false
declare SKIP_BUILD=false
declare SKIP_BUILD_TEST=false
declare SKIP_COPY=false
declare SKIP_DOCKER_BUILD=false
declare SKIP_DOCKER_RUN=false
declare USE_SUDO_DOCKER=false
declare ONLY_LOCALHOST=false
declare BUILD_ONLY_WEBAPP=false
declare BUILD_ONLY_DIR=false
declare WEBAPP_DIR="contrast-finder-webapp"
declare CONTAINER_EXPOSED_PORT="8087"
declare CONTAINER_NAME="contrast.finder"
declare IMAGE_NAME="asqatasun/contrast-finder"
declare TAG_NAME=${TIMESTAMP}

while true; do
  case "$1" in
    -s | --source-dir )         SOURCE_DIR="$2"; shift 2 ;;
    -d | --docker-dir )         DOCKER_DIR="$2"; shift 2 ;;
    -p | --port )               CONTAINER_EXPOSED_PORT="$2"; shift 2 ;;
    -n | --container-name )     CONTAINER_NAME="$2"; shift 2 ;;
    -i | --image-name )         IMAGE_NAME="$2"; shift 2 ;;
    -t | --tag-name  )          TAG_NAME="$2"; shift 2 ;;
    -b | --build-only-dir )     BUILD_ONLY_DIR="$2"; shift 2 ;;
    -w | --build-only-webapp )  BUILD_ONLY_WEBAPP=true; shift ;;
    -h | --help )               HELP=true; shift ;;
    -t | --functional-tests )   FTESTS=true; shift ;;
    -l | --only-localhost )     ONLY_LOCALHOST=true; shift ;;

    --skip-build-test )         SKIP_BUILD_TEST=true; shift ;;
    --skip-build )              SKIP_BUILD=true; shift ;;
    --skip-copy )               SKIP_COPY=true; shift ;;
    --skip-docker-build )       SKIP_DOCKER_BUILD=true; shift ;;
    --skip-docker-run )         SKIP_DOCKER_RUN=true; shift ;;
    --use-sudo-docker )         USE_SUDO_DOCKER=true; shift ;;

    * ) break ;;
  esac
done

if [[ -z "$SOURCE_DIR" || -z "$DOCKER_DIR" || "$HELP" == "true" ]]; then
    usage
fi

#############################################
# Functions
#############################################

fail() {
    echo ""
    echo "FAILURE : $*"
    echo ""
    exit -1
}

#############################################
# Variables
#############################################


TGZ_BASENAME="webapp/target/contrast-finder"
TGZ_EXT=".tar.gz"
ADD_IP=''
URL="http://localhost:${CONTAINER_EXPOSED_PORT}/contrast-finder/"
if ${ONLY_LOCALHOST} ; then  
    ADD_IP="127.0.0.1:";
    URL="http://127.0.0.1:${CONTAINER_EXPOSED_PORT}/contrast-finder/"
fi

SUDO=''
if ${USE_SUDO_DOCKER} ; then   SUDO='sudo'; fi


#############################################
# Functions
#############################################

function kill_previous_container() {
    set +e
    RUNNING=$(${SUDO} docker inspect --format="{{ .State.Status }}" ${CONTAINER_NAME} 2>/dev/null)
    set -e

    if [ "${RUNNING}" == "running" ]; then
        ${SUDO} docker stop ${CONTAINER_NAME}
        ${SUDO} docker rm ${CONTAINER_NAME}
    elif [ "${RUNNING}" == "exited" ]; then
        ${SUDO} docker rm ${CONTAINER_NAME}
    fi
}

function do_build() {
    MAVEN_OPTION=''
    if ${SKIP_BUILD_TEST} ; then
        MAVEN_OPTION=' -Dmaven.test.skip=true '; # skip unit tests
    fi


    if [[ -n "$BUILD_ONLY_DIR" && "$BUILD_ONLY_DIR" != "false" ]]  ; then
        if [[ -d "${SOURCE_DIR}/${BUILD_ONLY_DIR}" ]] ; then
            # clean and build $BUILD_ONLY_DIR directory and webapp
            (   cd "${SOURCE_DIR}/${BUILD_ONLY_DIR}"; mvn clean install ${MAVEN_OPTION}; \
                cd "${SOURCE_DIR}/${WEBAPP_DIR}";     mvn clean install ${MAVEN_OPTION}) ||
                   fail "Error at build"
        else
            fail "not valid directory ${SOURCE_DIR}/${BUILD_ONLY_DIR}"
        fi
    elif ${BUILD_ONLY_WEBAPP} ; then
        # clean and build only webapp
        (cd "${SOURCE_DIR}/${WEBAPP_DIR}"; mvn clean install ${MAVEN_OPTION}) ||
            fail "Error at build"
    else
        # clean and build
        (cd "$SOURCE_DIR"; mvn clean install ${MAVEN_OPTION}) ||
            fail "Error at build"
    fi
}

function do_copy_targz() {
    # copy .WAR to docker dir
    cp "${SOURCE_DIR}/${TGZ_BASENAME}"*"${TGZ_EXT}" "${SOURCE_DIR}/${DOCKER_DIR}/" ||
        fail "Error copying ${SOURCE_DIR}/${TGZ_BASENAME}"
}

function do_docker_build() {
    # build Docker container
    (cd "${SOURCE_DIR}/${DOCKER_DIR}" ; \
        ${SUDO} docker build -t ${IMAGE_NAME}:${TAG_NAME} "${SOURCE_DIR}/${DOCKER_DIR}" ) ||
        fail "Error building container"
}

function do_docker_run() {
    kill_previous_container

    set +e
    RESULT=$(curl -o /dev/null --silent --write-out '%{http_code}\n' ${URL})
    set -e
    if [ "${RESULT}" == "000" ]; then
        DOCKER_RUN="${SUDO} docker run -p ${ADD_IP}${CONTAINER_EXPOSED_PORT}:8080 --name ${CONTAINER_NAME} -d ${IMAGE_NAME}:${TAG_NAME}"
        eval ${DOCKER_RUN}
    else 
        fail  "${CONTAINER_EXPOSED_PORT} port is already allocated"
    fi

    # wait a bit to let container start
    # test if URL responds with 200
    time=0
    while ((RESULT!=200))
    do
        set +e
        RESULT=$(curl -o /dev/null --silent --write-out '%{http_code}\n' ${URL})
        set -e
        if [ "${RESULT}" == "200" ]; then
            echo "... it's done ... ${RESULT}"
        else 
            ((time+=1))
            echo "... ${time} ... loading ... "
            sleep 1
        fi
    done
}

function do_functional_testing() {
    # functional testing
    echo "------------------------"
    echo "The functional tests are not yet implemented"
}

#############################################
# Do the actual job
#############################################

if ! ${SKIP_BUILD} ; then            do_build; fi
if ! ${SKIP_COPY} ; then             do_copy_targz; fi
if ! ${SKIP_DOCKER_BUILD} ; then     do_docker_build; fi
if ! ${SKIP_DOCKER_RUN} ; then       do_docker_run; fi
if ${FTESTS} ; then                  do_functional_testing; fi

echo "------------------------"
echo "CMD       ---->   ${DOCKER_RUN}"
echo "Image     ---->   ${IMAGE_NAME}:${TAG_NAME}"
echo "Container ---->   ${CONTAINER_NAME}"
echo "Shell     ---->  ${SUDO} docker exec -ti ${CONTAINER_NAME}  /bin/bash"
echo "Log       ---->  ${SUDO} docker logs -f ${CONTAINER_NAME}"
echo "URL       ---->   ${URL}"

