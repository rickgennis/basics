#!/bin/sh

# run this when the box becomes a db slave 
# that's when we want it to start doing dumps

/usr/local/bin/cronedit.pl --enable --user mysql /usr/local/bin/dump_mysql.sh
/usr/local/bin/cronedit.pl --enable --user mysql /usr/local/bin/dump_slaving_mysql.sh
