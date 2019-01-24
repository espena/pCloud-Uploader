#!/usr/bin/env bash
#
# pCloud uploader
#
# Based on Andrea Fabrizi's "Dropbox-Uploader"
# Adapted for pCloud by Espen Andersen - post@espenandersen.no
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#

# Default configuration file
CONFIG_FILE=~/.pcloud_uploader

# Default values
TMP_DIR="/tmp"
EXCLUDE=()
SKIP_EXISTING_FILES=0

# Curl location
# If not set, curl will be searched into the $PATH
# CURL_BIN="/usr/bin/curl"

# Internal parameters
BIN_DEPS="sed basename date grep stat dd mkdir"
APP_CREATE_URL="https://docs.pcloud.com/my_apps/"
APP_AUTHORIZE_URL="https://my.pcloud.com/oauth2/authorize"
API_CHECKSUMFILE_URL="https://api.pcloud.com/checksumfile"
API_CREATEFOLDER_URL="https://api.pcloud.com/createfolder"
API_LISTFOLDER_URL="https://api.pcloud.com/listfolder"
API_OAUTH2_TOKEN_URL="https://api.pcloud.com/oauth2_token"
API_UPLOADFILE_URL="https://api.pcloud.com/uploadfile"

RESPONSE_FILE="$TMP_DIR/pu_resp_$RANDOM"

CURL_PARAMETERS="-L -s"
VERSION=1.0a

umask 077

# Check the shell
if [ -z "$BASH_VERSION" ]; then
    echo -e "Error: This script requires BASH!"
    exit 1
fi

shopt -s nullglob
shopt -s dotglob

# Check temp folder
if [[ ! -d "$TMP_DIR" ]]; then
    echo -e "Error: the temporary folder $TMP_DIR doesn't exists!"
    echo -e "Please edit this script and set the TMP_DIR variable to a valid temporary folder to use."
    exit 1
fi

# Read optional parameters
while getopts ":d" opt; do
  case $opt in
  d)
    DEBUG=1
  ;;
  k)
    CURL_ACCEPT_CERTIFICATES="-k"
  ;;
  esac
done

# Locate curl
if [[ $CURL_BIN == "" ]]; then
    BIN_DEPS="$BIN_DEPS curl"
    CURL_BIN="curl"
fi

# Dependencies check
which $BIN_DEPS > /dev/null
if [[ $? != 0 ]]; then
    for i in $BIN_DEPS; do
        which $i > /dev/null ||
            NOT_FOUND="$i $NOT_FOUND"
    done
    echo -e "Error: Required program could not be found: $NOT_FOUND"
    exit 1
fi

# Check if readlink is installed and supports the -m option
# It's not necessary, so no problem if it's not installed
which readlink > /dev/null
if [[ $? == 0 && $(readlink -m "//test" 2> /dev/null) == "/test" ]]; then
    HAVE_READLINK=1
else
    HAVE_READLINK=0
fi

# Forcing to use the builtin printf, if it's present, because it's better
# otherwise the external printf program will be used
# Note that the external printf command can cause character encoding issues!
builtin printf "" 2> /dev/null
if [[ $? == 0 ]]; then
    PRINTF="builtin printf"
    PRINTF_OPT="-v o"
else
    PRINTF=$(which printf)
    if [[ $? != 0 ]]; then
        echo -e "Error: Required program could not be found: printf"
    fi
    PRINTF_OPT=""
fi

