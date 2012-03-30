#!/bin/sh

#######################################################################
# Aeolus library (originally factored out of the Aeolus backup script)
# by Daniel Malament
# see ae_license() for license info
#######################################################################

# TODO:
# prune dated files by number
#
# better handling of long errors?
# i18n?
# pathological cases in getparentdir()?
# squeeze // in getparentdir() output?
# strange test problems in validcreate()?
# actually parse vars on cl, in config file?
# queue sendalert()s for non-fatal messages (e.g., skipping many DB dumps)?
#
# do more to protect against leading - in settings?

#!!! [config settings]
# $ssh_port: SSH port (optional)
# $ssh_keyfile: path to key file (optional)
# $ssh_options: general options (optional)
# $ssh_user: username (optional)
# $ssh_host: hostname
# $ssh_rcommand: remote command (optional, but usually supplied)
# config settings: tun_sshlocalport, tun_sshremoteport, tun_sshport,
#                  tun_sshkeyfile, tun_sshoptions, tun_sshuser, tun_sshhost
#
# $dbms_prefix: DBMS (currently only "mysql")
# $*_user: username (optional*)
# $*_pwfile: path to password file (optional*)
# $*_protocol: protocol (optional*)
# $*_host: hostname (optional*)
# $*_port: port (optional*)
# $*_socketfile: path to socket file (optional*)
# $*_options: client options (optional*)
# $*_dbname: database name (optional*)
# $*_command: SQL command (or equivalent)
#
# * optional arguments may only be optional for some DBMSes; OTOH, not all
#   arguments apply to all DBMSes

# config settings: rsync_mode, rsync_pwfile, rsync_localport, rsync_port,
#                  rsync_sshport, rsync_sshkeyfile, rsync_sshoptions,
#                  rsync_filterfile, rsync_options, rsync_add, rsync_source,
#                  rsync_dest


############################################################################

############
# VARIABLES
############


###################
# useful constants
###################

# a newline character
# see section 8 of http://www.dwheeler.com/essays/filenames-in-shell.html
newline=$(printf "\nX")
newline="${newline%X}"

# a tab character
tab='	'


#####################
# initialize globals
#####################

#
# centralized so it's clear what sourcing the library will create/change,
# as opposed to what's only required if you use particular functions
#

# see setexitval()
exitval="-1"

# see do_exit()
cleanup_on_exit="no"

# see saveclset()
clsetsaved="no"



############
# FUNCTIONS
############


############
# debugging
############

#
# clarify how arguments are being grouped
#
# prints number of arguments, and each argument in 's
#
# utilities: printf
#
clarifyargs () {
  printf "%s:" "$#"
  for arg in ${1+"$@"}; do
    printf " '%s'" "$arg"
  done
  printf "\n"
}

#
# check for the existence of external commands in the PATH
#
# "local" vars: extcmd, cmdlen
# global vars: externalcmds
# utilities: printf, echo
#
checkextcmds () {
  # get column width
  cmdlen=0
  for extcmd in $externalcmds; do
     # if [ "${#extcmd}" -gt "$cmdlen" ]; then
     # slower but more portable; see http://mywiki.wooledge.org/BashFAQ/007
     if [ "$(expr \( "X$extcmd" : ".*" \) - 1)" -gt "$cmdlen" ]; then
      cmdlen="${#extcmd}"
    fi
  done

  echo
  echo "checking for commands in the PATH..."
  echo "(note that missing commands may not matter, depending on the command"
  echo "and the settings used; on the other hand, commands may be present"
  echo "but not support required options)"
  echo
  for extcmd in $externalcmds; do
    if command -v "$extcmd" > /dev/null 2>&1; then
      printf "%-${cmdlen}s %s\n" "$extcmd" "was found"
    else
      printf "%-${cmdlen}s %s\n" "$extcmd" "was NOT found"
    fi
  done
  echo
}


###########################
# shutdown and exit values
###########################

#
# update an exit value for the script
#
# if the value has already been set, don't change it,
# so that we can return the value corresponding to
# the first error encountered
#
# global vars: exitval (initialized to "-1", above)
# utilities: [
#
setexitval () {
  if [ "$exitval" = "-1" ]; then
    exitval="$1"
  fi
}

#
# update exit value (see setexitval()) and exit, possibly doing some cleanup
#
# $1 = exit value (required)
#
# if cleanup_on_exit="yes", calls do_exit_cleanup(), which must be defined
# by the calling script
#
# global vars: cleanup_on_exit (initialized to "no", above), exitval
# user-defined functions: do_exit_cleanup()
# library functions: setexitval()
# utilities: [
#
do_exit () {
  if [ "$cleanup_on_exit" = "yes" ]; then
    do_exit_cleanup
  fi

  setexitval "$1"
  exit "$exitval"
}

#
# print an error to stderr and exit
#
# $1 = message
# $2 = exit value
#
# library functions: do_exit()
# utilities: cat
#
throwerr () {
  cat <<-EOF 1>&2

	$1

	EOF
  do_exit "$2"
}


########################################################################
# logging and alerts: stdout/err, syslog, email, status log, output log
########################################################################

#
# log a message ($1) to the status log
# (depending on $statuslog)
#
# message is preceded by the date and the script's PID
#
# config settings: statuslog
# utilities: printf, date, [
# files: $statuslog
#
logstatlog () {
  if [ "$statuslog" != "" ]; then
    # note: use quotes to preserve spacing, including in the output of date
    printf "%s\n" "$(date) [$$]: $1" >> "$statuslog"
  fi
}

#
# log a message ($1) to stdout and/or the status log
# (depending on $quiet and $statuslog)
#
# config settings: quiet
# library functions: logstatlog()
# utilities: printf, [
#
logprint () {
  # use "$1" to preserve spacing

  if [ "$quiet" = "no" ]; then  # default to yes
    printf "%s\n" "$1"
  fi

  logstatlog "$1"
}

#
# log a message ($1) to stderr and/or the status log
# (depending on $quiet and $statuslog)
#
# config settings: quiet
# library functions: logstatlog()
# utilities: printf, [
#
logprinterr () {
  # use "$1" to preserve spacing

  if [ "$quiet" = "no" ]; then  # default to yes
    printf "%s\n" "$1" 1>&2
  fi

  logstatlog "$1"
}

#
# actually send a syslog message; factored out here so logger
# is only called in one place, for maintainability
#
# note: syslog may turn control characters into octal, including whitespace
# (e.g., newline -> #012)
#
# $1 = message
# $2 = priority (facility.level or numeric)
#      (optional; use "" if not passing priority but passing a tag)
# $3 = tag (optional)
#
# utilities: logger
#
do_syslog () {
  logger -i ${2:+-p "$2"} ${3:+-t "$3"} "$1"
}

#
# log a status message ($1) to syslog, stdout, and/or the status log
# (depending on $usesyslog, $quiet, and $statuslog)
#
# if $2 is "all", only log to syslog if usesyslog="all" (but printing
# and status logging proceed normally)
#
# config settings: usesyslog, syslogstat, syslogtag
# library functions: do_syslog(), logprint()
# utilities: [
#
logstatus () {
  # use "$1" to preserve spacing

  if { [ "$2" != "all" ] && [ "$usesyslog" != "no" ]; } \
     || \
     { [ "$2" = "all" ] && [ "$usesyslog" = "all" ]; }; then
    do_syslog "$1" "$syslogstat" "$syslogtag"
  fi

  logprint "$1"
}

#
# log an alert/error message ($1) to syslog, stdout, and/or the status log
# (depending on $usesyslog, $quiet, and $statuslog)
#
# if $2 is "all", only log to syslog if usesyslog="all" (but printing
# and status logging proceed normally)
#
# config settings: usesyslog, syslogstat, syslogtag
# library functions: do_syslog(), logprint()
# utilities: [
#
logalert () {
  # use "$1" to preserve spacing

  if { [ "$2" != "all" ] && [ "$usesyslog" != "no" ]; } \
     || \
     { [ "$2" = "all" ] && [ "$usesyslog" = "all" ]; }; then
    do_syslog "$1" "$syslogerr" "$syslogtag"
  fi

  logprint "$1"
}

#
# log a status message ($1) to syslog and/or the status log, (depending on
# $usesyslog and $statuslog), but not to stdout, regardless of the setting
# of $quiet
#
# used to avoid duplication when also logging to the output log
#
# if $2 is "all", only log to syslog if usesyslog="all" (but status logging
# proceeds normally)
#
# "local" vars: savequiet
# config settings: quiet
# library functions: logstatus()
#
logstatusquiet () {
  savequiet="$quiet"
  quiet="yes"
  logstatus "$1" "$2"
  quiet="$savequiet"
}

#
# log an alert/error message ($1) to syslog and/or the status log,
# (depending on $usesyslog and $statuslog), but not to stdout, regardless of
# the setting of $quiet
#
# used to avoid duplication when also logging to the output log
#
# if $2 is "all", only log to syslog if usesyslog="all" (but status logging
# proceeds normally)
#
# "local" vars: savequiet
# config settings: quiet
# library functions: logstatus()
#
logalertquiet () {
  savequiet="$quiet"
  quiet="yes"
  logalert "$1" "$2"
  quiet="$savequiet"
}

