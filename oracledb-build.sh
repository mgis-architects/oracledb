#!/bin/bash
################################################################################
## Configure Linux and install Oracle single instance 
## on Grid Infrastructure Restart 
## with Oracle ASM on udev persisted disks
##
## This script only supports Azure currently, mainly due to the disk persistence method
##
## USAGE:
##
##    sudo oracledb-build.sh ./oracledb-build.ini
##
################################################################################

g_prog=oracledb-build
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

function fixSwap()
{
    cat /etc/waagent.conf | while read LINE
    do
        if [ "$LINE" == "ResourceDisk.EnableSwap=n" ]; then
                LINE="ResourceDisk.EnableSwap=y"
        fi

        if [ "$LINE" == "ResourceDisk.SwapSizeMB=2048" ]; then
                LINE="ResourceDisk.SwapSizeMB=14000"
        fi
        echo $LINE
    done > /tmp/waagent.conf
    /bin/cp /tmp/waagent.conf /etc/waagent.conf
    systemctl restart waagent.service
}

function installRPMs()
{
    INSTALL_RPM_LOG=$LOG_DIR/yum.${g_prog}_install.log.$$

    STR=""
    STR="$STR tcsh.x86_64 unzip.x86_64 libaio.x86_64  libXext.x86_64 libXtst.x86_64 sysstat.x86_64 compat-libcap1.x86_64"
    STR="$STR compat-libstdc++-33.x86_64 gcc.x86_64 gcc-c++.x86_64 compat-libstdc++-33.i686 glibc-devel.i686 glibc-devel.x86_64 libstdc++.i686"
    STR="$STR libstdc++-devel.x86_64 libstdc++-devel.i686 libaio.i686 libaio-devel.i686 libaio-devel.x86_64 libXext.i686 libXtst.i686"
    STR="$STR nfs-utils.x86_64 nscd.x86_64 xauth xorg-x11-utils zip dos2unix bind-utils openssh-clients rsync ksh cifs-utils"
    STR="$STR psmisc" # needed for fuser
    # STR="$STR expect"
    
    yum makecache fast
    
    echo "installRPMs(): to see progress tail $INSTALL_RPM_LOG"
    if ! yum -y install $STR > $INSTALL_RPM_LOG
    then
        fatalError "installRPMs(): failed; see $INSTALL_RPM_LOG"
    fi
}

function addGroups()
{
    local l_group_list=$LOG_DIR/groups.${g_prog}.lst.$$
    local l_found
    local l_user
    local l_x
    local l_gid
    local l_newgid
    local l_newgname

    cat > $l_group_list << EOFaddGroups
54321 oinstall
54322 dba
54323 oper
54324 backupdba
54325 dgdba
54326 kmdba
54327 asmdba
54328 asmoper
54329 asmadmin
EOFaddGroups

    while read l_newgid l_newgname
    do    
    
        local l_found=0
        grep $l_newgid /etc/group | while IFS=: read l_gname l_x l_gid
        do
            if [ $l_gname != $l_newgname ]; then
                fatalError "addGroups(): gid $l_newgid exists with a different group name $l_gname"
            fi
        done
        
        log "addGroups(): /usr/sbin/groupadd -g $l_newgid $l_newgname"
        if ! /usr/sbin/groupadd -g $l_newgid $l_newgname; then 
            log "addGroups() failed on $l_newgid $l_newgname"
        fi
    
    done < $l_group_list   
}

function addUsers()
{

    if ! id -a oracle 2> /dev/null; then
        /usr/sbin/useradd -u 54321 -g oinstall -G dba,asmdba,backupdba,dgdba,kmdba,asmoper,asmdba,oper,asmadmin oracle -p c6kTxMi2LR1l2
    else
        fatalError "addUsers(): user 54321/oracle already exists"
    fi
    
    if ! id -a grid 2> /dev/null; then
        /usr/sbin/useradd -u 54322 -g oinstall -G dba,asmadmin,asmdba,asmoper grid -p c6kTxMi2LR1l2
    else
        fatalError "addUsers(): user 54322/grid already exists"
    fi
}

function addLimits()
{
    local l_mem

    cp /etc/security/limits.conf /etc/security/limits.conf.preDB
    
    # at least 90 percent of the current RAM
    let l_mem=`grep MemTotal /proc/meminfo | awk '{print $2}'`*91/100

    cat >> /etc/security/limits.conf << EOFaddLimits
oracle           soft    nproc     16384
oracle           hard    nproc     16384
oracle           soft    nofile    65536
oracle           hard    nofile    65536
oracle           soft    stack     10240
oracle           hard    stack     10240
oracle           soft    memlock  $l_mem
oracle           hard    memlock  $l_mem

grid             soft    nproc     16384
grid             hard    nproc     16384
grid             soft    nofile    65536
grid             hard    nofile    65536
grid             soft    stack     10240
grid             hard    stack     10240
grid             soft    memlock  $l_mem
grid             hard    memlock  $l_mem
EOFaddLimits
}

