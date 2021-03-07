#!/bin/bash
#
# Run CloudQA Test Suite and wait for result

APIKEY=$CLOUDQA_API_KEY
SUITE_ID=$CLOUDQA_SUITE_ID
BROWSER=$CLOUDQA_BROWSER
USER_VARIABLES=$CLOUDQA_VARIABLES
TAG=$CLOUDQA_BUILD_TAG
BASE_URL=$CLOUDQA_BASE_URL
SEQUENTIAL_EXECUTION=$CLOUDQA_SEQUENTIAL_EXECUTION
ENVIRONMENT_NAME=$CLOUDQA_ENVIRONMENT_NAME
API="https://app.cloudqa.io/api/v1"
# API="http://localhost:55777/api/v1"
# API="https://stage.cloudqa.io/api/v1"
MAX_POLL_DURATION=1200
POLL_INTERVAL=10

run_id=""

function show_help {
    echo -e "Usage: Declare required environment variables in .circleci/.config.yml and then run bash \\n$0 . For more information check documentation at https://doc.cloudqa.io/CircleCI.html"
}


function get_variables {
    variables_json_str=""
    if [ -n "$USER_VARIABLES" ]
    then
        variables_json=()
        IFS=',' read -ra variables <<< "$USER_VARIABLES"
        for i in "${variables[@]}"
        do
            IFS='=' read -ra variable <<< "$i"
            variable_json='"'"${variable[0]}"'":"'"${variable[1]}"'"'
            variables_json+=("$variable_json")
        done
        variables_json_str='{ '"$(IFS=,; echo "${variables_json[*]}")"' }'
    fi
    echo "$variables_json_str"
}

parsed_variables=$(get_variables)

function invoke_suite {
  dataJson='
  {
      "Browser": "'"$BROWSER"'", 
      "Variables": '"${parsed_variables:-null}"',
      "Tag": "'"$TAG"'",
      "BaseUrl": "'"$BASE_URL"'",
	  "RunSequentially": "'"$SEQUENTIAL_EXECUTION"'",
	  "EnvironmentName": "'"$ENVIRONMENT_NAME"'"
  }'

  http_response=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -X POST \
  --url "$API/suites/$SUITE_ID/runs" \
  --header "authorization: ApiKey $APIKEY" \
  --header 'content-type: application/json' \
  --data "$dataJson")
}

function get_status {
    run_status=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" \
    --url "$API/suites/$SUITE_ID/runs/$run_id" \
    --header "authorization: ApiKey $APIKEY")
}

function get_run_id {
    if hash jq 2>/dev/null; then
        run_id=$(echo "$http_body" | jq -r '.runId')
    elif hash python 2>/dev/null; then
        run_id=$(echo "$http_body" | python -c 'import json,sys;obj=json.load(sys.stdin);print obj["runId"]')
    fi
}

command -v jq >/dev/null || command -v python >/dev/null || { echo "jq or python not installed.  Aborting."; exit 1; }

if [ ! "$APIKEY" ]
then
    echo "API key is not provided. Please set environment variable CLOUDQA_API_KEY" >&2
    show_help
    exit 1
fi

if [ ! "$SUITE_ID" ]
then
    echo "Suite Id is not provided. Please set environment variable CLOUDQA_SUITE_ID" >&2
    show_help
    exit 1
fi

if [ ! "$BROWSER" ]
then
    echo "Browser not specified. Defaulting to Chrome."
    BROWSER="Chrome"
else
    echo "Browser $BROWSER"
fi

if [ "$BASE_URL" ]
then
    echo "Base URL: $BASE_URL"
else
    echo "Base URL: Default"
fi

if [ "${SEQUENTIAL_EXECUTION,,}" == "false" ]
then
    echo "PARALLEL EXECUTION"
	SEQUENTIAL_EXECUTION="false"
else
	SEQUENTIAL_EXECUTION="true"
fi

if [ ! "$ENVIRONMENT_NAME" ]
then
    echo "Environment Name not specified."
    ENVIRONMENT_NAME=""
else
    echo "Environment Name: $ENVIRONMENT_NAME"
fi

invoke_suite

http_body=$(echo $http_response | sed -e 's/HTTPSTATUS\:.*//g')

http_status=$(echo $http_response | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')

SUCCESS="$(echo "$http_response" | grep 202)"

if [ "$http_status" == "401" ]
then
    echo "Execution failed:" >&2
    echo "An error occurred while authenticating the request. This may be due to an invalid API key."
    echo -e "For usage, refer https://doc.cloudqa.io/CircleCI.html"
    echo "$http_response" >&2
    echo "" >&2
    exit 1
fi

if [ "$http_status" != "202" ]
then
    echo "Execution failed:" >&2
    echo "The server did not accept the request and returned status: "
    echo "$http_response" >&2
    echo "" >&2
    exit 1
fi

get_run_id

echo "Test suite triggered. Received run Id: $run_id"
echo "Checking status of current run every $POLL_INTERVAL seconds"

elapsed=0
while true
do
    if [ $elapsed -gt $MAX_POLL_DURATION ]
    then
        echo "Timed out waiting for the result." >&2
        exit 1
    fi
    get_status

    if [ -n "$(echo "$run_status" | grep "Passed")" ]
    then
     echo "Test suite status: Passed."
        exit 0
    fi

    if [ -n "$(echo "$run_status" | grep "Failed")" ]
    then
        echo "Test suite status: Failed." >&2
        exit 1
    fi

    if [ -n "$(echo "$run_status" | grep "Running")" ]
    then
        echo "Test suite status: Running"
        sleep $POLL_INTERVAL
        elapsed=$((elapsed + POLL_INTERVAL))
    else
        echo "Unknown status received. Received response: $run_status. Aborting. " >&2
        exit 1
    fi
done