#
# send an alert email, and log to syslog/stdout/status log that an email
# was sent
#
# * message begins with the contents of $1, followed by the output of
#   sendalert_body(), which must be defined by the calling script
# * if $2 is "log", $1 is also logged before the sent notice
#
# note: even if suppressemail="yes", $1 is still logged
# (if settings permit)
#
# config settings: suppressemail, mailto, subject
# user-defined functions: sendalert_body()
# library functions: logalert()
# utilities: mailx, [
#
sendalert () {
  if [ "$suppressemail" != "yes" ]; then
    mailx -s "$subject" $mailto <<-EOF
	$1
	$(sendalert_body)
	EOF
  fi

  if [ "$2" = "log" ]; then
    logalert "$1"
  fi

  if [ "$suppressemail" != "yes" ]; then
    logalert "alert email sent to $mailto"
  fi
}

#
# start the output log pipe
#
# set up a fifo for logging; this has two benefits:
# 1) we can handle multiple output options in one place
# 2) we can run commands without needing pipelines, so we can get the
#    return values
#
# NOTE: this function also gets the datestring for the output log name, so
# if you need to get other datestrings close to that one, get them right
# *before* calling this function
#
# "local" vars: outputlog_filename, outputlog_datestring
# global vars: logfifo
# config settings: lockfile, outputlog, outputlog_layout, outputlog_sep,
#                  outputlog_date, quiet
# library functions: rotatepruneoutputlogs()
# utilities: date, touch, mkfifo, tee, cat, [
# files: $lockfile/$logfifo, $outputlog, (previous outputlogs)
# FDs: 3
#
startoutputlog () {
  # get the full filename, including datestring if applicable
  outputlog_filename="$outputlog"
  if [ "$outputlog" != "" ] && [ "$outputlog_layout" = "date" ]; then
    if [ "$outputlog_date" != "" ]; then
      outputlog_datestring=$(date "$outputlog_date")
    else
      outputlog_datestring=$(date)
    fi
    outputlog_filename="$outputlog_filename$outputlog_sep$outputlog_datestring"
    touch "$outputlog_filename"  # needed for prunedayslogs()
  fi

  mkfifo "$lockfile/$logfifo"

  # rotate and prune output logs
  # (also tests in case there is no output log, and prints status
  # accordingly)
  rotatepruneoutputlogs

  if [ "$outputlog" != "" ]; then
    # append to the output log and possibly stdout
    # appending is always safe / the right thing to do, because either the
    # file won't exist, or it will have been moved out of the way by the
    # rotation - except in one case:
    # if we're using a date layout, and the script has been run more
    # recently than the datestring allows for, we should append so as not to
    # lose information
    if [ "$quiet" = "no" ]; then  # default to yes
      tee -a "$outputlog_filename" < "$lockfile/$logfifo" &
    else
      cat >> "$outputlog_filename" < "$lockfile/$logfifo" &
    fi
  else  # no output log
    if [ "$quiet" = "no" ]; then
      cat < "$lockfile/$logfifo" &
    else
      cat > /dev/null < "$lockfile/$logfifo" &
    fi
  fi

  # create an fd to write to instead of the fifo,
  # so it won't be closed after every line;
  # see http://mywiki.wooledge.org/BashFAQ/085
  exec 3> "$lockfile/$logfifo"
}

#
# stop the output log pipe
#
# remove the fifo and kill the reader process;
# note that we don't have to worry about doing this if we exit abnormally,
# because exiting will close the fd, and the fifo is in the lockfile dir
#
# global vars: logfifo
# config settings: lockfile
# utilities: rm
# files: $lockfile/$logfifo
# FDs: 3
#
stopoutputlog () {
  exec 3>&-  # close the fd, this should kill the reader
  rm -f "$lockfile/$logfifo"
}

#
# see also rotatepruneoutputlogs()
#


####################################
# file tests and path manipulations
####################################

#
# check if the file in $1 is less than $2 minutes old
#
# $2 must be an unsigned integer (/[0-9]+/)
# if timecomptype="date-d", "awk", or "gawk", $3 must be the path to a
#   tempfile (which will be deleted when the function exits)
#
# the file in $1 must exist; check before calling
#
# this is factored out for simplicity, but it's also a wrapper to choose
# between different non-portable methods; see the config settings section,
# under 'timecomptype', for details
#
# returns 0 (true) / 1 (false) / other (error)
#
# "local" vars: curtime, filetime, timediff, reftime, greprv
# config settings: timecomptype
# library functions: escregex()
# utilities: find, grep, date, expr, echo, touch, [
#
newerthan () {
  case "$timecomptype" in
    find)
      # find returns 0 even if no files are matched
      find "$1" \! -mmin +"$2" | grep "^$(escregex "$1")$" > /dev/null 2>&1
      return
      ;;
    date-r)
      curtime=$(date "+%s")
      filetime=$(date -r "$1" "+%s")
      # expr is more portable than $(())
      timediff=$(expr \( "$curtime" - "$filetime" \) / 60)
      [ "$timediff" -lt "$2" ]
      return
      ;;
    date-d)
      reftime=$(date -d "$2 minutes ago" "+%Y%m%d%H%M.%S")
      ;;  # continue after esac
    awk|gawk)
      reftime=$(echo | "$timecomptype" \
          '{print strftime("%Y%m%d%H%M.%S", systime() - ('"$2"' * 60))}')
      ;;  # continue after esac
  esac

  if [ "$3" != "" ] && touch -t "$reftime" "$3"; then
    # find returns 0 even if no files are matched
    find "$1" -newer "$3" | grep "^$(escregex "$1")$" > /dev/null 2>&1
    greprv=$?
    rm -f "$3"
    return "$greprv"
  else
    return 2
  fi
}

#
# wrapper: are two files identical?
#
# $1, $2: file paths
#
# returns 0 (true) / 1 (false) / 2 (error), so test for success, not failure
#
# config settings: filecomptype
# utilities: cmp, diff
#
filecomp () {
  # don't redirect stderr, so we can see any actual errors
  case "$filecomptype" in
    # make sure it's something safe before calling it
    cmp|diff)
      "$filecomptype" "$1" "$2" > /dev/null
      ;;
  esac
}

#
# print the metadata of a file/dir if it exists, or "(none)"
#
# originally, the goal was to be able to just print timestamps, but it's
# more or less impossible to to that portably, so this just prints the
# output of 'ls -ld'
#
# utilities: ls, echo, [
#
getfilemetadata () {
  # -e isn't portable, and we're really only dealing with files and dirs
  # (or links to them, which [ handles for us)
  if [ -f "$1" ] || [ -d "$1" ]; then
    ls -ld "$1" 2>&1
  else
    echo "(none)"
  fi
}

#
# get the parent directory of a file or dir
#
# this is more portable and more correct than dirname;
# in particular, dirname returns . for any of . ./ .. ../
# which fits the documentation, but doesn't make sense for our purposes
#
# to get the "standard" behavior, make $2 non-null
#
# note: still doesn't always correctly handle paths starting with /
# and containing . or .., e.g., getparentdir /foo/..
#
# "local" vars: parentdir
# utilities: printf, echo, sed, grep, [
#
getparentdir () {
  # remove trailing /'s
  parentdir=$(printf "%s\n" "$1" | sed 's|/*$||')

  # are there no /'s left?
  if printf "%s\n" "$parentdir" | grep -v '/' > /dev/null 2>&1; then
    if [ "$parentdir" = "" ]; then
      echo "/"  # it was /, and / is its own parent
      return
    fi
    if [ "$2" = "" ]; then
      if [ "$parentdir" = "." ]; then
        echo ".."
        return
      fi
      if [ "$parentdir" = ".." ]; then
        echo "../.."
        return
      fi
    fi
    echo "."
    return
  fi
  parentdir=$(printf "%s\n" "$parentdir" | sed 's|/*[^/]*$||')
  if [ "$parentdir" = "" ]; then
    echo "/"
    return
  fi
  printf "%s\n" "$parentdir"
}

# tests for getparentdir:
#getparentdir //                   # /
#getparentdir //foo                # /
#getparentdir //foo//              # /
#getparentdir //foo//bar           # //foo
#getparentdir //foo//bar//         # //foo
#getparentdir //foo//bar//baz      # //foo//bar
#getparentdir //foo//bar//baz//    # //foo//bar
#getparentdir .                    # ..
#getparentdir .//                  # ..
#getparentdir . x                  # .
#getparentdir .// x                # .
#getparentdir .//foo               # .
#getparentdir .//foo//             # .
#getparentdir .//foo//bar          # .//foo
#getparentdir .//foo//bar//        # .//foo
#getparentdir .//foo//bar//baz     # .//foo//bar
#getparentdir .//foo//bar//baz//   # .//foo//bar
#getparentdir ..                   # ../..
#getparentdir ..//                 # ../..
#getparentdir .. x                 # .
#getparentdir ..// x               # .
#getparentdir ..//foo              # ..
#getparentdir ..//foo//            # ..
#getparentdir ..//foo//bar         # ..//foo
#getparentdir ..//foo//bar//       # ..//foo
#getparentdir ..//foo//bar//baz    # ..//foo//bar
#getparentdir ..//foo//bar//baz//  # ..//foo//bar
#getparentdir foo                  # .
#getparentdir foo//                # .
#getparentdir foo//bar             # foo
#getparentdir foo//bar//           # foo
#getparentdir foo//bar//baz        # foo//bar
#getparentdir foo//bar//baz//      # foo//bar
#getparentdir foo//bar//baz// x    # foo//bar
#exit


###################################
# character escapes and delimiters
###################################