function addPam()
{

    cp /etc/pam.d/login /etc/pam.d/login.preDB
    
    cat >> /etc/pam.d/login << EOFaddPam
# Doc ID 1529864.1
session    required     pam_limits.so
EOFaddPam

}

function addSysctlConfig() 
{

    local l_sysctl_log=$LOG_DIR/sysctl.${g_prog}.log.$$
    local l_physmem
    local l_shmmax
    local l_shmall
    local l_hugepages
    
    if [ -f /etc/sysctl.conf.preDB ]; then
        fatalError "addSysctlConfig(): server apparently already has its database config applied"
    fi
    
    cp /etc/sysctl.conf /etc/sysctl.conf.preDB
    
    let l_physmem=`grep MemTotal /proc/meminfo | awk '{print $2}'`
    let l_shmmax=1024*$l_physmem*70/100
    let l_shmall=$l_physmem*80/100/4
    let l_hugepages=$l_physmem*70/100/2048+100

    echo "kernel.shmmax = $l_shmmax" >> /etc/sysctl.conf
    echo "kernel.shmall = $l_shmall" >> /etc/sysctl.conf
    echo "kernel.shmmni = 4096" >> /etc/sysctl.conf
    echo "kernel.sem = 250 32000 100 128" >> /etc/sysctl.conf
    echo "fs.file-max = 6815744" >> /etc/sysctl.conf
    echo "fs.aio-max-nr = 1048576" >> /etc/sysctl.conf
    echo "net.ipv4.ip_local_port_range = 9000 65500" >> /etc/sysctl.conf
    echo "net.core.rmem_default = 262144" >> /etc/sysctl.conf
    echo "net.core.rmem_max = 4194304" >> /etc/sysctl.conf
    echo "net.core.wmem_default = 262144" >> /etc/sysctl.conf
    echo "net.core.wmem_max = 1048576" >> /etc/sysctl.conf
    echo "kernel.panic_on_oops=1" >> /etc/sysctl.conf
    echo "vm.nr_hugepages = $l_hugepages" >> /etc/sysctl.conf
    
    if ! sysctl -p; then
        fatalError "addSysctlConfig(): error applying sysctl changes"
    fi

}

function makeFolders()
{

    local l_error=0
    
    if ! mkdir -p /u01/app/grid/12.1.0; then l_error=1; fi
    if ! mkdir -p /u01/app/grid; then l_error=1; fi
    if ! mkdir -p /u01/app/oracle; then l_error=1; fi
    if ! chown -R grid:oinstall /u01; then l_error=1; fi
    if ! chown oracle:oinstall /u01/app/oracle; then l_error=1; fi
    if ! chmod -R 775 /u01/; then l_error=1; fi
    # EM agent needs parent owned by root hence
    if ! chown root:root /u01/app; then l_error=1; fi
    
    if [ $l_error -eq 1 ]; then
        fatalError "makeFolders(): error creating folders"
    fi

}

function setOraInstLoc() 
{

    if [ ! -f /etc/oraInst.loc ]; then
    
        cat > /etc/oraInst.loc << EOForaInst
inventory_loc=/u01/app/oracle/oraInventory
inst_group=oinstall
EOForaInst

        chown oracle:oinstall /etc/oraInst.loc
    fi

}

function sshConfig() 
{

    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.preDB
    
    nFound=0
    cat /etc/ssh/sshd_config.preDB | while read LINE
    do
        if [ "$LINE" == "X11Forwarding no" ]; then
            echo "X11Forwarding yes"
        else 
            echo $LINE
        fi
    done > /etc/ssh/sshd_config
}

function gridProfile() 
{

    cat >> /home/grid/.bashrc << EOFFgridProfile1
    if [ -t 0 ]; then
       stty intr ^C
    fi
EOFFgridProfile1

    cat >> /home/grid/.bash_profile << EOFgridProfile2
    umask 022
    set -o vi
    export EDITOR=vi
    export TMP=/tmp
    export TMPDIR=/tmp
    export ORACLE_BASE=/u01/app/grid
    export ORACLE_HOME=/u01/app/grid/12.1.0
    export GRID_HOME=/u01/app/grid/12.1.0
    export PATH=\$ORACLE_HOME/bin:\$PATH
    export ORACLE_SID=+ASM
EOFgridProfile2

    chown grid:oinstall /home/grid/.bashrc 
    chown grid:oinstall /home/grid/.bash_profile
}

function oracleProfile() 
{

    cat >> /home/oracle/.bashrc << EOForacleProfile1
    if [ -t 0 ]; then
       stty intr ^C
    fi
EOForacleProfile1

    cat >> /home/oracle/.bash_profile << EOForacleProfile2
    umask 022
    set -o vi
    export EDITOR=vi
    export TMP=/tmp
    export TMPDIR=/tmp
    export ORACLE_HOME=/u01/app/oracle/product/12.1.0/db_1
    export GRID_HOME=/u01/app/grid/12.1.0
    export PATH=\$ORACLE_HOME/bin:\$PATH
EOForacleProfile2

    chown oracle:oinstall /home/oracle/.bashrc 
    chown oracle:oinstall /home/oracle/.bash_profile

}