function check_http_response {
  CODE=$?
  # Checking curl exit code
  case $CODE in
    #OK
    0)

    ;;

    #Proxy error
    5)
      echo -ne "\nError: Couldn't resolve proxy. The given proxy host could not be resolved.\n"
      remove_temp_files
      exit 1
    ;;

    #Missing CA certificates
    60|58|77)
      echo -ne "\nError: cURL is not able to performs peer SSL certificate verification.\n"
      echo -ne "Please, install the default ca-certificates bundle.\n"
      echo -ne "To do this in a Debian/Ubuntu based system, try:\n"
      echo -ne "  sudo apt-get install ca-certificates\n\n"
      echo -ne "If the problem persists, try to use the -k option (insecure).\n"
      remove_temp_files
      exit 1
    ;;

    6)
      echo -ne "\nError: Couldn't resolve host.\n"
      remove_temp_files
      exit 1
    ;;

    7)
      echo -ne "\nError: Couldn't connect to host.\n"
      remove_temp_files
      exit 1
    ;;

  esac

  # Checking response file for generic errors
  if grep -q "HTTP/1.1 400" "$RESPONSE_FILE"; then
    ERROR_MSG=$(sed -n -e 's/{"error": "\([^"]*\)"}/\1/p' "$RESPONSE_FILE")

    case $ERROR_MSG in

      *access?attempt?failed?because?this?app?is?not?configured?to?have*)
        echo -e "\nError: The Permission type/Access level configured doesn't match the pCloud App settings!\nPlease run \"$0 unlink\" and try again."
        exit 1
      ;;

    esac
  fi
}

function get_api_result {
  sed -n 's/.*"result": \([0-9]*\).*/\1/p' "$RESPONSE_FILE"
}

