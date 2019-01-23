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

# Curl location
# If not set, curl will be searched into the $PATH
# CURL_BIN="/usr/bin/curl"

# Internal parameters
BIN_DEPS="sed basename date grep stat dd mkdir"
APP_CREATE_URL="https://docs.pcloud.com/my_apps/"
APP_AUTHORIZE_URL="https://my.pcloud.com/oauth2/authorize"
API_CHECKSUMFILE_URL="https://api.pcloud.com/checksumfile"
API_LISTFOLDER_URL="https://api.pcloud.com/listfolder"
API_OAUTH2_TOKEN_URL="https://api.pcloud.com/oauth2_token"

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
      print "\nError: Couldn't resolve proxy. The given proxy host could not be resolved.\n"
      remove_temp_files
      exit 1
    ;;

    #Missing CA certificates
    60|58|77)
      print "\nError: cURL is not able to performs peer SSL certificate verification.\n"
      print "Please, install the default ca-certificates bundle.\n"
      print "To do this in a Debian/Ubuntu based system, try:\n"
      print "  sudo apt-get install ca-certificates\n\n"
      print "If the problem persists, try to use the -k option (insecure).\n"
      remove_temp_files
      exit 1
    ;;

    6)
      print "\nError: Couldn't resolve host.\n"
      remove_temp_files
      exit 1
    ;;

    7)
      print "\nError: Couldn't connect to host.\n"
      remove_temp_files
      exit 1
    ;;

  esac

  # Checking response file for generic errors
  if grep -q "HTTP/1.1 400" "$RESPONSE_FILE"; then
    ERROR_MSG=$(sed -n -e 's/{"error": "\([^"]*\)"}/\1/p' "$RESPONSE_FILE")

    case $ERROR_MSG in

      *access?attempt?failed?because?this?app?is?not?configured?to?have*)
        echo -e "\nError: The Permission type/Access level configured doesn't match the DropBox App settings!\nPlease run \"$0 unlink\" and try again."
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

# Generic upload wrapper around pcloud_upload_file and db_upload_dir functions
# $1 = Local source file/dir
# $2 = Remote destination file/dir
function pcloud_upload {

  local SRC=$(normalize_path "$1")
  local DST=$(normalize_path "$2")

  for j in "${EXCLUDE[@]}"

    # Checking excluded files
    do :
      if [[ $(echo "$SRC" | grep "$j" | wc -l) -gt 0 ]]; then
        print "Skipping excluded file/dir: "$j
        return
      fi
  done

  # Checking if the file/dir exists
  if [[ ! -e $SRC && ! -d $SRC ]]; then
    print " > No such file or directory: $SRC\n"
    ERROR_STATUS=1
    return
  fi

  # Checking if the file/dir has read permissions
  if [[ ! -r $SRC ]]; then
    print " > Error reading file $SRC: permission denied\n"
    ERROR_STATUS=1
    return
  fi

  TYPE=$(pcloud_stat "$DST")

  # If DST it's a file, do nothing, it's the default behaviour
  if [[ $TYPE == "FILE" ]]; then
    DST="$DST"
  # If DST doesn't exists and doesn't ends with a /, it will be the destination file name
  elif [[ $TYPE == "NOT_FOUND" && "${DST: -1}" != "/" ]]; then
    DST="$DST"
  # If DST doesn't exists and ends with a /, it will be the destination folder
  elif [[ $TYPE == "NOT_FOUND" && "${DST: -1}" == "/" ]]; then
    local filename=$(basename "$SRC")
    DST="$DST$filename"
  #If DST it's a directory, it will be the destination folder
  elif [[ $TYPE == "DIR" ]]; then
    local filename=$(basename "$SRC")
    if [[ "${DST: -1}" == "/" ]]; then
      DST="$DST$filename"
    else
      DST="$DST/$filename"
    fi
  fi

  # It's a directory
  if [[ -d $SRC ]]; then
    pcloud_upload_dir "$SRC" "$DST"
  # It's a file
  elif [[ -e $SRC ]]; then
    pcloud_upload_file "$SRC" "$DST"
  # Unsupported object...
  else
    print " > Skipping not regular file \"$SRC\"\n"
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
  db_mkdir "$DIR_DST"

  for file in "$DIR_SRC/"*; do
    db_upload "$file" "$DIR_DST"
  done
}

# Generic upload wrapper around db_chunked_upload_file and db_simple_upload_file
# The final upload function will be choosen based on the file size
# $1 = Local source file
# $2 = Remote destination file
function pcloud_upload_file {
  FOO="bar"
}

function remove_temp_files {
  local FOO="BAR"
}

function urlencode {
  #The printf is necessary to correctly decode unicode sequences
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
# echo -e "\t mkdir    <REMOTE_DIR>"
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

  echo -ne " 1) Open the following URL in your Browser, and log in using your account: $APP_CREATE_URL\n"
  echo -ne " 2) Click on \"New app\"\n"
  echo -ne " 3) Enter the \"App name\" that you prefer (e.g. pCloudUploader$RANDOM$RANDOM$RANDOM)\n"
  echo -ne " 4) Now go on with the configuration, choosing the app permissions and access restrictions to your pCloud folder\n\n"

  echo -ne " Now, click on the \"Add new app\" button.\n\n"

  echo -ne " When your new app is successfully created, please click on it under \"My applications\".\n\n"

  echo -ne " Copy and paste the client ID:\n\n"

  echo -ne " # Client ID: "
  read -r CLIENT_ID

  echo -ne " Copy and paste the client secret:\n\n"

  echo -ne " # Client secret: "
  read -r CLIENT_SECRET

  echo -ne " Open the following URL in your browser. Log in if necessary and click \"Allow\": $APP_AUTHORIZE_URL?client_id=$CLIENT_ID&response_type=code\n\n"

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