createFilesystem()
{
    # createFilesystem /u01 $l_disk $diskSectors  
    # size is diskSectors-128 (offset)

    local p_filesystem=$1
    local p_disk=$2
    local p_sizeInSectors=$3
    local l_sectors
    local l_layoutFile=$LOG_DIR/sfdisk.${g_prog}_install.log.$$
    
    if [ -z $p_filesystem ] || [ -z $p_disk ] || [ -z $p_sizeInSectors ]; then
        fatalError "createFilesystem(): Expected usage mount,device,numsectors, got $p_filesystem,$p_disk,$p_sizeInSectors"
    fi
    
    let l_sectors=$p_sizeInSectors-128
    
    cat > $l_layoutFile << EOFsdcLayout
# partition table of /dev/sdc
unit: sectors

/dev/sdc1 : start=     128, size=  ${l_sectors}, Id= 83
/dev/sdc2 : start=        0, size=        0, Id= 0
/dev/sdc3 : start=        0, size=        0, Id= 0
/dev/sdc4 : start=        0, size=        0, Id= 0
EOFsdcLayout

    set -x # debug has been useful here

    if ! sfdisk $p_disk < $l_layoutFile; then fatalError "createFilesystem(): $p_disk does not exist"; fi
    
    sleep 4 # add a delay - experiencing occasional "cannot stat" for mkfs
    
    log "createFilesystem(): Dump partition table for $p_disk"
    fdisk -l 
    
    if ! mkfs.ext4 ${p_disk}1; then fatalError "createFilesystem(): mkfs.ext4 ${p_disk}1"; fi
    
    if ! mkdir -p $p_filesystem; then fatalError "createFilesystem(): mkdir $p_filesystem failed"; fi
    
    if ! chmod 755 $p_filesystem; then fatalError "createFilesystem(): chmod $p_filesystem failed"; fi
    
    if ! chown oracle:oinstall $p_filesystem; then fatalError "createFilesystem(): chown $p_filesystem failed"; fi
    
    if ! mount ${p_disk}1 $p_filesystem; then fatalError "createFilesystem(): mount $p_disk $p_filesytem failed"; fi

    log "createFilesystem(): Dump blkid"
    blkid
    
    if ! blkid | egrep ${p_disk}1 | awk '{printf "%s\t'${p_filesystem}' \t ext4 \t defaults \t 1 \t2\n", $2}' >> /etc/fstab; then fatalError "createFilesystem(): fstab update failed"; fi

    log "createFilesystem() fstab success: $(grep $p_disk /etc/fstab)"

    set +x    
}

createASM()
{
    # Parameters
    # createASM DATA $l_disk
    # createASM RECO $l_disk
    local p_diskgroup=$1
    local p_disk=$2
    local l_UUID
    local l_disk=`basename $p_disk`
    local l_udev_file=/etc/udev/rules.d/99-oracle.rules
    
    if [ -z $p_diskgroup ] || [ -z $p_disk ]; then
        fatalError "createASM(): Expected usage [diskGroup,disk] got [$p_diskgroup,$p_disk]"
    fi
    
    log "createASM(): create ASM disk for $p_diskgroup on $p_disk"
    
    pvcreate $p_disk
    l_UUID=`udevadm info --query=property --name=$p_disk|grep ID_SERIAL=|awk -F '=' '{print $2}'`
    log "createASM(): extracted UUID for $p_disk is $l_UUID"
  # echo KERNEL==\"sd*\", SUBSYSTEM==\"block\", ENV{DEVTYPE}==\"disk\", ENV{ID_SERIAL}==\"${l_UUID}\", NAME=\"asmdisk-${p_diskgroup}-${l_disk}\", OWNER=\"grid\", GROUP=\"oinstall\", MODE=\"0660\", ATTR{queue/scheduler}=\"deadline\" >> $l_udev_file
    echo KERNEL==\"sd*\", SUBSYSTEM==\"block\", ENV{DEVTYPE}==\"disk\", ENV{ID_SERIAL}==\"${l_UUID}\", SYMLINK+=\"asmdisk-${p_diskgroup}-${l_disk}\", OWNER=\"grid\", GROUP=\"oinstall\", MODE=\"0660\", ATTR{queue/scheduler}=\"deadline\" >> $l_udev_file

    
    l_major_minor=`ls -l /sys/dev/block | grep $l_disk | awk '{print $9}'`
    if ! udevadm test /sys/dev/block/$l_major_minor; then
        fatalError "createASM(): Error with udevadm test for $p_disk. udevadm test /sys/dev/block/$l_major_minor"
    fi
}