function normalize_path {
  # The printf is necessary to correctly decode unicode sequences
  path=$($PRINTF "${1//\/\///}")
  if [[ $HAVE_READLINK == 1 ]]; then
    new_path=$(readlink -m "$path")
    # Adding back the final slash, if present in the source
    if [[ ${path: -1} == "/" && ${#path} -gt 1 ]]; then
      new_path="$new_path/"
    fi
    echo "$new_path"
  else
    echo "$path"
  fi
}

#Create a new directory
#$1 = Remote directory to create
function pcloud_mkdir {

    local DIR_DST=$(normalize_path "$1")

    echo -ne " > Creating Directory \"$DIR_DST\"... "

    $CURL_BIN $CURL_ACCEPT_CERTIFICATES -X GET -L -s --show-error --globoff -i -o "$RESPONSE_FILE" "$API_CREATEFOLDER_URL?access_token=$ACCESS_TOKEN&path=$DIR_DST" 2> /dev/null
    check_http_response
    local RES=$(get_api_result)

    if [[ $RES == 2002 ]]; then
      local TMP_DST="/"
      for PARENT in ${DIR_DST//\// }; do
        TMP_DST="$TMP_DST/$PARENT"
        $CURL_BIN $CURL_ACCEPT_CERTIFICATES -X GET -L -s --show-error --globoff -i -o "$RESPONSE_FILE" "$API_CREATEFOLDER_URL?access_token=$ACCESS_TOKEN&path=$TMP_DST" 2> /dev/null
        check_http_response
        if [[ $(get_api_result) != 0 ]]; then
          exit 1
        fi
      done
    fi

    local RES=$(get_api_result)
    case "$RES" in
      0)
        echo -ne "DONE\n" ;;
      2004)
        echo -ne "ALREADY_EXISTS\n" ;;
      *)
        echo -ne "FAILED\n" ;;
    esac
}

# Query the sha256-pcloud-sum of a remote file
# $1 = Remote file
function pcloud_sha {
  # TODO: Implement proper hashing
  echo "*****"
}

# Query the sha256-pcloud-sum of a local file
# $1 = Local file
function pcloud_sha_local {
  # TODO: Implement proper hashing
  echo "*****"
}

# Check if it's a file or directory
# Returns FILE/DIR/NOT_FOUND/ERR
function pcloud_stat
{
  if [[ $1 == "/" ]]; then
    echo "DIR"
    return
  fi
  local FILE=$(urlencode "$(normalize_path "${1%/}")")
  $CURL_BIN $CURL_ACCEPT_CERTIFICATES -X GET -L -s --show-error --globoff -i -o "$RESPONSE_FILE" "$API_LISTFOLDER_URL?access_token=$ACCESS_TOKEN&path=$FILE" 2> /dev/null
  check_http_response
  local RES=$(get_api_result)
  local TYPE="ERR"
  if [[ $RES == 0 ]]; then
    TYPE="DIR"
  else
    $CURL_BIN $CURL_ACCEPT_CERTIFICATES -X GET -L -s --show-error --globoff -i -o "$RESPONSE_FILE" "$API_CHECKSUMFILE_URL?access_token=$ACCESS_TOKEN&path=$FILE" 2> /dev/null
    check_http_response
    RES=$(get_api_result)
    if [[ $RES == 0 ]]; then
      TYPE="FILE"
    elif [[ $RES == 2009 ]]; then
      TYPE="NOT_FOUND"
    fi
  fi
  echo $TYPE
}

function pcloud_unlink {
  echo -ne "Are you sure you want unlink this script from your pCloud account? [y/n]"
  read -r answer
  if [[ $answer == "y" ]]; then
    rm -fr "$CONFIG_FILE"
    echo -ne "DONE\n"
  fi
}

# Generic upload wrapper around pcloud_upload_file and pcloud_upload_dir functions
# $1 = Local source file/dir
# $2 = Remote destination file/dir
function pcloud_upload {

  local SRC=$(normalize_path "$1")
  local DST=$(normalize_path "$2")

  for j in "${EXCLUDE[@]}"
    # Checking excluded files
    do :
      if [[ $(echo "$SRC" | grep "$j" | wc -l) -gt 0 ]]; then
        echo -ne "Skipping excluded file/dir: "$j
        return
      fi
  done

  # Checking if the file/dir exists
  if [[ ! -e $SRC && ! -d $SRC ]]; then
    echo -ne " > No such file or directory: $SRC\n"
    ERROR_STATUS=1
    return
  fi

  # Checking if the file/dir has read permissions
  if [[ ! -r $SRC ]]; then
    echo -ne " > Error reading file $SRC: permission denied\n"
    ERROR_STATUS=1
    return
  fi

  TYPE=$(pcloud_stat "$DST")

  # If DST is a file, do nothing (default behaviour)
  if [[ $TYPE == "FILE" ]]; then
    DST="$DST"
  # If DST doesn't exist and doesn't end with a /, it will be the destination file name
  elif [[ $TYPE == "NOT_FOUND" && "${DST: -1}" != "/" ]]; then
    DST="$DST"
  # If DST doesn't exist and ends with a /, it will be the destination folder
  elif [[ $TYPE == "NOT_FOUND" && "${DST: -1}" == "/" ]]; then
    local filename=$(basename "$SRC")
    DST="$DST$filename"
  # If DST is a directory, it will be the destination folder
  elif [[ $TYPE == "DIR" ]]; then
    local filename=$(basename "$SRC")
    if [[ "${DST: -1}" != "/" ]]; then
      # Append / if missing
      DST="$DST/$filename"
    else
      DST="$DST$filename"
    fi
  fi

  pcloud_mkdir $(dirname "$DST")

  # The source is a directory
  if [[ -d $SRC ]]; then
    pcloud_upload_dir "$SRC" "$DST"
  # The source is a file
  elif [[ -e $SRC ]]; then
    pcloud_upload_file "$SRC" "$DST"
  # Unsupported object
  else
    echo -ne " > Skipping irregular file \"$SRC\"\n"
  fi

}

# Directory upload
# $1 = Local source dir
# $2 = Remote destination dir
function pcloud_upload_dir
{
  local DIR_SRC=$(normalize_path "$1")
  local DIR_DST=$(normalize_path "$2")

  # Creating remote directory
  pcloud_mkdir "$DIR_DST"

  for file in "$DIR_SRC/"*; do
    pcloud_upload "$file" "$DIR_DST"
  done
}

# $1 = Local source file
# $2 = Remote destination file
function pcloud_upload_file {


  local FILE_SRC=$(normalize_path "$1")
  local FILE_DST=$(normalize_path "$2")

  shopt -s nocasematch

  # Checking not allowed file names
  basefile_dst=$(basename "$FILE_DST")
  if [[ $basefile_dst == "thumbs.db" || \
    $basefile_dst == "desktop.ini" || \
    $basefile_dst == ".ds_store" || \
    $basefile_dst == "icon\r" || \
    $basefile_dst == ".dropbox" || \
    $basefile_dst == ".dropbox.attr" ]]; then

    echo -ne " > Skipping not allowed file name \"$FILE_DST\"\n"
    return

  fi

  shopt -u nocasematch

  # Checking if the file already exists
  TYPE=$(pcloud_stat "$FILE_DST")
  if [[ $TYPE == "FILE" && $SKIP_EXISTING_FILES == 1 ]]; then
      echo -ne " > Skipping already existing file \"$FILE_DST\"\n"
      return
  fi
  # Checking if the file has the correct check sum
  if [[ $TYPE == "FILE" ]]; then
      sha_src=$(pcloud_sha_local "$FILE_SRC")
      sha_dst=$(pcloud_sha "$FILE_DST")
      if [[ $sha_src == $sha_dst && $sha_src != "ERR" ]]; then
          echo -ne "> Skipping file \"$FILE_SRC\", file exists with the same hash\n"
          return
      fi
  fi

  local PATH_DST=$(urlencode $(dirname "$FILE_DST"))
  FILE_DST=$(urlencode $(basename "$FILE_DST"))
  $CURL_BIN $CURL_ACCEPT_CERTIFICATES $CURL_PARAMETERS -X POST -i --globoff -o "$RESPONSE_FILE" --header "Content-Type: application/octet-stream" --data-binary @"$FILE_SRC" "$API_UPLOADFILE_URL?access_token=$ACCESS_TOKEN&path=$PATH_DST&filename=$FILE_DST"
  check_http_response
  local RES=$(get_api_result)
  echo "RESULT: $RES"

}

function remove_temp_files {
  local FOO="BAR"
}

function urlencode {
  # The printf is necessary to correctly decode unicode sequences
  local string=$($PRINTF "${1}")
  local strlen=${#string}
  local encoded=""
  for (( pos=0 ; pos<strlen ; pos++ )); do
    c=${string:$pos:1}
    case "$c" in
      [-_.~a-zA-Z0-9] ) o="${c}" ;;
      * ) $PRINTF $PRINTF_OPT '%%%02x' "'$c"
    esac
    encoded="${encoded}${o}"
  done
  echo "$encoded"
}