#
# escape shell glob metacharacters:
#   * ? [
#
# usually, just enclosing strings in quotes suffices for the shell itself,
# but some commands, such as find, take arguments which are then globbed
#
# usage example:
#   find /path -name "$(escglob "$somevar")"
# note that you MUST use $(), NOT ``; `` does strange things with \ escapes
#
# see also escregex(), escereg(), escsedrepl()
#
# utilities: printf, sed
#
escglob () {
  printf "%s\n" "$1" | sed \
      -e 's/\*/\\*/g' \
      -e 's/\?/\\?/g' \
      -e 's/\[/\\[/g'
}

#
# escape basic regex metacharacters:
#   . * [ ^ $ \
#
# for grep, sed, etc.; use when including non-sanitized data in a regex
# for example:
#   somecommand | grep "$(escregex "$somevar")"
# note that you MUST use $(), NOT ``; `` does strange things with \ escapes
#
# characters which are special only in extended regexes are not escaped:
#   ? + ( ) { |
# however, some versions of grep/sed/etc. will still accept these in basic
# regexes when they are preceded by \;
# in this case, our existing escape of \ will keep these from having a
# regex meaning (e.g., '\[' will become '\\[')
#
# see also escereg(), escglob(), escsedrepl()
#
# utilities: printf, sed
#
escregex () {
  # note: \ must be first
  printf "%s\n" "$1" | sed \
      -e 's/\\/\\\\/g' \
      -e 's/\./\\./g' \
      -e 's/\*/\\*/g' \
      -e 's/\[/\\[/g' \
      -e 's/\^/\\^/g' \
      -e 's/\$/\\$/g'
}

#
# escape basic and extended regex metacharacters:
#   . * [ ^ $ \ ? + ( ) { |
#
# for grep, sed, etc.; use when including non-sanitized data in a regex
# for example:
#   somecommand | grep -E "$(escregex "$somevar")"
# note that you MUST use $(), NOT ``; `` does strange things with \ escapes
#
# portability note: ) needs escaping, but ] and } don't; see, e.g.,
# http://www.gnu.org/savannah-checkouts/gnu/autoconf/manual/autoconf-2.68/html_node/Limitations-of-Usual-Tools.html#Limitations-of-Usual-Tools
# under egrep
#
# see also escregex(), escglob(), escsedrepl()
#
# utilities: printf, sed
#
escereg () {
  # note: \ must be first
  printf "%s\n" "$1" | sed \
      -e 's/\\/\\\\/g' \
      -e 's/\./\\./g' \
      -e 's/\*/\\*/g' \
      -e 's/\[/\\[/g' \
      -e 's/\^/\\^/g' \
      -e 's/\$/\\$/g' \
      -e 's/?/\\?/g' \
      -e 's/+/\\+/g' \
      -e 's/(/\\(/g' \
      -e 's/)/\\)/g' \
      -e 's/{/\\{/g' \
      -e 's/|/\\|/g'
}

#
# escape sed replacement-expression metacharacters:
#   \ &
#
# usage example:
#   somecommand | sed "s/foo/$(escsedrepl "$somevar")/"
# note that you MUST use $(), NOT ``; `` does strange things with \ escapes
#
# see also escregex(), for escaping the search expression, getseddelim(),
# for finding delimiters, and escglob() and escereg()
#
# utilities: printf, sed
#
escsedrepl () {
  # note: \ must be first
  printf "%s\n" "$1" | sed \
      -e 's/\\/\\\\/g' \
      -e 's/&/\\\&/g'
}

#
# find a character that can be used as a sed delimiter for a string
#
# $1 is the string to check; for a substitution, this should be the
# concatenation of both halves, without the 's' or delimiters
#
# prints an empty string if no character can be found (highly unlikely),
# otherwise the delimiter
#
# note: assumes your sed can handle any character as a delimiter
#
# portability note: we can't just escape existing separators because
# escaped separators aren't portable; see
# http://www.gnu.org/savannah-checkouts/gnu/autoconf/manual/autoconf-2.68/html_node/Limitations-of-Usual-Tools.html#Limitations-of-Usual-Tools
# under sed
#
# see also escregex() and escsedrepl(), for escaping sed search and replace
# expressions
#
# "local" vars: seddelim, char
# utilities: printf, tr, [
#
getseddelim () {
  seddelim=""

  # note: some characters are left out because they have special meanings
  # to the shell (e.g., we would have to escape " if we used it as the
  # delimiter)
  for char in '/' '?' '.' ',' '<' '>' ';' ':' '|' '[' ']' '{' '}' \
              '=' '+' '_' '-' '(' ')' '*' '&' '^' '%' '#' '@' '!' '~' \
              A B C D E F G H I J K L M N O P Q R S T U V W X Y Z \
              a b c d e f g h i j k l m n o p q r s t u v w x y z ; do
    # use tr instead of grep so we don't have to worry about metacharacters
    # (we could use escregex(), but that's rather heavyweight for this)
    if [ "$1" = "$(printf "%s\n" "$1" | tr -d "$char")" ]; then
      seddelim="$char"
    fi
  done

  printf "%s" "$seddelim"
}

#
# assemble a complete, escaped, delimited sed substitution command
# (only useful if neither side of the substitution has any metacharacters)
#
# $1: search expression
# $2: replace expression
#
# usage example:
#   somecommand | sed "$(escsedsubst "searchexpr" "replexpr")"
# note that you MUST use $(), NOT ``; `` does strange things with \ escapes
#
# prints an empty string if getseddelim() does, otherwise the command
#
# "local" vars: seddelim, lhs_esc, rhs_esc
# library functions: getseddelim(), escregex(), escsedrepl()
# utilities: echo, printf, [
#
escsedsubst () {
  seddelim=$(getseddelim "$1$2")
  if [ "$seddelim" = "" ]; then
    echo
  else
    lhs_esc=$(escregex "$1")
    rhs_esc=$(escsedrepl "$2")
    printf "%s\n" "s$seddelim$lhs_esc$seddelim$rhs_esc$seddelim"
  fi
}


####################################
# startup and config settings/files
####################################

#
# print a license message to stderr
#
# (this is the license for the library)
#
# utilities: cat
#
ae_license () {
  cat <<EOF 1>&2

Copyright 2011 Daniel Malament.  All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

  1. Redistributions of source code must retain the above copyright
     notice, this list of conditions and the following disclaimer.

  2. Redistributions in binary form must reproduce the above copyright
     notice, this list of conditions and the following disclaimer in the
     documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY AUTHOR AND CONTRIBUTORS "AS IS" AND ANY
EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED.  IN NO EVENT SHALL AUTHOR OR CONTRIBUTORS BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
SUCH DAMAGE.

EOF
}

#
# save setting variables supplied on the command line (even if they're set
# to null)
#
# "local" vars: setting, cmdtemp
# global vars: configsettings, clsetsaved (initialized to "no", above)
# config settings: (*, cl_*)
# utilities: [
#
saveclset () {
  # so we know if anything was saved, when we want to use logclconfig()
  clsetsaved="no"

  for setting in $configsettings; do
    cmdtemp="[ \"\${$setting+X}\" = \"X\" ] &&"
    cmdtemp="$cmdtemp cl_$setting=\"\$$setting\" && clsetsaved=\"yes\""
    eval "$cmdtemp"  # doesn't work if combined into one line
  done
}

#
# restore setting variables supplied on the command line, overriding the
# config file
#
# "local" vars: setting, cmdtemp
# global vars: configsettings
# config settings: (*, cl_*)
# utilities: [
#
restoreclset () {
  for setting in $configsettings; do
    cmdtemp="[ \"\${cl_$setting+X}\" = \"X\" ] &&"
    cmdtemp="$cmdtemp $setting=\"\$cl_$setting\""
    eval "$cmdtemp"  # doesn't work if combined into one line
  done
}

#
# log config file, current working directory, and setting variables supplied
# on the command line
#
# saveclset() must be called before function, to set up $cl_*
#
# "local" vars: setting, cmdtemp
# global vars: configsettings, noconfigfile, configfile, clsetsaved
# config settings: (*, cl_*)
# library functions: logstatus()
# utilities: pwd, [
#
logclconfig () {
  # $(pwd) is more portable than $PWD
  if [ "$noconfigfile" = "yes" ]; then
    logstatus "no config file, cwd: \"$(pwd)\""
  else
    logstatus "using config file: \"$configfile\", cwd: \"$(pwd)\""
  fi

  if [ "$clsetsaved" = "yes" ]; then
    logstatus "settings passed on the command line:"
    for setting in $configsettings; do
      cmdtemp="[ \"\${cl_$setting+X}\" = \"X\" ] &&"
      cmdtemp="$cmdtemp logstatus \"$setting='\$cl_$setting'\""
      eval "$cmdtemp"  # doesn't work if combined into one line
    done
  else
    logstatus "no settings passed on the command line"
  fi
}

#
# print all of the current config settings
#
# will print settings with '""' and "\"\"" sub-quoting correctly,
# but not "''" (prints as '''')
#
# "local" vars: setting, sval
# global vars: configsettings
# config settings: (all)
# utilities: printf
#
printsettings () {
  for setting in $configsettings; do
    # split into two lines for readability
    eval "sval=\"\$$(printf "%s" "$setting")\""
    printf "%s\n" "$setting=\"$sval\""
  done
}