function allocateStorage() 
{
    local l_disk
    local l_size
    local l_sectors
    local l_hasPartition

    eval `grep u01_Disk_Size_In_GB $INI_FILE`
    eval `grep asm_Data_Disk_Size_In_GB $INI_FILE`
    eval `grep asm_Reco_Disk_Size_In_GB $INI_FILE`

    l_str=""
    if [ -z $u01_Disk_Size_In_GB ]; then
        l_str+="asmStorage(): u01_Disk_Size_In_GB not found in $INI_FILE; "
    fi
    if [ -z $asm_Data_Disk_Size_In_GB ]; then
        l_str+="asmStorage(): asm_Data_Disk_Size_In_GB not found in $INI_FILE; "
    fi
    if [ -z $asm_Reco_Disk_Size_In_GB ]; then
        l_str+="asmStorage(): asm_Reco_Disk_Size_In_GB not found in $INI_FILE; "
    fi
    if ! [ -z $l_str ]; then
        fatalError "allocateStorage(): $l_str"
    fi
    
    for l_disk in /dev/sd? 
    do
    
         l_hasPartition=$(( $(fdisk -l $l_disk | wc -l) != 6 ? 1 : 0 ))

        # only use if it doesnt already have a blkid or udev UUID
        if [ $l_hasPartition -eq 0 ]; then
        
            let l_size=`fdisk -l $l_disk | grep 'Disk.*sectors' | awk '{print $5}'`/1024/1024/1024
            let l_sectors=`fdisk -l $l_disk | grep 'Disk.*sectors' | awk '{print $7}'`
            
            if [ $u01_Disk_Size_In_GB -eq $l_size ]; then
                log "allocateStorage(): Creating /u01 on $l_disk"
                createFilesystem /u01 $l_disk $l_sectors
            fi
            
            if [ $asm_Data_Disk_Size_In_GB -eq $l_size ]; then
                log "allocateStorage(): Creating ASM Data disk on $l_disk"
                createASM DATA $l_disk
            fi
            
            if [ $asm_Reco_Disk_Size_In_GB -eq $l_size ]; then
                log "allocateStorage(): Creating ASM Reco disk on $l_disk"
                createASM RECO $l_disk
            fi
        fi
    done   
    
}

function restartUdev() 
{
    echo "Restarting Udev"
    udevadm control --reload-rules
    udevadm trigger
    
    ls -la /dev/asm* | while read LINE
    do
        log "restartUdev(): Added $LINE"
    done
}

function mountMedia() {

    mkdir /mnt/software
    
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
}

function installGridHome() 
{
    local l_tmp_script=$LOG_DIR/$g_prog.installGridHome.$$.sh
    local l_tmp_responsefile=$LOG_DIR/$g_prog.installGridHome.$$.rsp
    local l_runInstaller_log=$LOG_DIR/$g_prog.installGridHome.$$.runinstaller.log
    local l_gridinstall_log=$LOG_DIR/$g_prog.installGridHome.$$.gridinstall.log
    local l_root_sh_log=$LOG_DIR/$g_prog.installGridHome.$$.root.log
    local l_grid_stage=$STAGE_DIR/grid12102
    local l_diskstring
    local l_cnt
    
    if [ ! -f /mnt/software/grid12102/V46096-01_1of2.zip ]; then
        fatalError "installGridHome(): media missing /mnt/software/grid12102/V46096-01_1of2.zip"
    fi
    if [ ! -f /mnt/software/grid12102/V46096-01_2of2.zip ]; then
        fatalError "installGridHome(): media missing /mnt/software/grid12102/V46096-01_2of2.zip"
    fi
    
    ################################
    # Get passwords from ini file
    ################################
    eval `grep asmSysasmPassword $INI_FILE`
    if [ -z $asmSysasmPassword ]; then    
        fatalError "installGridHome(): asmSysasmPassword missing"
    fi
    eval `grep asmMonitorPassword $INI_FILE`
    if [ -z $asmMonitorPassword ]; then    
        fatalError "installGridHome(): asmMonitorPassword missing"
    fi
    
    ################################
    # Get DATA diskgroup disk list
    ################################
    l_diskstring=''
    l_cnt=0
    while read LINE
    do
        if [ $l_cnt -gt 0 ]; then
            l_diskstring=${l_diskstring},
        fi
        l_diskstring=${l_diskstring}$LINE
        let l_cnt=l_cnt+1
    done < <(ls -1 /dev/asm*DATA*)

    ################################
    # Generate responsefile
    ################################
    cat > $l_tmp_responsefile << EOFigh1
oracle.install.responseFileVersion=/oracle/install/rspfmt_crsinstall_response_schema_v12.1.0
INVENTORY_LOCATION=/u01/app/oraInventory
SELECTED_LANGUAGES=en
oracle.install.option=HA_CONFIG
ORACLE_BASE=/u01/app/grid
ORACLE_HOME=/u01/app/grid/12.1.0
oracle.install.asm.OSDBA=asmdba
oracle.install.asm.OSOPER=asmoper
oracle.install.asm.OSASM=asmadmin
oracle.install.asm.SYSASMPassword=${asmSysasmPassword}
oracle.install.asm.diskGroup.name=DATA
oracle.install.asm.diskGroup.redundancy=EXTERNAL
oracle.install.asm.diskGroup.AUSize=4
oracle.install.asm.diskGroup.disks=${l_diskstring}
oracle.install.asm.diskGroup.diskDiscoveryString=/dev/asm*
oracle.install.asm.monitorPassword=${asmMonitorPassword}
oracle.install.config.managementOption=NONE
EOFigh1

    chmod 644 ${l_tmp_responsefile}

    ################################
    # Create script to run as grid
    ################################
    cat > $l_tmp_script << EOFigh2
rm -rf $STAGE_DIR
mkdir -p $STAGE_DIR/grid12102
unzip -q -d $l_grid_stage /mnt/software/grid12102/V46096-01_1of2.zip
unzip -q -d $l_grid_stage /mnt/software/grid12102/V46096-01_2of2.zip
cd ${l_grid_stage}/grid
./runInstaller -silent -waitforcompletion -responseFile $l_tmp_responsefile |tee $l_runInstaller_log
EOFigh2

    ################################
    # Run the script
    ################################
    # Ignore [WARNING] [INS-13014] Target environment does not meet some optional requirements.
    su - grid -c "bash -x $l_tmp_script" |tee ${l_gridinstall_log}
    
    if [ ! -f /u01/app/grid/12.1.0/root.sh ]; then
        fatalError "installGrid(): cant find root.sh in /u01/app/grid/12.1.0"
    fi
    
    sh -x /u01/app/grid/12.1.0/root.sh |tee ${l_root_sh_log}
}