function usage
{
  echo -e "\n"
  echo -e "pCloud Uploader v$VERSION\n"
  echo -e "Based on Andrea Fabrizi's \"Dropbox-Uploader\","
  echo -e "adapted for pCloud by Espen Andersen - post@espenandersen.no\n"
  echo -e "Usage: $0 [PARAMETERS] COMMAND..."
  echo -e "\nCommands:"

  echo -e "\t upload   <LOCAL_FILE/DIR ...>  <REMOTE_FILE/DIR>"
# echo -e "\t download <REMOTE_FILE/DIR> [LOCAL_FILE/DIR]"
# echo -e "\t delete   <REMOTE_FILE/DIR>"
# echo -e "\t move     <REMOTE_FILE/DIR> <REMOTE_FILE/DIR>"
# echo -e "\t copy     <REMOTE_FILE/DIR> <REMOTE_FILE/DIR>"
  echo -e "\t mkdir    <REMOTE_DIR>"
# echo -e "\t list     [REMOTE_DIR]"
# echo -e "\t monitor  [REMOTE_DIR] [TIMEOUT]"
# echo -e "\t share    <REMOTE_FILE>"
# echo -e "\t saveurl  <URL> <REMOTE_DIR>"
# echo -e "\t search   <QUERY>"
# echo -e "\t info"
# echo -e "\t space"
# echo -e "\t unlink"

# echo -e "\nOptional parameters:"
# echo -e "\t-f <FILENAME> Load the configuration file from a specific file"
# echo -e "\t-s            Skip already existing files when download/upload. Default: Overwrite"
# echo -e "\t-d            Enable DEBUG mode"
# echo -e "\t-q            Quiet mode. Don't show messages"
# echo -e "\t-h            Show file sizes in human readable format"
# echo -e "\t-p            Show cURL progress meter"
# echo -e "\t-k            Doesn't check for SSL certificates (insecure)"
# echo -e "\t-x            Ignores/excludes directories or files from syncing. -x filename -x directoryname. example: -x .git"

  echo -en "\nFor more info and examples, please see the README file.\n\n"
  remove_temp_files
  exit 1
}

