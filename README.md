# Simple Oracle Data Pump Export Wrapper Script.

The script read a configuration file that defines several variables in order to perform a database dump, a copy to a remote server and the sending of notifications in case of success and/or failure.

The Oracle Data Pump Export can be executed in FULL or SCHEMA mode. The configuration file describes how to active each mode. By default, the script executes it in FULL mode.

In order to active the notifications, sendmail or postfix must be installed and configured as a send-only SMTP server.
