#!/usr/bin/env bash
#
# pCloud uploader
#
# Copyright (C) 2019 Espen Andersen <post@espenandersen.no>
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

# Curl location
# If not set, curl will be searched into the $PATH
# CURL_BIN="/usr/bin/curl"

# Internal parameters
BIN_DEPS="sed basename date grep stat dd mkdir"
APP_CREATE_URL="https://docs.pcloud.com/my_apps/"
APP_AUTHORIZE_URL="https://my.pcloud.com/oauth2/authorize"

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

function remove_temp_files {
		FOO="BAR"
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
  if [[ $OAUTH_ACCESS_TOKEN = "" ]]; then
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

	# TODO Get access token from server using CURL request

	echo -ne "CLIENT_ID=$CLIENT_ID\nCLIENT_SECRET=$CLIENT_SECRET\nACCESS_TOKEN=$ACCESS_TOKEN\n" > "$CONFIG_FILE"

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