################################################################################
#                                                                              #
#    S E T U P                                                                 #
#                                                                              #
################################################################################

# Check for config file
if [[ -e $CONFIG_FILE ]]; then
  # Load data
  source "$CONFIG_FILE" 2>/dev/null
  # Checking loaded data
  if [[ $ACCESS_TOKEN = "" ]]; then
    echo -ne "Error loading data from $CONFIG_FILE...\n"
    echo -ne "It is recommended to run $0 unlink\n"
    remove_temp_files
    exit 1
  fi
else

  # New setup

  echo -ne "\n This is the first time you run this script, please follow the instructions:\n\n"

  echo -ne " 1) Open the following URL in your Browser, and log in using your account:\n    $APP_CREATE_URL\n\n"
  echo -ne " 2) Click on \"New app\"\n\n"
  echo -ne " 3) Enter the \"App name\" that you prefer (e.g. pCloudUploader$RANDOM$RANDOM$RANDOM)\n\n"
  echo -ne " 4) Now go on with the configuration, choosing the app permissions and access restrictions to your pCloud folder\n\n"

  echo -ne " Now, click on the \"Add new app\" button.\n\n"

  echo -ne " When your new app is successfully created, please click on it under \"My applications\".\n\n"

  echo -ne " Copy and paste the client ID:\n\n"

  echo -ne " # Client ID: "
  read -r CLIENT_ID

  echo -ne " Copy and paste the client secret:\n\n"

  echo -ne " # Client secret: "
  read -r CLIENT_SECRET

  echo -ne " Open the following URL in your browser, log in if necessary and click \"Allow\": $APP_AUTHORIZE_URL?client_id=$CLIENT_ID&response_type=code\n\n"
  echo -ne "   $APP_AUTHORIZE_URL?client_id=$CLIENT_ID&response_type=code\n\n"

  echo -ne " Copy and paste the access code here:\n\n"

  echo -ne " # Access code: "
  read -r ACCESS_CODE

  $CURL_BIN $CURL_ACCEPT_CERTIFICATES $CURL_PARAMETERS -X GET -i --globoff -o "$RESPONSE_FILE"  "$API_OAUTH2_TOKEN_URL?client_id=$CLIENT_ID&client_secret=$CLIENT_SECRET&code=$ACCESS_CODE"
  check_http_response

  ACCESS_TOKEN=$( sed -n 's/.*"access_token":[^"]*"\([^"]*\)".*/\1/p' "$RESPONSE_FILE" )

  echo -ne "CLIENT_ID=\"$CLIENT_ID\"\nCLIENT_SECRET=\"$CLIENT_SECRET\"\nACCESS_TOKEN=\"$ACCESS_TOKEN\"\n" > "$CONFIG_FILE"

  echo -ne "   The configuration has been saved.\n\n"

  remove_temp_files

  exit 0

fi

################################################################################
#                                                                              #
#    S T A R T                                                                 #
#                                                                              #
################################################################################

CMD="${*:$OPTIND:1}"
ARG1="${*:$OPTIND+1:1}"
ARG2="${*:$OPTIND+2:1}"

let argnum=$#-$OPTIND

case $CMD in

  mkdir)

    if [[ $argnum -lt 1 ]]; then
      usage
    fi

    DIR_DST="$ARG1"

    pcloud_mkdir "/$DIR_DST"

  ;;

  upload)

    if [[ $argnum -lt 2 ]]; then
      usage
    fi

    FILE_DST="${*:$#:1}"

    for (( i=OPTIND+1; i<$#; i++ )); do
      FILE_SRC="${*:$i:1}"
      pcloud_upload "$FILE_SRC" "/$FILE_DST"
    done

  ;;

  unlink)
    pcloud_unlink
  ;;

esac
