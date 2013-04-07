#!/bin/sh

case "$1" in
  system)
    cp aeolus /usr/local/bin/
    chmod 755 /usr/local/bin/aeolus
    chown 0:0 /usr/local/bin/aeolus
    mkdir -p /etc/aeolus  # don't complain if it exists
    chmod 755 /etc/aeolus
    chown 0:0 /etc/aeolus
    cp CONFIG.SAMPLE USAGE /etc/aeolus/
    chmod 644 /etc/aeolus/CONFIG.SAMPLE /etc/aeolus/USAGE
    chown 0:0 /etc/aeolus/CONFIG.SAMPLE /etc/aeolus/USAGE
    ;;
  user)
    mkdir -p ~/bin  # don't complain if it exists
    chmod u=rwx ~/bin
    cp aeolus ~/bin/
    chmod u=rwx ~/bin/aeolus
    mkdir -p ~/.aeolus  # don't complain if it exists
    chmod u=rwx ~/.aeolus
    cp CONFIG.SAMPLE USAGE ~/.aeolus/
    chmod u=rw ~/.aeolus/CONFIG.SAMPLE ~/.aeolus/USAGE
    ;;
  *)
    cat 1>&2 <<-EOF

	Usage:

	  $0 { system | user }

	"system" installs systemwide;
	"user" installs to the home directory of the current user

	EOF
    ;;
esac