#
# print the current config settings, including config file name, CWD, etc.
#
# see printsettings() about quoting
#
# doesn't print surrounding blank lines; add them if necessary in context
#
# "local" vars: cfgfilestring
# global vars: noconfigfile, configfile
# library functions: printsettings()
# utilities: cat, pwd, [
#
printconfig () {
  if [ "$noconfigfile" = "yes" ]; then
    cfgfilestring="(none)"
  else
    cfgfilestring="$configfile"
  fi

  # $(pwd) is more portable than $PWD
  cat <<-EOF
	-----------------
	Current Settings:
	-----------------

	Config file: $cfgfilestring
	CWD: $(pwd)

	$(printsettings)
	EOF
}

#
# output a "blank" config file
#
# $1 is a string to use as the header of the config file, e.g.:
# "# see CONFIG for details"
#
# returns 1 if the config file already exists, else 0
#
# note: this function is mostly meant to be run from a manual command line
# mode, but for flexibility, it does not call do_exit() itself
#
# "local" vars: setting
# global vars: configfile, noconfigfile, configsettings
# utilities: printf, [
# FDs: 3
#
createblankconfig () {
  if [ "$noconfigfile" = "no" ] && [ "$configfile" != "" ]; then
    if [ -f "$configfile" ]; then
      return 1
    else
      # use a separate FD to make the code cleaner
      exec 3>&1  # save for later
      exec 1>"$configfile"
    fi
  fi

  # header
  printf "\n"
  printf "%s\n" "$1"
  printf "\n"

  # config settings
  for setting in $configsettings; do
    printf "%s\n" "#$setting=\"\""
  done

  if [ "$noconfigfile" = "no" ] && [ "$configfile" != "" ]; then
    exec 1>&3  # put stdout back
  fi

  return 0
}

#
# print a startup error to stderr and exit
#
# $1 = message
#
# global vars: startup_exitval
# library functions: throwerr()
#
throwstartuperr () {
  throwerr "$1" "$startup_exitval"
}

#
# print a command-line option error to stderr and exit
#
# $1 = message
#
# assumes "$scriptname --help" works as expected
#
# global vars: newline, scriptname
# library functions: throwstartuperr()
#
throwusageerr () {
  throwstartuperr "$1${newline}${newline}Run '$scriptname --help' for more information."
}

#
# print a bad-setting error to stderr and exit
#
# $1 = variable name
#
# "local" vars: vname, vval
# config settings: (contents of $1)
# library functions: throwstartuperr()
# utilities: printf
#
throwsettingerr () {
  vname="$1"
  eval "vval=\"\$$(printf "%s" "$vname")\""

  throwstartuperr "Error: invalid setting for $vname (\"$vval\"); exiting."
}

#
# validate a setting that can't be blank
#
# $1 = variable name
#
# "local" vars: vname, vval
# config settings: (contents of $1)
# library functions: throwstartuperr()
# utilities: printf, [
#
validnoblank () {
  vname="$1"
  eval "vval=\"\$$(printf "%s" "$vname")\""

  if [ "$vval" = "" ]; then
    throwstartuperr "Error: $vname is unset or blank; exiting."
  fi
}

#
# validate two settings that can't both be blank
#
# $1 = first variable name
# $2 = second variable name
#
# "local" vars: vname1, vval1, vname2, vval2
# config settings: (contents of $1, contents of $2)
# library functions: throwstartuperr()
# utilities: printf, [
#
validnotbothblank () {
  vname1="$1"
  eval "vval1=\"\$$(printf "%s" "$vname1")\""
  vname2="$2"
  eval "vval2=\"\$$(printf "%s" "$vname2")\""

  if [ "$vval1" = "" ] && [ "$vval2" = "" ]; then
    throwstartuperr "Error: $vname1 and $vname2 cannot both be blank; exiting."
  fi
}

#
# validate a numeric setting (only digits 0-9 allowed, no - or .)
#
# $1 = variable name
# $2 = minimum (optional, use "" if using $3 but not $2)
# $3 = maximum (optional)
#
# "local" vars: vname, vval
# config settings: (contents of $1)
# library functions: throwsettingerr()
# utilities: printf, grep, [
#
validnum () {
  vname="$1"
  eval "vval=\"\$$(printf "%s" "$vname")\""

  # use extra [0-9] to avoid having to use egrep
  if printf "%s\n" "$vval" | grep '^[0-9][0-9]*$' > /dev/null 2>&1; then
    if [ "$2" != "" ] && [ "$vval" -lt "$2" ]; then
      throwsettingerr "$vname"
    fi
    if [ "$3" != "" ] && [ "$vval" -gt "$3" ]; then
      throwsettingerr "$vname"
    fi
  else
    throwsettingerr "$vname"
  fi
}

#
# validate a setting that may not contain a particular character
#
# $1 = variable name
# $2 = character
#
# "local" vars: vname, vval, char
# config settings: (contents of $1)
# library functions: throwstartuperr()
# utilities: printf, tr, [
#
validnochar () {
  vname="$1"
  eval "vval=\"\$$(printf "%s" "$vname")\""
  char="$2"

  # use tr so we don't have to worry about metacharacters
  # (we could use escregex(), but that's rather heavyweight for this)
  if [ "$vval" != "$(printf "%s\n" "$vval" | tr -d "$char")" ]; then
    throwstartuperr "Error: $vname cannot contain '$char' characters; exiting."
  fi
}

#
# validate a directory setting, for directories in which we need to create
# and/or rotate files:
# setting must not be blank, and directory must exist, be a directory or a
# symlink to a one, and have full permissions (r/w/x; r for rotation,
# wx for creating files)
#
# $1 = variable name
#
# "local" vars: vname, vval
# config settings: (contents of $1)
# library functions: validnoblank(), throwstartuperr()
# utilities: printf, [
#
validrwxdir () {
  vname="$1"
  eval "vval=\"\$$(printf "%s" "$vname")\""

  validnoblank "$vname"

  # [ dereferences symlinks for us
  if [ ! -d "$vval" ]; then
    throwstartuperr "Error: $vname is not a directory or a symlink to one; exiting."
  fi
  if [ ! -r "$vval" ]; then
    throwstartuperr "Error: $vname is not readable; exiting."
  fi
  if [ ! -w "$vval" ]; then
    throwstartuperr "Error: $vname is not writable; exiting."
  fi
  if [ ! -x "$vval" ]; then
    throwstartuperr "Error: $vname is not searchable; exiting."
  fi
}

#
# validate a file/dir setting, for files/directories we're going to be
# touching, writing to, creating, and/or rotating (but not reading):
# 1) the setting may not be blank
# 2) if the file/dir exists, then:
#    2a) if $2="file", it must be a file or a symlink to one,
#        and it must be writable
#    2b) if $2="dir", it must be a directory or a symlink to one,
#        and it must be writable and searchable (wx; for creating files)
# 3) regardless, the parent directory must exist, be a directory or a
#    symlink to one, and be writable and searchable (wx); if $3 is not
#    null, it must also be readable (for rotation)
#
# $1 = variable name
# $2 = "file" or "dir"
# $3 = if not null (e.g., "rotate"), parent directory must be readable
#
# note: some tests (e.g., -x) seem to silently succeed in some cases in
# which the file/dir isn't readable, even if they should fail, but I'm
# not going to add extra restrictions just for that
#
# "local" vars: vname, vval, parentdir
# config settings: (contents of $1)
# library functions: validnoblank(), throwstartuperr(), getparentdir()
# utilities: printf, ls, [
#
validcreate () {
  vname="$1"
  eval "vval=\"\$$(printf "%s" "$vname")\""

  # condition 1
  validnoblank "$vname"

  # condition 2
  #
  # note: [ -e ] isn't portable, so try ls, even though it's probably not
  # robust enough to be a general solution...
  if ls "$vval" > /dev/null 2>&1; then
    case "$2" in
      file)
        # [ dereferences symlinks for us
        if [ ! -f "$vval" ]; then
          throwstartuperr "Error: $vname is not a file or a symlink to one; exiting."
        fi
        if [ ! -w "$vval" ]; then
          throwstartuperr "Error: $vname is not writable; exiting."
        fi
        ;;
      dir)
        # [ dereferences symlinks for us
        if [ ! -d "$vval" ]; then
          throwstartuperr "Error: $vname is not a directory or a symlink to one; exiting."
        fi
        if [ ! -w "$vval" ]; then
          throwstartuperr "Error: $vname is not writable; exiting."
        fi
        if [ ! -x "$vval" ]; then
          throwstartuperr "Error: $vname is not searchable; exiting."
        fi
        ;;
      *)
        throwstartuperr "Internal Error: illegal file-type value (\"$2\") in validcreate(); exiting."
        ;;
    esac
  fi

  # condition 3
  parentdir=$(getparentdir "$vval")
  # [ dereferences symlinks for us
  if [ ! -d "$parentdir" ]; then
    # ... or a non-directory, but this is more concise
    throwstartuperr "Error: $vname is in a non-existent directory (\"$parentdir\"); exiting."
  fi
  if [ ! -w "$parentdir" ]; then
    throwstartuperr "Error: $vname is in a non-writable directory; exiting."
  fi
  if [ ! -x "$parentdir" ]; then
    throwstartuperr "Error: $vname is in a non-searchable directory; exiting."
  fi
  if [ "$3" != "" ] && [ ! -r "$parentdir" ]; then
    throwstartuperr "Error: $vname is in a non-readable directory; exiting."
  fi
}

