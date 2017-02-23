#!/bin/bash
#########################################################################################
## Oracle DB Test Suite
#########################################################################################
# Installs Swingbench 2.5 http://dominicgiles.com/swingbench.html
# Create a simpleschema for testing (ade.customer)
# on an existing Oracle database 
# built via https://github.com/mgis-architects/terraform/tree/master/azure/oracledb
# This script only supports Azure currently, mainly due to the disk persistence method
#
# USAGE:
#
#    sudo oracledb-testsuite.sh ~/oracledb-testsuite.ini
#
# USEFUL LINKS: 
# 
# docs:     http://dominicgiles.com/swingbench.html
# download: http://dominicgiles.com/swingbench/swingbench25971.zip
# install:  https://docs.oracle.com/goldengate/c1221/gg-winux/GIORA/GUID-FBE6775F-A3F8-4765-BEAE-A302C7D8B6F9.htm#GIORA977
#
#########################################################################################

g_prog=oracledb-testsuite
RETVAL=0

######################################################
## defined script variables
######################################################
STAGE_DIR=/tmp/$g_prog/stage
LOG_DIR=/var/log/$g_prog
LOG_FILE=$LOG_DIR/${prog}.log.$(date +%Y%m%d_%H%M%S_%N)
INI_FILE=$LOG_DIR/${g_prog}.ini

THISDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SCR=$(basename "${BASH_SOURCE[0]}")
THIS_SCRIPT=$THISDIR/$SCR

######################################################
## log()
##
##   parameter 1 - text to log
##
##   1. write parameter #1 to current logfile
##
######################################################
function log ()
{
    if [[ -e $LOG_DIR ]]; then
        echo "$(date +%Y/%m/%d_%H:%M:%S.%N) $1" >> $LOG_FILE
    fi
}

######################################################
## fatalError()
##
##   parameter 1 - text to log
##
##   1.  log a fatal error and exit
##
######################################################
function fatalError ()
{
    MSG=$1
    log "FATAL: $MSG"
    echo "ERROR: $MSG"
    exit -1
}

function mountMedia() {

    if [ -f /mnt/software/swingbench2.5.971/swingbench25971.zip ]; then
    
        log "mountMedia(): Filesystem already mounted"
        
    else
    
        umount /mnt/software
    
        mkdir -p /mnt/software
        
        eval `grep mediaStorageAccountKey $INI_FILE`
        eval `grep mediaStorageAccount $INI_FILE`
        eval `grep mediaStorageAccountURL $INI_FILE`

        l_str=""
        if [ -z $mediaStorageAccountKey ]; then
            l_str+="mediaStorageAccountKey not found in $INI_FILE; "
        fi
        if [ -z $mediaStorageAccount ]; then
            l_str+="mediaStorageAccount not found in $INI_FILE; "
        fi
        if [ -z $mediaStorageAccountURL ]; then
            l_str+="mediaStorageAccountURL not found in $INI_FILE; "
        fi
        if ! [ -z $l_str ]; then
            fatalError "mountMedia(): $l_str"
        fi

        cat > /etc/cifspw << EOF1
username=${mediaStorageAccount}
password=${mediaStorageAccountKey}
EOF1

        cat >> /etc/fstab << EOF2
//${mediaStorageAccountURL}     /mnt/software   cifs    credentials=/etc/cifspw,vers=3.0,gid=54321      0       0
EOF2

        mount -a
        
        if [ ! -f /mnt/software/swingbench2.5.971/swingbench25971.zip ]; then
            fatalError "mountMedia(): media missing /mnt/software/swingbench2.5.971/swingbench25971.zip"
        fi

    fi
    
}

installSwingbench()
{
    local l_installdir=/u01/app/oracle/product
    local l_media1=/mnt/software/swingbench2.5.971/swingbench25971.zip
    local l_tmp_script=$LOG_DIR/$g_prog.installSwingbench.$$.sh
    local l_swingbench_install_log=$LOG_DIR/$g_prog.installTestSuite.$$.swingbenchInstall.log

    if [ ! -f ${l_media1} ]; then
        fatalError "installSwingbench(): media missing ${l_media1}"
    fi

    ################################
    # Create script to run as oracle
    ################################
    cat > $l_tmp_script << EOFsb
cd ${l_installdir}
unzip -q ${l_media1}
EOFsb

    ################################
    # Run the script
    ################################
    su - oracle -c "bash -x $l_tmp_script" |tee ${l_swingbench_install_log}
}

