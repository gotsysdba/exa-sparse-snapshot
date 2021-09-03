#!/bin/env ksh
#------------------------------------------------------------------------------
# GLOBAL/DEFAULT VARS
#------------------------------------------------------------------------------
typeset -i  RC=0
typeset -r  IFS_ORIG=$IFS
typeset -rx SCRIPT_NAME="${0##*/}"
typeset -r  HOST=$(hostname -s)
typeset -ru NOW=$(date +%d%h%y%H%M)

#------------------------------------------------------------------------------
# LOCAL FUNCTIONS
#------------------------------------------------------------------------------
function usage {
	# Required Usage Function
	print "${SCRIPT_NAME} Usage"
	print "\t\t${SCRIPT_NAME} -a <Test Master>"
	return 0
}

function run_sql {
	typeset -r _SQL=$1
	typeset -r _SPOOL=${2:-OFF}
	typeset -i _RC=0

	#print -- "Running ${_SQL}"
	if [[ ${_SPOOL} != "OFF" ]]; then
		print -- "Spooling to ${_SPOOL}"
		${ORACLE_HOME}/bin/sqlplus -s / as sysdba <<-EOSQL1 >/dev/null 2>&1
			set newpage 0 linesize 999 pagesize 0 feedback off heading off
			set echo off space 0 tab off trimspool on
			whenever sqlerror exit 1
			spool ${_SPOOL}
			${_SQL}
		EOSQL1
	else
		${ORACLE_HOME}/bin/sqlplus -s / as sysdba <<-EOSQL2
			set newpage 0 linesize 999 pagesize 0 feedback off heading off
			set echo off space 0 tab off trimspool on
			whenever sqlerror exit 1
			${_SQL}
		EOSQL2
	fi
	_RC=$?

	return ${_RC}
}

function run_dgmgrl {
	typeset -n _DGMGRL_OUT=$1
	typeset -r _CMD=$2
	typeset -i _RC=0

	print -- "Running: dgmgrl -silent / \"${_CMD}\""
	${ORACLE_HOME}/bin/dgmgrl -silent / "${_CMD}" | while read _DGMGRL_OUT; do
		case ${_DGMGRL_OUT} in
			"ORA-01034"* )	print -- "${_DGMGRL_OUT}"; _RC=1 ;;
			"ORA-12162"* )	print -- "${_DGMGRL_OUT}"; _RC=1 ;;
			"Error:"* )		print -- "${_DGMGRL_OUT}"; _RC=1 ;;
			* )				print -- "${_DGMGRL_OUT}" ;;
		esac
	done
	return ${_RC}
}

function run_srvctl {
	typeset -r  _CMD=$1
	typeset -i  _RC=0

	print -- "Running: ${ORACLE_HOME}/bin/srvctl ${_CMD}"
	${ORACLE_HOME}/bin/srvctl ${_CMD} | while read _SRVCTL_OUT; do
		case ${_SRVCTL_OUT} in
			"PRCC-1016"* )  print -- "${_SRVCTL_OUT}"; _RC=0; break ;; # stopped on stop request
			"PRCC-1014"* )	print -- "${_SRVCTL_OUT}"; _RC=0; break ;; # started on start request
			"PRKO-3116"* )	print -- "${_SRVCTL_OUT}"; _RC=1 ;;
			"PRCD"* )       print -- "${_SRVCTL_OUT}"; _RC=1 ;;
			* )				print -- "${_SRVCTL_OUT}" ;;
		esac
	done
	return ${_RC}
}

#------------------------------------------------------------------------------
# INIT
#------------------------------------------------------------------------------
while getopts :a:b:c:h args; do
	case $args in
		a) typeset -ru MYTESTMASTER="$OPTARG" ;;
		b) typeset -r  MYSPARSE_DIR="$OPTARG" ;;
		c) typeset -ru MYDSTDG="$OPTARG" ;;
		h) usage ;;
	esac
done
shift $((OPTIND-1));

if [[ -z ${MYTESTMASTER} || ${MYSPARSE_DIR} ]]; then
	usage && exit 1
fi

# Add a + to the MYSPARSE_DIR if not provided during input
typeset DSTDG="+${MYDSTDG#+}"