#
# validate a file setting, for files we just need to be able to read:
# setting must not be blank, and file must exist, be a file or a symlink
# to one, and be readable
#
# $1 = variable name ("configfile" treated specially)
#
# "local" vars: vname, vval
# global vars: (contents of $1, if "configfile")
# config settings: (contents of $1, usually)
# library functions: validnoblank(), throwstartuperr()
# utilities: printf, [
#
validreadfile () {
  vname="$1"
  eval "vval=\"\$$(printf "%s" "$vname")\""

  # blank?
  validnoblank "$vname"

  # from here on, we will only be using $vname for printing purposes,
  # so we can doctor it
  if [ "$vname" = "configfile" ]; then
    vname="config file \"$vval\""
  fi

  # not a file or symlink to one?
  # ([ dereferences symlinks for us)
  if [ ! -f "$vval" ]; then
    throwstartuperr "Error: $vname does not exist, or is not a file or a symlink to one; exiting."
  fi

  # not readable?
  if [ ! -r "$vval" ]; then
    throwstartuperr "Error: $vname is not readable; exiting."
  fi
}

#
# validate a file setting, for files we need to be able to read and write,
# but not create or rotate:
# setting must not be blank, and file must exist, be a file or a
# symlink to a file, and be readable and writable
#
# $1 = variable name
#
# "local" vars: vname, vval
# config settings: (contents of $1)
# library functions: validreadfile(), throwstartuperr()
# utilities: printf, [
#
validrwfile () {
  vname="$1"
  eval "vval=\"\$$(printf "%s" "$vname")\""

  validreadfile "$vname"

  # not writable?
  if [ ! -w "$vval" ]; then
    throwstartuperr "Error: $vname is not writable; exiting."
  fi
}

#
# validate a setting that can be one of a list of possiblities
#
# $1 = variable name ("mode" treated specially)
# other args = list of possiblities (can include "")
#
# "local" vars: vname, vval, poss
# global vars: (contents of $1, if "mode")
# config settings: (contents of $1, usually)
# library functions: throwusageerr(), throwsettingerr()
# utilities: printf, [
#
validlist () {
  vname="$1"
  eval "vval=\"\$$(printf "%s" "$vname")\""
  shift

  # implied $@ isn't supported by ksh
  for poss in ${1+"$@"}; do
    if [ "$vval" = "$poss" ]; then
      return
    fi
  done

  if [ "$vname" = "mode" ]; then
    throwusageerr "Error: invalid mode supplied on the command line; exiting."
  else
    throwsettingerr "$vname"
  fi
}

#
# process command-line settings and the config file
#
# the calling script must define applydefaults() and validconf();
# neither needs to return anything
#
# global vars: configfile, noconfigfile, defaultconfigfile
# user-defined functions: applydefaults(), validconf()
# library functions: saveclset(), restoreclset(), validreadfile()
# utilities: printf, grep, [
#
do_config () {
  # save variables set on the command line
  saveclset

  # check and source config file
  if [ "$noconfigfile" = "no" ]; then
    # apply default config file if applicable
    if [ "$configfile" = "" ]; then
      configfile="$defaultconfigfile"
    fi

    validreadfile "configfile"

    # . won't work with no directory (unless ./ is in the PATH);
    # the cwd has to be specified explicitly
    if printf "%s\n" "$configfile" | grep -v '/' > /dev/null 2>&1; then
      . "./$configfile"
    else
      . "$configfile"
    fi
  fi

  # restore variables set on the command line, overriding the config file
  restoreclset

  # apply default settings where applicable
  applydefaults

  # validate the config settings
  validconf
}


##################################
# status checks and modifications
##################################

#
# check if we should actually start running
#
# * has $runevery passed?
# * does the $lockfile already exist?
# * send alerts about it if necessary
# * has the script been disabled?
#
# $1 is a description of the script's purpose, such as "backup"; this is
# used in messages like "backup interval has not expired"
# $2 is the plural of $1, used in messages like "backups have been manually
# disabled"
#
# global vars: no_error_exitval, lockfile_exitval, cleanup_on_exit,
#              silencealerts, disable
# config settings: runevery, startedfile, lockfile, ifrunning, alertfile
# library functions: newerthan(), logstatus(), logalert(), sendalert(),
#                    do_exit()
# utilities: mkdir, rm, touch, [
# files: $startedfile, $lockfile, $alertfile, $lockfile/$silencealerts,
#        $lockfile/$disable
#
checkstatus () {
  if [ "$runevery" != "0" ]; then
    # has it been long enough since the script was last started
    # (sucessfully)?
    #
    # if $startedfile exists and is newer than $runevery, exit
    # (-f instead of -e because it's more portable)
    if [ -f "$startedfile" ] && newerthan "$startedfile" "$runevery"; then
      logstatus "$1 interval has not expired; exiting"
      do_exit "$no_error_exitval"
    else
      logstatus "$1 interval has expired; continuing"
    fi
  else
    logstatus "interval checking has been disabled; continuing"
  fi

  # did the previous run finish?
  #
  # use an atomic command to check and create the lock
  # (could also be ln -s, but we might not be able to set the metadata, and
  # it could cause issues with commands that don't manipulate symlinks
  # directly; plus, now we have a tempdir)
  if mkdir "$lockfile" > /dev/null 2>&1; then
    # got the lock, clear lock-alert status
    if [ -f "$alertfile" ]; then  # -f is more portable than -e
      rm "$alertfile"
      sendalert "lockfile created; cancelling previous alert status" log
    fi
    # set flag to remove the lockfile (etc.) on exit
    cleanup_on_exit="yes"
  else
    # assume mkdir failed because it already existed;
    # but that could be because we manually disabled the script
    if [ -f "$lockfile/$disable" ]; then
      logalert "$2 have been manually disabled; exiting"
    else
      logalert "could not create lockfile (previous $1 still running or failed?); exiting"
    fi
    # don't actually exit yet

    # send the initial alert email (no "log", we already logged it)
    #
    # (-f instead of -e because it's more portable)
    if [ ! -f "$alertfile" ]; then
      touch "$alertfile"
      if [ -f "$lockfile/$disable" ]; then
        sendalert "$2 have been manually disabled; exiting"
      else
        sendalert "could not create lockfile (previous $1 still running or failed?); exiting"
      fi
      do_exit "$lockfile_exitval"
    fi

    # but what about subsequent emails?

    # if ifrunning=0, log it but don't send email
    if [ "$ifrunning" = "0" ]; then
      logalert "ifrunning=0; no email sent"
      do_exit "$lockfile_exitval"
    fi

    # if alerts have been silenced, log it but don't send email
    # (and don't bother checking $ifrunning)
    if [ -f "$lockfile/$silencealerts" ]; then
      logalert "alerts have been silenced; no email sent"
      do_exit "$lockfile_exitval"
    fi

    # if $alertfile is newer than $ifrunning, log it but don't send email
    if newerthan "$alertfile" "$ifrunning"; then
      logalert "alert interval has not expired; no email sent"
      do_exit "$lockfile_exitval"
    fi

    # send an alert email (no "log", we already logged it)
    touch "$alertfile"
    if [ -f "$lockfile/$disable" ]; then
      sendalert "$2 have been manually disabled; exiting"
    else
      sendalert "could not create lockfile (previous $1 still running or failed?); exiting"
    fi
    do_exit "$lockfile_exitval"
  fi  # if mkdir "$lockfile"
}

#
# begin working
#
# log starting messages and timestamp, and touch $startedfile
#
# config settings: startedfile
# library functions: logstatus()
# utilities: touch, printf, date
# files: $startedfile
# FDs: 3
#
do_start () {
  logstatus "starting backup"
  touch "$startedfile"
  printf "%s\n" "backup started $(date)" >&3
}

#
# done working
#
# log finished messages and timestamp
#
# library functions: logstatus()
# utilities: printf, date
# FDs: 3
#
do_finish () {
  logstatus "backup finished"
  printf "%s\n" "backup finished $(date)" >&3
}

#
# note: below functions are meant to be run from manual command line modes,
# not autonomous operation; they only log actual status changes, and they
# exit when finished
#

#
# silence lockfile-exists alerts
#
# note: not named silencealerts() partly because some shells have issues
# with functions having the same names as variables
#
# global vars: no_error_exitval, startup_exitval, silencealerts
# config settings: lockfile, quiet (value not actually used)
# library functions: logclconfig(), logstatus(), do_exit()
# utilities: touch, echo, [
# files: $lockfile, $lockfile/$silencealerts
#
silencelfalerts () {
  if [ ! -d "$lockfile" ]; then  # -e isn't portable
    echo "lockfile directory doesn't exist; nothing to silence"
    do_exit "$startup_exitval"
  fi
  if [ -f "$lockfile/$silencealerts" ]; then  # -e isn't portable
    echo "lockfile alerts were already silenced"
    do_exit "$startup_exitval"
  fi
  # using a file in the lockfile dir means that we automatically
  # get the silencing cleared when the lockfile is removed
  touch "$lockfile/$silencealerts"
  echo "lockfile alerts have been silenced"
  quiet="yes"  # don't print to the terminal again
  logclconfig  # so we know what the status message means
  logstatus "lockfile alerts have been silenced, lockfile=\"$lockfile\""
  do_exit "$no_error_exitval"
}