function installSimpleSchema() 
{

    local l_tmp_script=$LOG_DIR/$g_prog.installTestSuite.$$.installSimpleSchema.sh
    local l_log=$LOG_DIR/$g_prog.installTestSuite.$$.installSimpleSchema.log
    
    eval `grep simpleSchema $INI_FILE`
    eval `grep pdbConnectStr $INI_FILE`
    eval `grep pdbName $INI_FILE`
    eval `grep pdbDBA $INI_FILE`
    eval `grep pdbDBApassword $INI_FILE`
    
    l_str=""
    if [ -z $simpleSchema ]; then
        l_str+="simpleSchema not found in $INI_FILE; "
    fi
    if [ -z $pdbConnectStr ]; then
        l_str+="pdbConnectStr not found in $INI_FILE; "
    fi
    if [ -z $pdbDBA ]; then
        l_str+="pdbDBA not found in $INI_FILE; "
    fi
    if [ -z $pdbDBApassword ]; then
        l_str+="pdbDBApassword not found in $INI_FILE; "
    fi
    if ! [ -z $l_str ]; then
        fatalError "installSimpleSchema(): $l_str"
    fi
    
    ################################
    # Create script to run as oracle
    ################################

    cat > $l_tmp_script << EOFsimple
    
    sqlplus $pdbDBA/$pdbDBApassword@$pdbConnectStr << EOFsql
drop user ade cascade;
create user ade identified by ade default tablespace users;
grant connect, resource, unlimited tablespace to ade;

CREATE TABLE ade.CUSTOMERS 
( 
 CUSTOMER_ID NUMBER (6)  NOT NULL , 
 FIRST_NAME VARCHAR2 (20)  NOT NULL , 
 LAST_NAME VARCHAR2 (20)  NOT NULL , 
 JOIN_DATE date not null,
 ADDRESS_LINE1 varchar2(50), 
 ADDRESS_LINE2 varchar2(50), 
 ADDRESS_LINE3 varchar2(50), 
 POSTCODE varchar2(10), 
 PHONE_NUMBER varchar2(30)      
) tablespace USERS;

CREATE SEQUENCE customer_id_seq start with 1 increment by 1 cache 20;

begin
    for i in 1..10000 loop
        insert into ade.customers (customer_id, first_name, last_name, join_date)
        values (customer_id_seq.nextval, 
                dbms_random.string('U', 1), 
                dbms_random.string('U', dbms_random.value(5,10)),
                to_date(trunc(DBMS_RANDOM.VALUE(to_char(DATE '2000-01-01','J'),to_char(DATE '2016-12-31','J') ) ),'J' ));
    end loop;
    commit;
end;
/
;

create unique index ade.pki_customer_id on ade.customers(customer_id) tablespace users;
create index ade.ix_customer_join_date on ade.customers(join_date) tablespace users;
create index ade.ix_customer_name on ade.customers(first_name, last_name) tablespace users;
    
EOFsql
EOFsimple

    ################################
    # Run the script
    ################################
    su - oracle -c "bash -x $l_tmp_script" |tee ${l_swingbench_install_log}
}

function run()
{
    eval `grep platformEnvironment $INI_FILE`
    if [ -z $platformEnvironment ]; then    
        fatalError "$g_prog.run(): Unknown environment, check platformEnvironment setting in iniFile"
    elif [ $platformEnvironment != "AZURE" ]; then    
        fatalError "$g_prog.run(): platformEnvironment=AZURE is the only valid setting currently"
    fi

    # function calls
    mountMedia
    installSwingbench
    installSimpleSchema
}


######################################################
## Main Entry Point
######################################################

log "$g_prog starting"
log "STAGE_DIR=$STAGE_DIR"
log "LOG_DIR=$LOG_DIR"
log "INI_FILE=$INI_FILE"
log "LOG_FILE=$LOG_FILE"
echo "$g_prog starting, LOG_FILE=$LOG_FILE"

if [[ $EUID -ne 0 ]]; then
    fatalError "$THIS_SCRIPT must be run as root"
    exit 1
fi

INI_FILE_PATH=$1

if [[ -z $INI_FILE_PATH ]]; then
    fatalError "${g_prog} called with null parameter, should be the path to the driving ini_file"
fi

if [[ ! -f $INI_FILE_PATH ]]; then
    fatalError "${g_prog} ini_file cannot be found"
fi

if ! mkdir -p $LOG_DIR; then
    fatalError "${g_prog} cant make $LOG_DIR"
fi

chmod 777 $LOG_DIR

cp $INI_FILE_PATH $INI_FILE

run

log "$g_prog ended cleanly"
exit $RETVAL