if [[ ! -r /etc/oracle/olr.loc ]]; then
	print -- "Unable to find the GI Home" && exit 1
fi

if [[ -z ${MYSPARSE_DIR} ]]; then
	typeset SPARSE_DIR=$(mktemp -d)
else
	typeset SPARSE_DIR=${MYSPARSE_DIR}
fi
typeset -r SPARSE_DIR=${SPARSE_DIR}/${MYTESTMASTER}
mkdir -p ${SPARSE_DIR}
print -- "Storing files ${SPARSE_DIR}"
#------------------------------------------------------------------------------
# MAIN
#------------------------------------------------------------------------------
# Set the GI Home for crsctl calls
typeset -r CRS_HOME=$(grep -e '^crs_home=' /etc/oracle/olr.loc |awk -F= '{print $2}')
typeset -x PATH=$PATH:$CRS_HOME/bin

# Pull out info for MYTESTMASTER to set database environment
print -- "Running: ${CRS_HOME}/bin/crsctl status resource -f -w \"((TYPE = ora.database.type) AND (DB_UNIQUE_NAME = ${MYTESTMASTER}) AND (LAST_SERVER = ${HOST}))\""
${CRS_HOME}/bin/crsctl status resource -f -w "((TYPE = ora.database.type) AND (DB_UNIQUE_NAME = ${MYTESTMASTER}) AND (LAST_SERVER = ${HOST}))" |
while IFS="=" read KEY VALUE; do
	case ${KEY} in
		ORACLE_HOME)    		typeset -r DB_HOME=${VALUE} ;;
		DB_UNIQUE_NAME) 		typeset -r DB_UNIQUE_NAME=${VALUE} ;;
		DATABASE_TYPE)			typeset -r DB_TYPE=${VALUE} ;;
		GEN_USR_ORA_INST_NAME)	typeset -r INSTANCE_NAME=${VALUE} ;;
	esac
done
if [[ -z ${DB_UNIQUE_NAME} ]] || [[ -z ${DB_HOME} ]]; then
	print -- "Unable to find ${MYTESTMASTER} in CRS; unable to continue"
	exit 1
fi

typeset -x ORACLE_SID=${INSTANCE_NAME:-UNKNOWN}
typeset -x ORACLE_HOME=${DB_HOME}
typeset -x PATH=$ORACLE_HOME/bin:$PATH
print -- "Found ${ORACLE_SID} running in ${ORACLE_HOME}"
print -- "####################################################################"
print -- "# Preparing Cloning Files"
print -- "####################################################################"
#Stop the Apply
run_dgmgrl "THROWAWAY" "show configuration;"
# We assume that the Standby Da
run_dgmgrl "THROWAWAY" "edit database '${DB_UNIQUE_NAME}' set state='APPLY-OFF';"
RC=$?
if (( RC > 0 )); then
	print -- "Error stopping the Apply Process; unable to continue"
	exit 1
fi
#------------------------------------------------------------------------------
# Prepare Required Files
#------------------------------------------------------------------------------
# Backup Controlfile of currently running TM
typeset -r CONTROL_FILE="${SPARSE_DIR}/control_${NOW}.ctl" 
run_sql "ALTER DATABASE BACKUP CONTROLFILE TO '${CONTROL_FILE}';" "OFF"

# Create PFILE
typeset -r PFILE_FILE="${SPARSE_DIR}/pfile_${NOW}.ora" 
run_sql "CREATE PFILE='${PFILE_FILE}' from SPFILE;" "OFF"
# Determine current db_create_file_dest
if [[ ! -f ${PFILE_FILE} ]]; then
	print -- "Failed to create pfile ${PFILE_FILE}"
	exit 1