#
# unsilence lockfile-exists alerts
#
# global vars: no_error_exitval, startup_exitval, silencealerts
# config settings: lockfile, quiet (value not actually used)
# library functions: logclconfig(), logstatus(), do_exit()
# utilities: rm, echo, [
# files: $lockfile/$silencealerts
#
unsilencelfalerts () {
  if [ ! -f "$lockfile/$silencealerts" ]; then  # -e isn't portable
    echo "lockfile alerts were already unsilenced"
    do_exit "$startup_exitval"
  fi
  rm -f "$lockfile/$silencealerts"
  echo "lockfile alerts have been unsilenced"
  quiet="yes"  # don't print to the terminal again
  logclconfig  # so we know what the status message means
  logstatus "lockfile alerts have been unsilenced, lockfile=\"$lockfile\""
  do_exit "$no_error_exitval"
}

#
# disable the script
#
# $1 is the article to use with $2, such as "a" or "an"; this is used in
# messages like "a backup is probably running"
# $2 is a description of the script's purpose, such as "backup"; this is
# used in messages like "after the current backup finishes"
# $3 is the plural of $2, used in messages like "backups have been disabled"
#
# global vars: no_error_exitval, startup_exitval, disable
# config settings: lockfile, quiet (value not actually used)
# library functions: logclconfig(), logstatus(), do_exit()
# utilities: mkdir, touch, printf, [
# files: $lockfile, $lockfile/disable
#
disablescript () {
  if [ -f "$lockfile/$disable" ]; then  # -e isn't portable
    printf "%s\n" "$3 were already disabled"
    do_exit "$startup_exitval"
  fi
  if [ -d "$lockfile" ]; then  # -e isn't portable
    printf "%s\n" "lockfile directory exists; $1 $2 is probably running"
    printf "%s\n" "disable command will take effect after the current $2 finishes"
    printf "\n"
  fi
  mkdir "$lockfile" > /dev/null 2>&1  # ignore already-exists errors
  touch "$lockfile/$disable"
  printf "%s\n" "$3 have been disabled; remember to re-enable them later!"
  quiet="yes"  # don't print to the terminal again
  logclconfig  # so we know what the status message means
  logstatus "$3 have been disabled, lockfile=\"$lockfile\""
  do_exit "$no_error_exitval"
}

#
# (re-)enable the script
#
# $1 is the article to use with $2, such as "a" or "an"; this is used in
# messages like "a backup is probably running"
# $2 is a description of the script's purpose, such as "backup"; this is
# used in messages like "after the current backup finishes"
# $3 is the plural of $2, used in messages like "backups have been disabled"
#
# global vars: no_error_exitval, startup_exitval, disable
# config settings: lockfile, quiet (value not actually used)
# library functions: logclconfig(), logstatus(), do_exit()
# utilities: rm, printf, [
# files: $lockfile/$disable
#
enablescript () {
  if [ ! -f "$lockfile/$disable" ]; then  # -e isn't portable
    printf "%s\n" "$3 were already enabled"
    do_exit "$startup_exitval"
  fi
  rm -f "$lockfile/$disable"
  printf "%s\n" "$3 have been re-enabled"
  printf "%s\n" "if $1 $2 is not currently running, you should now remove the lockfile"
  printf "%s\n" "with the unlock command"
  quiet="yes"  # don't print to the terminal again
  logclconfig  # so we know what the status message means
  logstatus "$3 have been re-enabled, lockfile=\"$lockfile\""
  do_exit "$no_error_exitval"
}

#
# forcibly remove the lockfile directory
#
# $1 is the article to use with $2, such as "a" or "an"; this is used in
# messages like "a backup is probably running"
# $2 is a description of the script's purpose, such as "backup"; this is
# used in messages like "after the current backup finishes"
#
# "local" vars: type_y
# global vars: no_error_exitval, startup_exitval
# config settings: lockfile, quiet (value not actually used)
# library functions: logclconfig(), logstatus(), do_exit()
# utilities: rm, echo, printf, [
# files: $lockfile
#
clearlock () {
  if [ ! -d "$lockfile" ]; then  # -e isn't portable
    echo "lockfile has already been removed"
    do_exit "$startup_exitval"
  fi
  printf "\n"
  printf "%s\n" "WARNING: the lockfile should only be removed if you're sure $1 $2 is not"
  printf "%s\n" "currently running."
  printf "%s\n" "Type 'y' (without the quotes) to continue."
  # it would be nice to have this on the same line as the prompt,
  # but the portability issues aren't worth it for this
  read type_y
  if [ "$type_y" != "y" ]; then
    echo "Exiting."
    do_exit "$no_error_exitval"
  fi
  echo
  rm -rf "$lockfile"
  echo "lockfile has been removed"
  quiet="yes"  # don't print to the terminal again
  logclconfig  # so we know what the status message means
  logstatus "lockfile \"$lockfile\" has been manually removed"
  do_exit "$no_error_exitval"
}


######################################
# file rotation, pruning, and zipping
######################################

#
# rotate numbered files
#
# $1: full path up to the number, not including any trailing separator
# $2: separator before the number (not in $1 because the most recent
#     file won't have a separator or a number)
# $3: suffix after the number, including any leading separator
#     (cannot begin with a number)
#
# filenames can have an optional .gz, .bz, .bz2, or .lz after $3
#
# also works on directories
#
# in the unlikely event that the function can't find a sed delimeter for
# a string, it calls sendalert() and exits with exit value nodelim_exitval
#
# "local" vars: prefix, sep, suffix, filename, filenum, newnum, newname, D
# global vars: nodelim_exitval
# library functions: escregex(), escsedrepl(), getseddelim(), sendalert(),
#                    do_exit()
# utilities: printf, grep, sed, expr, mv, [
#
rotatenumfiles () {
  prefix="$1"
  sep="$2"
  suffix="$3"

  # first pass
  for filename in "$prefix$sep"[0-9]*"$suffix"*; do
    # if nothing is found, the actual glob will be used for $filename
    if [ "$filename" = "$prefix$sep[0-9]*$suffix*" ]; then
      break
    fi

    # check more precisely
    #
    # do some contortions to avoid needing egrep
    if printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")$" > /dev/null 2>&1 \
       && \
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.lz$" > /dev/null 2>&1 \
       && \
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.gz$" > /dev/null 2>&1 \
       && \
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.bz$" > /dev/null 2>&1 \
       && \
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.bz2$" > /dev/null 2>&1; then
      continue
    fi

    # get the file number
    #
    # the regexp could be a bit more concise, but it would be less portable
    D=$(getseddelim "^$(escregex "$prefix$sep")\\([0-9][0-9]*\\)$(escregex "$suffix").*\$\\1")
    if [ "$D" = "" ]; then
      sendalert "can't find a delimiter for string '^$(escregex "$prefix$sep")\\([0-9][0-9]*\\)$(escregex "$suffix").*\$\\1' in function rotatenumfiles(); exiting" log
      do_exit "$nodelim_exitval"
    fi
    filenum=$(printf "%s\n" "$filename" | \
              sed "s$D^$(escregex "$prefix$sep")\\([0-9][0-9]*\\)$(escregex "$suffix").*\$$D\\1$D")

    # create the new filename
    D=$(getseddelim "^\\($(escregex "$prefix$sep")\\)[0-9][0-9]*\\1$(escsedrepl "$newnum")")
    if [ "$D" = "" ]; then
      sendalert "can't find a delimiter for string '^\\($(escregex "$prefix$sep")\\)[0-9][0-9]*\\1$(escsedrepl "$newnum")' in function rotatenumfiles(); exiting" log
      do_exit "$nodelim_exitval"
    fi
    # expr is more portable than $(())
    newnum=$(expr "$filenum" + 1)  # pulled out for readability (ha)
    newname=$(printf "%s\n" "$filename" | \
              sed "s$D^\\($(escregex "$prefix$sep")\\)[0-9][0-9]*$D\\1$(escsedrepl "$newnum")$D")

    # move the file
    #
    # if we renumber the files without going in descending order,
    # we'll overwrite some, but sorting on the $filenum is tricky;
    # instead, add .new, then rename all of them
    mv "$filename" "$newname.new"
  done  # first pass

  # remove .new extensions
  for filename in "$prefix$sep"[0-9]*"$suffix"*".new"; do
    # if nothing is found, the actual glob will be used for $filename
    if [ "$filename" = "$prefix$sep[0-9]*$suffix*.new" ]; then
      break
    fi

    # check more precisely and move the file
    #
    # do some contortions to avoid needing egrep
    if printf "%s\n" "$filename" | grep "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.new$" > /dev/null 2>&1 \
       || \
       printf "%s\n" "$filename" | grep "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.lz\.new$" > /dev/null 2>&1 \
       || \
       printf "%s\n" "$filename" | grep "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.gz\.new$" > /dev/null 2>&1 \
       || \
       printf "%s\n" "$filename" | grep "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.bz\.new$" > /dev/null 2>&1 \
       || \
       printf "%s\n" "$filename" | grep "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.bz2\.new$" > /dev/null 2>&1; then
      mv "$filename" "$(printf "%s\n" "$filename" | sed 's|\.new$||')"
    else
      continue
    fi
  done

  # handle the most recent file
  for filename in "$prefix$suffix"*; do
    # if nothing is found, the actual glob will be used for $filename
    if [ "$filename" = "$prefix$suffix*" ]; then
      break
    fi

    # check more precisely
    #
    # do some contortions to avoid needing egrep
    if printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$suffix")$" > /dev/null 2>&1 \
       && \
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$suffix")\.lz$" > /dev/null 2>&1 \
       && \
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$suffix")\.gz$" > /dev/null 2>&1 \
       && \
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$suffix")\.bz$" > /dev/null 2>&1 \
       && \
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$suffix")\.bz2$" > /dev/null 2>&1; then
      continue
    fi

    # move the file
    D=$(getseddelim "^$(escregex "$prefix$suffix")$(escsedrepl "$prefix${sep}1$suffix")")
    if [ "$D" = "" ]; then
      sendalert "can't find a delimiter for string '^$(escregex "$prefix$suffix")$(escsedrepl "$prefix${sep}1$suffix")' in function rotatenumfiles(); exiting" log
      do_exit "$nodelim_exitval"
    fi
    mv "$filename" "$(printf "%s\n" "$filename" | \
                      sed "s$D^$(escregex "$prefix$suffix")$D$(escsedrepl "$prefix${sep}1$suffix")$D")"
  done
}