function gridConfigTool() 
{
    local l_tmp_cfgtoolrspfile=$LOG_DIR/$g_prog.installGridHome_cfgtool.$$.rsp
    local l_cfgtool_log=$LOG_DIR/$g_prog.installGridHome.$$.cfg.log    

    cat > $l_tmp_cfgtoolrspfile << EOFctrp
oracle.assistants.asm|S_ASMPASSWORD=${asmSysasmPassword}
oracle.assistants.asm|S_ASMMONITORPASSWORD=${asmMonitorPassword}
EOFctrp

    if [ ! -f /u01/app/grid/12.1.0/cfgtoollogs/configToolAllCommands ]; then
        fatalError "installGrid(): cant find /u01/app/grid/12.1.0/cfgtoollogs/configToolAllCommands"
    fi
    
    su - grid -c "/u01/app/grid/12.1.0/cfgtoollogs/configToolAllCommands RESPONSE_FILE=$l_tmp_cfgtoolrspfile"  |tee ${l_cfgtool_log}
}

function createRECOdiskgroup()
{
    ################################
    # Get RECO diskgroup disk list
    ################################
    l_diskstring=''
    l_cnt=0
    while read LINE
    do
        if [ $l_cnt -gt 0 ]; then
            l_diskstring=${l_diskstring},
        fi
        l_diskstring=${l_diskstring}\'$LINE\'
        let l_cnt=l_cnt+1
    done < <(ls -1 /dev/asm*RECO*)

    su - grid -c "sqlplus / as sysasm << EOFreco
    CREATE DISKGROUP RECO EXTERNAL REDUNDANCY DISK ${l_diskstring} ATTRIBUTE 'AU_SIZE' = '4M';
EOFreco"
}


function installOracleHome()
{
    local l_tmp_script=$LOG_DIR/$g_prog.installOracleHome.$$.sh
    local l_tmp_responsefile=$LOG_DIR/$g_prog.installOracleHome.$$.rsp
    local l_runInstaller_log=$LOG_DIR/$g_prog.installOracleHome.$$.runinstaller.log
    local l_oracleinstall_log=$LOG_DIR/$g_prog.installOracleHome.$$.oracleinstall.log
    local l_root_sh_log=$LOG_DIR/$g_prog.installOracleHome.$$.root.log
    local l_oracle_stage=$STAGE_DIR/oracle12102
    
    if [ ! -f /mnt/software/database12102/V46095-01_1of2.zip ]; then
        fatalError "installOracleHome(): media missing /mnt/software/database12102/V46095-01_1of2.zip"
    fi
    if [ ! -f /mnt/software/database12102/V46095-01_2of2.zip ]; then
        fatalError "installOracleHome(): media missing /mnt/software/database12102/V46095-01_2of2.zip"
    fi

    cat > $l_tmp_responsefile << EOF1
oracle.install.responseFileVersion=/oracle/install/rspfmt_dbinstall_response_schema_v12.1.0
oracle.install.option=INSTALL_DB_SWONLY
ORACLE_HOSTNAME=
UNIX_GROUP_NAME=oinstall
INVENTORY_LOCATION=/u01/app/oraInventory
SELECTED_LANGUAGES=en
ORACLE_HOME=/u01/app/oracle/product/12.1.0/db_1
ORACLE_BASE=/u01/app/oracle
oracle.install.db.InstallEdition=EE
oracle.install.db.DBA_GROUP=dba
oracle.install.db.OPER_GROUP=oper
oracle.install.db.BACKUPDBA_GROUP=backupdba
oracle.install.db.DGDBA_GROUP=dgdba
oracle.install.db.KMDBA_GROUP=kmdba
SECURITY_UPDATES_VIA_MYORACLESUPPORT=false
DECLINE_SECURITY_UPDATES=true
EOF1

    chmod 644 ${l_tmp_responsefile}
    rm -rf $STAGE_DIR/oracle12102
    chmod 777 $STAGE_DIR
    
    cat > $l_tmp_script << EOForadb
mkdir -p $STAGE_DIR/oracle12102
unzip -q -d $l_oracle_stage /mnt/software/database12102/V46095-01_1of2.zip
unzip -q -d $l_oracle_stage /mnt/software/database12102/V46095-01_2of2.zip
cd ${l_oracle_stage}/database
./runInstaller -silent -waitforcompletion -responseFile $l_tmp_responsefile |tee $l_runInstaller_log
EOForadb

    su - oracle -c "bash -x $l_tmp_script" |tee ${l_oracleinstall_log}
    
    if [ ! -f /u01/app/oracle/product/12.1.0/db_1/root.sh ]; then
        fatalError "installOracleHome(): cant find root.sh in /u01/app/oracle/product/12.1.0/db_1"
    fi
    
    sh -x /u01/app/oracle/product/12.1.0/db_1/root.sh |tee ${l_root_sh_log}
}