fi
SRCDG=$(grep "db_create_file_dest=" ${PFILE_FILE} |awk -F\' '{print $2}')
if [[ -z ${SRCDG} ]]; then
	print -- "Failed to determine the db_create_file_dest"
	exit 1
fi
print -- "Source Diskgroup: ${SRCDG}"

# Generate ASM Ownership Script
typeset -r OWNER_FILE="${SPARSE_DIR}/asm_set_owner_${NOW}.sql"
typeset -r OWNER_SQL="select 'ALTER DISKGROUP ${SRCDG} set ownership owner='||
						''''||'oracle'||''''||' for file '||''''||name||''''||';' 
				   from v\$datafile;"
run_sql "${OWNER_SQL}" "${OWNER_FILE}" 

# Generate ASM MKDIR Script (note in mount, so no with cluase)
typeset -r MKDIR_FILE="${SPARSE_DIR}/asm_mkdir_${NOW}.sh"
typeset -r MKDIR_SQL="
	SELECT 'asmcmd --nocp --privilege sysdba mkdir '||d.dir||CHR(13)||CHR(10)
	  from 
		(select replace(dir_path,'${SRCDG}/','${DSTDG}/') dir
			from (select distinct dir_level, substr(name,1,regexp_instr(name,'/',1,dir_level)-1) dir_path
					from v\$datafile, 
						(select level dir_level 
							from dual connect by level <= (select max(regexp_count(name,'/')) from v\$datafile))
							where dir_level > 1)
					where dir_path is not null order by dir_level) d;"
run_sql "${MKDIR_SQL}" "${MKDIR_FILE}"
print -- "asmcmd --nocp --privilege sysdba ls -lg ${DSTDG}/${DB_UNIQUE_NAME}/*" >> ${MKDIR_FILE}

# Generate DB Rename Script
typeset -r RENAME_FILE="${SPARSE_DIR}/df_rename_${NOW}.sql"
typeset -r RENAME_SQL="select 'EXECUTE dbms_dnfs.clonedb_renamefile ('||''''||name||''''||
						','||''''||replace(replace(name,'.','_'),'${SRCDG}/','${DSTDG}/')||'_${NOW}'''||
						');' from v\$datafile;"
run_sql "${RENAME_SQL}" "${RENAME_FILE}"
#------------------------------------------------------------------------------
# Start Clone to DST DG
#------------------------------------------------------------------------------
print -- "####################################################################"
print -- "# Starting Cloning Activities"
print -- "####################################################################"
print -- "Creating ASM Directories with ${SPARSE_DIR}/asm_mkdir_${NOW}.sh"
sh ${MKDIR_FILE}

# If a RAC, bring up only one instance in mount
if [[ ${DB_TYPE} == "RAC" ]]; then
	print -- "Stopping ${MYTESTMASTER} (${DB_UNIQUE_NAME})"
	run_srvctl "stop database -d ${DB_UNIQUE_NAME} -o IMMEDIATE"
	RC=$?
	if (( RC > 0 )); then
		print -- "Failed to Stop ${MYTESTMASTER} (${DB_UNIQUE_NAME})"
		exit 1
	fi

	# Startup Single Instance
	print -- "Starting ${ORACLE_SID} in MOUNT"
	run_sql "startup mount"
fi

print -- "Running SQL> alter system set standby_file_management='MANUAL';"
run_sql "alter system set standby_file_management='MANUAL';"
print -- "Running SQL> alter system set db_create_file_dest='${DSTDG}';"
run_sql "alter system set db_create_file_dest='${DSTDG}';"
print -- "Running SQL> @${RENAME_FILE}"
run_sql "@${RENAME_FILE}"
RC=$?
run_sql "alter system set standby_file_management='AUTO';"

if [[ ${DB_TYPE} == "RAC" ]]; then
	# Shutdown Single Instance
	print -- "Stopping ${ORACLE_SID}"
	run_sql "shutdown abort"

	print -- "Starting ${MYTESTMASTER} (${DB_UNIQUE_NAME})"
	run_srvctl "start database -d ${DB_UNIQUE_NAME} -o MOUNT"
	RC=$?
	if (( RC > 0 )); then
		print -- "Failed to Start ${MYTESTMASTER} (${DB_UNIQUE_NAME})"
		exit 1
	fi
	# Allow the DG Broker to start
	sleep 30
fi

#Start the Apply
run_dgmgrl "THROWAWAY" "edit database '${DB_UNIQUE_NAME}' set state='APPLY-ON';"
print -- "Exiting: ${RC}"
exit ${RC}