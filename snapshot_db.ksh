#!/bin/env ksh
#------------------------------------------------------------------------------
# GLOBAL/DEFAULT VARS
#------------------------------------------------------------------------------
typeset -i  RC=0
typeset -r  IFS_ORIG=$IFS
typeset -rx SCRIPT_NAME="${0##*/}"
typeset -r  HOST=$(hostname -s)

#------------------------------------------------------------------------------
# LOCAL FUNCTIONS
#------------------------------------------------------------------------------
function usage {
	# Required Usage Function
	print "${SCRIPT_NAME} Usage"
	print "\t\t${SCRIPT_NAME} -a <Test Master>"
	return 0
}

function create_pfile {
	typeset -r _PFILE=$1
	typeset -r _CONTROL=$2
	typeset -r _SNAP=$3
	typeset -r _PRIMARY=$4
	typeset -r _RC=0


	cat <<- EOF > ${_PFILE}
		control_files='${_CONTROL}'
		db_name=${_PRIMARY}
		db_unique_name=${_SNAP}
		sga_target=5g
	EOF

	return ${_RC}
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
#------------------------------------------------------------------------------
# INIT
#------------------------------------------------------------------------------
while getopts :a:b:c:d:h args; do
	case $args in
		a) typeset -ru MYTESTMASTER="$OPTARG" ;;
		b) typeset -r  MYSPARSE_DIR="$OPTARG" ;;
		c) typeset -ru MYDATE="$OPTARG" ;;
		d) typeset -ru MYSNAPSHOT="$OPTARG" ;;
		h) usage ;;
	esac
done
shift $((OPTIND-1));

if [[ -z ${MYTESTMASTER} || -z ${MYSPARSE_DIR} || -z ${MYDATE} ]]; then
	usage && exit 1
fi

typeset -r SPARSE_DIR=${MYSPARSE_DIR}/${MYTESTMASTER}
typeset -r WORKING_DIR=${MYSPARSE_DIR}/${MYSNAPSHOT}
if [[ ! -d ${SPARSE_DIR} ]]; then
	print -- "Unable to find ${SPARSE_DIR}"
	exit 1
fi

print -- "Using files in ${SPARSE_DIR} and ${WORKING_DIR}"
cp -R ${SPARSE_DIR} ${WORKING_DIR}
typeset -r CONTROL_FILE="${WORKING_DIR}/control_${MYDATE}.ctl"
if [[ ! -f ${CONTROL_FILE} ]]; then
	print -- "Unable to find ${CONTROL_FILE}"
	exit 1
fi
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
		ORACLE_HOME)	typeset -r DB_HOME=${VALUE} ;;
		DB_NAME)		typeset -r PRIMARY=${VALUE} ;;
	esac
done
if [[ -z ${PRIMARY} ]] || [[ -z ${DB_HOME} ]]; then
	print -- "Unable to find ${MYTESTMASTER} in CRS; unable to continue"
	exit 1
fi

typeset -r PFILE="${WORKING_DIR}/pfile_${MYSNAPSHOT}.ctl"
create_pfile "${PFILE}" "${CONTROL_FILE}" "${MYSNAPSHOT}" "${PRIMARY}" 

export ORACLE_SID=${MYSNAPSHOT}
export ORACLE_HOME=${DB_HOME}
print -- "Running SQL> startup mount pfile='${PFILE}'"
run_sql "startup mount pfile='${PFILE}'"



print -- "Exiting: ${RC}"
exit ${RC}