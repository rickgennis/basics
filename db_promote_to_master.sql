#
# {ansible managed - do not edit}
#
STOP SLAVE;
RESET SLAVE ALL;
UNLOCK TABLES;
SET @@global.read_only := 0;