function createCDB()
{
    local l_tmp_script=$LOG_DIR/$g_prog.installOracleHome.$$.createCDB.sh
    local l_createDatabase_log=$LOG_DIR/$g_prog.installOracleHome.$$.createCDB.log
    local l_str

    eval `grep sysPassword $INI_FILE`
    eval `grep systemPassword $INI_FILE`
    eval `grep cdbName $INI_FILE`
    eval `grep cdbDomain $INI_FILE`
    eval `grep asmMonitorPassword $INI_FILE`
    
    l_str=""
    if [ -z $sysPassword ]; then
        l_str+="sysPassword not found in $INI_FILE; "
    fi
    if [ -z $systemPassword ]; then
        l_str+="systemPassword not found in $INI_FILE; "
    fi
    if [ -z $cdbName ]; then
        l_str+="cdbName not found in $INI_FILE; "
    fi
    if [ -z $cdbDomain ]; then
        l_str+="cdbDomain not found in $INI_FILE; "
    fi
    if [ -z $asmMonitorPassword ]; then
        l_str+="asmMonitorPassword not found in $INI_FILE; "
    fi
    if [ ! -z $l_str ]; then
        fatalError "createCDB(): $l_str"
    fi
    
    cat > $l_tmp_script << EOFcdb
    dbca -silent \
         -createDatabase \
         -templateName General_Purpose.dbc \
         -gdbName ${cdbName}.${cdbDomain} \
         -sid ${cdbName} \
         -createAsContainerDatabase true -numberOfPDBs 0 \
         -sysPassword ${sysPassword} -systemPassword ${systemPassword} \
         -emConfiguration NONE  \
         -redoLogFileSize 100 \
         -storageType ASM -asmsnmpPassword ${asmMonitorPassword} -diskGroupName DATA -recoveryGroupName RECO \
         -characterSet AL32UTF8 -nationalCharacterSet UTF8 \
         -initParams db_unique_name=${cdbName},audit_file_dest='/u01/app/oracle/admin/${cdbName}/adump',audit_sys_operations=true,audit_trail='db',compatible='12.1.0.2.0',db_block_checking='FULL',db_block_checksum='TYPICAL',db_lost_write_protect='TYPICAL',diagnostic_dest='/u01/app/oracle',dispatchers='(PROTOCOL=TCP)(SERVICE=${cdbName}XDB)',fast_start_mttr_target=300,filesystemio_options='SETALL',global_names=TRUE,log_archive_format='%d_%t_%S_%r.dbf',nls_language='ENGLISH',open_cursors=1000,parallel_adaptive_multi_user=FALSE,parallel_max_servers=32,parallel_min_servers=4,processes=2500,sessions=200,remote_login_passwordfile='exclusive',shared_pool_size=2G,sql92_security=TRUE \
         -sampleSchema false \
         -automaticMemoryManagement false

    export ORACLE_SID=${cdbName}
    sqlplus / as sysdba << EOFsp1
    alter system set sga_target=8G scope=spfile;
    alter system set shared_pool_size=2G scope=spfile;
    alter system set pga_aggregate_target=2G scope=spfile;
    shutdown immediate;
    startup;
EOFsp1
EOFcdb

    su - oracle -c "bash -x $l_tmp_script" |tee ${l_createDatabase_log}
}