#
# prune numbered files by number and date
#
# $1: full path up to the number, not including any trailing separator
# $2: separator before the number
# $3: suffix after the number, including any leading separator
#     (cannot begin with a number)
#
# $4: number of files, 0=unlimited
# $5: days worth of files, 0=unlimited
#
# filenames can have an optional .gz, .bz, .bz2, or .lz after $3
#
# also works on directories
#
# "local" vars: prefix, sep, suffix, numf, daysf, filename, filenum, D
# global vars: nodelim_exitval
# library functions: escregex(), getseddelim(), sendalert(), do_exit()
# utilities: printf, grep, sed, rm, find, [
#
prunenumfiles () {
  prefix="$1"
  sep="$2"
  suffix="$3"
  numf="$4"
  daysf="$5"

  # anything to do?
  if [ "$numf" = "0" ] && [ "$daysf" = "0" ]; then
    return
  fi

  for filename in "$prefix$sep"[0-9]*"$suffix"*; do
    # if nothing is found, the actual glob will be used for $filename
    if [ "$filename" = "$prefix$sep[0-9]*$suffix*" ]; then
      break
    fi

    # check more precisely
    #
    # do some contortions to avoid needing egrep
    if printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")$" > /dev/null 2>&1 \
       && \
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.lz$" > /dev/null 2>&1 \
       && \
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.gz$" > /dev/null 2>&1 \
       && \
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.bz$" > /dev/null 2>&1 \
       && \
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.bz2$" > /dev/null 2>&1; then
      continue
    fi

    # get the file number
    #
    # the regexp could be a bit more concise, but it would be less portable
    D=$(getseddelim "^$(escregex "$prefix$sep")\\([0-9][0-9]*\\)$(escregex "$suffix").*\$\\1")
    if [ "$D" = "" ]; then
      sendalert "can't find a delimiter for string '^$(escregex "$prefix$sep")\\([0-9][0-9]*\\)$(escregex "$suffix").*\$\\1' in function prunenumfiles(); exiting" log
      do_exit "$nodelim_exitval"
    fi
    filenum=$(printf "%s\n" "$filename" | \
              sed "s$D^$(escregex "$prefix$sep")\\([0-9][0-9]*\\)$(escregex "$suffix").*\$$D\\1$D")

    # check number and delete
    if [ "$numf" != "0" ] && [ "$filenum" -ge "$numf" ]; then
      # -r for dirs
      rm -rf "$filename"
      continue
    fi

    # delete by date
    if [ "$daysf" != "0" ]; then
      # -r for dirs
      find "$filename" -mtime +"$daysf" -exec rm -rf {} \;
    fi
  done
}

#
# prune dated files by date
#
# _should_ also prune by number, but it's practically impossible to do
# it properly in pure shell
#
# $1: full path up to the date, not including any trailing separator
# $2: separator before the date
# $3: suffix after the date, including any leading separator
#
# $4: days worth of files, 0=unlimited
#
# filenames can have an optional .gz, .bz, .bz2, or .lz after $3
#
# also works on directories
#
# note: "current" file must exist before calling this function, so that
# it can be counted
#
# also, because we can't make any assumptions about the format of the date
# string, this function can be over-broad in the files it looks at;
# make sure there are no files that match $prefix$sep*$suffix* except for
# the desired ones
#
# "local" vars: prefix, sep, suffix, daysf, filename
# library functions: escregex()
# utilities: printf, grep, find, rm, [
#
prunedatefiles () {
  prefix="$1"
  sep="$2"
  suffix="$3"
  daysf="$4"

  # prune by date
  if [ "$daysf" != "0" ]; then
    for filename in "$prefix$sep"*"$suffix"*; do
      # if nothing is found, the actual glob will be used for $filename
      if [ "$filename" = "$prefix$sep*$suffix*" ]; then
        break
      fi

      # check more precisely
      #
      # do some contortions to avoid needing egrep
      if printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep").*$(escregex "$suffix")$" > /dev/null 2>&1 \
         && \
         printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep").*$(escregex "$suffix")\.lz$" > /dev/null 2>&1 \
         && \
         printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep").*$(escregex "$suffix")\.gz$" > /dev/null 2>&1 \
         && \
         printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep").*$(escregex "$suffix")\.bz$" > /dev/null 2>&1 \
         && \
         printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep").*$(escregex "$suffix")\.bz2$" > /dev/null 2>&1; then
        continue
      fi

      # delete
      #
      # -r for dirs
      find "$filename" -mtime +"$daysf" -exec rm -rf {} \;
    done
  fi
}

#
# wrapper: prune numbered or dated files by number and date
#
# dated files are only pruned by date; _should_ also prune by number,
# but it's practically impossible to do it properly in pure shell
#
# $1: layout type
#
# $2: full path up to the number/date, not including any trailing separator
# $3: separator before the number/date
# $4: suffix after the number/date, including any leading separator
#     (cannot begin with a number if using a numbered layout)
#
# $5: number of files, 0=unlimited
# $6: days worth of files, 0=unlimited
#
# filenames can have an optional .gz, .bz, .bz2, or .lz after $4
#
# also works on directories
#
# library functions: prunenumfiles(), prunedatefiles()
#
prunefiles () {
  case "$1" in
    # currently, the function is not actually called for "append",
    # but put it here for future use / FTR
    single|singledir|append)
      :  # nothing to do
      ;;
    number|numberdir)
      prunenumfiles "$2" "$3" "$4" "$5" "$6"
      ;;
    date|datedir)
      prunedatefiles "$2" "$3" "$4" "$6"
      ;;
  esac
}

#
# rotate and prune output logs
#
# filenames can have an optional trailing .gz, .bz, .bz2, or .lz
#
# config settings: outputlog, outputlog_layout, outputlog_sep, numlogs,
#                  dayslogs
# library functions: logstatus(), rotatenumfiles(), prunefiles()
# utilities: [
# files: $outputlog, (previous outputlogs)
#
rotatepruneoutputlogs () {
  if [ "$outputlog" = "" ]; then
    logstatus "output logging is off; not rotating logs"
    return
  fi

  if [ "$outputlog_layout" = "append" ]; then
    logstatus "output logs are being appended to a single file; not rotating logs"
    return
  fi

  logstatus "rotating logs"

  # rotate
  if [ "$outputlog_layout" = "number" ]; then
    rotatenumfiles "$outputlog" "$outputlog_sep" ""
  fi

  # prune
  prunefiles "$outputlog_layout" "$outputlog" "$outputlog_sep" "" \
             "$numlogs" "$dayslogs"
}

#
# remove a file, including zipped versions of it
#
# $1 = file to remove
# $2 = type of zip to remove (same options as *_zipmode)
#
# utilities: rm
#
removefilezip () {
  rm -f "$1"
  case "$2" in
    none)
      :  # nothing else to remove
      ;;
    gzip|pigz)
      rm -f "$1.gz"
      ;;
    bzip2)
      rm -f "$1.bz"
      rm -f "$1.bz2"
      ;;
    lzip)
      rm -f "$1.lz"
      ;;
  esac
}


################
# SSH functions
################

#
# run a remote ssh command
#
# config settings: ssh_port, ssh_keyfile, ssh_options, ssh_user, ssh_host,
#                  ssh_rcommand
# utilities: ssh
# files: $ssh_keyfile
#
sshrcmdcmd () {
  # note no " on ssh_options
  ssh \
    ${ssh_port:+-p "$ssh_port"} \
    ${ssh_keyfile:+-i "$ssh_keyfile"} \
    ${ssh_options:+ $ssh_options} \
    ${ssh_user:+-l "$ssh_user"} \
    "$ssh_host" \
    ${ssh_rcommand:+ "$ssh_rcommand"}
}

#
# run an ssh tunnel command
#
# config settings: tun_sshlocalport, tun_sshremoteport, tun_sshport,
#                  tun_sshkeyfile, tun_sshoptions, tun_sshuser, tun_sshhost
# utilities: ssh
# files: $ssh_keyfile
#
sshtunnelcmd () {
  # note no " on tun_sshoptions
  ssh \
    -L "$ssh_localport:localhost:$ssh_remoteport" -N \
    ${tun_sshport:+-p "$tun_sshport"} \
    ${tun_sshkeyfile:+-i "$tun_sshkeyfile"} \
    ${tun_sshoptions:+ $tun_sshoptions} \
    ${tun_sshuser:+-l "$tun_sshuser"} \
    "$tun_sshhost"
}

