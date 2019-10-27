#!/bin/bash

set -e

function help {
    echo \
"$(command -v gitlab-ci)

    Usage: gitlab-ci [command]

    Commands:
        run [job]   Run
        *           Help"
}

if [ -z "$1" ] || ! [ "$1" = 'run' ]; then
    help
    exit 0
fi

################################################################################
# Check if dependencies are installed
################################################################################

function check_dependecy {
    if ! [ -x $(command -v $1) ]; then
        echo "Error: $1 is not installed."
        exit 1
    fi
}

check_dependecy git
check_dependecy curl
check_dependecy jq
check_dependecy yq
check_dependecy gitlab-runner


################################################################################
# Check if we are in a git repository
################################################################################

if ! [ -d .git ]; then
    echo 'Not in a git repository!'
    exit 1
fi


################################################################################
# Check if there is a .gitlab-ci.yml file
################################################################################

if ! [ -f .gitlab-ci.yml ]; then
    echo 'Missing .gitlab-ci.yml file!'
    exit 1
fi


################################################################################
# Check if the required environment variables have been set
################################################################################

function check_variable {
    if ! [ -n $1 ]; then
        echo "Error: $1 variable is not set."
        exit 1
    fi
}

check_variable GITLAB_CI_TOKEN


################################################################################
# Retrieve CI/CD environment variables from gitlab
################################################################################

SSH_URL_TO_REPO=$(git remote get-url origin)

HTTP_URL_TO_REPO=$(echo $SSH_URL_TO_REPO \
                        | sed 's/:.*//' \
                        | sed 's/git@/https:\/\//')

PROJECT_NAME=$(echo $SSH_URL_TO_REPO \
                    | sed 's/.*://' \
                    | sed 's/.git//' \
                    | sed 's/\//%2F/')

VARIABLES_LINK=$(curl --insecure \
                      -H "Private-Token: ${GITLAB_CI_TOKEN}" \
                      $HTTP_URL_TO_REPO/api/v4/projects/$PROJECT_NAME \
                | jq --raw-output '._links.self + "/variables"')

PROJECT_RAW_VARIABLES=$(curl --insecure \
                         -H "Private-Token: ${GITLAB_CI_TOKEN}" \
                         ${VARIABLES_LINK} \
                   | jq --raw-output)

echo $PROJECT_RAW_VARIABLES | jq 'sort_by(.key) | from_entries'

PROJECT_VARIABLES=$(echo $PROJECT_RAW_VARIABLES \
                   | jq --raw-output 'map("--env " + .key + "=" + .value) 
                                     | join(" ")')

################################################################################
# Extract list of jobs from .gitlab-ci.yml file
################################################################################

JOBS=($(yq r -j .gitlab-ci.yml \
        | jq -r 'with_entries(select(.value | objects)) 
                | with_entries(select(.value.stage | strings)) 
                | keys 
                | @sh' \
        | sed "s/\'//g"))

################################################################################
# If job name specified executes it, otherwise execute all jobs
################################################################################

if [ -z "$2" ]; then
    for JOB in "${JOBS[@]}"
    do
        gitlab-runner exec docker $JOB \
            --docker-volumes /var/run/docker.sock:/var/run/docker.sock \
            --env CI_COMMIT_SHA=$(git rev-parse HEAD) \
            $PROJECT_VARIABLES
    done
else
    if [[ " ${JOBS[@]} " =~ " $2 " ]]; then
        gitlab-runner exec docker $2 \
            --docker-volumes /var/run/docker.sock:/var/run/docker.sock \
            --env CI_COMMIT_SHA=$(git rev-parse HEAD) \
            $PROJECT_VARIABLES
    else
        echo "Job $2 does not exists!"
    fi
fi