function createPDB() {

    local l_tmp_script=$LOG_DIR/$g_prog.installOracleHome.$$.createPDB.sh
    local l_createDatabase_log=$LOG_DIR/$g_prog.installOracleHome.$$.createPDB.log
    
    eval `grep sysPassword $INI_FILE`
    eval `grep cdbName $INI_FILE`
    eval `grep pdbName $INI_FILE`
    eval `grep pdbDBA $INI_FILE`
    eval `grep pdbDBApassword $INI_FILE`
    
    l_str=""
    if [ -z $sysPassword ]; then
        l_str+="sysPassword not found in $INI_FILE; "
    fi
    if [ -z $cdbName ]; then
        l_str+="cdbName not found in $INI_FILE; "
    fi
    if [ -z $pdbName ]; then
        l_str+="pdbName not found in $INI_FILE; "
    fi
    if [ -z $pdbDBA ]; then
        l_str+="pdbDBA not found in $INI_FILE; "
    fi
    if [ -z $pdbDBApassword ]; then
        l_str+="pdbDBApassword not found in $INI_FILE; "
    fi
    if ! [ -z $l_str ]; then
        fatalError "createPDB(): $l_str"
    fi

    cat > $l_tmp_script << EOFpdb
    export ORACLE_SID=${cdbName}
    sqlplus / as sysdba << EOFsp1
    CREATE PLUGGABLE DATABASE ${pdbName} 
    DEFAULT TABLESPACE users DATAFILE '+DATA' SIZE 20M AUTOEXTEND ON NEXT 10M
    ADMIN USER ${pdbDBA} IDENTIFIED BY ${pdbDBApassword} ROLES=(DBA);

    ALTER PLUGGABLE DATABASE ${pdbName} open;
    alter pluggable database all save state;
    
    -- 1929745.1 Jan 2017 psu java mitigation 
    @?/rdbms/admin/dbmsjdev.sql
    exec dbms_java_dev.disable

EOFsp1
EOFpdb

    su - oracle -c "bash -x $l_tmp_script" |tee ${l_createDatabase_log}

}

function enableArchiveLog() {

    local l_tmp_script=$LOG_DIR/$g_prog.installOracleHome.$$.archiveLog.sh
    local l_createDatabase_log=$LOG_DIR/$g_prog.installOracleHome.$$.archiveLog.log
    
    eval `grep cdbName $INI_FILE`
    
    l_str=""
    if [ -z $cdbName ]; then
        l_str+="cdbName not found in $INI_FILE; "
    fi
    if ! [ -z $l_str ]; then
        fatalError "createPDB(): $l_str"
    fi

    cat > $l_tmp_script << EOFpdb
    export ORACLE_SID=${cdbName}
    sqlplus / as sysdba << EOFsp1
    shutdown immediate;
    startup mount;
    alter database archivelog;
    alter database open;
    archive log list;
EOFsp1
EOFpdb

    su - oracle -c "bash -x $l_tmp_script" |tee ${l_createDatabase_log}

}

function updateOpatch()
{
    local l_tmp_script=$LOG_DIR/$g_prog.installOpatch.$$.sh
    local l_opatch_grid_log=$LOG_DIR/$g_prog.installOpatch.$$.opatchinstallgrid.log
    local l_opatch_oracle_log=$LOG_DIR/$g_prog.installOpatch.$$.opatchinstalldatabase.log
    local l_media=/mnt/software/database12102/p6880880_121010_Linux-x86-64.zip
        
    if [ ! -f ${l_media} ]; then
        fatalError "updateOpatch(): media missing ${l_media}"
    fi
    
    cat > $l_tmp_script << EOFopatch
    cd \$ORACLE_HOME
    unzip -oq ${l_media}
    \$ORACLE_HOME/OPatch/opatch version
EOFopatch

    su - grid -c "bash -x $l_tmp_script" |tee ${l_opatch_grid_log}
    su - oracle -c "bash -x $l_tmp_script" |tee ${l_opatch_oracle_log}
}

# Not needed with latest opatch
# function generateOCM()
# {
# 
#     local l_tmp_script=$LOG_DIR/$g_prog.generateOCM.$$.sh
#     local l_log=$LOG_DIR/$g_prog.generateOCM.$$.generateOCM.log
# 
#     cat > ${l_tmp_script} << EOFocm
# 
#     EMOCMRSP=\$ORACLE_HOME/OPatch/ocm/bin/emocmrsp
#     OCM_FILE=/u01/app/oracle/ocm.rsp
# 
#     /usr/bin/expect - <<ENDOFFILE
#     spawn \$EMOCMRSP -no_banner -output \$OCM_FILE
#     expect {
#       "Email address/User Name:"
#       {
#         send "\\n
#     "
#         exp_continue
#       }
#       "Do you wish to remain uninformed of security issues*"
#       {
#         send "Y\\n
#     "
#         exp_continue
#       }
#     }
# ENDOFFILE
# 
#     chmod 644 \$OCM_FILE
# EOFocm
# 
#     su - oracle -c "bash -x $l_tmp_script" 2>&1 |tee ${l_log}
# 
# }