#
# open an SSH tunnel
#
# $1 is the name of a variable to store the ssh PID in, to differentiate
# between multiple tunnels; if unset or null, it defaults to "sshpid"
#
# returns 0 on success
# on error, calls sendalert(), then acts according to the value of
# $on_ssherr:
#   "exit": exits with exitval $sshtunnel_exitval (*)
#   "phase": returns 1 ("skip to the next phase of the script")
#   unset or null: defaults to "exit"
# *if $sshtunnel_exitval is unset or null, "1" is used as the default
#
# FD 3 gets a start message and the actual output (stdout and stderr) of
# ssh
#
# "local" vars: waited, sshexit, sshpid_var, sshpid_l, on_err_l, exitval_l
# global vars: (contents of $1, or sshpid), tun_prefix,
#              sshtunnel_exitval (optional)
# config settings: tun_sshlocalport, tun_sshtimeout, on_ssherr (optional)
# library functions: sshtunnelcmd(), logstatus(), logstatusquiet(),
#                    sendalert(), do_exit()
# utilities: nc, printf, sleep, kill, expr, [
# FDs: 3
#
opensshtunnel () {
  # apply some defaults
  sshpid_var="sshpid"
  [ "$1" != "" ] && sshpid_var="$1"
  on_err_l="exit"
  [ "$on_ssherr" != "" ] && on_err_l="$on_ssherr"
  exitval_l=1
  [ "$sshtunnel_exitval" != "" ] && exitval_l="$sshtunnel_exitval"

  # log that we're running the command
  logstatusquiet "running SSH tunnel command for $tun_prefix"
  printf "%s\n" "running SSH tunnel command for $tun_prefix" >&3

  # run the command and get the PID
  sshtunnelcmd >&3 2>&1 &
  sshpid_l="$!"
  eval "$(printf "%s" "$sshpid_var")=\"$sshpid_l\""  # set the global

  # make sure it's actually working;
  # see http://mywiki.wooledge.org/ProcessManagement#Starting_a_.22daemon.22_and_checking_whether_it_started_successfully
  waited="0"
  while sleep 1; do
    nc -z localhost "$tun_sshlocalport" && break
    if kill -0 "$sshpid_l"; then
      # expr is more portable than $(())
      waited=$(expr "$waited" + 1)
      if [ "$waited" -ge "$tun_sshtimeout" ]; then
        sendalert "could not establish SSH tunnel for $tun_prefix (timed out); exiting" log
        kill "$sshpid_l"
        wait "$sshpid_l"
        case "$on_err_l" in
          exit)
            do_exit "$exitval_l"
            ;;
          phase)
            return 1  # skip to the next phase
            ;;
        esac
      fi
    else
      wait "$sshpid_l"
      sshexit="$?"
      sendalert "could not establish SSH tunnel for $tun_prefix (error code $sshexit); exiting" log
      case "$on_err_l" in
        exit)
          do_exit "$exitval_l"
          ;;
        phase)
          return 1  # skip to the next phase
          ;;
      esac
    fi
  done

  logstatus "SSH tunnel for $tun_prefix established"

  return 0
}

#
# close an SSH tunnel
#
# $1 is the name of a variable that contains the ssh PID, to differentiate
# between multiple tunnels; if unset or null, it defaults to "sshpid"
#
# local vars: sshpid_var, sshpid_l
# global vars: (contents of $1, or sshpid), tun_prefix
# library functions: logstatus()
# utilities: printf, kill, [
#
closesshtunnel () {
  # apply default
  sshpid_var="sshpid"
  [ "$1" != "" ] && sshpid_var="$1"

  eval "sshpid_l=\"\$$(printf "%s" "$sshpid_var")\""

  kill "$sshpid_l"
  wait "$sshpid_l"

  eval "$(printf "%s" "$sshpid_var")=\"\""  # so we know it's been closed

  logstatus "SSH tunnel for $tun_prefix closed"
}


#####################
# database functions
#####################

#
# run a database command
#
# (in the notes below, [dbms] = the value of $dbms_prefix)
# global vars: dbms_prefix
# config settings: [dbms]_user, [dbms]_pwfile, [dbms]_protocol, [dbms]_host,
#                  [dbms]_port, [dbms]_socketfile, [dbms]_options,
#                  [dbms]_dbname, [dbms]_command
# utilities: mysql
# files: $[dbms]_pwfile, $[dbms]_socketfile
#
dbcmd () {
  case "$dbms_prefix" in
    mysql)
      # --defaults-extra-file must be the first option if present
      # note no " on mysql_options
      mysql \
        ${mysql_pwfile:+"--defaults-extra-file=$mysql_pwfile"} \
        ${mysql_user:+-u "$mysql_user"} \
        ${mysql_protocol:+"--protocol=$mysql_protocol"} \
        ${mysql_host:+-h "$mysql_host"} \
        ${mysql_port:+-P "$mysql_port"} \
        ${mysql_socketfile:+-S "$mysql_socketfile"} \
        ${mysql_options:+$mysql_options} \
        ${mysql_dbname:+"$mysql_dbname"} \
        ${mysql_command:+-e "$mysql_command"}
      ;;
  esac
}

#
# run a get-database-list command
#
# (may not be possible/straightforward for all DBMSes)
#
# for MySQL, '-BN' is already included in the options
#
# (in the notes below, [dbms] = the value of $dbms_prefix)
# global vars: dbms_prefix
# config settings: [dbms]_user, [dbms]_pwfile, [dbms]_protocol, [dbms]_host,
#                  [dbms]_port, [dbms]_socketfile, [dbms]_options
# utilities: mysql
# files: $[dbms]_pwfile, $[dbms]_socketfile
#
dblistcmd () {
  case "$dbms_prefix" in
    mysql)
      # --defaults-extra-file must be the first option if present
      # note no " on mysql_options
      mysql \
        ${mysql_pwfile:+"--defaults-extra-file=$mysql_pwfile"} \
        ${mysql_user:+-u "$mysql_user"} \
        ${mysql_protocol:+"--protocol=$mysql_protocol"} \
        ${mysql_host:+-h "$mysql_host"} \
        ${mysql_port:+-P "$mysql_port"} \
        ${mysql_socketfile:+-S "$mysql_socketfile"} \
        ${mysql_options:+$mysql_options} \
        -BN -e "SHOW DATABASES;"
      ;;
  esac
}

#
# convert DB name escape sequences to the real characters
# used, e.g., on the output of dblistcmd()
#
# $1 = DB name to un-escape
#
# sequences to un-escape:
#   MySQL:
#     newline -> \n
#     tab -> \t
#     \ -> \\
#
# global vars: dbms_prefix, tab
# utilities: printf, sed
#
dbunescape () {
  case "$dbms_prefix" in
    mysql)
      # note: \\ must be last; \t isn't portable in sed
      printf "%s\n" "$1" | \
        sed \
          -e 's/^\\n/\n/' -e 's/\([^\]\)\\n/\1\n/g' \
          -e "s/^\\\\t/$tab/" -e "s/\\([^\\]\)\\\\t/\\1$tab/g" \
          -e 's/\\\\/\\/g'
      ;;
  esac
}


##################
# rsync functions
##################

#
# run an rsync command
#
# config settings: rsync_mode, rsync_pwfile, rsync_localport, rsync_port,
#                  rsync_sshport, rsync_sshkeyfile, rsync_sshoptions,
#                  rsync_filterfile, rsync_options, rsync_add, rsync_source,
#                  rsync_dest
# utilities: rsync, (ssh)
# files: $rsync_sshkeyfile, $rsync_pwfile, $rsync_filterfile
#
rsynccmd () {
  case "$rsync_mode" in
    tunnel)
      # note no " on rsync_options, rsync_add, rsync_source
      rsync \
        ${rsync_pwfile:+"--password-file=$rsync_pwfile"} \
        "--port=$rsync_localport" \
        ${rsync_filterfile:+-f "merge $rsync_filterfile"} \
        ${rsync_options:+$rsync_options} \
        ${rsync_add:+$rsync_add} \
        $rsync_source \
        "$rsync_dest"
      ;;
    direct)
      # note no " on rsync_options, rsync_add, rsync_source
      rsync \
        ${rsync_pwfile:+"--password-file=$rsync_pwfile"} \
        ${rsync_port:+"--port=$rsync_port"} \
        ${rsync_filterfile:+-f "merge $rsync_filterfile"} \
        ${rsync_options:+$rsync_options} \
        ${rsync_add:+$rsync_add} \
        $rsync_source \
        "$rsync_dest"
      ;;
    nodaemon)
      # note no " on rsync_sshoptions, rsync_options, rsync_add,
      # rsync_source
      rsync \
        -e "ssh
            ${rsync_sshport:+-p "$rsync_sshport"} \
            ${rsync_sshkeyfile:+-i "$rsync_sshkeyfile"} \
            ${rsync_sshoptions:+$rsync_sshoptions}" \
        ${rsync_filterfile:+-f "merge $rsync_filterfile"} \
        ${rsync_options:+$rsync_options} \
        ${rsync_add:+$rsync_add} \
        $rsync_source \
        "$rsync_dest"
      ;;
    local)
      # note no " on rsync_options, rsync_add, rsync_source
      rsync \
        ${rsync_filterfile:+-f "merge $rsync_filterfile"} \
        ${rsync_options:+$rsync_options} \
        ${rsync_add:+$rsync_add} \
        $rsync_source \
      ;;
  esac
}