function jan2017psu()
{
    #  README https://updates.oracle.com/Orion/Services/download?type=readme&aru=20758305
    
    local l_media=/mnt/software/database12102/p24917825_121020_Linux-x86-64.zip
    local l_tmp_script1=$LOG_DIR/$g_prog.stagejan2017psu.$$.sh
    local l_tmp_script2=$LOG_DIR/$g_prog.installjan2017psu.$$.sh
    local l_log1=$LOG_DIR/$g_prog.stagejan2017psu.$$.log
    local l_log2=$LOG_DIR/$g_prog.installjan2017psu.$$.log
    local l_stage=$STAGE_DIR/jan2017psu
    
    cat > $l_tmp_script1 << EOFpsu1
    rm -rf $l_stage
    mkdir -p ${l_stage}
    unzip -q -d ${l_stage} ${l_media}
EOFpsu1

    su - grid -c "bash -x $l_tmp_script1" |tee ${l_log1}

    cat > $l_tmp_script2 << EOFpsu2
    cd ${l_stage}
    export PATH=\$PATH:/u01/app/grid/12.1.0/OPatch
    opatchauto apply ./24917825
    rm -rf $l_stage
EOFpsu2

    # opatchauto has to be run as root
    su - -c "bash -x $l_tmp_script2" |tee ${l_log2}
}

function jan2017psuoracle()
{
    #  README https://updates.oracle.com/Orion/Services/download?type=readme&aru=20758305
    
    local l_media=/mnt/software/database12102/p24917825_121020_Linux-x86-64.zip
    local l_tmp_script1=$LOG_DIR/$g_prog.stagejan2017psu.$$.sh
    local l_tmp_script2=$LOG_DIR/$g_prog.installjan2017psu.$$.sh
    local l_log1=$LOG_DIR/$g_prog.stagejan2017psu.$$.log
    local l_log2=$LOG_DIR/$g_prog.installjan2017psu.$$.log
    local l_stage=$STAGE_DIR/jan2017psu
    
    cat > $l_tmp_script1 << EOFpsu1
    rm -rf $l_stage
    mkdir -p ${l_stage}
    unzip -q -d ${l_stage} ${l_media}
EOFpsu1

    su - grid -c "bash -x $l_tmp_script1" |tee ${l_log1}

    cat > $l_tmp_script2 << EOFpsu2
    cd ${l_stage}
    export PATH=\$PATH:/u01/app/oracle/product/12.1.0/db_1/OPatch
    opatchauto apply ./24917825 -oh /u01/app/oracle/product/12.1.0/db_1
    rm -rf $l_stage
EOFpsu2

    # opatchauto has to be run as root
    su - -c "bash -x $l_tmp_script2" |tee ${l_log2}
}


function rebuildRedoLogs()
{


    local l_tmp_script=$LOG_DIR/$g_prog.installOracleHome.$$.rebuildLogs.sh
    local l_log=$LOG_DIR/$g_prog.installOracleHome.$$.rebuildLogs.log
    
    eval `grep cdbName $INI_FILE`
    
    l_str=""
    if [ -z $cdbName ]; then
        l_str+="cdbName not found in $INI_FILE; "
    fi
    if ! [ -z $l_str ]; then
        fatalError "rebuildLogs(): $l_str"
    fi

    cat > $l_tmp_script << EOFpdb
    export ORACLE_SID=${cdbName}
    sqlplus / as sysdba << EOFrl1

    alter database add logfile group 4 ('+DATA','+RECO') size 4096M;
    alter database add logfile group 5 ('+DATA','+RECO') size 4096M;
    alter database add logfile group 6 ('+DATA','+RECO') size 4096M;
    alter database add logfile group 7 ('+DATA','+RECO') size 4096M;
    alter system switch logfile;
    alter system switch logfile;
    alter system switch logfile;
    alter database drop logfile group 1;
    alter database drop logfile group 2;
    alter database drop logfile group 3;

    archive log list;
EOFrl1
EOFpdb

    su - oracle -c "bash -x $l_tmp_script" |tee ${l_log}


}

function run()
{
    eval `grep platformEnvironment $INI_FILE`
    if [ -z $platformEnvironment ]; then    
        fatalError "$g_prog.run(): Unknown environment, check platformEnvironment setting in iniFile"
    elif [ $platformEnvironment != "AZURE" ]; then    
        fatalError "$g_prog.run(): platformEnvironment=AZURE is the only valid setting currently"
    fi

    fixSwap
    installRPMs 
    addGroups
    addUsers
    addLimits
    addPam
    addSysctlConfig
    allocateStorage
    restartUdev
    makeFolders
    setOraInstLoc
    sshConfig
    gridProfile
    oracleProfile
    mountMedia
    installGridHome
    gridConfigTool
    createRECOdiskgroup
    installOracleHome
    updateOpatch
    jan2017psu
    jan2017psuoracle
    createCDB
    createPDB
    rebuildRedoLogs
    enableArchiveLog
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

